#!/usr/bin/env bash
# push-runtime-s3.sh <ver> <s3_url> <deb...> — publish runtime/services .debs to the
# MinIO runtime plane theia-runtime/<ver>/ with the index.json install-runtime-s3.yml
# reads ({debs:[{file,sha256}]}). The runtime-plane analogue of theia.py's
# _publish_app_plane (apps). aws-cli against MinIO; creds from MINIO_USER/PASSWORD.
set -euo pipefail
VER="${1:?ver}"; S3="${2:?s3 url}"; shift 2
DEBS=("$@"); [ "${#DEBS[@]}" -gt 0 ] || { echo "no debs given" >&2; exit 1; }
BUCKET="${S3_RUNTIME_BUCKET:-theia-runtime}"
export AWS_ACCESS_KEY_ID="${MINIO_USER:-theia}"
export AWS_SECRET_ACCESS_KEY="${MINIO_PASSWORD:-theiaminio}"
export AWS_DEFAULT_REGION="us-east-1"
AWS=(aws --endpoint-url "$S3" s3)
AWSAPI=(aws --endpoint-url "$S3" s3api)

"${AWS[@]}" mb "s3://$BUCKET" 2>/dev/null || true   # idempotent
# Public-read the bucket: install-runtime-s3.yml fetches the index.json + debs
# ANONYMOUSLY (no creds), so the bucket must allow anonymous GET (the dalek MinIO
# is public-read). Set a get-only policy.
cat > /tmp/.s3pol-$$.json <<POL
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["*"]},
 "Action":["s3:GetObject"],"Resource":["arn:aws:s3:::$BUCKET/*"]}]}
POL
"${AWSAPI[@]}" put-bucket-policy --bucket "$BUCKET" --policy "file:///tmp/.s3pol-$$.json" >/dev/null 2>&1 || true
rm -f /tmp/.s3pol-$$.json
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
entries=""
for deb in "${DEBS[@]}"; do
  [ -f "$deb" ] || { echo "missing deb: $deb" >&2; exit 1; }
  base="$(basename "$deb")"
  key="$VER/$base"
  "${AWS[@]}" cp "$deb" "s3://$BUCKET/$key" >/dev/null
  sha="$(sha256sum "$deb" | cut -d' ' -f1)"
  entries="${entries:+$entries,}{\"file\":\"$key\",\"sha256\":\"$sha\"}"
done
printf '{"plane":"runtime","version":"%s","debs":[%s]}\n' "$VER" "$entries" > "$WORK/index.json"
"${AWS[@]}" cp "$WORK/index.json" "s3://$BUCKET/$VER/index.json" >/dev/null
echo "[push-runtime-s3] published s3://$BUCKET/$VER/ (${#DEBS[@]} debs + index.json)"
