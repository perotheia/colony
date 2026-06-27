#!/usr/bin/env bash
# deb-to-mender.sh <machine> <ver> <deb> — pack a theia-release .mender from the
# /opt/theia tree inside a per-machine dist .deb (what `theia dist` builds).
#
# This sidesteps `theia release-role`, which builds //packaging/theia (a FRAMEWORK
# target absent from a consuming/demo workspace). The dist .deb already carries the
# right per-machine release tree (central = services incl nm; compute = demo apps
# p1-p4 + shwa), so we extract /opt/theia from it and pack THAT — the demo apps end
# up in the OTA payload, as intended. gzip (portable).
set -euo pipefail
MACHINE="${1:?machine}"; VER="${2:?ver}"; DEB="${3:?deb path}"
DIST_ROOT="${DIST_ROOT:-$(cd "$(dirname "$0")/../../../../theia/demo/dist" && pwd)}"
MA="$(command -v mender-artifact-wrap || command -v mender-artifact)"
[ -f "$DEB" ] || { echo "no deb: $DEB" >&2; exit 1; }
mkdir -p "$DIST_ROOT/roles"
OUT="$DIST_ROOT/roles/${MACHINE}-${VER}.mender"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# extract the deb's /opt/theia tree → the release dir
dpkg-deb -x "$DEB" "$WORK/root"
[ -d "$WORK/root/opt/theia" ] || { echo "deb has no /opt/theia tree" >&2; exit 1; }
# pack release.tar.gz from /opt/theia (bin/ lib/ …) + the version marker
echo "${MACHINE}-${VER}" > "$WORK/version.txt"
tar -C "$WORK/root/opt/theia" -czf "$WORK/release.tar.gz" .
"$MA" write module-image \
  --type theia-release --artifact-name "${MACHINE}-${VER}" --device-type theia-rig \
  --file "$WORK/release.tar.gz" --file "$WORK/version.txt" \
  --output-path "$OUT" >/dev/null
echo "[deb-to-mender] $OUT ($(du -h "$OUT" | cut -f1))"
