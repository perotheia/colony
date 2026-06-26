#!/usr/bin/env bash
# build-artifacts.sh — produce everything the OTA e2e run consumes, from source.
#
#   dist/manifest/{central,compute}/        the DOCKER (x86) split + per-machine .deb
#   dist/roles/{central,compute}-0.2.1.mender   the FIRST-install role artifacts
#   dist/roles/{central,compute}-0.2.2.mender   the UPDATE role artifacts
#   dist/roles/central-0.2.3-broken.mender      the deliberate-fail (corrupt payload)
#
# All x86_64 / gzip (the portable artifact compression — boards may lack zstd).
# This is the HEAVY stage (bazel builds the FC binaries); CI caches the bazel tree.
#
# Run from anywhere; operates on $THEIA_DIR (default: sibling ../../../theia).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
THEIA_DIR="${THEIA_DIR:-$(cd "$HERE/../../../theia" && pwd)}"
cd "$THEIA_DIR"
export PATH="$THEIA_DIR/.venv/bin:$PATH"

ARCH="host"                 # x86_64 native (the DOCKER attr)
log() { printf '\n[build] %s\n' "$*"; }

# ── 1. the DOCKER split manifest (x86 central+compute) + per-machine .deb ──────
log "serialize the DOCKER split manifest"
artheia serialize-manifest manifest.services.split_rig --attr DOCKER --out dist/manifest

log "build the per-machine .deb bundles (theia dist — bazel)"
# theia dist builds the per-host .deb from dist/manifest JSON. host arch.
theia dist || { echo "[build] theia dist failed" >&2; exit 1; }
# the .deb lands under bazel-bin or dist/manifest/<m>/<m>.deb depending on the rule;
# normalize to dist/manifest/<m>/<m>.deb (what install-bundle.yml's deb_src expects).
for m in central compute; do
  if [ ! -f "dist/manifest/$m/$m.deb" ]; then
    found="$(find dist bazel-bin -name "$m*.deb" 2>/dev/null | head -1 || true)"
    [ -n "$found" ] && cp "$found" "dist/manifest/$m/$m.deb"
  fi
done

# ── 2. the role .mender artifacts (first-install 0.2.1, update 0.2.2) ──────────
# Force gzip (portable). release-role builds the role tree from the services .deb.
export ARTIFACT_COMPRESS=gzip
for ver in 0.2.1 0.2.2; do
  for role in central compute; do
    log "pack $role-$ver.mender (theia-release, gzip)"
    theia release-role --role "$role" --arch "$ARCH" --version "$ver" --mender-only \
      || { echo "[build] release-role $role-$ver failed" >&2; exit 1; }
  done
done

# Make 0.2.2 genuinely DIFFER from 0.2.1 (a real update, not a no-op) by stamping
# a release-notes marker the assert step can see. release-role rebuilds the tree
# per call, so add the marker via a tiny repack of the 0.2.2 artifacts.
"$HERE/helpers/stamp-version.sh" central 0.2.2
"$HERE/helpers/stamp-version.sh" compute 0.2.2

# ── 3. the deliberately-broken artifact (corrupt tarball → install fails) ──────
log "pack central-0.2.3-broken.mender (corrupt payload → rollback test)"
"$HERE/helpers/build-broken.sh" central 0.2.3

log "done — artifacts under $THEIA_DIR/dist/{manifest,roles}/"
ls -la dist/roles/*.mender
