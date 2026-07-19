#!/usr/bin/env python3
"""ucm-drive.py — drive the on-board UCM agent from the HOST (dev/test tool).

Host-side probe (shared TIPC netid with the board under host-net compose) —
the DEVICE runs no python: UcmGate executes the whole lifecycle, including
config migration, in C++. This helper only casts the operator's intent, the
same wire com's UcmView proxies for the GS.

  ucm-drive.py request <version> [--partial] [--config] [--no-migrations]
  ucm-drive.py confirm <version>
  ucm-drive.py cancel  <version>
"""
import os
import sys
from pathlib import Path

ROOT = Path(os.environ.get("THEIA_ROOT", "/opt/theia"))
sys.path.insert(0, str(ROOT / "artheia"))

from artheia.gen_server.probe import ArtheiaContext  # noqa: E402


def main() -> int:
    verb, version = sys.argv[1], sys.argv[2]
    ctx = ArtheiaContext(str(ROOT / "system/tools/tdb/tdb.art"),
                         str(ROOT / "platform/proto"))
    probe = ctx.probe("TdbUcm", instance=(os.getpid() & 0x7FFFFFFF)).start()
    try:
        if verb == "request":
            rep = probe.call(
                "UcmDaemon", "RequestUpdate", timeout=8.0,
                name="theia",
                version=version,
                kind=1 if "--config" in sys.argv else 0,
                scope=1 if "--partial" in sys.argv else 0,
                artifact_path=str(ROOT / "releases"),
                signature="",
                requires=[],
                fcs=[],
                has_migrations=("--no-migrations" not in sys.argv))
        elif verb == "confirm":
            rep = probe.call("UcmDaemon", "Confirm", timeout=8.0,
                             campaign_id=version)
        elif verb == "cancel":
            rep = probe.call("UcmDaemon", "Cancel", timeout=8.0,
                             campaign_id=version)
        else:
            print(f"unknown verb {verb}", file=sys.stderr)
            return 2
        print(rep)
        return 0 if rep.get("status", 1) == 0 else 1
    finally:
        probe.stop()


if __name__ == "__main__":
    raise SystemExit(main())
