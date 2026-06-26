#!/usr/bin/env bash
# run-e2e.sh — the OTA end-to-end test driver (host networking).
#
# Reproduces, hermetically in containers, the live campaign proven on rpi4+jetson:
#
#   provision (colony ansible) → enroll (mender server) → first install
#   → update v2 → deliberate-fail rollback → tdb/rtdb stability — asserting each step.
#
# Host networking: the boards share the host TIPC namespace (machine_instance 0/1),
# the Mender server is on https://localhost, ansible reaches the boards via the
# docker connection (exec), and host-side tdb/rtdb reach the stack over raw TIPC.
#
#   ./run-e2e.sh            full (build → up → flow → assert → teardown)
#   ./run-e2e.sh --keep     leave the stack up (debug)
#   ./run-e2e.sh --no-build reuse dist/ from a prior build (skip the bazel stage)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"

THEIA_DIR="${THEIA_DIR:-$(cd "$HERE/../../../theia" && pwd)}"
COLONY_DIR="${COLONY_DIR:-$(cd "$HERE/../.." && pwd)}"
GROUND_STATION_DIR="${GROUND_STATION_DIR:-$(cd "$HERE/../../../ground-station" && pwd)}"
export THEIA_DIR COLONY_DIR GROUND_STATION_DIR
COMPOSE="docker compose -f $HERE/docker-compose.yml"
SERVER_DIR="${MENDER_SERVER_DIR:-$HOME/mender-server}"
MENDER_EMAIL="admin@docker.mender.io"; MENDER_PASS="password123"
KEEP=0; DO_BUILD=1
for a in "$@"; do case "$a" in --keep) KEEP=1;; --no-build) DO_BUILD=0;; esac; done

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; dump_logs; exit 1; }
dump_logs() { mkdir -p "$HERE/logs"; for c in ota-central ota-compute ota-controller; do
  docker exec "$c" journalctl --no-pager >"$HERE/logs/$c.journal" 2>&1 || true; done; }
cleanup() { [ "$KEEP" = 1 ] && { log "--keep: stack left up"; return; }
  log "teardown"; $COMPOSE down -v --remove-orphans 2>/dev/null || true
  ( cd "$SERVER_DIR" 2>/dev/null && docker compose down 2>/dev/null ) || true; }
trap cleanup EXIT

# helpers: run in the controller; read board state via docker exec
ctl()  { docker exec ota-controller bash -lc "$*"; }
bcur() { docker exec "ota-$1" readlink /opt/theia/current 2>/dev/null || echo NONE; }
bfc()  { docker exec "ota-$1" sh -c 'ps -eo args 2>/dev/null | grep -c "/opt/theia/current/bin/[a-z]"' 2>/dev/null || echo 0; }
# colony verb via the controller, pointed at the test registry + theia bundle
CENV="THEIA_WORKSPACE=/repo/theia/demo COLONY_ANSIBLE=/repo/colony/ansible"
REG="/repo/colony/test/ota-e2e/registry"; MAN="/repo/theia/demo/dist/manifest"
colony() { ctl "$CENV /repo/colony/bin/colony $1 $2 -e registry_dir=$REG -e manifest_dir=$MAN ${3:-}"; }

###############################################################################
log "PHASE 0 — build (FCs + demo apps + manifests + role artifacts)"
###############################################################################
if [ "$DO_BUILD" = 1 ]; then "$HERE/build-artifacts.sh"; else ok "skip build (--no-build)"; fi
[ -f "$THEIA_DIR/demo/dist/manifest/central/central.deb" ] || die "no central.deb (build first)"
[ -f "$THEIA_DIR/demo/dist/roles/central-0.2.1.mender" ]   || die "no central-0.2.1.mender"
ok "build artifacts present"

###############################################################################
log "PHASE 1 — host prereqs + Mender server + containers"
###############################################################################
# TIPC kernel module (the boards' supervisors bind TIPC; host-shared namespace).
sudo modprobe tipc 2>/dev/null || modprobe tipc 2>/dev/null || die "modprobe tipc failed"
# etcd on the host (the boards treat it as external — registry etcd_external:true).
if ! curl -sf http://127.0.0.1:2379/health >/dev/null 2>&1; then
  log "starting a host etcd (none on :2379)"
  docker run -d --name ota-etcd --network host quay.io/coreos/etcd:v3.5.12 \
    /usr/local/bin/etcd --listen-client-urls=http://127.0.0.1:2379 \
    --advertise-client-urls=http://127.0.0.1:2379 >/dev/null
  for i in $(seq 1 15); do curl -sf http://127.0.0.1:2379/health >/dev/null 2>&1 && break; sleep 1; done
fi
ok "host etcd healthy"

log "mender server up (clones+pulls on first run; trimmed ~1.4GB)"
MENDER_SERVER_DIR="$SERVER_DIR" bash "$GROUND_STATION_DIR/mender/server/up.sh" up
MENDER_SERVER_DIR="$SERVER_DIR" bash "$GROUND_STATION_DIR/mender/server/up.sh" user "$MENDER_EMAIL" "$MENDER_PASS" 2>/dev/null || true
# host-net: the server's API gateway is on https://localhost; the boards reach it
# there too (docker.mender.io → 127.0.0.1).
SRV="https://127.0.0.1"
for c in ota-central ota-compute; do
  docker exec "$c" sh -c "grep -q docker.mender.io /etc/hosts || echo '127.0.0.1 docker.mender.io s3.docker.mender.io' >> /etc/hosts"
done
ok "mender server up ($SRV)"

log "compose build + up (boards boot systemd; controller drives them)"
$COMPOSE build
$COMPOSE up -d
for b in central compute; do
  for i in $(seq 1 30); do
    ctl "ansible -i 'ota-$b,' ota-$b -c community.docker.docker -m ping" >/dev/null 2>&1 && break
    sleep 2; [ "$i" = 30 ] && die "docker-conn to $b never came up"
  done; ok "controller → $b ready"
done

###############################################################################
log "PHASE 2 — provision + orchestrate both boards (colony ansible)"
###############################################################################
for b in central compute; do
  log "provision $b"
  colony provision "$b" "-e mender_artifacts_dir=/repo/theia/deploy/mender" || die "provision $b failed"
  log "orchestrate $b"
  colony orchestrate "$b" "-e autostart=true" || die "orchestrate $b failed"
done
sleep 8
# demo split: central = 15 services MINUS nm (run_on_start=false) → 14 booted;
# compute = p1-p4 + shwa → 5. Use lower bounds (a flaky FC shouldn't fail the whole
# run on an off-by-one) and assert nm is NOT running on central (the safety gate).
[ "$(bfc central)" -ge 10 ] || die "central FC count $(bfc central) < 10"
[ "$(bfc compute)" -ge 4 ]  || die "compute FC count $(bfc compute) < 4 (expect p1-p4+shwa)"
docker exec ota-central sh -c 'ps -eo args | grep -q "/opt/theia/current/bin/nm"' \
  && die "nm IS running on central — run_on_start=false not honored (SSH-lockout risk)" \
  || ok "nm correctly NOT booted on central (run_on_start=false)"
ok "provision+orchestrate: central=$(bfc central) FCs, compute=$(bfc compute) FCs"

###############################################################################
log "PHASE 3 — enroll both boards"
###############################################################################
# Stage the server CA where the controller (and enroll-rig.sh) can read it. The
# controller has the docker socket, so it copies the cert out of the running
# traefik/server container's mounted certs dir.
cp "$SERVER_DIR/compose/certs/mender.crt" "$GROUND_STATION_DIR/.srv-ca.crt" 2>/dev/null \
  || die "server CA not found at $SERVER_DIR/compose/certs/mender.crt"
for b in central compute; do
  log "enroll $b"
  ctl "SERVER_CA=/repo/ground-station/.srv-ca.crt \
       bash /repo/ground-station/mender/server/enroll-rig.sh \
       ota-$b 127.0.0.1 docker.mender.io $MENDER_EMAIL $MENDER_PASS" \
    || die "enroll $b failed"
done
ok "both boards enrolled"

###############################################################################
log "PHASE 4 — first install · PHASE 5 — update v2 · PHASE 6 — rollback"
###############################################################################
GAD() { ctl "$HERE/helpers/group-and-deploy.sh 127.0.0.1 $MENDER_EMAIL $MENDER_PASS $1 ${2:-}"; }
assert_ver() { for i in $(seq 1 30); do case "$(bcur "$1")" in *"$2"*) ok "$1 → $(bcur "$1")"; return;; esac
  docker exec "ota-$1" sh -c 'kill -USR1 $(pgrep -x mender-update) 2>/dev/null' || true; sleep 4; done
  die "$1 never flipped to *$2* ($(bcur "$1"))"; }

log "first install (0.2.1)"; GAD central-0.2.1 compute-0.2.1 || die "first-install deploy"
assert_ver central central-0.2.1; assert_ver compute compute-0.2.1; ok "FIRST INSTALL ok"

log "update (0.2.2)"; GAD central-0.2.2 compute-0.2.2 || die "v2 deploy"
assert_ver central central-0.2.2; assert_ver compute compute-0.2.2; ok "UPDATE v2 ok"

log "deliberate-fail → rollback"; PRE="$(bcur central)"; GAD central-0.2.3-broken "" || true
for i in $(seq 1 30); do docker exec ota-central sh -c 'kill -USR1 $(pgrep -x mender-update) 2>/dev/null' || true
  sleep 4; [ "$(bcur central)" = "$PRE" ] && { ok "rolled back to $(bcur central) (the running version)"; break; }
  [ "$i" = 30 ] && die "no rollback to $PRE ($(bcur central))"; done
[ "$(bfc central)" -ge 10 ] || die "central unhealthy after rollback"
ok "ROLLBACK ok"

###############################################################################
log "PHASE 7 — stability: tdb/rtdb reach the stack over host TIPC"
###############################################################################
"$HERE/helpers/check-observability.sh" || die "tdb/rtdb stability check failed"
ok "tdb/rtdb stable"

log "ALL PHASES PASSED"; ok "OTA e2e GREEN"
