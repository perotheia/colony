"""Regression (live UI test 2026-11-19): two tasks in install-runtime-s3.yml registered `_dpkg`; on a debian rig
the SKIPPED opkg task ran last and overwrote the result with changed=false, so a runtime upgrade never
restarted the supervisor (0.3.1 installed, 0.3.0 processes kept running). A register name is unique per file."""
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "ansible"


def test_register_names_unique_per_file():
    bad = []
    for f in sorted(ROOT.rglob("*.yml")):
        names = re.findall(r"^\s*register:\s*([A-Za-z_][A-Za-z0-9_]*)\s*$", f.read_text(), re.M)
        bad += [f"{f.relative_to(ROOT)}: {n} x{c}" for n, c in Counter(names).items() if c > 1]
    assert not bad, "a register name used twice in one file (a skipped task overwrites it):\n  " + "\n  ".join(bad)
