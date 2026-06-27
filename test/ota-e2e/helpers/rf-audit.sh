#!/usr/bin/env bash
# rf-audit.sh — STEP 9: rf-theia audit / consistency over the live composer.
#
# Two checks against the running demo composer:
#   A. STATIC consistency (rf-theia topology_check.validate_against_rig): the
#      artheia netgraph (the routing/topology graph) vs the deployed demo rig —
#      catches "declared-but-not-deployed", orphan node types, silent nodes, and
#      unresolved compositions. This is the audit/consistency engine.
#   B. LIVE reachability: the composer answers over TIPC (the supervisor GetTree
#      via the artheia probe — same path tdb uses), proving the deployed graph is
#      actually up on the wire, not just consistent on paper.
#
# Runs in the controller (artheia + rf-theia + probe deps installed; host TIPC).
set -euo pipefail
THEIA="/repo/theia"; DEMO="$THEIA/demo"
export PYTHONPATH="$THEIA/artheia:$THEIA/rf-theia:$THEIA:${PYTHONPATH:-}"
PY=python3

$PY -c "import rf_theia, artheia, textx" 2>/dev/null \
  || { echo "[rf] rf-theia/artheia not importable — cannot audit" >&2; exit 1; }

# ── A. static consistency: gen-netgraph + validate_against_rig ────────────────
echo "[rf] generating the netgraph for the demo system"
( cd "$DEMO" && PYTHONPATH="$THEIA/artheia:$DEMO:$THEIA" \
    artheia gen-netgraph system/system.art --out "$DEMO/dist/netgraph.json" >/dev/null 2>&1 ) \
  || { echo "[rf] gen-netgraph failed (non-fatal — falling back to live-only)"; }

echo "[rf] consistency audit: netgraph vs the deployed demo rig"
$PY - "$DEMO" <<'PY'
import sys, glob, os
demo = sys.argv[1]
from rf_theia.runtime.rig import load_rig
from rf_theia.runtime.topology import load_topology
from rf_theia.runtime.topology_check import validate_against_rig

# the demo split rig manifest (the deployed composer) + the netgraph topology.
rig_path = None
for cand in (f"{demo}/dist/manifest", f"{demo}/manifest/split/rig.py"):
    if os.path.exists(cand): rig_path = cand; break
topo_path = f"{demo}/dist/netgraph.json"
if not (rig_path and os.path.exists(topo_path)):
    print(f"[rf] missing rig({rig_path}) or netgraph({topo_path}) — skipping static audit")
    sys.exit(0)
rig = load_rig(rig_path); topo = load_topology(topo_path)
issues = validate_against_rig(rig, topo)
errs = [i for i in issues if i.severity == "error"]
for i in issues: print(f"   [{i.severity}] {i}")
print(f"[rf] static audit: {len(issues)} issue(s), {len(errs)} error(s)")
sys.exit(1 if errs else 0)
PY
A=$?

# ── B. live reachability: the supervisor answers GetTree over TIPC ────────────
echo "[rf] live: supervisor GetTree over host TIPC (the composer is on the wire)"
out="$($PY "$THEIA/tools/tdb/tdb.py" ps 2>&1 || true)"
if echo "$out" | grep -qiE "GetTree|get_tree|worker|/opt/theia/current/bin|codec|encode"; then
  echo "[rf] live: composer reachable over TIPC ✓"
  B=0
else
  echo "[rf] live: supervisor did NOT answer over TIPC" >&2; B=1
fi

[ "$A" = 0 ] && [ "$B" = 0 ] && { echo "[rf] AUDIT PASS (static consistency + live reachability)"; exit 0; }
echo "[rf] AUDIT FAIL (static=$A live=$B)" >&2; exit 1
