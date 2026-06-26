#!/usr/bin/env bash
# stamp-version.sh <role> <ver> — repack an existing dist/roles/<role>-<ver>.mender
# so its release tree carries a RELEASE_NOTES.txt marker. Makes an "update" target
# genuinely DIFFER from the prior version (so the flip is a real content change the
# assert step can observe), without a second bazel build. gzip payload (portable).
set -euo pipefail
ROLE="${1:?role}"; VER="${2:?ver}"
THEIA_DIR="${THEIA_DIR:-$(cd "$(dirname "$0")/../../../../theia" && pwd)}"
SRC="$THEIA_DIR/dist/roles/${ROLE}-${VER}.mender"
[ -f "$SRC" ] || { echo "no $SRC to stamp" >&2; exit 1; }
MA="$(command -v mender-artifact-wrap || command -v mender-artifact)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
# unpack outer artifact → data/0000.tar.gz → release.tar.gz + version.txt
tar xf "$SRC" data/0000.tar.gz
mkdir payload && tar xf data/0000.tar.gz -C payload
mkdir reldir && tar xf payload/release.tar.gz -C reldir
echo "${VER} ota-update role=${ROLE}" > reldir/RELEASE_NOTES.txt
tar -C reldir -czf release.tar.gz .
"$MA" write module-image \
  --type theia-release --artifact-name "${ROLE}-${VER}" --device-type theia-rig \
  --file release.tar.gz --file payload/version.txt \
  --output-path "$SRC" >/dev/null
echo "[stamp] $ROLE-$VER repacked with RELEASE_NOTES marker"
