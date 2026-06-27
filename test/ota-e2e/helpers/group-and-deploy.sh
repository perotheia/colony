#!/usr/bin/env bash
# group-and-deploy.sh <server-ip> <email> <pass> <central-artifact> <compute-artifact>
#
# The fleet-side step: mint a PAT, group each enrolled device by role
# (central/compute), upload the role .mender(s), and create a per-group deployment.
# Runs INSIDE the controller container (fleet.py + the theia checkout are present).
#
# An empty <compute-artifact> ("") deploys only to central (the rollback test, which
# targets central alone).
set -euo pipefail
IP="${1:?server ip}"; EMAIL="${2:?email}"; PASS="${3:?pass}"
ART_CENTRAL="${4:-}"; ART_COMPUTE="${5:-}"
API="https://$IP/api/management"
ROLES="${ROLES_DIR:-/repo/theia/demo/dist/roles}"
FLEET="/repo/ground-station/fleet/fleet.py"

jwt() { curl -sk -u "$EMAIL:$PASS" -X POST "$API/v1/useradm/auth/login"; }
J="$(jwt)"; [ -n "$J" ] || { echo "login failed" >&2; exit 1; }
# Use the login JWT directly as the bearer token for fleet.py — minting a named PAT
# every run collides on the name (Mender rejects the duplicate → an invalid token,
# 401 on the next call). The JWT is a valid management bearer for this session.
export MENDER_TOKEN="$J"

# group each device by its `device` IDENTITY (== the board name, set at enroll via
# DEVICE_ID). On host networking the boards share a MAC, so identity — not MAC — is
# what distinguishes them; the identity IS the board name, so the mapping is direct.
declare -A WANT
[ -n "$ART_CENTRAL" ] && WANT[central]="$ART_CENTRAL"
[ -n "$ART_COMPUTE" ] && WANT[compute]="$ART_COMPUTE"

devs_json="$(curl -sk -H "Authorization: Bearer $J" "$API/v2/devauth/devices?per_page=100")"
for board in "${!WANT[@]}"; do
  dev_id="$(printf '%s' "$devs_json" | python3 -c "
import sys,json
board='$board'
for d in json.load(sys.stdin):
    if d.get('identity_data',{}).get('device')==board:
        print(d['id']); break
")"
  [ -n "$dev_id" ] || { echo "no device with identity device=$board in devauth yet" >&2; exit 1; }
  curl -sk -o /dev/null -w "  group $board ($dev_id): %{http_code}\n" \
    -H "Authorization: Bearer $J" -H 'Content-Type: application/json' \
    -X PUT "$API/v1/inventory/devices/$dev_id/group" -d "{\"group\":\"$board\"}"
done

# upload + deploy each role artifact to its group
for board in "${!WANT[@]}"; do
  art="${WANT[$board]}"
  f="$ROLES/${art}.mender"
  [ -f "$f" ] || { echo "missing artifact $f" >&2; exit 1; }
  python3 "$FLEET" --server "https://$IP" --insecure upload "$f" || true   # idempotent-ish
  python3 "$FLEET" --server "https://$IP" --insecure deploy "$art" "$board"
done
