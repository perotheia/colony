#!/usr/bin/env bash
# test/opkg-mender/run.sh — regression test for the Mender client on OPKG (TI Arago) rigs, no board needed.
#
#   0. resource guard: free memory > 8 GB, disk < 90 %
#   1. ansible --syntax-check of ansible/provision.yml (+ this test's play)
#   2. a container that imitates Arago (no apt-get/dpkg, opkg stub, systemctl stub that records calls) and a fake
#      S3 plane (plain http, a second container) staged by tools/publish-mender-client.sh --stage with the REAL
#      cross-built tarball and the version + sha256 PINNED in ansible/inventory/hosts
#   3. runs the production tasks (rig-class, install-mender-opkg, mender-enroll) through play.yml and checks:
#        a. without the test var, a plain-http rig URL is REFUSED (TLS + CA required)
#        b. first run: files in place with the right modes, MANIFEST check ran, systemctl got daemon-reload,
#           reload dbus, enable --now mender-authd mender-updated; mender.conf carries ArtifactVerifyKey
#        c. second run: changed=0, no new systemctl reload/enable
#        d. a wrong pinned sha256 fails the play (the controller's index check)
#        e. a tampered installed binary is detected and repaired, then the next run is idle again
#        f. a swapped object in the plane (index + pin intact) fails the play at the rig's sha256 check
#   4. removes every container / network / image it created
#
# Usage: test/opkg-mender/run.sh [--keep]
# Env:   MENDER_CLIENT_TGZ  the tarball (default /bigdata/work/architect/mender-sk/out/mender-client-<ver>.tar.gz)
#        ANSIBLE_VENV       venv with ansible-core + community.docker (default /bigdata/work/architect/venvs/ansible;
#                           created when missing)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1
VENV="${ANSIBLE_VENV:-/bigdata/work/architect/venvs/ansible}"
TAG="colony-opkg-mender-rig:test"
ID="$$"; RIG="colony-opkg-rig-$ID"; S3C="colony-opkg-s3-$ID"; NET="colony-opkg-net-$ID"
WORK="$(mktemp -d)"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
rig()  { docker exec "$RIG" sh -c "$1"; }

cleanup() {
  if [ "$KEEP" = 1 ]; then echo "[keep] $RIG $S3C $NET $TAG $WORK"; return; fi
  docker rm -f "$RIG" "$S3C" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker rmi "$TAG" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── 0. resources ──────────────────────────────────────────────────────────────────────────────────────────────────
avail_g=$(free -g | awk '/^Mem:/ {print $7}')
disk_pc=$(df --output=pcent / | tail -1 | tr -dc 0-9)
echo "[res] available memory ${avail_g} GB, disk ${disk_pc} %"
[ "$avail_g" -gt 8 ] || { echo "refusing: available memory ${avail_g} GB <= 8 GB" >&2; exit 2; }
[ "$disk_pc" -lt 90 ] || { echo "refusing: disk ${disk_pc} % >= 90 %" >&2; exit 2; }

# ── pins (the test runs what inventory/hosts pins) ───────────────────────────────────────────────────────────────────
pin() { sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$REPO/ansible/inventory/hosts" | head -1; }
VER="$(pin mender_client_opkg_version)"; SHA="$(pin mender_client_opkg_sha256)"
[ -n "$VER" ] && [ -n "$SHA" ] || { echo "no mender_client_opkg_{version,sha256} in inventory/hosts" >&2; exit 1; }
TGZ="${MENDER_CLIENT_TGZ:-/bigdata/work/architect/mender-sk/out/mender-client-$VER.tar.gz}"
[ -f "$TGZ" ] || { echo "tarball not found: $TGZ (set MENDER_CLIENT_TGZ)" >&2; exit 1; }
echo "[pin] $VER sha256=$SHA"

# ── venv ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
if [ ! -x "$VENV/bin/ansible-playbook" ]; then
  echo "[venv] creating $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q "ansible-core>=2.16,<2.19" docker requests
fi
[ -d "$VENV/collections/ansible_collections/community/docker" ] \
  || "$VENV/bin/ansible-galaxy" collection install -p "$VENV/collections" community.docker >/dev/null
export ANSIBLE_COLLECTIONS_PATH="$VENV/collections" ANSIBLE_NOCOLOR=1 ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_RETRY_FILES_ENABLED=False ANSIBLE_PYTHON_INTERPRETER=/usr/bin/python3

# ── 1. syntax ───────────────────────────────────────────────────────────────────────────────────────────────────────
echo "[1] syntax check"
check "provision.yml syntax" sh -c "cd '$REPO/ansible' && THEIA_S3_ENDPOINT=http://syntax.invalid:9000 \
  '$VENV/bin/ansible-playbook' --syntax-check provision.yml -e target=syntax >'$WORK/syntax.log' 2>&1"
check "test play syntax" sh -c "'$VENV/bin/ansible-playbook' -i 'opkg-rig,' --syntax-check '$HERE/play.yml' \
  >>'$WORK/syntax.log' 2>&1"
[ "$FAIL" = 0 ] || { cat "$WORK/syntax.log"; exit 1; }

# ── 2. fixtures: image, fake plane, containers ───────────────────────────────────────────────────────────────────
echo "[2] build the Arago-like image + stage the fake plane"
docker build -q -t "$TAG" "$HERE" >/dev/null
PLANE="$WORK/plane"; OTA="$WORK/ota"
"$REPO/tools/publish-mender-client.sh" --stage "$PLANE" "$TGZ" "$SHA" >/dev/null
mkdir -p "$PLANE/theia-runtime/provisioning" "$OTA/modules" "$OTA/state-scripts"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$WORK/verify.key" 2>/dev/null
openssl pkey -in "$WORK/verify.key" -pubout -out "$PLANE/theia-runtime/provisioning/artifact-verify-key.pem"
for m in theia-swp theia-app theia-release; do printf '#!/bin/sh\n# test stub %s\nexit 0\n' "$m" > "$OTA/modules/$m"; done
printf '#!/bin/sh\nexit 0\n' > "$OTA/state-scripts/ArtifactInstall_Leave_01_ucm-request"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=docker.mender.test -days 1 \
  -keyout "$WORK/server.key" -out "$WORK/server.crt" 2>/dev/null
chmod -R a+rX "$PLANE"

docker network create "$NET" >/dev/null
docker run -d --name "$S3C" --network "$NET" --network-alias fake-s3 --memory 256m \
  -v "$PLANE:/srv:ro" -w /srv "$TAG" python3 -m http.server 8080 >/dev/null
docker run -d --name "$RIG" --network "$NET" --memory 512m "$TAG" >/dev/null
S3IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$S3C")"
for _ in $(seq 1 20); do curl -fsS "http://$S3IP:8080/" >/dev/null 2>&1 && break; sleep 0.5; done

printf 'opkg-rig ansible_connection=community.docker.docker ansible_host=%s\n' "$RIG" > "$WORK/inventory"
play() {   # play <log> [extra ansible args...]
  local log="$1"; shift
  "$VENV/bin/ansible-playbook" -i "$WORK/inventory" "$HERE/play.yml" \
    -e "s3_endpoint=http://$S3IP:8080" -e "s3_rig_endpoint=http://fake-s3:8080" -e s3_rig_ca= \
    -e s3_runtime_bucket=theia-runtime \
    -e "mender_client_opkg_version=$VER" -e "mender_client_opkg_sha256=$SHA" \
    -e "mender_artifacts_dir=$OTA" \
    -e mender_server_host=docker.mender.test -e mender_server_ip=10.99.0.1 -e "mender_server_ca=$WORK/server.crt" \
    "$@" >"$log" 2>&1 && rc=0 || rc=$?
  grep -qE '^opkg-rig +:' "$log" || { echo "  (no play recap for opkg-rig in $log)"; return 1; }
  return "$rc"
}
recap() { grep -E '^opkg-rig +:' "$1"; }
changed() { recap "$1" | sed -E 's/.*changed=([0-9]+).*/\1/'; }
TESTVAR=(-e mender_opkg_test_container=true)

# ── 3a. plain http refused without the test var ─────────────────────────────────────────────────────────────────────
echo "[3a] plain-http rig URL without the test var"
if play "$WORK/run-notls.log"; then bad "plain http accepted without mender_opkg_test_container"; else
  check "refused: TLS + CA required" grep -q "fetches the Mender client over the gateway's TLS" "$WORK/run-notls.log"
  check "nothing unpacked" rig '! test -e /usr/bin/mender-update'
fi

# ── 3b. first run ───────────────────────────────────────────────────────────────────────────────────────────────────
echo "[3b] first run"
if play "$WORK/run1.log" "${TESTVAR[@]}"; then ok "first run green ($(recap "$WORK/run1.log" | tr -s ' '))"; else
  bad "first run failed"; tail -40 "$WORK/run1.log"; exit 1; fi
check "manifest check ran (all files OK)" grep -q 'MANIFEST_CHECK=ok:' "$WORK/run1.log"
mode() { rig "stat -c %a '$1'"; }
for f in /usr/bin/mender-update /usr/bin/mender-auth /usr/share/mender/modules/v3/directory \
         /usr/share/mender/modules/v3/single-file /usr/share/mender/modules/v3/theia-swp \
         /usr/share/mender/modules/v3/theia-app /usr/share/mender/modules/v3/theia-release \
         /usr/share/mender/identity/mender-device-identity /etc/mender/scripts/ArtifactInstall_Leave_01_ucm-request; do
  check "$f 755" test "$(mode "$f")" = 755
done
for f in /usr/lib/systemd/system/mender-authd.service /usr/lib/systemd/system/mender-updated.service \
         /usr/share/dbus-1/system.d/io.mender.AuthenticationManager.conf \
         /usr/share/dbus-1/system-services/io.mender.AuthenticationManager.service \
         /etc/mender/artifact_info /var/lib/mender/device_type /etc/mender/artifact-verify-key.pem \
         /etc/mender/server.crt; do
  check "$f 644" test "$(mode "$f")" = 644
done
check "/etc/mender 755"               test "$(mode /etc/mender)" = 755
check "/var/lib/mender 700"           test "$(mode /var/lib/mender)" = 700
check "/usr/share/mender/inventory 755" test "$(mode /usr/share/mender/inventory)" = 755
check "/etc/mender/mender.conf 600"   test "$(mode /etc/mender/mender.conf)" = 600
check "mender.conf: ArtifactVerifyKey + ServerURL" rig \
  'grep -q "\"ArtifactVerifyKey\": \"/etc/mender/artifact-verify-key.pem\"" /etc/mender/mender.conf &&
   grep -q "\"ServerURL\": \"https://docker.mender.test\"" /etc/mender/mender.conf'
check "mender.conf is valid JSON" rig 'python3 -c "import json; json.load(open(\"/etc/mender/mender.conf\"))"'
check "identity = the rig name" rig 'sh /usr/share/mender/identity/mender-device-identity | grep -qx device_id=opkg-rig'
check "verify key is the plane's" sh -c "docker exec $RIG cat /etc/mender/artifact-verify-key.pem \
  | cmp -s - '$PLANE/theia-runtime/provisioning/artifact-verify-key.pem'"
check "COLONY_MENDER_PUBKEY = the rig's key" bash -c "grep -o 'COLONY_MENDER_PUBKEY opkg-test [A-Za-z0-9+/=]*' \
  '$WORK/run1.log' | head -1 | cut -d' ' -f3 | base64 -d | cmp -s - <(docker exec $RIG openssl pkey -in /var/lib/mender/mender-agent.pem -pubout)"
check "marker = pinned sha256" test "$(rig 'cat /usr/share/mender-client-arago/.colony-installed')" = "$SHA"
check "no download left behind" rig '! ls /var/tmp/mender-client-arago.tar.gz* >/dev/null 2>&1'
LOG=/var/log/systemctl-stub.log
check "systemctl daemon-reload"         rig "grep -qx 'daemon-reload' $LOG"
check "systemctl reload dbus"           rig "grep -qx 'reload dbus' $LOG"
check "systemctl enable --now both"     rig "grep -qx 'enable --now mender-authd mender-updated' $LOG"
check "reload dbus before enable --now" rig "a=\$(grep -nx 'reload dbus' $LOG | cut -d: -f1); \
  b=\$(grep -nx 'enable --now mender-authd mender-updated' $LOG | cut -d: -f1); [ -n \"\$a\" ] && [ -n \"\$b\" ] && [ \$a -lt \$b ]"
mut() { rig "grep -cvE '^is-(enabled|active) ' $LOG"; }
M1="$(mut)"

# ── 3c. second run changes nothing ──────────────────────────────────────────────────────────────────────────────────
echo "[3c] second run"
if play "$WORK/run2.log" "${TESTVAR[@]}"; then
  check "second run changed=0 ($(recap "$WORK/run2.log" | tr -s ' '))" test "$(changed "$WORK/run2.log")" = 0
  check "second run skipped download/unpack" grep -q 'MANIFEST_CHECK=skipped STATE=installed' "$WORK/run2.log"
  check "no new systemctl reload/enable" test "$(mut)" = "$M1"
else bad "second run failed"; tail -30 "$WORK/run2.log"; fi

# ── 3d. a wrong pinned sha256 fails ─────────────────────────────────────────────────────────────────────────────────
echo "[3d] wrong pinned sha256"
WRONG="$(printf '%s' "$SHA" | tr '0-9a-f' '1-9a-f0')"
if play "$WORK/run-wrongpin.log" "${TESTVAR[@]}" -e "mender_client_opkg_sha256=$WRONG"; then
  bad "wrong pinned sha256 accepted"
else check "wrong pin fails at the index check" grep -q 'inventory pins' "$WORK/run-wrongpin.log"; fi

# ── 3e. a tampered binary is detected (marker present, manifest fails) and repaired ─────────────────────────
echo "[3e] tampered binary"
rig 'printf x >> /usr/bin/mender-auth'
if play "$WORK/run-repair.log" "${TESTVAR[@]}"; then
  check "tamper detected (STATE=damaged)" grep -q 'STATE=damaged' "$WORK/run-repair.log"
  check "re-fetched + manifest re-checked" grep -q 'MANIFEST_CHECK=ok:' "$WORK/run-repair.log"
  check "mender-auth restored" rig 'cd / && grep " usr/bin/mender-auth$" /usr/share/mender-client-arago/MANIFEST.sha256 | sha256sum -c - >/dev/null'
  play "$WORK/run-repair2.log" "${TESTVAR[@]}" && check "and the next run is idle again" test "$(changed "$WORK/run-repair2.log")" = 0
else bad "repair run failed"; tail -30 "$WORK/run-repair.log"; fi

# ── 3f. a swapped object in the plane fails at the rig's sha256 check, nothing unpacked ─────────────────────────────
echo "[3f] swapped object in the plane"
OBJ="$PLANE/theia-runtime/mender-client/$VER/mender-client-$VER.tar.gz"
cp "$OBJ" "$WORK/obj.orig"; printf 'swapped' >> "$OBJ"
rig 'rm -f /usr/share/mender-client-arago/.colony-installed; touch -d 2000-01-01 /usr/bin/mender-auth'
if play "$WORK/run-swapped.log" "${TESTVAR[@]}"; then bad "swapped object accepted"; else
  check "swap fails at the rig's sha256 check" grep -q 'sha256 mismatch' "$WORK/run-swapped.log"
  check "nothing unpacked (mender-auth untouched)" rig 'test "$(stat -c %Y /usr/bin/mender-auth)" -lt 1000000000'
  check "the bad download was deleted" rig '! ls /var/tmp/mender-client-arago.tar.gz* >/dev/null 2>&1'
fi
cp "$WORK/obj.orig" "$OBJ"

echo "[done] PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || { echo "logs: $WORK (kept with --keep)"; exit 1; }
