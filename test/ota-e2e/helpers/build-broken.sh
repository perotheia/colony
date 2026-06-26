#!/usr/bin/env bash
# build-broken.sh <role> <ver> — pack a DELIBERATELY corrupt theia-release
# artifact (a release.tar.gz that is not a valid tarball) so the on-device install
# fails mid-stage and the theia-release module rolls back. Proves the field-safety
# property + the rollback-target fix (rolls back to the RUNNING version).
set -euo pipefail
ROLE="${1:?role}"; VER="${2:?ver}"
THEIA_DIR="${THEIA_DIR:-$(cd "$(dirname "$0")/../../../../theia" && pwd)}"
MA="$(command -v mender-artifact-wrap || command -v mender-artifact)"
[ -n "$MA" ] || { echo "mender-artifact not found" >&2; exit 1; }

OUT="$THEIA_DIR/dist/roles/${ROLE}-${VER}-broken.mender"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
echo "${ROLE}-${VER}" > "$WORK/version.txt"
echo "THIS IS NOT A VALID TARBALL — deliberate fail for the rollback test" \
  > "$WORK/release.tar.gz"
"$MA" write module-image \
  --type theia-release --artifact-name "${ROLE}-${VER}" --device-type theia-rig \
  --file "$WORK/release.tar.gz" --file "$WORK/version.txt" \
  --output-path "$OUT" >/dev/null
echo "[broken] wrote $OUT"
