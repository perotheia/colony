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
PAT="$(curl -sk -H "Authorization: Bearer $J" -H 'Content-Type: application/json' \
  -X POST "$API/v1/useradm/settings/tokens" -d '{"name":"e2e"}')"
export MENDER_TOKEN="$PAT"

# group each device by the role its mac maps to. We discover macs from the boards'
# eth0 and match against the inventory device list.
declare -A WANT
[ -n "$ART_CENTRAL" ] && WANT[central]="$ART_CENTRAL"
[ -n "$ART_COMPUTE" ] && WANT[compute]="$ART_COMPUTE"

# map board → mac (ask the board over ssh) → device id (inventory) → set group
devs_json="$(curl -sk -H "Authorization: Bearer $J" "$API/v1/inventory/devices?per_page=100")"
for board in "${!WANT[@]}"; do
  mac="$(ssh -o StrictHostKeyChecking=no root@"$board" 'cat /sys/class/net/eth0/address' 2>/dev/null)"
  dev_id="$(printf '%s' "$devs_json" | python3 -c "
import sys,json
mac='$mac'
for d in json.load(sys.stdin):
    if any(a.get('name')=='mac' and a.get('value')==mac for a in d.get('attributes',[])):
        print(d['id']); break
")"
  [ -n "$dev_id" ] || { echo "no device for $board (mac $mac) in inventory yet" >&2; exit 1; }
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
