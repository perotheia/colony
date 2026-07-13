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
# (central only; compute stays idle). Reuses the ota-e2e compose (bridge net,
# per-board TIPC ns), the Mender server bring-up, colony provisioning and the
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
# The consuming workspace this run scaffolds (fresh unless --no-build).
WS="$HERE/work/migration-ws"
KEEP=0; DO_BUILD=1
for a in "$@"; do case "$a" in --keep) KEEP=1;; --no-build) DO_BUILD=0;; esac; done

export PATH="$THEIA_DIR/.venv/bin:$PATH"
export ARTIFACT_COMPRESS=gzip

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; dump_logs; exit 1; }
dump_logs() { mkdir -p "$HERE/logs"; for c in ota-central ota-controller; do
  docker exec "$c" journalctl --no-pager >"$HERE/logs/$c.migration.journal" 2>&1 || true; done; }
cleanup() { [ "$KEEP" = 1 ] && { log "--keep: stack left up"; return; }
  log "teardown"; $COMPOSE down -v --remove-orphans 2>/dev/null || true
  ( cd "$SERVER_DIR" 2>/dev/null && docker compose down 2>/dev/null ) || true; }
trap cleanup EXIT

ctl()  { docker exec ota-controller bash -lc "$*"; }
bexec(){ docker exec ota-central sh -c "$*"; }
# on-board config get/put (raw bytes; encode/decode stays host-side)
bcfg() { docker exec ota-central python3 /opt/theia/e2e/board-config.py "$@"; }

# colony verb via the controller (test registry, THIS ws's manifest)
CENV="THEIA_WORKSPACE=/repo/ws COLONY_ANSIBLE=/repo/colony/ansible COLONY_REGISTRY=/repo/colony/test/ota-e2e/registry"
MAN="/repo/ws/dist/manifest"
colony() { ctl "$CENV /repo/colony/bin/colony $1 $2 -e manifest_dir=$MAN ${3:-}"; }

# host-side proto codec: encode/decode CounterConfig via the ws venv probe codec
enc_counter() {  # $1..: field=value → hex on stdout
  python3 - "$@" <<'PY'
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
  python3 - "$1" <<'PY'
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
    && artheia gen-app --kind fc system/apps/component.art --out apps --proto-out proto >/dev/null \
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
  ( cd "$WS" && theia dist ) || die "theia dist failed"
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
MENDER_SERVER_DIR="$SERVER_DIR" bash "$GROUND_STATION_DIR/mender/server/up.sh" up
MENDER_SERVER_DIR="$SERVER_DIR" bash "$GROUND_STATION_DIR/mender/server/up.sh" user "$MENDER_EMAIL" "$MENDER_PASS" 2>/dev/null || true
ok "mender server up"
# the controller mounts THIS ws at /repo/ws
export BOARD_BASE="$( . /etc/os-release; echo "${ID:-ubuntu}:${VERSION_ID:-22.04}" )"
export WS_MOUNT="$WS"
COMPOSE="docker compose -f $HERE/docker-compose.yml -f $HERE/docker-compose.migration.yml"
$COMPOSE build
$COMPOSE up -d
for i in $(seq 1 30); do
  ctl "ansible -i 'ota-central,' ota-central -c community.docker.docker -m ping" >/dev/null 2>&1 && break
  sleep 2; [ "$i" = 30 ] && die "docker-conn to central never came up"
done
docker exec ota-central sh -c "grep -q docker.mender.io /etc/hosts || echo '$(docker network inspect ota-e2e -f '{{(index .IPAM.Config 0).Gateway}}') docker.mender.io s3.docker.mender.io' >> /etc/hosts"
ok "boards up; docker.mender.io wired"

###############################################################################
log "PHASE 2 — provision + orchestrate central (v1 live)"
###############################################################################
colony provision central "-e mender_artifacts_dir=/repo/theia/platform/runtime/ota" || die "provision failed"
colony orchestrate central "-e autostart=true" || die "orchestrate failed"
sleep 8
FCN="$(bexec 'ps -eo args 2>/dev/null | grep -c "/opt/theia/current/bin/[a-z]"' || echo 0)"
[ "$FCN" -ge 10 ] || die "central FC count $FCN < 10"
bexec 'ps -eo args | grep -q "/opt/theia/current/bin/p1"' || die "p1 (counter) not running"
ok "central v1 live ($FCN FCs incl. p1)"
# stage the on-board helper
docker exec ota-central mkdir -p /opt/theia/e2e
docker cp "$HERE/helpers/board-config.py" ota-central:/opt/theia/e2e/board-config.py

###############################################################################
log "PHASE 3 — enroll central"
###############################################################################
cp "$SERVER_DIR/compose/certs/mender.crt" "$GROUND_STATION_DIR/.srv-ca.crt" 2>/dev/null || die "no server CA"
ctl "SERVER_CA=/repo/ground-station/.srv-ca.crt bash /repo/ground-station/mender/server/enroll-rig.sh ota-central 127.0.0.1 docker.mender.io $MENDER_EMAIL $MENDER_PASS" || die "enroll failed"
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
( cd "$WS" && artheia gen-app --kind fc system/apps/component.art --out apps --proto-out proto >/dev/null ) || die "regen failed"
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
ART_V2="apps-2.0.0"
[ -f "$WS/dist/apps/apps/$ART_V2.mender" ] || die "no $ART_V2.mender"
tar -tzf "$WS/dist/apps/apps/$ART_V2.tar.gz" | grep -q "migration/00-migrate-config.py" \
  || die "migration driver not in the v2 payload"
ok "v2 --migrate released ($DIG_V1 → $DIG_V2), driver packed"

log "deploy v2 via Mender"
ctl "ROLES_DIR=/repo/ws/dist/apps/apps bash /repo/colony/test/ota-e2e/helpers/group-and-deploy.sh 127.0.0.1 $MENDER_EMAIL $MENDER_PASS $ART_V2 ''" \
  || die "mender deploy failed"
# wait for the SWP to land (the module logs to the mender deployment; poll per state)
for i in $(seq 1 40); do
  GOT="$(bcfg get counter 2>/dev/null || echo '{}')"
  echo "$GOT" | grep -q "$DIG_V2" && break
  docker exec ota-central sh -c 'kill -USR1 $(pgrep -x mender-update) 2>/dev/null' || true
  sleep 6; [ "$i" = 40 ] && die "config never flipped to v2 digest (last: $GOT)"
done
HEX_NOW="$(echo "$GOT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hex"])')"
VALS="$(dec_counter "$HEX_NOW")"
echo "  migrated config: $VALS"
echo "$VALS" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["ceiling"] == 250, f"ceiling {d[\"ceiling\"]} != 250 (seeded max_value NOT carried)"
assert d["warn_at"] == 90,  f"warn_at {d[\"warn_at\"]} != 90 (add-rule default)"
assert d["step"] == 7,      f"step {d[\"step\"]} != 7 (untouched field lost)"
' || die "migrated values wrong"
bexec 'ls /tmp/theia/dbbackup/pre-apps-2.0.0*.persnap' >/dev/null 2>&1 || die "no pre-update snapshot on board"
ok "MIGRATED: digest v2, ceiling=250 carried, warn_at=90 added, snapshot present"

###############################################################################
log "PHASE 6 — rollback restore (driver --rollback) → config back at v1"
###############################################################################
bexec 'python3 /opt/theia/swp/apps/migration/00-migrate-config.py /opt/theia --rollback' \
  || die "driver --rollback failed"
GOT="$(bcfg get counter)"
echo "$GOT" | grep -q "$DIG_V1" || die "config did not restore to v1 digest: $GOT"
HEX_BACK="$(echo "$GOT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hex"])')"
[ "$HEX_BACK" = "$HEX_V1" ] || die "restored bytes differ from the seeded v1 value"
ok "ROLLBACK: config restored byte-identical at v1"

log "OTA CONFIG-MIGRATION E2E: ALL GREEN"
