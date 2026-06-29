"""The deployment runner + journal — colony's analogue of Mender's deployments.

A colony "deployment" = one Ansible play run (provision | orchestrate | cleanup)
against one rig. We run it via the colony CLI (`colony <kind> <rig>`), capture the
log, parse the PLAY RECAP, and expose status with the SAME vocabulary the Mender
deployments API uses — so gs-api's existing RolloutBar/StatusBadge render colony
rows unchanged:

    status:      pending | scheduled | inprogress | finished
    statistics:  {success, failure, pending, ...}   (Mender's per-device dict)

The journal is in-memory + a JSONL spill (so a restart keeps history). One worker
thread drains a queue; scheduled runs wait for their timestamp. No external DB —
a lab fleet's deployment history is small.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import time
import uuid
from pathlib import Path

# ── status vocabulary (aligned to Mender) ────────────────────────────────────
PENDING = "pending"        # queued, not yet started (Mender: pending)
SCHEDULED = "scheduled"    # queued for a future time
INPROGRESS = "inprogress"  # the play is running (Mender: inprogress)
FINISHED = "finished"      # play returned (Mender: finished) — see statistics

_COLONY_BIN = Path(__file__).resolve().parents[2] / "bin" / "colony"
_JOURNAL = Path(os.environ.get("COLONY_JOURNAL") or "/var/lib/colony/journal.jsonl")

_PLAY_RECAP_RE = re.compile(
    r"^(?P<host>\S+)\s*:\s*ok=(?P<ok>\d+)\s+changed=(?P<changed>\d+)\s+"
    r"unreachable=(?P<unreachable>\d+)\s+failed=(?P<failed>\d+)", re.M)


def _now() -> float:
    return time.time()


def _parse_recap(log: str, rig_host: str) -> dict:
    """PLAY RECAP → a Mender-shaped {success, failure, pending} statistics dict.

    Mender counts DEVICES; a colony play targets ONE rig, so the dict is 1-hot:
    failed/unreachable>0 on the rig host → failure:1, else success:1. (The
    localhost play-recap line, used for fact-gathering, is ignored.)"""
    stats = {"success": 0, "failure": 0, "pending": 0, "noartifact": 0}
    recaps = {m.group("host"): m.groupdict()
              for m in _PLAY_RECAP_RE.finditer(log)}
    # Prefer the rig host's recap; fall back to any non-localhost host.
    target = recaps.get(rig_host) or next(
        (v for h, v in recaps.items() if h != "localhost"), None)
    if target is None:
        stats["pending"] = 1            # never ran / no recap → treat as pending
        return stats
    bad = int(target["failed"]) + int(target["unreachable"])
    if bad > 0:
        stats["failure"] = 1
    else:
        stats["success"] = 1
    return stats


class Runner:
    """Single-worker deployment queue + journal."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._deps: dict[str, dict] = {}     # id -> deployment record
        self._cv = threading.Condition(self._lock)
        self._load_journal()
        self._worker = threading.Thread(target=self._drain, daemon=True)
        self._worker.start()

    # ── public API (the routes call these) ──────────────────────────────────
    def create(self, rig: str, kind: str, schedule: float | None = None,
               name: str | None = None, host: str | None = None) -> dict:
        did = uuid.uuid4().hex
        rec = {
            "id": did,
            "name": name or f"{kind}-{rig}",
            "rig": rig,
            "host": host,            # explicit IP override (per-device deploy) or None
            "kind": kind,                       # provision | orchestrate | cleanup
            "authority": "colony",
            "artifact_name": f"{kind}:{rig}",   # gives the UI a stable label
            "status": SCHEDULED if schedule else PENDING,
            "schedule": schedule,
            "created": _now(),
            "started": None,
            "finished": None,
            "statistics": {"status": {"success": 0, "failure": 0,
                                      "pending": 1, "noartifact": 0}},
            "log": "",
        }
        with self._cv:
            self._deps[did] = rec
            self._spill(rec)
            self._cv.notify()
        return self._public(rec)

    def list(self) -> list[dict]:
        with self._lock:
            return [self._public(r) for r in sorted(
                self._deps.values(), key=lambda r: r["created"], reverse=True)]

    def get(self, did: str) -> dict | None:
        with self._lock:
            r = self._deps.get(did)
            return self._public(r) if r else None

    def log(self, did: str) -> str | None:
        with self._lock:
            r = self._deps.get(did)
            return r["log"] if r else None

    def abort(self, did: str) -> bool:
        """Abort a not-yet-running deployment (pending/scheduled). A running play
        is not interrupted (Ansible mid-flight) — matches Mender's abort window."""
        with self._cv:
            r = self._deps.get(did)
            if r and r["status"] in (PENDING, SCHEDULED):
                r["status"] = FINISHED
                r["finished"] = _now()
                r["statistics"]["status"] = {"success": 0, "failure": 0,
                                             "aborted": 1, "pending": 0}
                self._spill(r)
                return True
        return False

    # ── worker ───────────────────────────────────────────────────────────────
    def _drain(self) -> None:
        while True:
            with self._cv:
                nxt = self._next_runnable()
                while nxt is None:
                    self._cv.wait(timeout=2.0)
                    nxt = self._next_runnable()
                rec = nxt
                rec["status"] = INPROGRESS
                rec["started"] = _now()
                self._spill(rec)
            self._run_play(rec)

    def _next_runnable(self) -> dict | None:
        now = _now()
        for r in sorted(self._deps.values(), key=lambda r: r["created"]):
            if r["status"] == PENDING:
                return r
            if r["status"] == SCHEDULED and (r["schedule"] or 0) <= now:
                return r
        return None

    def _run_play(self, rec: dict) -> None:
        env = {**os.environ}
        # colony CLI resolves the registry/bundle from $THEIA_WORKSPACE.
        cmd = ["python3", str(_COLONY_BIN), rec["kind"], rec["rig"]]
        if rec.get("host"):
            # per-device IP override (the device's local/remote_ip) — beats the
            # registry ansible_host. colony passes extra args after `--` to ansible.
            cmd += ["--", "-e", "ansible_host=" + str(rec["host"])]
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, env=env,
                               timeout=1800)
            log = (p.stdout or "") + (p.stderr or "")
            rc = p.returncode
        except subprocess.TimeoutExpired as e:
            def _txt(x):
                return x.decode(errors="replace") if isinstance(x, bytes) else (x or "")
            log = _txt(e.stdout) + _txt(e.stderr) + "\n[colony-api] TIMEOUT"
            rc = 124
        rig_host = self._rig_host(rec["rig"])
        stats = _parse_recap(log, rig_host)
        if rc != 0 and stats["failure"] == 0 and stats["success"] == 0:
            stats["failure"] = 1          # nonzero exit, no recap → failure
        with self._cv:
            rec["status"] = FINISHED
            rec["finished"] = _now()
            rec["log"] = log[-65536:]     # keep the tail; full log is large
            rec["statistics"]["status"] = stats
            rec["rc"] = rc
            self._spill(rec)

    @staticmethod
    def _rig_host(rig: str) -> str:
        from . import registry
        r = registry.get_rig(rig) or {}
        # ansible names the host by the registry target name (add_host name=target).
        return rig

    # ── journal (JSONL spill so history survives a restart) ──────────────────
    def _public(self, rec: dict) -> dict:
        return {k: v for k, v in rec.items() if k != "log"}

    def _spill(self, rec: dict) -> None:
        try:
            _JOURNAL.parent.mkdir(parents=True, exist_ok=True)
            with _JOURNAL.open("a") as f:
                f.write(json.dumps(rec) + "\n")
        except OSError:
            pass    # journal is best-effort; the in-memory map is the source

    def _load_journal(self) -> None:
        if not _JOURNAL.is_file():
            return
        try:
            for line in _JOURNAL.read_text().splitlines():
                if not line.strip():
                    continue
                rec = json.loads(line)
                # last-write-wins per id (the file is append-only event log)
                prev = self._deps.get(rec["id"])
                if prev is None or rec["created"] >= prev["created"]:
                    # a still-"inprogress" record from a crashed run → mark finished
                    if rec.get("status") == INPROGRESS:
                        rec["status"] = FINISHED
                        rec.setdefault("statistics", {})["status"] = {
                            "success": 0, "failure": 1, "pending": 0}
                    self._deps[rec["id"]] = rec
        except (OSError, json.JSONDecodeError):
            pass


# module-level singleton (the app imports this)
runner = Runner()
