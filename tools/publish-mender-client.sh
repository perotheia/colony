#!/usr/bin/env bash
# publish-mender-client.sh — publish the cross-built Mender client tarball for OPKG rigs (TI Arago) to the GS S3
# runtime plane, where provision (ansible/tasks/install-mender-opkg.yml) fetches it:
#
#   s3://<bucket>/mender-client/<version>/mender-client-<version>.tar.gz
#   s3://<bucket>/mender-client/<version>/index.json    {"file": <key in bucket>, "sha256": ..., "size": ...}
#
# <version> is taken from the file name (mender-client-<version>.tar.gz, e.g. 5.2.0-arago-aarch64) and must equal
# mender_client_opkg_version in ansible/inventory/hosts; the sha256 must equal mender_client_opkg_sha256 there (the
# provision refuses an index that names any other hash). The tarball goes up first, the index last, so a reader
# never sees an index without its object. See docs/mender-opkg.md.
#
# Usage:
#   tools/publish-mender-client.sh [--dry-run | --stage <dir>] <tarball> [<expected-sha256>]
#     --dry-run          print the keys + index.json, upload nothing
#     --stage <dir>      write <dir>/<bucket>/<keys> instead of uploading (a local fake plane: test/opkg-mender)
#     <expected-sha256>  default: the <tarball>.sha256 sidecar if present; the upload refuses on a mismatch
# Environment:
#   THEIA_S3_ENDPOINT   the plane's S3 API as THIS host reaches it (e.g. http://<fleet host>:9000)   REQUIRED
#   THEIA_S3_BUCKET     default theia-runtime
#   credentials: AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY, or S3_ACCESS_KEY + S3_SECRET_KEY (ground-station's
#                names). Read from the environment only; never printed, never put on a command line.
set -euo pipefail
set +x   # never trace: the environment carries credentials

DRY=0; STAGE=""
case "${1:-}" in
  --dry-run) DRY=1; shift ;;
  --stage) STAGE="${2:?--stage needs a directory}"; shift 2 ;;
esac
TGZ="${1:?usage: publish-mender-client.sh [--dry-run | --stage <dir>] <tarball> [<expected-sha256>]}"
EXPECT="${2:-}"
BUCKET="${THEIA_S3_BUCKET:-theia-runtime}"

[ -f "$TGZ" ] || { echo "no such file: $TGZ" >&2; exit 1; }
base="$(basename "$TGZ")"
case "$base" in
  mender-client-*.tar.gz) VER="${base#mender-client-}"; VER="${VER%.tar.gz}" ;;
  *) echo "expected mender-client-<version>.tar.gz, got $base" >&2; exit 1 ;;
esac
[ -n "$VER" ] || { echo "empty version in $base" >&2; exit 1; }

sha="$(sha256sum "$TGZ" | cut -d' ' -f1)"
size="$(stat -c %s "$TGZ")"
if [ -z "$EXPECT" ] && [ -f "$TGZ.sha256" ]; then EXPECT="$(cut -d' ' -f1 "$TGZ.sha256")"; fi
if [ -n "$EXPECT" ] && [ "$EXPECT" != "$sha" ]; then
  echo "sha256 mismatch: $base is $sha, expected $EXPECT; refusing to publish" >&2; exit 1
fi
[ -n "$EXPECT" ] || echo "WARNING: no expected sha256 given and no $base.sha256 sidecar: publishing $sha unchecked" >&2

# the payload must be the layout install-mender-opkg.yml unpacks and checks
tar -tzf "$TGZ" | grep -qx 'usr/share/mender-client-arago/MANIFEST.sha256' \
  || { echo "$base has no usr/share/mender-client-arago/MANIFEST.sha256: not the Arago client tarball" >&2; exit 1; }

PREFIX="mender-client/$VER"
KEY="$PREFIX/$base"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cat > "$work/index.json" <<JSON
{
  "plane": "mender-client",
  "version": "$VER",
  "file": "$KEY",
  "sha256": "$sha",
  "size": $size
}
JSON

echo "[publish] s3://$BUCKET/$KEY  sha256=$sha  size=$size"
echo "[publish] s3://$BUCKET/$PREFIX/index.json"
echo "[publish] pin in ansible/inventory/hosts: mender_client_opkg_version = $VER, mender_client_opkg_sha256 = $sha"
if [ "$DRY" = 1 ]; then cat "$work/index.json"; echo "[publish] dry run: nothing uploaded"; exit 0; fi
if [ -n "$STAGE" ]; then
  mkdir -p "$STAGE/$BUCKET/$PREFIX"
  cp "$TGZ" "$STAGE/$BUCKET/$KEY"; cp "$work/index.json" "$STAGE/$BUCKET/$PREFIX/index.json"
  echo "[publish] staged under $STAGE (nothing uploaded)"; exit 0
fi

S3="${THEIA_S3_ENDPOINT:?set THEIA_S3_ENDPOINT=http://<fleet host>:9000}"
command -v aws >/dev/null || { echo "aws cli required" >&2; exit 1; }
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  if [ -n "${S3_ACCESS_KEY:-}" ] && [ -n "${S3_SECRET_KEY:-}" ]; then
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
  else
    echo "credentials missing: set AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY (or S3_ACCESS_KEY + S3_SECRET_KEY)" >&2
    exit 1
  fi
fi
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
aws=(aws --endpoint-url "$S3" s3)

"${aws[@]}" cp --only-show-errors "$TGZ" "s3://$BUCKET/$KEY"
"${aws[@]}" cp --only-show-errors --content-type application/json "$work/index.json" "s3://$BUCKET/$PREFIX/index.json"

# read back the way the controller will (the bucket is anonymously readable) and check the object's hash
curl -fsS "$S3/$BUCKET/$PREFIX/index.json" -o "$work/index.check.json"
cmp -s "$work/index.json" "$work/index.check.json" || { echo "read-back index.json differs" >&2; exit 1; }
curl -fsS "$S3/$BUCKET/$KEY" -o "$work/obj"
echo "$sha  $work/obj" | sha256sum -c --quiet - || { echo "read-back object hash differs" >&2; exit 1; }
echo "[publish] done: index + object read back, sha256 matches"
