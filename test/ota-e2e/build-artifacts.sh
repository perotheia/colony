#!/usr/bin/env bash
# build-artifacts.sh — produce everything the OTA e2e run consumes, from the DEMO
# workspace (services on central + the demo apps p1-p4 + shwa on compute). This is
# the canonical demo split, so the OTA payload is the FULL demo release (services +
# apps), and nm lands on central — exercising run_on_start=false.
#
#   demo/dist/manifest/{central,compute}/         the DOCKER (x86) split + .deb
#   demo/dist/roles/{central,compute}-0.2.1.mender   first-install role artifacts
#   demo/dist/roles/{central,compute}-0.2.2.mender   the update
#   demo/dist/roles/central-0.2.3-broken.mender      the rollback test
#
# x86_64 / gzip (portable). The bazel build is the heavy stage; CI caches it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
THEIA_DIR="${THEIA_DIR:-$(cd "$HERE/../../../theia" && pwd)}"
DEMO_DIR="$THEIA_DIR/demo"
export PATH="$THEIA_DIR/.venv/bin:$PATH"
export THEIA_WORKSPACE="$DEMO_DIR"
export ARTIFACT_COMPRESS=gzip          # portable — boards may lack zstd
ARCH="host"
log() { printf '\n[build] %s\n' "$*"; }

cd "$DEMO_DIR"

# ── 1. the DOCKER split manifest (services on central, demo apps on compute) ──
# `theia manifest` (incl. per-FC config). The demo workspace must have its
# system/platform/msgs link (theia init --with-services plants it) so services that
# reference platform msgs — tsync → nav.GnssSolution — resolve; an older demo
# without it fails gen-params. `theia init` is idempotent, so (re)link it here.
log "theia init --with-services (idempotent — ensures the msgs link) + manifest split"
( cd "$DEMO_DIR" && THEIA_INVOCATION_CWD="$DEMO_DIR" theia init --with-services --name demo >/dev/null 2>&1 || true )
theia manifest split --attr DOCKER || { echo "[build] manifest failed" >&2; exit 1; }

# Mark nm run_on_start=false in central's executor.json — nm would reconfigure the
# host's net iface in a shared-namespace container and break the run. The supervisor
# honors run_on_start=false (defined-but-not-booted). Patch the emitted tree.
log "patch nm → run_on_start:false in central/executor.json"
python3 - "$DEMO_DIR/dist/manifest/central/executor.json" <<'PY'
import json, sys
p = sys.argv[1]; t = json.load(open(p))
def patch(n):
    if n.get("type") == "worker" and n.get("name") == "nm":
        n["run_on_start"] = False
    for c in n.get("children", []): patch(c)
patch(t)
json.dump(t, open(p, "w"), indent=2)
print("  nm run_on_start=false set")
PY

# ── 2. per-machine .deb bundles (theia dist — bazel) ──
log "theia dist (per-machine .deb — bazel, heavy)"
theia dist || { echo "[build] theia dist failed" >&2; exit 1; }
for m in central compute; do
  if [ ! -f "dist/manifest/$m/$m.deb" ]; then
    f="$(find dist bazel-bin -name "$m*.deb" 2>/dev/null | head -1 || true)"
    [ -n "$f" ] && cp "$f" "dist/manifest/$m/$m.deb"
  fi
done

# ── 3. the role .mender artifacts, packed FROM the dist .deb's /opt/theia tree ──
# NOT `theia release-role` — that builds //packaging/theia, a framework target the
# demo (consuming) workspace doesn't have. The per-machine dist .deb already carries
# the right tree (central=services incl nm, compute=demo apps p1-p4+shwa), so we pack
# the .mender straight from it — the demo apps land in the OTA payload.
for ver in 0.2.1 0.2.2; do
  for role in central compute; do
    log "pack $role-$ver.mender (from $role.deb)"
    DIST_ROOT="$DEMO_DIR/dist" "$HERE/helpers/deb-to-mender.sh" \
      "$role" "$ver" "$DEMO_DIR/dist/manifest/$role/$role.deb" \
      || { echo "[build] deb-to-mender $role-$ver failed" >&2; exit 1; }
  done
done
# make 0.2.2 differ from 0.2.1 (a real update — a marker file in the tree)
DIST_ROOT="$DEMO_DIR/dist" "$HERE/helpers/stamp-version.sh" central 0.2.2
DIST_ROOT="$DEMO_DIR/dist" "$HERE/helpers/stamp-version.sh" compute 0.2.2

# ── 4. the deliberately-broken artifact (rollback test) ──
log "pack central-0.2.3-broken.mender"
DIST_ROOT="$DEMO_DIR/dist" "$HERE/helpers/build-broken.sh" central 0.2.3

log "done — artifacts under $DEMO_DIR/dist/{manifest,roles}/"
ls -la "$DEMO_DIR"/dist/roles/*.mender
