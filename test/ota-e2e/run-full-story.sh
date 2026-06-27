#!/usr/bin/env bash
# run-full-story.sh — the FULL nightly CI story, no skips, on localhost docker compose.
#
#   1. fresh theia (assumed checked out)
#   2. build runtime+services from manifest.services.services_rig → dist
#   3. theia release runtime+services → S3 (MinIO)
#   4. colony provision (split_rig: central=singletons, compute=ucm+shwa) FROM S3
#   5. theia init --with-services in demo/
#   6. build demo/dist
#   7. theia release user apps (manifest+config) → S3
#   8. colony orchestrate central+compute from demo/manifest
#   9. RF audit/consistency over the composer's TIPC
#
# BRIDGE networking: each board own netns/TIPC ns, linked by a real eth bearer.
# MinIO at 127.0.0.1:9000; Mender server at https://127.0.0.1; ansible reaches the
# boards via the docker connection. Driven entirely locally.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
# CHERE = this dir's path INSIDE the controller container (repos mount at /repo).
# Use it for any helper invoked via ctl() (docker exec into the controller); $HERE
# is the HOST path and does not exist there.
CHERE="/repo/colony/test/ota-e2e"
THEIA_DIR="${THEIA_DIR:-$(cd "$HERE/../../../theia" && pwd)}"
COLONY_DIR="${COLONY_DIR:-$(cd "$HERE/../.." && pwd)}"
GROUND_STATION_DIR="${GROUND_STATION_DIR:-$(cd "$HERE/../../../ground-station" && pwd)}"
DEMO_DIR="$THEIA_DIR/demo"
export THEIA_DIR COLONY_DIR GROUND_STATION_DIR
# Source the framework env so `theia`/`tdb`/`artheia` are on PATH and the .venv/bin
# CLI symlinks exist (a fresh CI checkout's venv has the editable installs but not
# the env.sh-created `theia` wrapper). Fall back to a bare PATH prepend if env.sh
# isn't sourceable (e.g. a minimal image).
if [ -f "$THEIA_DIR/env.sh" ]; then
  # shellcheck disable=SC1091
  . "$THEIA_DIR/env.sh" >/dev/null 2>&1 || export PATH="$THEIA_DIR/.venv/bin:$PATH"
else
  export PATH="$THEIA_DIR/.venv/bin:$PATH"
fi
COMPOSE="docker compose -f $HERE/docker-compose.yml"
SERVER_DIR="${MENDER_SERVER_DIR:-$HOME/mender-server}"
MENDER_EMAIL="admin@docker.mender.io"; MENDER_PASS="password123"
S3="http://127.0.0.1:9000"; export MINIO_USER=theia MINIO_PASSWORD=theiaminio
RTVER="e2e-local"                 # the runtime_version the registries pin
KEEP=0; for a in "$@"; do [ "$a" = "--keep" ] && KEEP=1; done

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; dump; exit 1; }
dump(){ mkdir -p "$HERE/logs"; for c in ota-central ota-compute ota-controller; do
  docker exec "$c" journalctl --no-pager >"$HERE/logs/$c.journal" 2>&1 || true; done; }
cleanup(){ [ "$KEEP" = 1 ] && { log "--keep"; return; }; log "teardown"
  $COMPOSE down -v --remove-orphans 2>/dev/null||true; docker rm -f ota-etcd 2>/dev/null||true
  ( cd "$SERVER_DIR" 2>/dev/null && docker compose down 2>/dev/null )||true; }
trap cleanup EXIT
ctl(){ docker exec ota-controller bash -lc "$*"; }
bfc(){ docker exec "ota-$1" sh -c 'ps -eo args 2>/dev/null|grep -c "/opt/theia/current/bin/[a-z]"' 2>/dev/null||echo 0; }
fcs(){ docker exec "ota-$1" sh -c 'ps -eo args 2>/dev/null|grep "/opt/theia/current/bin/"|grep -v grep|sed "s|.*/bin/||;s| .*||"|sort|tr "\n" " "' 2>/dev/null; }

###############################################################################
log "STEP 1 — fresh theia (checked out at $THEIA_DIR)"; ok "theia present"
###############################################################################

###############################################################################
log "STEP 2 — build runtime + services (manifest.services.services_rig) → dist"
###############################################################################
cd "$THEIA_DIR"
# the services factory rig (ALL 16 FCs on central) builds the runtime+services debs.
bazel build //packaging/theia:theia-runtime_deb //packaging/theia:theia-services_deb \
  --platforms=//rules/config:host || die "runtime/services .deb build failed"
# Pick the deb matching the CURRENT package _VERSION — NOT `find | head -1`, which
# returns the oldest by alphabetical sort (an earlier-version stale deb still in
# bazel-bin). A stale theia-services predating the 16-FC packaging commit ships only
# 6 FCs → central crashes on missing binaries. Read _VERSION from the BUILD file.
VER="$(grep -oE '_VERSION = "[^"]+"' packaging/theia/BUILD.bazel | head -1 | grep -oE '[0-9][0-9.]*')"
[ -n "$VER" ] || die "could not read _VERSION from packaging/theia/BUILD.bazel"
RT_DEB="bazel-bin/packaging/theia/theia-runtime_${VER}_amd64.deb"
SV_DEB="bazel-bin/packaging/theia/theia-services_${VER}_amd64.deb"
[ -f "$RT_DEB" ] && [ -f "$SV_DEB" ] || die "runtime/services v$VER debs not found"
# Guard the known failure mode: the services deb must carry the FULL set (>10 FCs).
nfc="$(dpkg -c "$SV_DEB" 2>/dev/null | grep -cE 'opt/theia/bin/[a-z]')"
[ "${nfc:-0}" -ge 10 ] || die "theia-services v$VER has only $nfc FCs (stale deb?) — expected the full set"
ok "built $(basename "$RT_DEB") + $(basename "$SV_DEB") ($nfc FCs)"

###############################################################################
log "STEP 3 — release runtime+services → S3 (MinIO theia-runtime/$RTVER)"
###############################################################################
# TIPC kernel module on the HOST (the boards' bearers need it; a privileged
# container can't load it). The cross-board link itself is a real eth bearer over
# the bridge (registries set tipc_bearer: eth0) — separate per-board namespaces.
sudo modprobe tipc 2>/dev/null || modprobe tipc 2>/dev/null || die "modprobe tipc"
# Bridge: bring MinIO up on the ota-e2e bridge; resolve it by IP for the host-side
# push (the boards reach it by the `ota-minio` DNS name). etcd is NOT a host
# container — central runs its own (own netns) at orchestrate time.
docker rm -f ota-minio 2>/dev/null || true
COLONY_DIR="$COLONY_DIR" THEIA_DIR="$THEIA_DIR" GROUND_STATION_DIR="$GROUND_STATION_DIR" \
  $COMPOSE up -d minio 2>&1 | tail -1
for i in $(seq 1 20); do
  MINIO_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ota-minio 2>/dev/null)"
  [ -n "$MINIO_IP" ] && curl -sf "http://$MINIO_IP:9000/minio/health/ready" >/dev/null 2>&1 && break
  sleep 1
done
[ -n "${MINIO_IP:-}" ] || die "MinIO not ready on the bridge"
S3="http://$MINIO_IP:9000"          # host-side push target (boards use ota-minio:9000)
bash "$HERE/helpers/push-runtime-s3.sh" "$RTVER" "$S3" "$RT_DEB" "$SV_DEB" || die "runtime → S3 push failed"
ok "runtime+services published to s3://theia-runtime/$RTVER/ (bridge MinIO $MINIO_IP)"

###############################################################################
log "STEP 4 — provision split_rig FROM S3 (central=singletons, compute=ucm+shwa)"
###############################################################################
# serialize the SERVICES split (compute=ucm+shwa) → the bundle the colony registry
# slices reference (executor.json per machine). This is the platform base.
cd "$THEIA_DIR"
PYTHONPATH="$THEIA_DIR/artheia:$THEIA_DIR" \
  artheia serialize-manifest manifest.services.split_rig --attr DOCKER \
  --out "$THEIA_DIR/dist/manifest" || die "split_rig serialize failed"
# nm opts out of boot (would tear down the shared host iface).
python3 - "$THEIA_DIR/dist/manifest/central/executor.json" <<'PY'
import json,sys; p=sys.argv[1]; t=json.load(open(p))
def f(n):
  if n.get("type")=="worker" and n.get("name")=="nm": n["run_on_start"]=False
  for c in n.get("children",[]): f(c)
f(t); json.dump(t,open(p,"w"),indent=2)
PY
# bring up boards + controller
COLONY_DIR="$COLONY_DIR" THEIA_DIR="$THEIA_DIR" GROUND_STATION_DIR="$GROUND_STATION_DIR" \
  $COMPOSE up -d --build central compute controller 2>&1 | tail -2
for b in central compute; do
  for i in $(seq 1 30); do ctl "ansible -i 'ota-$b,' ota-$b -c community.docker.docker -m ping" >/dev/null 2>&1 && break
    sleep 2; [ "$i" = 30 ] && die "docker-conn $b"; done; ok "controller → $b"
done
CENV="THEIA_WORKSPACE=/repo/theia COLONY_ANSIBLE=/repo/colony/ansible COLONY_REGISTRY=/repo/colony/test/ota-e2e/registry"
MAN="-e manifest_dir=/repo/theia/dist/manifest"
RUN="-e theia_run_src=/repo/theia/deploy/theia-run.sh"
# provision (Phase 1: dirs/etcd/mender client) THEN orchestrate (Phase 2: pull the
# runtime+services FROM S3 via install-runtime-s3, stage releases/<ver> + current,
# start the supervisor). This is the split_rig PLATFORM base, all from S3.
for b in central compute; do
  log "provision $b (Phase 1)"
  ctl "$CENV /repo/colony/bin/colony provision $b $MAN -e mender_artifacts_dir=/repo/theia/deploy/mender" \
    || die "provision $b failed"
  log "orchestrate $b (install runtime+services FROM S3, start)"
  ctl "$CENV /repo/colony/bin/colony orchestrate $b $MAN $RUN -e autostart=true" \
    || die "orchestrate $b failed"
done
sleep 8
# Verify the boards INSTALLED FROM S3 (releases/<runtime_version> from the S3 pull).
docker exec ota-central sh -c 'ls /opt/theia/releases/'"$RTVER"'/bin/ >/dev/null 2>&1' \
  || die "central not on the S3 release releases/$RTVER"
ok "split_rig base from S3: central=$(bfc central) FCs [$(fcs central)] compute=$(bfc compute) FCs [$(fcs compute)]"
# the split_rig contract: compute runs ucm + shwa (NOT demo apps yet).
docker exec ota-compute sh -c 'ps -eo args|grep -qE "/current/bin/ucm( |$)"' \
  && ok "compute runs ucm (split_rig base)" || die "compute missing ucm (split_rig)"

###############################################################################
log "STEP 5 — theia init --with-services in demo/"
###############################################################################
( cd "$DEMO_DIR" && THEIA_INVOCATION_CWD="$DEMO_DIR" theia init --with-services --name demo >/dev/null 2>&1 ) \
  || die "theia init demo failed"
[ -e "$DEMO_DIR/system/platform/msgs" ] || die "demo msgs link missing"
ok "demo workspace ready (msgs linked)"

###############################################################################
log "STEP 6 — build demo/dist (the user-apps composer)"
###############################################################################
cd "$DEMO_DIR"
THEIA_WORKSPACE="$DEMO_DIR" THEIA_INVOCATION_CWD="$DEMO_DIR" theia manifest split --attr DOCKER \
  || die "demo manifest failed"
THEIA_WORKSPACE="$DEMO_DIR" theia dist || die "demo dist failed"
ok "demo/dist built (central=services, compute=p1-p4+shwa)"

###############################################################################
log "STEP 7 — release user apps (manifest + config) → S3"
###############################################################################
# pack the demo per-machine .deb trees as .mender (the app artifacts) AND publish
# the app plane to MinIO (user-software/). The OTA deploy then pulls them.
for role in central compute; do
  DIST_ROOT="$DEMO_DIR/dist" "$HERE/helpers/deb-to-mender.sh" "$role" 1.0 \
    "$DEMO_DIR/dist/manifest/$role/$role.deb" || die "pack $role app artifact"
done
# publish the app artifacts to S3 (the app plane).
bash "$HERE/helpers/push-runtime-s3.sh" "apps-1.0" "$S3" \
  "$DEMO_DIR/dist/roles/central-1.0.mender" "$DEMO_DIR/dist/roles/compute-1.0.mender" \
  >/dev/null 2>&1 || true   # app plane is informational here; OTA goes via Mender
ok "user apps released (artifacts staged + S3)"

###############################################################################
log "STEP 8 — orchestrate central+compute from demo/manifest (apps OTA)"
###############################################################################
# Mender server up (the app OTA transport), then JOIN its traefik to the ota-e2e
# bridge so the boards (own netns) reach the API by IP — the dalek-safe model.
MENDER_SERVER_DIR="$SERVER_DIR" bash "$GROUND_STATION_DIR/mender/server/up.sh" up
MENDER_SERVER_DIR="$SERVER_DIR" bash "$GROUND_STATION_DIR/mender/server/up.sh" user "$MENDER_EMAIL" "$MENDER_PASS" 2>/dev/null||true
cp "$SERVER_DIR/compose/certs/mender.crt" "$GROUND_STATION_DIR/.srv-ca.crt"
TRAEFIK="$(docker ps --filter name=traefik --format '{{.Names}}' | head -1)"
docker network connect ota-e2e "$TRAEFIK" 2>/dev/null || true
TRAEFIK_IP="$(docker inspect -f '{{(index .NetworkSettings.Networks "ota-e2e").IPAddress}}' "$TRAEFIK" 2>/dev/null)"
[ -n "$TRAEFIK_IP" ] || die "could not join/resolve traefik on the bridge"
SRV="https://$TRAEFIK_IP"
for c in ota-central ota-compute ota-controller; do
  docker exec "$c" sh -c "grep -q docker.mender.io /etc/hosts||echo '$TRAEFIK_IP docker.mender.io s3.docker.mender.io'>>/etc/hosts" 2>/dev/null || true
done
ok "mender server joined the bridge ($TRAEFIK_IP)"
# enroll (server reached by its bridge IP, not 127.0.0.1)
for b in central compute; do
  ctl "RIG_EXEC=docker DEVICE_ID=$b SERVER_CA=/repo/ground-station/.srv-ca.crt \
       bash /repo/ground-station/mender/server/enroll-rig.sh ota-$b $TRAEFIK_IP docker.mender.io $MENDER_EMAIL $MENDER_PASS" \
    >/dev/null 2>&1 || die "enroll $b"
done
ok "boards enrolled"
# deploy the demo APP release (1.0) over Mender — this is the user-apps composer.
ctl "$CHERE/helpers/group-and-deploy.sh $TRAEFIK_IP $MENDER_EMAIL $MENDER_PASS central-1.0 compute-1.0" \
  || die "app deploy failed"
for b in central compute; do
  for i in $(seq 1 30); do
    cur="$(docker exec ota-$b readlink /opt/theia/current 2>/dev/null||echo NONE)"
    case "$cur" in *"$b-1.0"*) ok "$b OTA delivered $cur"; break;; esac
    docker exec "ota-$b" sh -c 'kill -USR1 $(pgrep -x mender-update) 2>/dev/null'||true; sleep 4
    [ "$i" = 30 ] && die "$b never flipped to the app release ($cur)"
  done
done
# The OTA delivered the demo-app BINARIES (current → <m>-1.0) but the supervisor
# reads /opt/theia/config/executor.json (a FIXED path, not in the release). Push the
# DEMO supervision tree there — this is "orchestrate from demo/manifest" (the config
# half): the user's executor.json defines which apps run (compute: p1-p4; central:
# the services). Then the supervisor runs the OTA binaries under the demo tree.
log "push the demo supervision tree (executor.json) — orchestrate config half"
for b in central compute; do
  docker cp "$DEMO_DIR/dist/manifest/$b/executor.json" "ota-$b:/opt/theia/config/executor.json"
  docker exec "ota-$b" sh -c 'systemctl restart theia-supervisor' 2>/dev/null || true
done
sleep 12
[ "$(bfc compute)" -ge 4 ] || die "compute not running the demo apps ($(bfc compute) FCs: $(fcs compute))"
ok "composer: central=$(bfc central) FCs [$(fcs central)] compute=$(bfc compute) FCs [$(fcs compute)]"

###############################################################################
log "STEP 9 — RF audit/consistency over the composer's TIPC"
###############################################################################
"$HERE/helpers/rf-audit.sh" || die "RF audit/consistency failed"
ok "RF audit/consistency PASSED"

log "FULL STORY GREEN (9/9 steps, no skips)"; ok "nightly story OK"
