#!/usr/bin/env bash
# run-full-story.sh — the FULL nightly CI story, no skips, on localhost docker compose.
#
#   1. fresh theia (assumed checked out)
#   2. build runtime+services from manifest.services.rig (RIG=all 16 FCs) → dist
#   3. theia release runtime+services → S3 (SeaweedFS, the GS's gs-s3 image)
#   4. colony provision (master=singletons, zonal=ucm+shwa) FROM S3, WITH the fleet
#      PKI (gs_pki_url → a throwaway signer) → com serves MUTUAL TLS (regression 4b)
#   5-7. the app-plane releases (per-machine trees) → signed .mender + S3
#   8. app OTA over Mender (+ com still mutual TLS after the flip)
#   8.5 signed patch accepted · 8.6 UNSIGNED artifact refused (regression)
#   9. RF audit/consistency over the composer's TIPC
#
# BRIDGE networking: each board own netns/TIPC ns, linked by a real eth bearer.
# S3 on the bridge (ota-s3:9000); Mender server joined to the bridge; ansible reaches
# the boards via the docker connection. Driven entirely locally.
#
# com mutual TLS is MANDATORY on these rigs (theia-run.sh: THEIA_COM_TLS_REQUIRED=1):
# the test never sets com_insecure. A throwaway fleet CA lives in the controller
# (helpers/pki-signer.py runs ground-station's routers/pki.py) and every rig gets
# /etc/theia/pki through colony's NORMAL path (tasks/pki-enroll.yml, gs_pki_url).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
# CHERE = this dir's path INSIDE the controller container (repos mount at /repo).
# Use it for any helper invoked via ctl() (docker exec into the controller); $HERE
# is the HOST path and does not exist there.
CHERE="/repo/colony/test/ota-e2e"
THEIA_DIR="${THEIA_DIR:-$(cd "$HERE/../../../theia" && pwd)}"
COLONY_DIR="${COLONY_DIR:-$(cd "$HERE/../.." && pwd)}"
GROUND_STATION_DIR="${GROUND_STATION_DIR:-$(cd "$HERE/../../../ground-station" && pwd)}"
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
# S3 credentials (seaweedfs-s3.json identity `theia`); the variable names are the ones
# push-runtime-s3.sh + `theia cert copy` read (kept from the MinIO days).
export MINIO_USER=theia MINIO_PASSWORD=theiaminio
# The throwaway fleet signer (controller-local) + its API key (fresh per run).
PKI_PORT=8099; GS_API_KEY="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
PKI_URL="http://127.0.0.1:$PKI_PORT"; OPDIR=/tmp/e2e-operator
RTVER="e2e-local"                 # the runtime_version the registries pin
# Board image base MUST match THIS (build) host's distro — `theia dist` links the
# FCs against the host's system .so's, so the board needs the same soname versions.
# ubuntu:<codename> from the host os-release (22.04 jammy local / 24.04 noble on CI).
# Pinned BY DIGEST (multi-arch index digests); an unknown host release fails here
# rather than building on an unpinned base.
if [ -r /etc/os-release ]; then . /etc/os-release; fi
case "${ID:-ubuntu}:${VERSION_ID:-22.04}" in
  ubuntu:22.04) BOARD_BASE="ubuntu:22.04@sha256:9abcaffc92a5279fff3a6a41635c0800ea33e528425fb389658806476e7defde" ;;
  ubuntu:24.04) BOARD_BASE="ubuntu:24.04@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8" ;;
  *) echo "run-full-story: no pinned board base for ${ID:-?}:${VERSION_ID:-?} (add its digest)" >&2; exit 1 ;;
esac
export BOARD_BASE
KEEP=0; for a in "$@"; do [ "$a" = "--keep" ] && KEEP=1; done

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; dump; exit 1; }
dump(){ mkdir -p "$HERE/logs"; for c in ota-central ota-compute ota-controller; do
  docker exec "$c" journalctl --no-pager >"$HERE/logs/$c.journal" 2>&1 || true; done
  docker exec ota-controller cat /tmp/pki-signer.log >"$HERE/logs/pki-signer.log" 2>&1 || true
  docker logs ota-s3 >"$HERE/logs/ota-s3.log" 2>&1 || true; }
cleanup(){ [ -n "${SIGNDIR:-}" ] && rm -rf "$SIGNDIR" 2>/dev/null||true
  [ "$KEEP" = 1 ] && { log "--keep"; return; }; log "teardown"
  $COMPOSE down -v --remove-orphans 2>/dev/null||true; docker rm -f ota-etcd 2>/dev/null||true
  ( cd "$SERVER_DIR" 2>/dev/null && docker compose down 2>/dev/null )||true; }
trap cleanup EXIT
ctl(){ docker exec ota-controller bash -lc "$*"; }
bfc(){ docker exec "ota-$1" sh -c 'ps -eo args 2>/dev/null|grep -c "/opt/theia/current/bin/[a-z]"' 2>/dev/null||echo 0; }
fcs(){ docker exec "ota-$1" sh -c 'ps -eo args 2>/dev/null|grep "/opt/theia/current/bin/"|grep -v grep|sed "s|.*/bin/||;s| .*||"|sort|tr "\n" " "' 2>/dev/null; }

###############################################################################
# PRE-FLIGHT — free the ports a LOCAL dev stack holds, so the e2e's own
# containers can bind them. When run on a dev box (not a clean CI runner), a
# leftover `theia rig up` (deploy/docker-compose.yml: theia-central/compute +
# etcd) or a `theia start` supervisor holds the SAME host ports the e2e maps:
# com's gRPC views 7700/7710/7711 (ota-central). (S3 maps no host port.)
# A collision surfaces as "port is already allocated" on `compose up`. Bring the
# theia rig DOWN and stop any local supervisor + stray ota-* containers first.
# No-op on a clean CI runner (nothing to tear down).
###############################################################################
preflight_teardown() {
  log "pre-flight — free local ports (theia rig down + stray containers)"
  # 1) the theia dev rig (deploy/docker-compose.yml) — down if the theia CLI is on
  #    PATH and a compose file exists. Ignore failures (no stack / no compose).
  if command -v theia >/dev/null 2>&1 && [ -f "$THEIA_DIR/deploy/docker-compose.yml" ]; then
    ( cd "$THEIA_DIR" && theia rig down ) >/dev/null 2>&1 || true
    docker compose -f "$THEIA_DIR/deploy/docker-compose.yml" --profile etcd down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  # 2) a local `theia start` supervisor holding 7700/7710/7711 (com gRPC views).
  #    Kill only supervisors bound to those ports (leave unrelated ones alone).
  for port in 7700 7710 7711; do
    pid="$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)" || true
    [ -n "${pid:-}" ] && { echo "  freeing :$port (pid $pid)"; kill "$pid" 2>/dev/null || true; }
  done
  # 3) stray ota-* containers from a prior aborted run (compose down missed them).
  docker rm -f ota-central ota-compute ota-controller ota-s3 ota-minio ota-etcd >/dev/null 2>&1 || true
  $COMPOSE down -v --remove-orphans >/dev/null 2>&1 || true
  ok "pre-flight teardown done (ports 7700/7710/7711 free)"
}
preflight_teardown

###############################################################################
log "STEP 1 — fresh theia (checked out at $THEIA_DIR)"; ok "theia present"
###############################################################################

###############################################################################
log "STEP 2 — build runtime + services (manifest.services.rig (RIG=all 16 FCs)) → dist"
###############################################################################
cd "$THEIA_DIR"
# The services deb's Depends line is distro-specific (com/per link grpc++/protobuf
# SHARED, and the soname package names differ): 22.04 → libgrpc++1, libprotobuf23;
# 24.04 → libgrpc++1.51t64, libprotobuf32t64. The build emits the 22.04 names by
# default; on a 24.04 host pass --define distro=ubuntu24 so the deb declares the
# packages the (matching 24.04) board actually has. Else dpkg --install fails on
# "libgrpc++1 not installed". Derive from the build host's VERSION_ID.
DISTRO_DEF=()
case "${VERSION_ID:-}" in
  24.*) DISTRO_DEF=(--define=distro=ubuntu24) ;;
esac
# the services factory rig (ALL 16 FCs on central) builds the runtime+services debs.
bazel build //packaging/theia:theia-runtime_deb //packaging/theia:theia-services_deb \
  --platforms=//rules/config:host "${DISTRO_DEF[@]}" || die "runtime/services .deb build failed"
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
log "STEP 3 — release runtime+services → S3 (SeaweedFS theia-runtime/$RTVER)"
###############################################################################
# TIPC kernel module on the HOST (the boards' bearers need it; a privileged
# container can't load it). The cross-board link itself is a real eth bearer over
# the bridge (registries set tipc_bearer: eth0) — separate per-board namespaces.
sudo modprobe tipc 2>/dev/null || modprobe tipc 2>/dev/null || die "modprobe tipc"
# Bridge: bring the S3 (SeaweedFS) up on the ota-e2e bridge; resolve it by IP for the
# host-side push (the controller + boards reach it by the `ota-s3` DNS name). etcd is
# NOT a host container — central runs its own (own netns) at orchestrate time.
docker rm -f ota-s3 2>/dev/null || true
COLONY_DIR="$COLONY_DIR" THEIA_DIR="$THEIA_DIR" GROUND_STATION_DIR="$GROUND_STATION_DIR" \
  $COMPOSE up -d s3 2>&1 | tail -1
S3_IP=""
for i in $(seq 1 60); do
  S3_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ota-s3 2>/dev/null)"
  [ -n "$S3_IP" ] && curl -sf "http://$S3_IP:9000/healthz" >/dev/null 2>&1 && break
  S3_IP=""; sleep 1
done
[ -n "$S3_IP" ] || die "S3 (SeaweedFS) not ready on the bridge"
S3="http://$S3_IP:9000"             # host-side push target (boards use ota-s3:9000)
# Serialize the runtime manifest FIRST — push-runtime-s3.sh bundles
# dist/manifest into manifest.tar.gz (the object provision fetches).
# serialize the SERVICES split (compute=ucm+shwa) → the bundle the colony registry
# slices reference (executor.json per machine). This is the platform base.
cd "$THEIA_DIR"
PYTHONPATH="$THEIA_DIR/artheia:$THEIA_DIR" \
  artheia serialize-manifest manifest.services.rig \
  --out "$THEIA_DIR/dist/manifest" || die "rig MULTI serialize failed"
# HW-gate the master executor IN THE SERIALIZED BASE (so the S3 manifest carries
# the correct 14-FC tree with the right run_on_start flags). This is what
# `theia manifest services` does via deploy/config/master/executor.json — but the
# bare `artheia serialize-manifest` above doesn't apply that override, and colony's
# on-device config-override merges executor.json with combine(recursive) where
# LISTS REPLACE (it would truncate children[] to just the override's entries). So
# set the flags here, on the FULL tree, instead:
#   nm      — would tear down the shared docker host iface
#   fw/tsync/rds — the HW-gated safe base (netfilter / PTP clock / RouDi shm); a
#                  bare rig lacks them, so define-but-don't-boot (matches
#                  deploy/config/master/executor.json).
python3 - "$THEIA_DIR/dist/manifest/master/executor.json" <<'PY'
import json,sys; p=sys.argv[1]; t=json.load(open(p))
GATE={"nm","fw","tsync","rds"}
def f(n):
  if n.get("type")=="worker" and n.get("name") in GATE: n["run_on_start"]=False
  for c in n.get("children",[]): f(c)
f(t); json.dump(t,open(p,"w"),indent=2)
PY

bash "$HERE/helpers/push-runtime-s3.sh" "$RTVER" "$S3" "$RT_DEB" "$SV_DEB" || die "runtime → S3 push failed"
# the anonymous-read grant (seaweedfs-s3.json) is what the rigs' fetch relies on
curl -sf -o /dev/null "$S3/theia-runtime/$RTVER/index.json" || die "S3: anonymous read of theia-runtime/ refused"
ok "runtime+services published to s3://theia-runtime/$RTVER/ (bridge S3 $S3_IP)"

###############################################################################
log "STEP 3.5 — generate the SWP signing key + ship the PUBLIC key to S3"
###############################################################################
# App-plane authenticity: generate an EPHEMERAL keypair (nothing persisted),
# upload ONLY the public verify key to the S3 provisioning plane (colony's
# install-mender.yml pulls it onto each rig → mender.conf ArtifactVerifyKey), and
# export THEIA_SWP_SIGN_KEY so deb-to-mender.sh SIGNS the artifacts. The rig then
# ACCEPTS the signed release and REFUSES any unsigned/forged one.
SIGNDIR="$(mktemp -d)"   # cleaned by cleanup() on EXIT (the nightly's own trap)
THEIA_SIGNING_DIR="$SIGNDIR" theia cert generate >/dev/null 2>&1 \
  || die "cert generate failed"
THEIA_SIGNING_DIR="$SIGNDIR" theia cert copy --s3 "$S3" --bucket theia-runtime \
  || die "cert copy (verify key → S3) failed"
export THEIA_SWP_SIGN_KEY="$SIGNDIR/theia-swp-signing.key"
[ -f "$THEIA_SWP_SIGN_KEY" ] || die "signing key missing after generate"
ok "SWP signing key generated (ephemeral); PUBLIC verify key → s3://theia-runtime/provisioning/"

###############################################################################
log "STEP 4 — provision master+zonal FROM S3 (master=singletons, zonal=ucm+shwa)"
###############################################################################
# (the manifest was serialized in STEP 3, before the runtime push, so
# push-runtime-s3.sh could bundle it into manifest.tar.gz.)
# bring up boards + controller
COLONY_DIR="$COLONY_DIR" THEIA_DIR="$THEIA_DIR" GROUND_STATION_DIR="$GROUND_STATION_DIR" \
  $COMPOSE up -d --build central compute controller 2>&1 | tail -2
for b in central compute; do
  for i in $(seq 1 30); do ctl "ansible -i 'ota-$b,' ota-$b -c community.docker.docker -m ping" >/dev/null 2>&1 && break
    sleep 2; [ "$i" = 30 ] && die "docker-conn $b"; done; ok "controller → $b"
done
# The THROWAWAY fleet CA (TEST ONLY): the controller runs the ground station's own
# signer (routers/pki.py, loaded from the ground-station checkout) on its loopback.
# colony provision/orchestrate get -e gs_pki_url=<it>, so tasks/pki-enroll.yml — the
# path a field rig takes — generates each rig's key ON the rig, carries the CSR here
# and installs /etc/theia/pki/{device.crt,device.key,ca.crt}. The CA dies with the
# controller container. NO com_insecure anywhere: com on these rigs must serve mTLS.
docker exec -d ota-controller sh -c "GS_PKI_DIR=/tmp/e2e-fleet-ca GS_API_KEY=$GS_API_KEY \
  python3 /repo/colony/test/ota-e2e/helpers/pki-signer.py --port $PKI_PORT >/tmp/pki-signer.log 2>&1"
for i in $(seq 1 30); do
  ctl "curl -sf -H 'X-GS-Key: $GS_API_KEY' $PKI_URL/api/pki/ca >/dev/null" 2>/dev/null && break
  sleep 1; [ "$i" = 30 ] && die "the e2e fleet signer did not come up ($(docker exec ota-controller cat /tmp/pki-signer.log 2>&1 | tail -3))"
done
ctl "curl -s -o /dev/null -w '%{http_code}' $PKI_URL/api/pki/ca" | grep -q 401 \
  || die "the e2e fleet signer answers without the API key"
ok "throwaway fleet CA up in the controller ($PKI_URL, API-key gated)"
# colony is S3-EXCLUSIVE (registry-free): drive it by --host + --role, exactly
# as the Ground Station does. The docker test rigs use the docker connection, so
# pass target_connection=community.docker.docker (not ansible_connection — the
# playbook add_host reads target_connection). role: central=master, compute=zonal.
# GS_API_KEY: pki-enroll.yml sends it to the signer (lookup('env', 'GS_API_KEY')).
CENV="THEIA_WORKSPACE=/repo/theia COLONY_ANSIBLE=/repo/colony/ansible GS_API_KEY=$GS_API_KEY"
MAN="-e manifest_dir=/repo/theia/dist/manifest"
RUN="-e theia_run_src=/repo/theia/platform/runtime/ota/theia-run.sh"
DCONN="-e target_connection=community.docker.docker"
# The docker test rigs only have root — the registry used to set ansible_user:root;
# the inventory default is axadmin (a real rig's login), so pass root explicitly or
# ansible connects as axadmin, whose $HOME doesn't exist → UNREACHABLE on ~/.ansible.
DUSER="-e ansible_user=root"
S3E="-e s3_endpoint=http://ota-s3:9000 -e s3_runtime_bucket=theia-runtime -e runtime_version=$RTVER"
PKI="-e gs_pki_url=$PKI_URL"
# central=master (etcd here), compute=zonal (etcd_external). machine_instance
# distinguishes the boards (master=0, zonal=1) on the shared docker host TIPC ns.
for spec in "central master 0 false" "compute zonal 1 true"; do
  set -- $spec; b=$1; role=$2; inst=$3; ext=$4
  # the multi-board facts the (no longer read) registry/*.yml carried: the cross-board
  # TIPC eth bearer + cluster scope; central's etcd listens on the bridge for compute.
  EV="$MAN $DCONN $DUSER $S3E $PKI -e role=$role -e machine_instance=$inst -e etcd_external=$ext"
  EV="$EV -e tipc_bearer=eth0 -e tipc_scope=cluster -e deb_arch=amd64"
  [ "$b" = central ] && EV="$EV -e etcd_listen_host=0.0.0.0 -e etcd_advertise_host=central"
  log "provision $b (Phase 1, role=$role)"
  ctl "$CENV /repo/colony/bin/colony provision $b --host ota-$b --role $role $EV -e mender_artifacts_dir=/repo/theia/platform/runtime/ota" \
    || die "provision $b failed"
  log "orchestrate $b (install runtime+services FROM S3, start)"
  ctl "$CENV /repo/colony/bin/colony orchestrate $b --host ota-$b --role $role $EV $RUN -e autostart=true" \
    || die "orchestrate $b failed"
done
sleep 8
# Verify the boards INSTALLED FROM S3 (stage-release.yml: releases/runtime-<runtime_version>).
docker exec ota-central sh -c 'ls /opt/theia/releases/runtime-'"$RTVER"'/bin/ >/dev/null 2>&1' \
  || die "central not on the S3 release releases/runtime-$RTVER"
ok "master/zonal base from S3: central=$(bfc central) FCs [$(fcs central)] compute=$(bfc compute) FCs [$(fcs compute)]"
# the zonal contract: compute runs ucm + shwa (NOT demo apps yet).
docker exec ota-compute sh -c 'ps -eo args|grep -qE "/current/bin/ucm( |$)"' \
  && ok "compute runs ucm (zonal base)" || die "compute missing ucm (zonal)"

###############################################################################
log "STEP 4b — REGRESSION: com serves MUTUAL TLS with the fleet certificate"
###############################################################################
# (a) every rig got its fleet identity through the normal provision path: the key was
#     made on the rig, the certificate chains to the e2e CA and matches the key.
for b in central compute; do
  docker exec "ota-$b" sh -c 'openssl verify -CAfile /etc/theia/pki/ca.crt /etc/theia/pki/device.crt >/dev/null &&
    [ "$(openssl x509 -in /etc/theia/pki/device.crt -noout -pubkey | openssl sha256)" = \
      "$(openssl pkey -in /etc/theia/pki/device.key -pubout | openssl sha256)" ]' \
    || die "pki_rig_identity: $b has no valid /etc/theia/pki (pki-enroll did not run?)"
  docker exec "ota-$b" sh -c '! grep -q THEIA_COM_INSECURE /etc/systemd/system/theia-supervisor.service &&
    [ ! -e /opt/theia/config/com-insecure ]' || die "com_insecure_absent: $b runs com in DEBUG plaintext"
done
ok "pki_rig_identity: both rigs hold a fleet cert (CN=$(docker exec ota-central openssl x509 -in /etc/theia/pki/device.crt -noout -subject | sed 's/.*CN *= *//;s/,.*//')) chained to the e2e CA; com_insecure_absent"
# (b) the test OPERATOR's client certificate, from the same signer via the ground
#     station's own tools/operator-cert.sh (role operator: observe, no Provision).
ctl "GS=$PKI_URL GS_API_KEY=$GS_API_KEY THEIA_FLEET_DIR=$OPDIR bash /repo/ground-station/tools/operator-cert.sh e2e-operator >/dev/null" \
  || die "operator-cert.sh against the e2e signer failed"
ok "operator certificate issued (e2e-operator, role operator)"
# (c) com on each rig that RUNS com (the master's singletons — zonal runs none):
#     operator cert → ListMachines; plaintext / no client cert / foreign CA / wrong
#     rig name → refused. helpers/com-mtls-check.py names each check.
com_mtls_checks() {   # $1 = phase label
  local n=0 b ip
  for b in central compute; do
    docker exec "ota-$b" sh -c 'ps -eo args | grep -qE "/current/bin/com( |$)"' || continue
    n=$((n+1)); ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "ota-e2e").IPAddress}}' "ota-$b")"
    log "com mTLS checks on $b ($1)"
    ctl "python3 $CHERE/helpers/com-mtls-check.py --target $b:7700 --address $ip:7700 \
         --ca $OPDIR/ca.crt --cert $OPDIR/operator.crt --key $OPDIR/operator.key" \
      || die "com mutual-TLS regression failed on $b ($1)"
    # the com log line theia-run.sh + com_tls.hpp promise on a deployed rig
    docker exec "ota-$b" sh -c 'journalctl -u theia-supervisor --no-pager 2>/dev/null; cat /tmp/theia/*.log 2>/dev/null' \
      | grep -E 'gRPC: TLS on \(cert=/etc/theia/pki/device.crt.*MUTUAL' | tail -1 | grep -q . \
      && ok "com_log_mutual_tls: $b logs 'TLS on (cert=/etc/theia/pki/device.crt … MUTUAL'" \
      || die "com_log_mutual_tls: no 'gRPC: TLS on … MUTUAL' line from com on $b"
  done
  [ "$n" -ge 1 ] || die "no rig runs com — nothing to check ($1)"
}
com_mtls_checks "after provision"
ok "com serves MUTUAL TLS only (fleet cert, client certs required + verified)"

###############################################################################
log "STEP 5 — compose the app-plane release trees (one per machine)"
###############################################################################
# theia/demo/ (the consuming workspace this step used to scaffold) was RETIRED in
# theia 5d0b3eda (2026-07-10: the ci/ harness owns the user-flow role), so the app
# plane is composed from what this run built: the runtime+services binaries (STEP 2)
# + each machine's supervision tree and per-FC config (the STEP 3 manifest). That is
# a complete release in the two-plane layout theia-run.sh reads — current/bin +
# current/config/executor.json — and exercises the same OTA path (Mender → the
# theia-release module → current flip → supervisor restart) the demo apps did.
APPS="$HERE/.apps"; rm -rf "$APPS"; mkdir -p "$APPS/roles"
for m in master zonal; do
  t="$APPS/$m/root"; mkdir -p "$t"
  dpkg-deb -x "$THEIA_DIR/$RT_DEB" "$t"; dpkg-deb -x "$THEIA_DIR/$SV_DEB" "$t"
  tree="$t/opt/theia"; mkdir -p "$tree/config"
  cp "$THEIA_DIR/dist/manifest/$m/executor.json" "$THEIA_DIR/dist/manifest/machines.json" "$tree/config/"
  [ -d "$THEIA_DIR/dist/manifest/$m/config" ] && cp "$THEIA_DIR/dist/manifest/$m/config/"*.json "$tree/config/" 2>/dev/null || true
  # the theia-release module refuses links/devices in a payload: assert there are none
  [ -z "$(find "$tree" ! -type f ! -type d | head -1)" ] || die "app tree $m has non-regular members"
done
ok "app trees: master=$(ls "$APPS/master/root/opt/theia/bin" | wc -l) bins, zonal=$(ls "$APPS/zonal/root/opt/theia/bin" | wc -l) bins (+ config/executor.json)"

###############################################################################
log "STEP 6+7 — pack the app releases as SIGNED .mender → S3 (the app plane)"
###############################################################################
# DEVICE ↔ MACHINE: the rig is ROLE-KEYED (machines master/zonal), the DEVICES
# (containers/Mender identities) are central/compute. The artifact for device <dev>
# is packed from the <machine> tree and NAMED by the device (group-and-deploy
# targets it by device identity):  central ← master  |  compute ← zonal
pack() {  # $1=device $2=machine $3=version → $APPS/roles/<dev>-<ver>.mender (signed iff THEIA_SWP_SIGN_KEY)
  DIST_ROOT="$APPS" "$HERE/helpers/deb-to-mender.sh" "$1" "$3" "$APPS/$2/root/opt/theia"
}
packed() {  # pack + assert deb-to-mender's verdict word ($4 = SIGNED | unsigned). No `tee /dev/stderr`:
  local o     # reopening stderr TRUNCATES a log the run is redirected into.
  o="$(pack "$1" "$2" "$3")" || return 1; echo "$o"; echo "$o" | grep -qE " $4\$"
}
for pair in "central master" "compute zonal"; do
  set -- $pair
  packed "$1" "$2" 1.0 SIGNED || die "pack $1-1.0 (machine=$2) not SIGNED"
done
bash "$HERE/helpers/push-runtime-s3.sh" "apps-1.0" "$S3" \
  "$APPS/roles/central-1.0.mender" "$APPS/roles/compute-1.0.mender" \
  >/dev/null 2>&1 || true   # app plane is informational here; OTA goes via Mender
ok "app releases 1.0 packed (signed) + staged in S3"

###############################################################################
log "STEP 8 — app OTA over Mender (central+compute)"
###############################################################################
# Mender server up (the app OTA transport), then JOIN its traefik to the ota-e2e
# bridge so the boards (own netns) reach the API by IP — the dalek-safe model.
# RESET first: the mender_mongo/s3 volumes PERSIST across runs (up.sh reuses
# them), so stale deviceauth auth-sets accumulate → a re-enrolling board (same
# MAC identity) gets "dev auth: unauthorized" instead of landing PENDING. Wipe
# the state (keeps the pulled images — no ~2GB re-pull).
MENDER_SERVER_DIR="$SERVER_DIR" bash "$GROUND_STATION_DIR/mender/server/up.sh" reset
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
  # KEEP stderr: enroll-rig.sh emits its reachability pre-check + the mender-authd
  # journal dump on failure there — suppressing it (the old `>/dev/null 2>&1`)
  # hid WHY enrol failed. Drop only the (verbose apt/install) stdout.
  # SERVER_SSH: enroll-rig.sh requires it even when SERVER_CA is given (it is only
  # read when SERVER_CA is absent): a placeholder, never contacted.
  ctl "RIG_EXEC=docker DEVICE_ID=$b SERVER_CA=/repo/ground-station/.srv-ca.crt SERVER_SSH=unused-ca-from-file \
       bash /repo/ground-station/mender/server/enroll-rig.sh ota-$b $TRAEFIK_IP docker.mender.io $MENDER_EMAIL $MENDER_PASS" \
    >/dev/null || die "enroll $b"
done
ok "boards enrolled"
GAD() { ctl "ROLES_DIR=$CHERE/.apps/roles $CHERE/helpers/group-and-deploy.sh $TRAEFIK_IP $MENDER_EMAIL $MENDER_PASS $*"; }
kick() { docker exec "ota-$1" sh -c 'kill -USR1 $(pgrep -x mender-update) 2>/dev/null' || true; }
await_release() {  # $1=board $2=release name → current must flip to it
  local cur i
  for i in $(seq 1 45); do
    cur="$(docker exec "ota-$1" readlink /opt/theia/current 2>/dev/null || echo NONE)"
    case "$cur" in *"/$2") ok "$1 OTA delivered $cur"; return 0;; esac
    kick "$1"; sleep 4
  done
  die "$1 never flipped to $2 ($cur)"
}
# deploy the app release (1.0) over Mender.
GAD central-1.0 compute-1.0 || die "app deploy failed"
for b in central compute; do await_release "$b" "$b-1.0"; done
# The theia-release module lands the bits + flips current; restart the supervisor so
# it runs the new release's tree (current/config/executor.json, current/bin).
for b in central compute; do docker exec "ota-$b" systemctl restart theia-supervisor; done
sleep 12
docker exec ota-compute sh -c 'ps -eo args|grep -qE "/current/bin/ucm( |$)"' \
  || die "compute not running its release after the OTA ($(bfc compute) FCs: $(fcs compute))"
ok "composer: central=$(bfc central) FCs [$(fcs central)] compute=$(bfc compute) FCs [$(fcs compute)]"
com_mtls_checks "after the app OTA + supervisor restart"

###############################################################################
log "STEP 8.5 — SIGNED PATCH rollout (1.0 → 1.0.1) — proves signing gates the OTA"
###############################################################################
# Re-pack the SAME app tree as a PATCH (1.0.1), SIGNED with the same ephemeral key
# ($THEIA_SWP_SIGN_KEY, exported in STEP 3.5), and deploy it. The rigs provisioned
# with ArtifactVerifyKey MUST accept it (correct signature) and flip current →
# <dev>-1.0.1.
for pair in "central master" "compute zonal"; do
  set -- $pair
  packed "$1" "$2" 1.0.1 SIGNED || die "pack $1-1.0.1 not SIGNED"
done
bash "$HERE/helpers/push-runtime-s3.sh" "apps-1.0.1" "$S3" \
  "$APPS/roles/central-1.0.1.mender" "$APPS/roles/compute-1.0.1.mender" \
  >/dev/null 2>&1 || true
GAD central-1.0.1 compute-1.0.1 || die "PATCH app deploy failed"
for b in central compute; do await_release "$b" "$b-1.0.1"; done
ok "SIGNED PATCH rollout landed on both rigs (verify key gated + accepted the patch)"

###############################################################################
log "STEP 8.6 — REGRESSION: an UNSIGNED artifact is REFUSED (unsigned_artifact_refused)"
###############################################################################
# The same tree, packed WITHOUT the key. The rig (mender.conf ArtifactVerifyKey) must
# refuse it: the Mender deployment ends in failure and current stays on 1.0.1.
( unset THEIA_SWP_SIGN_KEY; packed central master 1.0.2-unsigned unsigned ) \
  || die "could not pack the unsigned control artifact"
out="$(GAD central-1.0.2-unsigned '""')" || die "unsigned deploy could not be created"
echo "$out"
DEP_ID="$(echo "$out" | grep -oE 'id [0-9a-f-]{36}' | tail -1 | cut -d' ' -f2)"
[ -n "$DEP_ID" ] || die "no deployment id for the unsigned artifact"
PRE="$(docker exec ota-central readlink /opt/theia/current)"
verdict=""
for i in $(seq 1 45); do
  kick central; sleep 4
  st="$(ctl "export MENDER_TOKEN=\$(curl -sk -u '$MENDER_EMAIL:$MENDER_PASS' -X POST https://$TRAEFIK_IP/api/management/v1/useradm/auth/login);
             python3 /repo/ground-station/fleet/fleet.py --server https://$TRAEFIK_IP --insecure status $DEP_ID" 2>/dev/null || true)"
  if echo "$st" | grep -qE '"failure": *[1-9]'; then verdict=failure; break; fi
  if echo "$st" | grep -qE '"success": *[1-9]'; then verdict=success; break; fi
done
echo "$st"
[ "$(docker exec ota-central readlink /opt/theia/current)" = "$PRE" ] \
  || die "unsigned_artifact_refused: central FLIPPED to the unsigned release ($(docker exec ota-central readlink /opt/theia/current))"
[ "$verdict" = failure ] || die "unsigned_artifact_refused: deployment $DEP_ID did not fail (verdict: ${verdict:-timeout})"
docker exec ota-central sh -c 'journalctl -u mender-updated --no-pager 2>/dev/null | grep -iE "signature|verif" | tail -2' || true
ok "unsigned_artifact_refused: deployment $DEP_ID failed on central, current stays $PRE"

###############################################################################
log "STEP 9 — RF audit/consistency over the composer's TIPC"
###############################################################################
"$HERE/helpers/rf-audit.sh" || die "RF audit/consistency failed"
ok "RF audit/consistency PASSED"

log "FULL STORY GREEN (9/9 steps + mTLS and signing regressions, no skips)"; ok "nightly story OK"
