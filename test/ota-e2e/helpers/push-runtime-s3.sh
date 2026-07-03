#!/usr/bin/env bash
# push-runtime-s3.sh <ver> <s3_url> <deb...> — publish runtime/services .debs +
# the manifest bundle to the MinIO runtime plane theia-runtime/<ver>/, matching what
# the REAL `theia release` (_release_runtime_plane) publishes and what colony
# provision (fetch-manifest-s3.yml) consumes:
#   <ver>/<deb>            the runtime + services debs
#   <ver>/index.json       {plane:runtime, version, debs:[{file,sha256}]}
#   <ver>/manifest.tar.gz  the serialized manifest tree ($THEIA_DIR/dist/manifest,
#                          machines.json + <machine>/*.json + config/) at root, PLUS
#                          theia-run.sh at root + ota/ (Mender modules {theia-swp,
#                          theia-app,theia-release} + state-scripts) from
#                          $THEIA_DIR/platform/runtime/ota. provision fetches this
#                          single GET and unpacks it (no theia checkout on the board).
# The manifest MUST already be serialized (dist/manifest) — the caller serializes
# BEFORE this push. aws-cli against MinIO; creds from MINIO_USER/PASSWORD.
set -euo pipefail
VER="${1:?ver}"; S3="${2:?s3 url}"; shift 2
DEBS=("$@"); [ "${#DEBS[@]}" -gt 0 ] || { echo "no debs given" >&2; exit 1; }
BUCKET="${S3_RUNTIME_BUCKET:-theia-runtime}"
THEIA_DIR="${THEIA_DIR:?THEIA_DIR must be set (for dist/manifest + platform/runtime/ota)}"
export AWS_ACCESS_KEY_ID="${MINIO_USER:-theia}"
export AWS_SECRET_ACCESS_KEY="${MINIO_PASSWORD:-theiaminio}"
export AWS_DEFAULT_REGION="us-east-1"
AWS=(aws --endpoint-url "$S3" s3)
AWSAPI=(aws --endpoint-url "$S3" s3api)

"${AWS[@]}" mb "s3://$BUCKET" 2>/dev/null || true   # idempotent
cat > /tmp/.s3pol-$$.json <<POL
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["*"]},
 "Action":["s3:GetObject"],"Resource":["arn:aws:s3:::$BUCKET/*"]}]}
POL
"${AWSAPI[@]}" put-bucket-policy --bucket "$BUCKET" --policy "file:///tmp/.s3pol-$$.json" >/dev/null 2>&1 || true
rm -f /tmp/.s3pol-$$.json
WORK="$(mktemp -d)"; trap "rm -rf \"$WORK\"" EXIT

# 1) debs + index.json (unchanged contract)
entries=""
for deb in "${DEBS[@]}"; do
  [ -f "$deb" ] || { echo "missing deb: $deb" >&2; exit 1; }
  base="$(basename "$deb")"
  key="$VER/$base"
  "${AWS[@]}" cp "$deb" "s3://$BUCKET/$key" >/dev/null
  sha="$(sha256sum "$deb" | cut -d" " -f1)"
  entries="${entries:+$entries,}{\"file\":\"$key\",\"sha256\":\"$sha\"}"
done
printf "{\"plane\":\"runtime\",\"version\":\"%s\",\"debs\":[%s]}\n" "$VER" "$entries" > "$WORK/index.json"
"${AWS[@]}" cp "$WORK/index.json" "s3://$BUCKET/$VER/index.json" >/dev/null

# 2) manifest.tar.gz — the manifest tree + theia-run.sh + ota/ (mirrors theia
#    release). provision (fetch-manifest-s3.yml) pulls + unpacks this ONE object.
MAN_DIR="${MANIFEST_DIR:-$THEIA_DIR/dist/manifest}"
OTA_DIR="$THEIA_DIR/platform/runtime/ota"
if [ ! -d "$MAN_DIR" ]; then
  echo "push-runtime-s3: no manifest dir at $MAN_DIR — serialize the rig BEFORE the push" >&2
  exit 1
fi
STAGE="$WORK/manifest"; mkdir -p "$STAGE"
# manifest tree at root (exclude debs + BUILD like theia release does)
( cd "$MAN_DIR" && tar --exclude="*.deb" --exclude="BUILD.bazel" -cf - . ) | tar -xf - -C "$STAGE"
# theia-run.sh at root + ota/ (modules + state-scripts) so the board is self-serving
if [ -f "$OTA_DIR/theia-run.sh" ]; then cp "$OTA_DIR/theia-run.sh" "$STAGE/theia-run.sh"; fi
if [ -d "$OTA_DIR" ]; then mkdir -p "$STAGE/ota"; cp -a "$OTA_DIR/." "$STAGE/ota/"; rm -f "$STAGE/ota/theia-run.sh"; fi
tar -C "$STAGE" -czf "$WORK/manifest.tar.gz" .
"${AWS[@]}" cp "$WORK/manifest.tar.gz" "s3://$BUCKET/$VER/manifest.tar.gz" >/dev/null

echo "[push-runtime-s3] published s3://$BUCKET/$VER/ (${#DEBS[@]} debs + index.json + manifest.tar.gz)"
