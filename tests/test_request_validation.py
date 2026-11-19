"""Review 2026-11-19 (HIGH, injection -> code execution on the controller): a deployment request reaches
ansible-playbook as extra vars. colony-api validates rig / host / role / every extra key and value, and the runner
hands the extra vars to ansible as ONE JSON object, never a space-joined k=v string (ansible split it:
role="master ansible_ssh_common_args=..." became a second variable). (MEDIUM) a 422 never echoes the request."""
import json
import os
import stat
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from colony_api import app as app_mod
from colony_api import runner as runner_mod

ROOT = Path(__file__).resolve().parents[1]
KEY = {"X-Colony-Key": os.environ["COLONY_API_KEY"]}
SECRET = "tskey-auth-kTESTSECRET0123456789"
EVIL = "master ansible_ssh_common_args=-oProxyCommand=touch/tmp/pwned"


@pytest.fixture
def created(monkeypatch):
    calls = []

    class R:
        def create(self, *a, **kw):
            calls.append((a, kw))
            return {"id": "x" * 32, "status": "pending"}
    monkeypatch.setattr(app_mod, "runner", R())
    return calls


def _fake_ansible(tmp_path) -> Path:
    """An `ansible-playbook` on PATH that records its argv (JSON) and prints a successful recap."""
    bindir = tmp_path / "bin"
    bindir.mkdir()
    out = tmp_path / "argv.json"
    f = bindir / "ansible-playbook"
    f.write_text("#!/usr/bin/env python3\nimport json, sys\n"
                 f"json.dump(sys.argv[1:], open({str(out)!r}, 'w'))\n"
                 "print('rig-a : ok=1 changed=0 unreachable=0 failed=0 skipped=0')\n")
    f.chmod(f.stat().st_mode | stat.S_IXUSR)
    return out


def _wait(r, did, timeout=30.0):
    import time
    end = time.time() + timeout
    while time.time() < end:
        d = r.get(did)
        if d["status"] == runner_mod.FINISHED:
            return d
        time.sleep(0.02)
    raise AssertionError("did not finish")


def test_extra_vars_are_json_not_kv(tmp_path, monkeypatch):
    """The runner -> the real bin/colony -> ansible-playbook: every -e is ONE JSON object (or the @secrets file);
    a value with spaces and '=' arrives as ONE variable, not as extra variables."""
    argv_file = _fake_ansible(tmp_path)
    monkeypatch.setattr(runner_mod, "_JOURNAL", tmp_path / "journal.jsonl")
    monkeypatch.setenv("COLONY_BIN", str(ROOT / "bin" / "colony"))
    monkeypatch.setenv("PATH", f"{tmp_path / 'bin'}:{os.environ['PATH']}")
    monkeypatch.setenv("COLONY_ANSIBLE", str(ROOT / "ansible"))
    r = runner_mod.Runner()
    # straight into the runner (below the API's validation): the transport alone must keep it one variable
    rec = r.create("rig-a", "orchestrate", host="10.0.0.5:2201",
                   extra={"role": "master", "note": EVIL, "machine_instance": 1, "clean_app": True})
    d = _wait(r, rec["id"])
    assert d["statistics"]["status"]["success"] == 1, r.log(rec["id"])
    argv = json.loads(argv_file.read_text())
    evals = [argv[i + 1] for i, a in enumerate(argv) if a == "-e"]
    assert evals, argv
    merged = {}
    for v in evals:
        assert v.startswith("{"), f"an -e that is not a JSON object: {v!r}"
        merged.update(json.loads(v))
    assert merged["note"] == EVIL                              # ONE variable, the whole string
    assert "ansible_ssh_common_args" not in merged
    assert merged["machine_instance"] == 1 and merged["clean_app"] is True
    assert merged["target"] == "rig-a" and merged["role"] == merged["machine"] == "master"
    assert merged["ansible_host"] == "10.0.0.5" and merged["ansible_port"] == 2201


def test_cli_refuses_bad_rig_host_role(tmp_path, monkeypatch):
    import subprocess
    _fake_ansible(tmp_path)
    env = {**os.environ, "PATH": f"{tmp_path / 'bin'}:{os.environ['PATH']}"}
    for args in (["rig a", "--host", "10.0.0.5", "--role", "master"],
                 ["rig-a", "--host", "10.0.0.5 -oProxyCommand=x", "--role", "master"],
                 ["rig-a", "--host", "10.0.0.5", "--role", EVIL]):
        p = subprocess.run(["python3", str(ROOT / "bin" / "colony"), "orchestrate", *args], env=env,
                           capture_output=True, text=True, timeout=30)
        assert p.returncode == 2 and "not a valid value" in p.stderr, (args, p.stderr)
    assert not (tmp_path / "argv.json").exists()               # ansible never ran


GOOD = {"rig": "ai64-proto", "kind": "orchestrate", "host": "10.0.0.5",
        "extra": {"role": "zonal", "runtime_version": "0.3.0-trixie-arm64", "ansible_user": "debian",
                  "mender_device_id": "ai64-proto", "machine_instance": 2, "clean_app": False}}


@pytest.mark.parametrize("patch", [
    {"rig": "ai64 proto"}, {"rig": "x ansible_connection=local"}, {"rig": "-x"},
    {"host": "10.0.0.5 -oProxyCommand=x"}, {"host": "10.0.0.5\n"}, {"host": "h;reboot"}, {"host": "-oFoo"},
    {"extra": {"role": EVIL}}, {"extra": {"role": "Master"}}, {"extra": {"role": "master\n"}},
    {"extra": {"Bad-Key": "x"}}, {"extra": {"a b": "x"}}, {"extra": {"x=y": "x"}},
    {"extra": {"ansible_connection": "local"}}, {"extra": {"ansible_ssh_common_args": "x"}},
    {"extra": {"target": "other"}}, {"extra": {"registry_dir": "x"}},
    {"extra": {"note": "a b"}}, {"extra": {"note": "a=b"}}, {"extra": {"note": "{{ lookup('pipe','id') }}"}},
    {"extra": {"note": "'q'"}}, {"extra": {"note": "/root/.ssh/id_rsa"}}, {"extra": {"note": "-x"}},
    {"extra": {"note": 1.5}}, {"extra": {"note": ["a"]}}, {"extra": {"note": {"a": 1}}}, {"extra": {"note": None}},
    {"extra": {"ansible_user": "root;id"}}, {"extra": {"runtime_version": "0.3.0 && x"}},
    {"extra": {"mender_device_id": "x y"}},
    {"secrets": {"vpn_authkey": "{{ lookup('pipe','id') }}"}}, {"secrets": {"Bad Key": SECRET}},
])
def test_create_rejects_bad_host_role_extra(created, patch):
    c = TestClient(app_mod.app)
    r = c.post("/deployments", json={**GOOD, **patch}, headers=KEY)
    assert r.status_code == 422, (patch, r.text)
    assert created == []                                       # nothing reached the runner
    assert "lookup" not in r.text and "ProxyCommand" not in r.text


def test_create_accepts_what_the_gs_sends(created):
    c = TestClient(app_mod.app)
    r = c.post("/deployments", json=GOOD, headers=KEY)
    assert r.status_code == 200, r.text
    r = c.post("/deployments", json={"rig": "sk-tda4vm", "kind": "provision", "host": "ota-central:2201",
                                     "extra": {"role": "central", "mender_device_id": "sk-tda4vm",
                                               "ansible_user": "root"},
                                     "secrets": {"vpn_authkey": SECRET}}, headers=KEY)
    assert r.status_code == 200, r.text
    r = c.post("/deployments", json={"rig": "x", "kind": "cleanup", "host": "10.0.0.5",
                                     "extra": {"role": "master", "clean_app": True, "clean_runtime": False}},
               headers=KEY)
    assert r.status_code == 200, r.text
    assert len(created) == 3


def test_validation_error_has_no_input(created):
    """An older GS sent `secrets` to an image without the field: the 422 carried the VPN key in `input`."""
    c = TestClient(app_mod.app)
    for body in ({**GOOD, "bogus": {"vpn_authkey": SECRET}},           # an unknown field (extra=forbid)
                 {**GOOD, "secrets": SECRET},                           # the wrong type
                 {"kind": "provision", "secrets": {"vpn_authkey": SECRET}}):   # a missing field
        r = c.post("/deployments", json=body, headers=KEY)
        assert r.status_code == 422, r.text
        assert SECRET not in r.text and "tskey" not in r.text
        for e in r.json()["detail"]:
            assert "input" not in e and set(e) <= {"type", "loc", "msg"}
    assert created == []


def test_abort_and_prune_drop_the_secrets(tmp_path, monkeypatch):
    monkeypatch.setattr(runner_mod, "_JOURNAL", tmp_path / "journal.jsonl")
    r = runner_mod.Runner.__new__(runner_mod.Runner)     # no worker: the runs stay pending / scheduled
    import threading
    r._lock = threading.Lock()
    r._cv = threading.Condition(r._lock)
    r._deps = {}
    a = r.create("rig-a", "provision", host="h", secrets={"vpn_authkey": SECRET})
    b = r.create("rig-b", "provision", host="h", schedule=9e9, secrets={"vpn_authkey": SECRET})
    assert set(r._secrets) == {a["id"], b["id"]}
    assert r.abort(a["id"]) and a["id"] not in r._secrets
    assert r.prune("rig-b", finished_only=False) == 1 and r._secrets == {}
