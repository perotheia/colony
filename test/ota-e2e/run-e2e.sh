#!/usr/bin/env bash
# run-e2e.sh — the isolated OTA end-to-end test driver.
#
# Reproduces, hermetically in containers, the live campaign proven on rpi4+jetson:
#
#   provision (colony ansible)  →  enroll (mender server)  →  first install
#   →  update v2  →  deliberate-fail rollback  —  asserting at each step.
#
# Topology (docker-compose.yml + the Mender server joined to the same network):
#   controller   drives colony ansible + enroll-rig.sh + fleet.py
#   central      a Theia rig (systemd) — 14-FC services slice + etcd + mender-gw
#   compute      a Theia rig (systemd) — ucm+shwa slice
#   mender-server  the OSS stack (ground-station up.sh), aliased docker.mender.io
#
# Usage:
#   ./run-e2e.sh            full run (build → up → flow → assert → teardown)
#   ./run-e2e.sh --keep     leave containers up on exit (debug)
#   ./run-e2e.sh --no-build skip the bazel FC build (reuse dist/ from a prior run)
#
# Exit non-zero on the first failed assertion. Designed for CI (workflow_dispatch /
# nightly). Logs from every container are dumped to ./logs/ on failure.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

# Repo roots (sibling layout by default; CI overrides via env).
THEIA_DIR="${THEIA_DIR:-$(cd "$HERE/../../../theia" && pwd)}"
COLONY_DIR="${COLONY_DIR:-$(cd "$HERE/../.." && pwd)}"
GROUND_STATION_DIR="${GROUND_STATION_DIR:-$(cd "$HERE/../../../ground-station" && pwd)}"
export THEIA_DIR COLONY_DIR GROUND_STATION_DIR

COMPOSE="docker compose -f $HERE/docker-compose.yml"
KEEP=0; DO_BUILD=1
for a in "$@"; do
  case "$a" in
    --keep) KEEP=1 ;;
    --no-build) DO_BUILD=0 ;;
  esac
done

MENDER_EMAIL="admin@docker.mender.io"
MENDER_PASS="password123"
SERVER_DIR="${MENDER_SERVER_DIR:-$HOME/mender-server}"

# Throwaway CI SSH keypair (controller → boards) — generated here, never committed.
# Must exist before `docker compose build` (the board image COPYs the pubkey).
if [ ! -f "$HERE/keys/ci_ed25519" ]; then
  mkdir -p "$HERE/keys"
  ssh-keygen -t ed25519 -N "" -C ota-e2e-ci -f "$HERE/keys/ci_ed25519" >/dev/null
fi

log()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; dump_logs; exit 1; }

dump_logs() {
  log "dumping container logs → $HERE/logs/"
  mkdir -p "$HERE/logs"
  for c in ota-central ota-compute ota-controller; do
    docker logs "$c" >"$HERE/logs/$c.log" 2>&1 || true
    docker exec "$c" journalctl --no-pager >"$HERE/logs/$c.journal" 2>&1 || true
  done
}

cleanup() {
  [ "$KEEP" = 1 ] && { log "--keep: leaving stack up"; return; }
  log "teardown"
  $COMPOSE down -v --remove-orphans 2>/dev/null || true
  ( cd "$SERVER_DIR" 2>/dev/null && docker compose down 2>/dev/null ) || true
}
trap cleanup EXIT

# ── ctl: run a command in the controller container (where ansible/fleet live) ──
ctl() { docker exec ota-controller bash -lc "$*"; }
# board state helper: read a board's current-symlink target
board_current() { docker exec "ota-$1" readlink /opt/theia/current 2>/dev/null || echo NONE; }
board_fc_count() { docker exec "ota-$1" sh -c 'ps -eo args 2>/dev/null | grep -c "/opt/theia/current/bin/[a-z]"' 2>/dev/null || echo 0; }

###############################################################################
log "PHASE 0 — build FC binaries + manifests + artifacts (controller-side)"
###############################################################################
# The controller checkout drives `theia` to build the x86 DOCKER split, the per-
# machine .deb bundles, and the role .mender artifacts. (In CI the bazel build is
# the heavy stage; --no-build reuses a prior dist/.)
if [ "$DO_BUILD" = 1 ]; then
  log "building Theia DOCKER split (x86) + .deb + .mender — this is the heavy stage"
  "$HERE/build-artifacts.sh"           # see that script: bazel + serialize + pack
else
  ok "skipping build (--no-build)"
fi
[ -f "$THEIA_DIR/dist/manifest/central/central.deb" ] \
  || die "no central.deb — run without --no-build first"
[ -f "$THEIA_DIR/dist/roles/central-0.2.1.mender" ] \
  || die "no central-0.2.1.mender — build-artifacts.sh did not pack it"
ok "build artifacts present"

###############################################################################
log "PHASE 1 — bring up the Mender server + the board/controller containers"
###############################################################################
log "mender server up (ground-station up.sh — clones+pulls on first run)"
MENDER_SERVER_DIR="$SERVER_DIR" bash "$GROUND_STATION_DIR/mender/server/up.sh" up
# join the server's traefik to our ota network so the boards can reach it
SERVER_NET="$(basename "$SERVER_DIR")_default"
docker network connect ota-e2e "$(docker ps --filter name=traefik --format '{{.Names}}' | head -1)" 2>/dev/null || true
# create the admin user (idempotent)
MENDER_SERVER_DIR="$SERVER_DIR" bash "$GROUND_STATION_DIR/mender/server/up.sh" user "$MENDER_EMAIL" "$MENDER_PASS" 2>/dev/null || true
ok "mender server up"

# TIPC is a KERNEL module — containers share the host kernel, so the cross-board
# TIPC bearer the boards enable needs `tipc` loaded ON THE HOST/runner (a privileged
# container can then use it). Load it here; harmless if already loaded.
log "load the tipc kernel module on the host (needed for the cross-board bearer)"
sudo modprobe tipc 2>/dev/null || modprobe tipc 2>/dev/null \
  || die "could not modprobe tipc on the host — the runner kernel must provide it"
ok "tipc module loaded"

log "compose build + up (board containers boot systemd)"
$COMPOSE build
$COMPOSE up -d
# wait for sshd on both boards
for b in central compute; do
  for i in $(seq 1 30); do
    docker exec ota-controller ssh -o ConnectTimeout=3 root@$b true 2>/dev/null && break
    sleep 2
    [ "$i" = 30 ] && die "ssh to $b never came up"
  done
  ok "ssh to $b ready"
done

# map docker.mender.io → traefik IP inside each board (enroll-rig.sh + boards need it)
TRAEFIK_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{if eq .NetworkID ""}}{{end}}{{.IPAddress}} {{end}}' "$(docker ps --filter name=traefik --format '{{.Names}}'|head -1)" 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -1)"
[ -n "$TRAEFIK_IP" ] || die "could not resolve traefik IP on the ota network"
for b in central compute; do
  docker exec "ota-$b" sh -c "grep -q docker.mender.io /etc/hosts || echo '$TRAEFIK_IP docker.mender.io s3.docker.mender.io' >> /etc/hosts"
done
ok "docker.mender.io → $TRAEFIK_IP wired into both boards"

###############################################################################
log "PHASE 2 — provision + orchestrate both boards (colony ansible)"
###############################################################################
# point colony at the TEST registry (container hosts) + the theia bundle
CENV="THEIA_WORKSPACE=/repo/theia COLONY_ANSIBLE=/repo/colony/ansible"
RREG="registry_dir=/repo/colony/test/ota-e2e/registry"
RMAN="manifest_dir=/repo/theia/dist/manifest"
for b in central compute; do
  log "provision $b"
  ctl "$CENV /repo/colony/bin/colony provision $b -e $RREG -e $RMAN -e mender_artifacts_dir=/repo/theia/deploy/mender" \
    || die "provision $b failed"
  log "orchestrate $b"
  ctl "$CENV /repo/colony/bin/colony orchestrate $b -e $RREG -e $RMAN -e autostart=true" \
    || die "orchestrate $b failed"
done
# assert supervisors up with the right FC counts
sleep 8
[ "$(board_fc_count central)" -ge 10 ] || die "central FC count $(board_fc_count central) < 10"
[ "$(board_fc_count compute)" -eq 2 ] || die "compute FC count $(board_fc_count compute) != 2"
ok "provision+orchestrate: central=$(board_fc_count central) FCs, compute=$(board_fc_count compute) FCs"

###############################################################################
log "PHASE 3 — enroll both boards to the Mender server"
###############################################################################
for b in central compute; do
  log "enroll $b"
  # SERVER_SSH is the controller talking to itself-as-server? No: enroll-rig.sh
  # fetches the CA from the server host. In-container we read it from the mounted
  # server dir + pass the board ssh target directly.
  ctl "SERVER_SSH=mender-server SERVER_CA=/repo/.mender-ca.crt \
       bash /repo/ground-station/mender/server/enroll-rig.sh $b $TRAEFIK_IP docker.mender.io $MENDER_EMAIL $MENDER_PASS" \
    || die "enroll $b failed"
done
ok "both boards enrolled (accepted on the server)"

###############################################################################
log "PHASE 4 — first-time OTA install (fleet.py upload + deploy)"
###############################################################################
PAT="$(ctl "curl -sk -u $MENDER_EMAIL:$MENDER_PASS -X POST https://$TRAEFIK_IP/api/management/v1/useradm/auth/login | \
       xargs -I{} curl -sk -H 'Authorization: Bearer {}' -H 'Content-Type: application/json' \
       -X POST https://$TRAEFIK_IP/api/management/v1/useradm/settings/tokens -d '{\"name\":\"e2e\"}'")"
FLEET="MENDER_TOKEN=$PAT python3 /repo/ground-station/fleet/fleet.py --server https://$TRAEFIK_IP --insecure"
# group the devices (central/compute) then deploy each role artifact
ctl "$HERE/helpers/group-and-deploy.sh '$TRAEFIK_IP' '$MENDER_EMAIL' '$MENDER_PASS' central-0.2.1 compute-0.2.1" \
  || die "first-install deploy failed"
# poll for the flip
assert_version() {  # board, expected-version-substring
  for i in $(seq 1 30); do
    cur="$(board_current "$1")"
    case "$cur" in *"$2"*) ok "$1 current → $cur"; return 0;; esac
    docker exec "ota-$1" sh -c 'kill -USR1 $(pgrep -x mender-update) 2>/dev/null' || true
    sleep 4
  done
  die "$1 never flipped to *$2* (current=$(board_current "$1"))"
}
assert_version central central-0.2.1
assert_version compute compute-0.2.1
ok "FIRST INSTALL ok"

###############################################################################
log "PHASE 5 — update to v2 (0.2.2)"
###############################################################################
ctl "$HERE/helpers/group-and-deploy.sh '$TRAEFIK_IP' '$MENDER_EMAIL' '$MENDER_PASS' central-0.2.2 compute-0.2.2" \
  || die "v2 deploy failed"
assert_version central central-0.2.2
assert_version compute compute-0.2.2
ok "UPDATE v2 ok (both boards flipped 0.2.1 → 0.2.2)"

###############################################################################
log "PHASE 6 — deliberate-fail → rollback (the field-safety property)"
###############################################################################
PRE="$(board_current central)"
ctl "$HERE/helpers/group-and-deploy.sh '$TRAEFIK_IP' '$MENDER_EMAIL' '$MENDER_PASS' central-0.2.3-broken ''" \
  || true   # the DEPLOY succeeds; the INSTALL fails on-device → rollback
# the broken artifact must NOT change current; it must roll back to PRE
for i in $(seq 1 30); do
  docker exec ota-central sh -c 'kill -USR1 $(pgrep -x mender-update) 2>/dev/null' || true
  sleep 4
  cur="$(board_current central)"
  # success = rolled back to the SAME running version (the fix: not 2 versions back)
  [ "$cur" = "$PRE" ] && { ok "central rolled back to $cur (the running version)"; break; }
  [ "$i" = 30 ] && die "central did not roll back to $PRE (current=$cur)"
done
[ "$(board_fc_count central)" -ge 10 ] || die "central unhealthy after rollback ($(board_fc_count central) FCs)"
ok "ROLLBACK ok — supervisor healthy, current=$(board_current central)"

###############################################################################
log "ALL PHASES PASSED — provision → enroll → install → update → rollback"
###############################################################################
ok "OTA e2e GREEN"
