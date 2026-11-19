"""Regression (live UI test 2026-11-19): a re-provision restarted etcd under the running Theia stack because the
restart task had no change condition. Every `state: restarted` task in the plays must be gated on a change
(`... is changed` / `.changed`) or be a handler (notified only on change)."""
import re
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


# Review 2026-11-19 (MEDIUM): on systemd-less rigs etcd.yml (`changed_when: true` running etcd-start.sh, which
# pkills etcd) and install-supervisor-unit.yml (kill -TERM the supervisor + relaunch) restarted the service on EVERY
# run. A shell/command task that kills or relaunches a service (directly, or by running a script a copy task in the
# same file writes) must be gated on a change: its `when` names `changed` (it may also start a service that is not
# running). The cleanup play stops the stack by design: exempt.
_KILL_RE = re.compile(r"\b(pkill|killall|kill|start-stop-daemon)\b|\bsystemctl\s+restart\b|\bservice\s+\S+\s+restart\b")
_EXEMPT = {"cleanup.yml"}


def _all_tasks(node):
    if isinstance(node, list):
        for x in node:
            yield from _all_tasks(x)
    elif isinstance(node, dict):
        yield node
        for k in ("tasks", "block", "rescue", "always", "pre_tasks", "post_tasks", "handlers"):
            if k in node:
                yield from _all_tasks(node[k])


def _mod(t, names):
    for k, v in t.items():
        if k.split(".")[-1] in names:
            return v
    return None


def _cmd_text(t) -> str | None:
    v = _mod(t, ("shell", "command", "raw", "script"))
    if v is None:
        return None
    if isinstance(v, dict):
        v = v.get("cmd") or v.get("_raw_params") or " ".join(map(str, v.get("argv") or []))
    return f"{v} {t.get('args', {}).get('cmd', '') if isinstance(t.get('args'), dict) else ''}"


def _kill_tasks(doc):
    """(task, why) for every shell/command task that kills/relaunches a service."""
    tasks = list(_all_tasks(doc))
    scripts = {}
    for t in tasks:
        c = _mod(t, ("copy",))
        if isinstance(c, dict) and isinstance(c.get("content"), str) and c.get("dest"):
            scripts[str(c["dest"])] = c["content"]
    for t in tasks:
        cmd = _cmd_text(t)
        if cmd is None:
            continue
        if _KILL_RE.search(cmd):
            yield t, "kills/restarts inline"
        for dest, content in scripts.items():
            if dest in cmd and _KILL_RE.search(content):
                yield t, f"runs {dest}, which kills/restarts"


def test_no_unconditional_kill_relaunch():
    bad = []
    for f in sorted(ROOT.rglob("*.yml")):
        if f.name in _EXEMPT:
            continue
        try:
            doc = yaml.safe_load(f.read_text())
        except yaml.YAMLError:
            continue
        for t, why in _kill_tasks(doc):
            when = t.get("when") or []
            when = " ".join(map(str, when if isinstance(when, list) else [when]))
            if "changed" not in when:
                bad.append(f"{f.relative_to(ROOT)}: {t.get('name')} ({why})")
    assert not bad, "kill/relaunch without a change condition:\n  " + "\n  ".join(bad)


def test_kill_detector_sees_the_old_shapes():
    """The detector flags what the review found (so a green run above means something)."""
    old_etcd = [{"name": "script", "ansible.builtin.copy": {"dest": "/usr/local/bin/etcd-start.sh",
                                                            "content": "pkill -x etcd\nsetsid etcd &\n"}},
                {"name": "launch", "ansible.builtin.command": "/usr/local/bin/etcd-start.sh", "changed_when": True}]
    old_sup = [{"name": "sup", "ansible.builtin.shell": "for p in $(pgrep x); do kill -TERM $p; done; setsid y &",
                "when": 'ansible_service_mgr != "systemd"', "changed_when": True}]
    assert [t["name"] for t, _ in _kill_tasks(old_etcd)] == ["launch"]
    assert [t["name"] for t, _ in _kill_tasks(old_sup)] == ["sup"]
