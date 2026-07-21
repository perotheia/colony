#!/usr/bin/env bash
# run-migration-e2e.sh — OTA CONFIG-MIGRATION end-to-end (P3 of theia's
# docs/tasks/PROGRESS/ota-config-migration.md), hermetic on docker compose.
#
# Proves the full chain on a provisioned board:
#
#   scaffold ws (ci seed) → dist → provision+orchestrate central (v1 running)
#   → enroll → seed a NON-DEFAULT CounterConfig v1 value in per
#   → release-swp 1.0.0 --s3            (publishes schema.json v1 — the gate's FROM)
#   → evolve the .art (max_value→ceiling + warn_at)                    [v2]
#   → release-swp 2.0.0 --migrate       (gate pulls v1 schema FROM S3; plugin
#                                        cross-built + packed in the .mender)
#   → Mender deploy v2 → theia-swp module runs 00-migrate-config.py on-board
#   → ASSERT: digest flipped v1→v2, ceiling CARRIES the seeded value,
#             warn_at at its default, snapshot 'pre-<artifact>' exists
#   → driver --rollback on-board → ASSERT config back at v1 (value intact).
#
# Unlike run-e2e.sh this scaffolds a FRESH consuming workspace from theia's
# ci/demo seed (the committed demo/ workspace is retired), single-board
# (central only; compute stays idle). Uses the HOST-NETWORK migration compose
# (docker-compose.migration.yml): the board shares the host net + TIPC namespace
# (E2E_TIPC_NETID), so config asserts drive per DIRECTLY from the host venv probe,
# Mender is https://127.0.0.1 and S3 is the standing gs-minio:9000. Reuses the
# Mender server bring-up, colony provisioning (registry-free --host/--role) and the
# fleet.py deploy helper.
#
#   ./run-migration-e2e.sh              full run
#   ./run-migration-e2e.sh --keep       leave the stack up
#   ./run-migration-e2e.sh --no-build   reuse the ws dist from a prior run
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"

THEIA_DIR="${THEIA_DIR:-$(cd "$HERE/../../../theia" && pwd)}"
COLONY_DIR="${COLONY_DIR:-$(cd "$HERE/../.." && pwd)}"
GROUND_STATION_DIR="${GROUND_STATION_DIR:-$(cd "$HERE/../../../ground-station" && pwd)}"
export THEIA_DIR COLONY_DIR GROUND_STATION_DIR
COMPOSE="docker compose -f $HERE/docker-compose.yml"
SERVER_DIR="${MENDER_SERVER_DIR:-$HOME/mender-server}"
MENDER_EMAIL="admin@docker.mender.io"; MENDER_PASS="password123"
# The package plane: dalek's standing MinIO (gs-minio) — the same S3 the GS
# catalog reads. The gate's FROM-schema fetch exercises the real S3 path.
S3="${S3:-http://127.0.0.1:9000}"; export MINIO_USER=theia MINIO_PASSWORD=theiaminio
FLEET="theia-rig"
# TIPC netid (cluster id) for THIS run's namespace — board (host net) + the
# host-side probe asserts share it. Non-default so a dev `theia start` /
# another rig on a TIPC bearer at 4711 can't cross-talk with the e2e.
# Configurable: E2E_TIPC_NETID=n ./run-migration-e2e.sh
E2E_TIPC_NETID="${E2E_TIPC_NETID:-4747}"
# The consuming workspace this run scaffolds (fresh unless --no-build).
WS="$HERE/work/migration-ws"
KEEP=0; DO_BUILD=1
for a in "$@"; do case "$a" in --keep) KEEP=1;; --no-build) DO_BUILD=0;; esac; done

export PATH="$THEIA_DIR/.venv/bin:$PATH"
export THEIA_ROOT="$THEIA_DIR"
export ARTIFACT_COMPRESS=gzip

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; dump_logs; exit 1; }
dump_logs() { mkdir -p "$HERE/logs"; for c in ota-central ota-controller; do
  docker exec "$c" journalctl --no-pager >"$HERE/logs/$c.migration.journal" 2>&1 || true; done
  echo "--- board ps ---";  docker exec ota-central ps -eo pid,args 2>/dev/null | grep -v "\]$" | head -30 || true
  echo "--- supervisor.log tail ---"
  docker exec ota-central sh -c 'tail -40 /var/log/theia-supervisor.log 2>/dev/null; tail -40 /opt/theia/install/central/supervisor.log 2>/dev/null' || true
  echo "--- /opt/theia ---"; docker exec ota-central sh -c 'ls /opt/theia /opt/theia/current 2>/dev/null' || true; }
cleanup() { [ -n "${SIGNDIR:-}" ] && rm -rf "$SIGNDIR" 2>/dev/null || true
  [ "$KEEP" = 1 ] && { log "--keep: stack left up"; return; }
  log "teardown"; $COMPOSE down -v --remove-orphans 2>/dev/null || true
  ( cd "$SERVER_DIR" 2>/dev/null && docker compose down 2>/dev/null ) || true; }
trap cleanup EXIT

ctl()  { docker exec ota-controller bash -lc "$*"; }
bexec(){ docker exec ota-central sh -c "$*"; }
# config get/put via the HOST venv probe — host net shares the theia netid,
# so per is directly reachable (raw bytes; encode/decode also host-side).
VPY="$THEIA_DIR/.venv/bin/python"
bcfg() { THEIA_ROOT="$THEIA_DIR" "$VPY" "$HERE/helpers/board-config.py" "$@"; }

# colony verb via the controller (test registry, THIS ws's manifest)
CENV="THEIA_WORKSPACE=/repo/ws COLONY_ANSIBLE=/repo/colony/ansible COLONY_REGISTRY=/repo/colony/test/ota-e2e/registry"
MAN="/repo/ws/dist/manifest"
colony() { ctl "$CENV /repo/colony/bin/colony $1 $2 -e manifest_dir=$MAN ${3:-}"; }

# host-side proto codec: encode/decode CounterConfig via the ws venv probe codec
enc_counter() {  # $1..: field=value → hex on stdout
  "$VPY" - "$@" <<'PY'
import sys
sys.path.insert(0, __import__('os').environ['THEIA_DIR'] + '/artheia')
from artheia.gen_server.probe.codec import Codec
c = Codec(__import__('os').environ['WS'] + '/proto')
fields = {}
for kv in sys.argv[1:]:
    k, v = kv.split('=', 1)
    fields[k] = (v == 'true') if v in ('true','false') else (int(v) if v.lstrip('-').isdigit() else v)
print(c.encode('system.apps', 'system_apps_CounterConfig', **fields).hex())
PY
}
dec_counter() {  # hex on argv → json on stdout
  "$VPY" - "$1" <<'PY'
import sys, json
sys.path.insert(0, __import__('os').environ['THEIA_DIR'] + '/artheia')
from artheia.gen_server.probe.codec import Codec
c = Codec(__import__('os').environ['WS'] + '/proto')
d = c.decode('system.apps', 'system_apps_CounterConfig', bytes.fromhex(sys.argv[1]))
print(json.dumps({k: (v if not isinstance(v, bytes) else v.hex()) for k, v in d.items()}))
PY
}
export WS

digest_of() {  # $1=schema.json $2=config_type
  python3 -c "import json,sys; print(json.load(open('$1'))['configs']['$2']['digest'])"
}

###############################################################################
log "PHASE 0 — scaffold the ws (ci seed) + build + dist"
###############################################################################
if [ "$DO_BUILD" = 1 ]; then
  rm -rf "$WS"; mkdir -p "$WS"
  ( cd "$WS" \
    && THEIA_INVOCATION_CWD="$WS" theia init --kind ws --name apps --with-services >/dev/null 2>&1 \
    && cp "$THEIA_DIR"/ci/demo/system-apps/*.art system/apps/ \
    && ( cd "$THEIA_DIR/ci/demo/impl" && find . -type f ) | while read -r f; do
         mkdir -p "$WS/apps/$(dirname "$f")"; cp "$THEIA_DIR/ci/demo/impl/$f" "$WS/apps/$f"; done \
    && artheia gen-fc system/apps/component.art >/dev/null \
    && artheia gen-manifest system/apps/component.art manifest/apps/manifest.py >/dev/null ) \
    || die "ws scaffold failed"
  ( cd "$WS" && theia manifest apps >/dev/null ) || die "theia manifest failed"
  # nm must not reconfigure a shared-net container's iface (same guard run-e2e uses)
  python3 - "$WS/dist/manifest/central/executor.json" <<'PY'
import json, sys
p = sys.argv[1]; t = json.load(open(p))
def patch(n):
    if n.get("type") == "worker" and n.get("name") == "nm": n["run_on_start"] = False
    for c in n.get("children", []): patch(c)
patch(t); json.dump(t, open(p, "w"), indent=2)
PY
  ( cd "$WS" && theia dist apps ) || die "theia dist failed"
  [ -f "$WS/dist/manifest/central/central.deb" ] \
    || { f="$(find "$WS/dist" "$WS/bazel-bin" -name "central*.deb" 2>/dev/null | head -1)"; \
         [ -n "$f" ] && cp "$f" "$WS/dist/manifest/central/central.deb" || die "no central.deb"; }
  ok "ws built + dist staged"
else
  ok "skip build (--no-build)"
fi

###############################################################################
log "PHASE 1 — prereqs: tipc, Mender server, boards up"
###############################################################################
sudo modprobe tipc 2>/dev/null || modprobe tipc 2>/dev/null || true
# Set the run's netid BEFORE anything binds TIPC (only possible while the
# namespace has no TIPC sockets/bearers — loud when it can't).
CUR_NETID="$(tipc node get netid 2>/dev/null | head -1 | tr -dc '0-9')"
if [ "$CUR_NETID" != "$E2E_TIPC_NETID" ]; then
  if sudo tipc node set netid "$E2E_TIPC_NETID" 2>/dev/null; then
    ok "TIPC netid → $E2E_TIPC_NETID (was ${CUR_NETID:-unset})"
  else
    echo "  ! could not set TIPC netid $E2E_TIPC_NETID (current ${CUR_NETID:-?};"          "TIPC sockets already up — stop other theia stacks first). Continuing"          "on the CURRENT netid; cross-talk with co-netid stacks is possible." >&2
  fi
else
  ok "TIPC netid already $E2E_TIPC_NETID"
fi
# RESET first: mongo/s3 volumes persist; a re-enrolling board otherwise hits
# stale devauth auth-sets ("dev auth: unauthorized" instead of PENDING).
MENDER_SERVER_DIR="$SERVER_DIR" bash "$GROUND_STATION_DIR/mender/server/up.sh" reset
MENDER_SERVER_DIR="$SERVER_DIR" bash "$GROUND_STATION_DIR/mender/server/up.sh" up
MENDER_SERVER_DIR="$SERVER_DIR" bash "$GROUND_STATION_DIR/mender/server/up.sh" user "$MENDER_EMAIL" "$MENDER_PASS" 2>/dev/null || true
ok "mender server up"

# SWP signing: ephemeral keypair; PUBLIC verify key → s3://theia-runtime/
# provisioning/ (provision's install-verify-key pulls it onto the board;
# mender then REFUSES unsigned artifacts — so release-swp must sign, below).
SIGNDIR="$(mktemp -d)"
THEIA_SIGNING_DIR="$SIGNDIR" theia cert generate >/dev/null 2>&1 || die "cert generate failed"
THEIA_SIGNING_DIR="$SIGNDIR" theia cert copy --s3 "$S3" --bucket theia-runtime || die "cert copy failed"
export THEIA_SWP_SIGN_KEY="$SIGNDIR/theia-swp-signing.key"
[ -f "$THEIA_SWP_SIGN_KEY" ] || die "signing key missing after generate"
# dalek's mender-artifact only parses TRADITIONAL (PKCS1) RSA PEM; cert
# generate emits PKCS8. Convert in place (same key, same public half).
openssl rsa -in "$THEIA_SWP_SIGN_KEY" -out "$THEIA_SWP_SIGN_KEY" -traditional 2>/dev/null \
  || openssl rsa -in "$THEIA_SWP_SIGN_KEY" -out "$THEIA_SWP_SIGN_KEY" 2>/dev/null || true
ok "SWP signing key generated; verify key published"
# the controller mounts THIS ws at /repo/ws
export BOARD_BASE="$( . /etc/os-release; echo "${ID:-ubuntu}:${VERSION_ID:-22.04}" )"
export WS_MOUNT="$WS"
COMPOSE="docker compose -f $HERE/docker-compose.migration.yml"
$COMPOSE build
$COMPOSE up -d
okc=0
for i in $(seq 1 40); do
  if ctl "ansible -i 'ota-central,' ota-central -c community.docker.docker -m ping" >/dev/null 2>&1; then
    okc=$((okc+1)); [ "$okc" -ge 2 ] && break        # two consecutive pings = settled
  else okc=0; fi
  sleep 3; [ "$i" = 40 ] && die "docker-conn to central never came up"
done
sleep 10   # let systemd finish its first service storm before ansible facts
# HOST NET: the board reaches the mender server on 127.0.0.1 directly.
TRAEFIK_IP="127.0.0.1"
docker exec ota-central sh -c "grep -q docker.mender.io /etc/hosts || echo '127.0.0.1 docker.mender.io s3.docker.mender.io' >> /etc/hosts" 2>/dev/null || true
ok "board up (host net, shared theia netid); mender at 127.0.0.1"

###############################################################################
log "PHASE 2 — provision + orchestrate central (v1 live)"
###############################################################################
# REGISTRY-FREE deploy (the GS path, same as run-full-story): --host + --role.
# The legacy registry path can't thread ansible_host through the localhost
# resolve-play; --role central keys the manifest slice (this ws's machine name).
# docker test rig: target_connection (NOT ansible_connection) + root login.
DEPLOY="--host ota-central --role central"
DCONN="-e target_connection=community.docker.docker -e ansible_user=root"
# etcd rides the etcd_machine gate — with --role central the default
# ('master') never matches and etcd is SILENTLY skipped; per then crash-loops
# with the misleading "failed to create a watch connection".
DCONN="$DCONN -e machine_instance=0 -e etcd_external=false -e etcd_machine=central -e tipc_netid=$E2E_TIPC_NETID"
RUNSRC="-e theia_run_src=/repo/theia/platform/runtime/ota/theia-run.sh"
colony provision central "$DEPLOY $DCONN -e mender_artifacts_dir=/repo/theia/platform/runtime/ota" \
  || { log "provision retry (board settle)"; sleep 15; \
       colony provision central "$DEPLOY $DCONN -e mender_artifacts_dir=/repo/theia/platform/runtime/ota" \
         || die "provision failed"; }
colony orchestrate central "$DEPLOY $DCONN $RUNSRC -e autostart=true" || die "orchestrate failed"
FCN=0
for i in $(seq 1 20); do
  FCN="$(bexec 'ps -eo args 2>/dev/null | grep -c "/opt/theia/current/bin/[a-z]" || true' | tail -1)"
  [ "${FCN:-0}" -ge 10 ] 2>/dev/null && break
  sleep 6
done
[ "${FCN:-0}" -ge 10 ] 2>/dev/null || die "central FC count ${FCN:-0} < 10 after 120s"
bexec 'ps -eo args | grep -q "/opt/theia/current/bin/p1"' || die "p1 (counter) not running"
ok "central v1 live ($FCN FCs incl. p1)"
# NOTE: the DEVICE runs no python — UcmGate executes the migration in C++.
# (The retired driver-env staging lived here; see the design doc.)
true

###############################################################################
log "PHASE 3 — enroll central"
###############################################################################
cp "$SERVER_DIR/compose/certs/mender.crt" "$GROUND_STATION_DIR/.srv-ca.crt" 2>/dev/null || die "no server CA"
ctl "RIG_EXEC=docker DEVICE_ID=central SERVER_CA=/repo/ground-station/.srv-ca.crt \
     bash /repo/ground-station/mender/server/enroll-rig.sh ota-central $TRAEFIK_IP docker.mender.io $MENDER_EMAIL $MENDER_PASS" \
  >/dev/null || die "enroll failed"
ok "central enrolled"

###############################################################################
log "PHASE 4 — publish SWP v1 (schema v1 → S3) + seed a NON-DEFAULT v1 value"
###############################################################################
( cd "$WS" && theia release-swp apps --swp-version 1.0.0 --fleet "$FLEET" --s3 "$S3" ) \
  || die "release-swp 1.0.0 failed"
SCHEMA_V1="$WS/dist/apps/apps/schema.json"
DIG_V1="$(digest_of "$SCHEMA_V1" CounterConfig)"
ok "v1 published (CounterConfig digest $DIG_V1)"

# seed: step=7 max_value=250 wrap=true label=e2e hysteresis=5 — NOT the defaults,
# so the migration visibly CARRIES data instead of re-defaulting.
HEX_V1="$(enc_counter step=7 max_value=250 wrap=true label=e2e hysteresis=5)"
bcfg put counter "$DIG_V1" "$HEX_V1" || die "seed PutConfig failed"
GOT="$(bcfg get counter)"
echo "$GOT" | grep -q "$DIG_V1" || die "seeded digest readback mismatch: $GOT"
ok "v1 value seeded in per (step=7, max_value=250)"

###############################################################################
log "PHASE 5 — evolve the .art (v2) + gated --migrate release + Mender deploy"
###############################################################################
python3 - "$WS/system/apps/package.art" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "    uint32 max_value  = 100          // saturate at this"
new = ("    uint32 ceiling    = 100          // saturate at this (renamed from max_value)\n"
       "    uint32 warn_at    = 90           // v3: early-warning threshold")
assert old in s, "package.art shape drifted — update the e2e's evolve step"
p.write_text(s.replace(old, new))
PY
( cd "$WS" && artheia gen-fc system/apps/component.art >/dev/null ) || die "regen failed"
# the REVIEWED transform (the gen-migration scaffold flags the tag-shift cascade
# for review; this IS the reviewed result)
mkdir -p "$WS/apps/apps/migrations"
( cd "$WS" && artheia gen-schema system/apps/package.art --out /tmp/schema_v2_probe.json >/dev/null )
DIG_V2="$(digest_of /tmp/schema_v2_probe.json CounterConfig)"
cat > "$WS/apps/apps/migrations/counter_v1_to_v2.json" <<EOF
{
  "config_type": "CounterConfig",
  "from_digest": "$DIG_V1",
  "to_digest": "$DIG_V2",
  "rules": [
    {"op": "rename", "from": "max_value", "to": "ceiling"},
    {"op": "add", "field": "warn_at", "default": 90}
  ]
}
EOF
# BUILD scaffold via gen-migration (write-once transforms are preserved)
( cd "$WS" && artheia gen-migration --from "$SCHEMA_V1" --to /tmp/schema_v2_probe.json \
    --out apps/apps/migrations >/dev/null ) || true
RT="$(bexec 'dpkg-query -W -f=${Version} theia-runtime 2>/dev/null' | sed 's/^[0-9]*://; s/-.*$//')"
( cd "$WS" && theia release-swp apps --swp-version 2.0.0 --migrate --from 1.0.0 \
    --requires-runtime "${RT:-0.0.0}" --fleet "$FLEET" --s3 "$S3" ) \
  || die "release-swp 2.0.0 --migrate failed (gate?)"
ART_V2="$(ls -t "$WS"/dist/apps/apps/apps-2.0.0*.mender 2>/dev/null | head -1 | xargs -r basename | sed 's/\.mender$//')"
[ -n "$ART_V2" ] || die "no apps-2.0.0*.mender"
tar -tzf "$WS/dist/apps/apps/$ART_V2.tar.gz" 2>/dev/null | grep -q "migration/00-migrate-config.py" \
  || die "migration driver not in the v2 payload"
ok "v2 --migrate released ($DIG_V1 → $DIG_V2), driver packed"

log "deploy v2 via the UCM lifecycle (the PRODUCTION path — C++ on-device)"
# Stage releases/2.0.0 on the board from the v2 SWP payload: the current
# release's full content + the v2 bins + the migration/ part. (The Mender
# module→UCM staging alignment is a separate work item; UCM's stage step is
# idempotent over a pre-staged release — the ucm-adopt contract.)
docker cp "$WS/dist/apps/apps/$ART_V2.tar.gz" ota-central:/tmp/swp2.tgz
bexec 'set -e
  cur="$(readlink /opt/theia/current)"
  rm -rf /opt/theia/releases/2.0.0 /tmp/swp2
  mkdir -p /tmp/swp2 && tar -xzf /tmp/swp2.tgz -C /tmp/swp2
  cp -a "$cur" /opt/theia/releases/2.0.0
  cp -a /tmp/swp2/bin/. /opt/theia/releases/2.0.0/bin/
  rm -rf /opt/theia/releases/2.0.0/migration
  cp -a /tmp/swp2/migration /opt/theia/releases/2.0.0/migration' \
  || die "staging releases/2.0.0 failed"
# UCM install back-end → simulate (the release is pre-staged); env rides the
# supervisor unit via a systemd drop-in.
bexec 'mkdir -p /etc/systemd/system/theia-supervisor.service.d
  printf "[Service]\nEnvironment=THEIA_UCM_MENDER=simulate\n" \
    > /etc/systemd/system/theia-supervisor.service.d/e2e.conf
  systemctl daemon-reload && systemctl restart theia-supervisor' \
  || die "simulate back-end drop-in failed"
sleep 12

UCMDRV() { THEIA_ROOT="$THEIA_DIR" "$VPY" "$HERE/helpers/ucm-drive.py" "$@"; }
UCMDRV request 2.0.0 || die "RequestUpdate 2.0.0 refused"
# Poll: UcmGate migrates (Snapshot + MigrateBulk) BEFORE switch_full, then
# switches + verifies. Config digest flips first; current follows.
for i in $(seq 1 30); do
  GOT="$(bcfg get counter 2>/dev/null || echo '{}')"
  echo "$GOT" | grep -q "$DIG_V2" && break
  sleep 4; [ "$i" = 30 ] && die "config never flipped to v2 digest (last: $GOT)"
done
for i in $(seq 1 30); do
  CUR="$(bexec 'readlink /opt/theia/current' || true)"
  case "$CUR" in *releases/2.0.0) break;; esac
  sleep 4; [ "$i" = 30 ] && die "current never switched to 2.0.0 (at: $CUR)"
done
HEX_NOW="$(echo "$GOT" | "$VPY" -c 'import json,sys; print(json.load(sys.stdin)["hex"])')"
VALS="$(dec_counter "$HEX_NOW")"
echo "  migrated config: $VALS"
echo "$VALS" | "$VPY" -c '
import json,sys
d=json.load(sys.stdin)
assert d["ceiling"] == 250, f"ceiling {d} — seeded max_value NOT carried"
assert d["warn_at"] == 90,  f"warn_at {d} — add-rule default wrong"
assert d["step"] == 7,      f"step {d} — untouched field lost"
' || die "migrated values wrong"
bexec 'ls /tmp/theia/dbbackup/pre-2.0.0*.persnap /tmp/theia/dbbackup/pre-2.0.0.persnap 2>/dev/null | head -1' >/dev/null \
  || die "no pre-update snapshot on board"
ok "UCM MIGRATED: digest v2, ceiling=250 carried, warn_at=90, snapshot present, current→2.0.0"

###############################################################################
log "PHASE 6 — fail-closed rollback: broken migration → EvFailed → config restored"
###############################################################################
# releases/3.0.0 = a copy of 2.0.0 whose migration declares a v2→v3 step with
# a MISSING plugin: MigrateBulk fails → EvFailed → RestoreSnapshot(pre-3.0.0)
# + release revert. Net effect must be NO change (still v2, values intact).
bexec 'set -e
  rm -rf /opt/theia/releases/3.0.0
  cp -a /opt/theia/releases/2.0.0 /opt/theia/releases/3.0.0
  cat > /opt/theia/releases/3.0.0/migration/migration.json <<JSON
{"artifact": "apps-3.0.0",
 "steps": [{"config_type": "CounterConfig",
            "from_digest": "'"$DIG_V2"'", "to_digest": "cfg_broken",
            "plugin": "libper_migrate_missing.so",
            "transform": "none.json"}]}
JSON' || die "staging broken 3.0.0 failed"
UCMDRV request 3.0.0 || true    # the request is accepted; the LIFECYCLE fails
sleep 15
CUR="$(bexec 'readlink /opt/theia/current')"
case "$CUR" in *releases/2.0.0) ok "current stayed on 2.0.0 (broken update rolled back)";;
  *) die "current moved to $CUR — broken migration was not fail-closed";; esac
GOT="$(bcfg get counter)"
echo "$GOT" | grep -q "$DIG_V2" || die "config digest changed across the failed update: $GOT"
HEX_BACK="$(echo "$GOT" | "$VPY" -c 'import json,sys; print(json.load(sys.stdin)["hex"])')"
[ "$HEX_BACK" = "$HEX_NOW" ] || die "config bytes changed across the failed update"
bexec 'journalctl -u theia-supervisor --no-pager | grep -q "config migration:"' \
  && ok "UcmGate logged the migration failure (fail-closed)" || true
ok "FAIL-CLOSED: broken migration aborted the update; config intact at v2"

log "OTA CONFIG-MIGRATION E2E: ALL GREEN"
