#!/usr/bin/env python3
"""board-config.py — thin on-BOARD per config get/put for the OTA e2e checks.

Runs on a provisioned board (needs /opt/theia/artheia + system/tools/tdb/
tdb.art — the same probe env ucm-adopt.py uses). Values stay RAW: the host
side encodes/decodes the config proto (it has the workspace protos); this
helper only moves bytes through PerManager so the e2e assertions never depend
on the board having the app's .proto.

  board-config.py get <node>                       -> {"digest": ..., "hex": ...}
  board-config.py put <node> <digest> <hex> [rev]  -> PutConfig (expect_rev
                                                      default 0 = create)
"""
import json
import os
import sys
from pathlib import Path

ROOT = Path(os.environ.get("THEIA_ROOT", "/opt/theia"))
sys.path.insert(0, str(ROOT / "artheia"))

from artheia.gen_server.probe import ArtheiaContext  # noqa: E402


def main() -> int:
    verb = sys.argv[1]
    node = sys.argv[2]
    ctx = ArtheiaContext(str(ROOT / "system/tools/tdb/tdb.art"),
                         str(ROOT / "platform/proto"))
    probe = ctx.probe("TdbPer", instance=(os.getpid() & 0x7FFFFFFF)).start()
    try:
        if verb == "get":
            rep = probe.call("PerManager", "GetStoreSnapshot", timeout=5.0,
                             config_type=node)
            rows = rep.get("rows", []) or []
            # a repeated MESSAGE field decodes to protobuf objects, not dicts
            def fld(r, name, default):
                if hasattr(r, name):
                    return getattr(r, name)
                return r.get(name, default) if hasattr(r, "get") else default
            row = rows[0] if len(rows) else None
            digest = fld(row, "digest", "") if row is not None else ""
            raw = fld(row, "config", b"") if row is not None else b""
            if not isinstance(raw, (bytes, bytearray)):
                raw = bytes(raw)
            print(json.dumps({"digest": digest, "hex": raw.hex()}))
            return 0
        if verb == "put":
            digest, hx = sys.argv[3], sys.argv[4]
            rev = int(sys.argv[5]) if len(sys.argv) > 5 else 0
            rep = probe.call("PerClient", "PutConfig", timeout=5.0,
                             target_node=node, config=bytes.fromhex(hx),
                             digest=digest, expect_rev=rev)
            print(json.dumps({"status": rep.get("status"),
                              "message": rep.get("message", "")}))
            return 0 if rep.get("status", 1) == 0 else 1
        print(f"unknown verb {verb}", file=sys.stderr)
        return 2
    finally:
        probe.stop()


if __name__ == "__main__":
    raise SystemExit(main())
