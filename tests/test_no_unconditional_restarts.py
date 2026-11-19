"""Regression (live UI test 2026-11-19): a re-provision restarted etcd under the running Theia stack because the
restart task had no change condition. Every `state: restarted` task in the plays must be gated on a change
(`... is changed` / `.changed`) or be a handler (notified only on change)."""
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1] / "ansible"


def _tasks(node):
    if isinstance(node, list):
        for x in node:
            yield from _tasks(x)
    elif isinstance(node, dict):
        if any(k in node for k in ("ansible.builtin.systemd", "systemd", "ansible.builtin.service", "service",
                                   "ansible.builtin.systemd_service", "systemd_service")):
            yield node
        for k in ("tasks", "block", "rescue", "always", "pre_tasks", "post_tasks", "roles"):
            if k in node:
                yield from _tasks(node[k])


def test_no_unconditional_restarts():
    bad = []
    for f in sorted(ROOT.rglob("*.yml")):
        if "handlers" in f.parts or f.name.startswith("handlers"):
            continue
        try:
            doc = yaml.safe_load(f.read_text())
        except yaml.YAMLError:
            continue
        for t in _tasks(doc):
            mod = next(v for k, v in t.items() if k.split(".")[-1] in ("systemd", "service", "systemd_service"))
            if not isinstance(mod, dict) or mod.get("state") != "restarted":
                continue
            when = t.get("when") or []
            when = " ".join(when if isinstance(when, list) else [str(when)])
            if "changed" not in when:
                bad.append(f"{f.relative_to(ROOT)}: {t.get('name')}")
    assert not bad, "restart without a change condition:\n  " + "\n  ".join(bad)
