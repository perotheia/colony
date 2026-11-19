"""colony-api runner: live progress while a play runs, the reported fields, the 409, the secrets channel.

A fake `bin/colony` ($COLONY_BIN -> tests/fake_colony.py) prints a recorded ansible log slowly."""
import json
import os
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from colony_api import app as app_mod
from colony_api import runner as runner_mod

HERE = Path(__file__).resolve().parent
SECRET = "tskey-auth-kTESTSECRET0123456789"
KEY = {"X-Colony-Key": os.environ["COLONY_API_KEY"]}


@pytest.fixture
def fake(tmp_path, monkeypatch):
    monkeypatch.setattr(runner_mod, "_JOURNAL", tmp_path / "journal.jsonl")
    monkeypatch.setenv("COLONY_BIN", str(HERE / "fake_colony.py"))
    monkeypatch.setenv("FAKE_COLONY_LOG", str(HERE / "fixtures" / "provision-ok.txt"))
    monkeypatch.setenv("FAKE_COLONY_DELAY", "0.03")
    monkeypatch.setenv("FAKE_COLONY_SEEN", str(tmp_path / "seen.txt"))
    monkeypatch.setenv("FAKE_COLONY_RC", "0")
    r = runner_mod.Runner()
    monkeypatch.setattr(app_mod, "runner", r)
    return r


def _wait(r, did, timeout=30.0, on_poll=None):
    end = time.time() + timeout
    while time.time() < end:
        d = r.get(did)
        if on_poll:
            on_poll(d)
        if d["status"] == runner_mod.FINISHED:
            return d
        time.sleep(0.01)
    raise AssertionError(f"deployment {did} did not finish")


def _no_secret_anywhere(r, did, tmp_path):
    assert SECRET not in json.dumps(r.get(did))
    assert SECRET not in (r.log(did) or "")
    assert SECRET not in (tmp_path / "journal.jsonl").read_text()


def test_progress_advances_while_running(fake, tmp_path):
    rec = fake.create("ai64-proto", "provision", host="192.168.1.50", extra={"role": "master"},
                      secrets={"vpn_authkey": SECRET})
    assert rec["progress"]["tasks_done"] == 0 and rec["log_tail"] == ""
    seen_running = []

    def poll(d):
        if d["status"] == runner_mod.INPROGRESS:
            seen_running.append((d["progress"]["tasks_done"], d["progress"]["current_task"],
                                 len(d["log_tail"])))
            assert SECRET not in json.dumps(d)          # never, not even mid-play
    d = _wait(fake, rec["id"], on_poll=poll)

    done_values = sorted({s[0] for s in seen_running})
    assert len(done_values) >= 3, done_values            # tasks_done moved while the play ran
    assert any(s[1] == "Base dirs" for s in seen_running)
    assert any(s[2] > 0 for s in seen_running)           # the tail was readable mid-play
    assert all(s[2] <= 4096 for s in seen_running)

    # the final record: the old shape + progress + the reported fields
    assert d["statistics"]["status"]["success"] == 1 and d["rc"] == 0
    assert d["vpn_ip"] == "100.91.130.60"
    assert d["pki"] == {"serial": "5d3f9a0c41e2", "not_after": "2027-11-19T10:00:00Z"}
    assert d["mender_pubkey"].startswith("LS0tLS1CRUdJTiBQVUJMSUMgS0VZ")   # kept as a field (log cap must not cut it)
    assert d["rig_class"] == "apt"
    assert d["skipped_by_design"] == ["mender-artifact-install", "opkg-feed"]
    p = d["progress"]
    assert p["current_task"] is None
    assert p["failed_task"] is None and p["failed_msg"] is None   # the ignored failure is not the play's
    assert p["tasks_done"] == len(p["tasks"]) == 15
    by_name = {t["name"]: t["result"] for t in p["tasks"]}
    assert by_name["Base dirs"] == "changed"
    assert by_name["Apt holds (kernel, bootloader)"] == "skipped"
    assert by_name["Optional probe (ignored when absent)"] == "ok"
    assert by_name["Include the fleet VPN join (Tailscale)"] == "ok"
    assert "PLAY RECAP" in d["log_tail"] and len(d["log_tail"]) <= 4096
    assert "log" not in d

    # the secrets channel: a 0600 file named by the env, gone after the play, scrubbed everywhere
    sec_path, existed, argv = (tmp_path / "seen.txt").read_text().split(" ", 2)
    assert existed == "True" and sec_path.startswith(("/tmp", os.path.realpath("/tmp")))
    assert "--host 192.168.1.50" in argv and "--role master" in argv
    assert not os.path.exists(sec_path)
    assert "***" in fake.log(rec["id"])
    _no_secret_anywhere(fake, rec["id"], tmp_path)


def test_failure_names_task_and_message(fake, tmp_path, monkeypatch):
    monkeypatch.setenv("FAKE_COLONY_LOG", str(HERE / "fixtures" / "provision-fail.txt"))
    monkeypatch.setenv("FAKE_COLONY_RC", "2")
    rec = fake.create("ai64-proto", "provision", host="192.168.1.50", secrets={"vpn_authkey": SECRET})
    d = _wait(fake, rec["id"])
    assert d["statistics"]["status"]["failure"] == 1 and d["rc"] == 2
    p = d["progress"]
    assert p["failed_task"] == "Install the runtime packages"
    assert p["failed_msg"] == "No package matching 'theia-runtime=0.9.9' is available"
    assert p["tasks"][-1] == {"name": "Install the runtime packages", "result": "failed"}
    assert p["tasks_done"] == 3
    assert d["vpn_ip"] is None and d["pki"] is None and d["rig_class"] is None
    _no_secret_anywhere(fake, rec["id"], tmp_path)
    assert "***" in d["log_tail"]                         # the echoed secret was scrubbed in the tail


def test_cli_refusal_without_ansible_is_readable(fake, monkeypatch, tmp_path):
    log = tmp_path / "refuse.txt"
    log.write_text("colony provision: no registry entry x.yml and no --host/--role\n")
    monkeypatch.setenv("FAKE_COLONY_LOG", str(log))
    monkeypatch.setenv("FAKE_COLONY_RC", "2")
    d = _wait(fake, fake.create("x", "provision")["id"])
    assert d["statistics"]["status"]["failure"] == 1
    assert d["progress"]["failed_task"] is None
    assert "no registry entry" in d["progress"]["failed_msg"]


def test_second_create_for_a_busy_rig_is_409(fake, monkeypatch):
    monkeypatch.setenv("FAKE_COLONY_DELAY", "0.05")
    c = TestClient(app_mod.app)
    body = {"rig": "ai64-proto", "kind": "provision", "host": "192.168.1.50",
            "secrets": {"vpn_authkey": SECRET}}
    r1 = c.post("/deployments", json=body, headers=KEY)
    assert r1.status_code == 200, r1.text
    did = r1.json()["id"]
    r2 = c.post("/deployments", json=body, headers=KEY)
    assert r2.status_code == 409
    assert did in r2.json()["detail"] and r2.json()["id"] == did
    # another rig is not blocked
    other = c.post("/deployments", json={**body, "rig": "sk-am62"}, headers=KEY)
    assert other.status_code == 200
    # live progress over the route, and the key still guards it
    assert c.get(f"/deployments/{did}").status_code == 401
    seen = []
    end = time.time() + 30
    while time.time() < end:
        d = c.get(f"/deployments/{did}", headers=KEY).json()
        if d["status"] == "inprogress":
            seen.append(d["progress"]["tasks_done"])
        if d["status"] == "finished":
            break
        time.sleep(0.02)
    assert len(set(seen)) >= 2
    assert SECRET not in json.dumps(d)
    # finished: the rig takes a new deployment again
    r3 = c.post("/deployments", json=body, headers=KEY)
    assert r3.status_code == 200
    _wait(app_mod.runner, r3.json()["id"])
    _wait(app_mod.runner, other.json()["id"])


def test_popen_exception_still_unlinks_the_secrets_file(fake, monkeypatch, tmp_path):
    seen = {}

    def boom(cmd, **kw):
        path = kw["env"]["COLONY_SECRETS_FILE"]
        seen["path"] = path
        seen["mode"] = os.stat(path).st_mode & 0o777
        raise OSError("exec failed")
    monkeypatch.setattr(runner_mod.subprocess, "Popen", boom)
    d = _wait(fake, fake.create("ai64-proto", "provision", host="h",
                                secrets={"vpn_authkey": SECRET})["id"])
    assert seen["mode"] == 0o600
    assert not os.path.exists(seen["path"])
    assert d["status"] == "finished" and d["rc"] == 125
    assert d["statistics"]["status"]["failure"] == 1
    assert "exec failed" in d["progress"]["failed_msg"]
    _no_secret_anywhere(fake, d["id"], tmp_path)


def test_exception_mid_play_kills_the_play_and_unlinks(fake, monkeypatch, tmp_path):
    real_feed = runner_mod.PlayProgress.feed
    calls = {"n": 0}

    def feed(self, line):
        calls["n"] += 1
        if calls["n"] == 5:
            raise RuntimeError("parser bug")
        return real_feed(self, line)
    monkeypatch.setattr(runner_mod.PlayProgress, "feed", feed)
    t0 = time.time()
    d = _wait(fake, fake.create("ai64-proto", "provision", host="h",
                                secrets={"vpn_authkey": SECRET})["id"])
    assert time.time() - t0 < 5                       # the child was killed, not waited out
    assert d["rc"] == 125 and d["statistics"]["status"]["failure"] == 1
    assert "parser bug" in d["progress"]["failed_msg"]
    sec_path = (tmp_path / "seen.txt").read_text().split(" ", 1)[0]
    assert not os.path.exists(sec_path)
    _no_secret_anywhere(fake, d["id"], tmp_path)
    # the worker survived: the next deployment runs
    monkeypatch.setattr(runner_mod.PlayProgress, "feed", real_feed)
    d2 = _wait(fake, fake.create("ai64-proto", "provision", host="h")["id"])
    assert d2["statistics"]["status"]["success"] == 1


def test_journal_reload_keeps_the_new_fields(fake, tmp_path):
    d = _wait(fake, fake.create("ai64-proto", "provision", host="h",
                                secrets={"vpn_authkey": SECRET})["id"])
    fresh = runner_mod.Runner()                       # a restart reads the JSONL spill
    g = fresh.get(d["id"])
    for k in ("progress", "log_tail", "vpn_ip", "pki", "rig_class", "skipped_by_design"):
        assert g[k] == d[k], k
