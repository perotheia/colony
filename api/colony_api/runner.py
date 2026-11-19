"""The deployment runner + journal — colony's analogue of Mender's deployments.

A colony "deployment" = one Ansible play run (provision | orchestrate | cleanup)
against one rig. We run it via the colony CLI (`colony <kind> <rig>`), capture the
log, parse the PLAY RECAP, and expose status with the SAME vocabulary the Mender
deployments API uses — so gs-api's existing RolloutBar/StatusBadge render colony
rows unchanged:

    status:      pending | scheduled | inprogress | finished
    statistics:  {success, failure, pending, ...}   (Mender's per-device dict)

The play runs under Popen and its output is folded in line by line (PlayProgress): while it runs,
GET /deployments/{id} shows `progress` {tasks_done, current_task, failed_task, failed_msg, tasks} and
`log_tail` (the last 4 KB, secrets scrubbed); the reported vpn_ip / pki / rig_class / skipped_by_design
are kept as fields. One rig has at most one pending/in-progress deployment (RigBusy -> 409).

The journal is in-memory + a JSONL spill (so a restart keeps history). One worker
thread drains a queue; scheduled runs wait for their timestamp. No external DB —
a lab fleet's deployment history is small.
"""
from __future__ import annotations

import json
import tempfile
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


def _colony_bin() -> Path:
    """The colony CLI; $COLONY_BIN overrides it (the tests point it at a fake that prints a recorded play)."""
    return Path(os.environ.get("COLONY_BIN") or _COLONY_BIN)


_PLAY_TIMEOUT = 1800        # s: a play that runs longer is killed (rc 124)
_TAIL_BYTES = 4096          # log_tail: the last 4 KB of the (scrubbed) output, live
_SPILL_EVERY = 15.0         # s: journal spill cadence while a play runs (the final record is always spilled)
_JOURNAL = Path(os.environ.get("COLONY_JOURNAL") or "/var/lib/colony/journal.jsonl")

_PLAY_RECAP_RE = re.compile(
    r"^(?P<host>\S+)\s*:\s*ok=(?P<ok>\d+)\s+changed=(?P<changed>\d+)\s+"
    r"unreachable=(?P<unreachable>\d+)\s+failed=(?P<failed>\d+)", re.M)


def _now() -> float:
    return time.time()


# ── live play parsing (ansible's default stdout callback) ────────────────────
_TASK_RE = re.compile(r"^(?:TASK|RUNNING HANDLER) \[(?P<name>.*)\] \**\s*$")
_PLAY_RECAP_HDR_RE = re.compile(r"^PLAY RECAP \**\s*$")
_RESULT_RE = re.compile(r"^(?P<kind>ok|changed|skipping|failed|fatal): \[(?P<host>[^\]]+)\]")
_INCLUDED_RE = re.compile(r"^included: ")
_IGNORING_RE = re.compile(r"^\.\.\.ignoring\s*$")
_VPN_RE = re.compile(r"COLONY_VPN_IP \S+ (\d+\.\d+\.\d+\.\d+)")
_PKI_RE = re.compile(r'COLONY_PKI \S+ serial (?P<serial>\S+) until (?P<until>[^"\n]+)')
_RIG_CLASS_RE = re.compile(r'rig_class=(?P<cls>[^;"\s]+); skipped by design: (?P<skips>[^"\n]*)')
_MSG_RE = re.compile(r'"msg":\s*"((?:[^"\\]|\\.)*)"')
_STDERR_RE = re.compile(r'"stderr":\s*"((?:[^"\\]|\\.)*)"')
_RESULT_RANK = {"skipped": 0, "ok": 1, "changed": 2, "failed": 3}
_MAX_TASKS = 500            # progress.tasks keeps the last N (a play has ~100-250)
_MAX_MSG = 1000


def _json_str(raw: str) -> str:
    try:
        return json.loads(f'"{raw}"')
    except ValueError:
        return raw


def _failure_message(line: str) -> str:
    """The readable part of a `fatal:`/`failed:` line: the result's msg (+ stderr when msg says only
    'non-zero return code'); the raw rest of the line when it is not the one-line JSON."""
    _, sep, rest = line.partition("=> ")
    msg = stderr = None
    if sep:
        try:
            res = json.loads(rest)
            if isinstance(res, dict):
                msg, stderr = res.get("msg"), res.get("stderr")
        except ValueError:
            pass
    if msg is None:
        m = _MSG_RE.search(line)
        msg = _json_str(m.group(1)) if m else None
    if stderr is None:
        m = _STDERR_RE.search(line)
        stderr = _json_str(m.group(1)) if m else None
    if msg is None:
        msg = (rest if sep else line).strip()
    msg = str(msg)
    if stderr and isinstance(stderr, str) and stderr.strip() and "non-zero return code" in msg:
        msg = f"{msg}: {stderr.strip()[-400:]}"
    return msg[:_MAX_MSG]


class PlayProgress:
    """Folds an ansible-playbook output stream (default callback), line by line, into
    `progress: {tasks_done, current_task, failed_task, failed_msg, tasks: [{name, result}]}` and the
    reported fields vpn_ip / pki {serial, not_after} / rig_class / skipped_by_design."""

    def __init__(self) -> None:
        self.tasks: list[dict] = []          # [{name, result}] (result None until a host line arrives)
        self.current_task: str | None = None
        self.failed_task: str | None = None
        self.failed_msg: str | None = None
        self._failed_idx: int | None = None
        self.recap = False
        self.fields: dict = {}

    def feed(self, line: str) -> bool:
        """Consume one output line; True when the progress/fields changed."""
        line = line.rstrip("\n")
        changed = False
        m = _VPN_RE.search(line)
        if m and not _TASK_RE.match(line):
            self.fields["vpn_ip"] = m.group(1)
            changed = True
        m = _PKI_RE.search(line)
        if m and not _TASK_RE.match(line):
            self.fields["pki"] = {"serial": m.group("serial"),
                                  "not_after": m.group("until").strip()}
            changed = True
        m = _RIG_CLASS_RE.search(line)
        if m and not _TASK_RE.match(line):
            skips = [s.strip() for s in m.group("skips").split(",") if s.strip()]
            self.fields["rig_class"] = m.group("cls")
            self.fields["skipped_by_design"] = [] if skips == ["nothing"] else skips
            changed = True
        m = _TASK_RE.match(line)
        if m:
            self.tasks.append({"name": m.group("name"), "result": None})
            if len(self.tasks) > _MAX_TASKS:
                self.tasks.pop(0)
                if self._failed_idx is not None:
                    self._failed_idx -= 1
            self.current_task = m.group("name")
            self.recap = False
            return True
        if _PLAY_RECAP_HDR_RE.match(line):
            self.recap = True
            self.current_task = None
            return True
        m = _RESULT_RE.match(line)
        if m and self.tasks and not self.recap:
            kind = m.group("kind")
            res = {"ok": "ok", "changed": "changed", "skipping": "skipped",
                   "failed": "failed", "fatal": "failed"}[kind]
            t = self.tasks[-1]
            if t["result"] is None or _RESULT_RANK[res] > _RESULT_RANK[t["result"]]:
                t["result"] = res
            if res == "failed":
                self.failed_task = t["name"]
                self.failed_msg = _failure_message(line)
                self._failed_idx = len(self.tasks) - 1
            return True
        if _INCLUDED_RE.match(line) and self.tasks and not self.recap:
            if self.tasks[-1]["result"] is None:
                self.tasks[-1]["result"] = "ok"
            return True
        if _IGNORING_RE.match(line) and self.tasks:
            # an ignored failure: the task counts as ok and is not the play's failure
            if self._failed_idx == len(self.tasks) - 1:
                self.tasks[-1]["result"] = "ok"
                self.failed_task = self.failed_msg = None
                self._failed_idx = None
            return True
        return changed

    def fail(self, task: str | None, msg: str) -> None:
        self.failed_task = task
        self.failed_msg = msg[:_MAX_MSG]

    def finish(self, ok: bool, log: str) -> None:
        """At the end of the play: a successful play has no failure (a rescued task); a failed one with
        no failing task line (the CLI refused, no ansible) carries the last output line as its message."""
        self.current_task = None
        self.recap = True
        if ok:
            self.failed_task = self.failed_msg = None
        elif not self.failed_msg:
            last = next((ln.strip() for ln in reversed(log.splitlines()) if ln.strip()), "")
            self.failed_msg = (last or "the play failed (no output)")[:_MAX_MSG]

    def snapshot(self) -> dict:
        done = len(self.tasks) if (self.recap or not self.tasks) else len(self.tasks) - 1
        return {"tasks_done": done,
                "current_task": self.current_task,
                "failed_task": self.failed_task,
                "failed_msg": self.failed_msg,
                "tasks": [{"name": t["name"], "result": t["result"] or "skipped"} for t in self.tasks]}


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


class RigBusy(Exception):
    """A second deployment for a rig that has one pending or in progress (the API answers 409)."""

    def __init__(self, rig: str, did: str, status: str) -> None:
        super().__init__(f"rig '{rig}' already has deployment {did} ({status})")
        self.rig, self.did, self.status = rig, did, status


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
               name: str | None = None, host: str | None = None,
               extra: dict | None = None, secrets: dict | None = None) -> dict:
        did = uuid.uuid4().hex
        rec = {
            "id": did,
            "name": name or f"{kind}-{rig}",
            "rig": rig,
            "host": host,            # explicit IP override (per-device deploy) or None
            "extra": extra or {},    # extra ansible vars (e.g. cleanup scope)
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
            "log_tail": "",
            "progress": {"tasks_done": 0, "current_task": None, "failed_task": None,
                         "failed_msg": None, "tasks": []},
            "vpn_ip": None,
            "pki": None,                # {serial, not_after} from the `COLONY_PKI` report
            "rig_class": None,
            "skipped_by_design": None,  # [..] from the `rig_class=..; skipped by design: ..` report
        }
        with self._cv:
            busy = next((r for r in self._deps.values()
                         if r.get("rig") == rig and r.get("status") in (PENDING, INPROGRESS)), None)
            if busy is not None:
                raise RigBusy(rig, busy["id"], busy["status"])
            if secrets:                  # memory only, dropped when the play ends (or on abort/prune)
                self.__dict__.setdefault("_secrets", {})[did] = dict(secrets)
            self._deps[did] = rec
            self._spill(rec)
            self._cv.notify()
        return self._public(rec)

    def list(self) -> list[dict]:
        with self._lock:
            return [self._public(r) for r in sorted(
                self._deps.values(), key=lambda r: r["created"], reverse=True)]

    def prune(self, rig: str | None = None, finished_only: bool = True) -> int:
        """Drop journal entries (default: FINISHED ones for `rig`) from memory
        + rewrite the JSONL spill. Returns how many were removed. In-flight
        (pending/inprogress/scheduled) are kept unless finished_only=False."""
        keep_states = None if not finished_only else {FINISHED}
        removed = 0
        with self._lock:
            for did in list(self._deps):
                rec = self._deps[did]
                if rig is not None and rec.get("rig") != rig:
                    continue
                if keep_states is not None and rec.get("status") not in keep_states:
                    continue
                del self._deps[did]
                removed += 1
            self._rewrite_journal()
        return removed

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
            try:
                self._run_play(rec)
            except Exception as e:  # noqa: BLE001: a bug here must not kill the worker or leave it inprogress
                with self._cv:
                    if rec.get("status") == INPROGRESS:
                        rec["status"] = FINISHED
                        rec["finished"] = _now()
                        rec["statistics"]["status"] = {"success": 0, "failure": 1,
                                                       "pending": 0, "noartifact": 0}
                        rec["rc"] = 125
                        prog = dict(rec.get("progress") or {})
                        prog["failed_msg"] = f"colony-api: {type(e).__name__}: {e}"[:_MAX_MSG]
                        rec["progress"] = prog
                        self._spill(rec)

    def _next_runnable(self) -> dict | None:
        now = _now()
        for r in sorted(self._deps.values(), key=lambda r: r["created"]):
            if r["status"] == PENDING:
                return r
            if r["status"] == SCHEDULED and (r["schedule"] or 0) <= now:
                return r
        return None

    def _run_play(self, rec: dict) -> None:
        """Run one play with Popen and read its output LINE BY LINE into the record
        (under the lock): `progress` + `log_tail` are visible while the play runs.
        The secrets file is unlinked in `finally`, whatever happens in between."""
        env = {**os.environ}
        kh = os.environ.get("COLONY_KNOWN_HOSTS", "/var/lib/colony/known_hosts")
        env["ANSIBLE_HOST_KEY_CHECKING"] = "True"
        env["ANSIBLE_SSH_ARGS"] = ("-o ControlMaster=auto -o ControlPersist=60s "
                                   f"-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile={kh}")
        env["PYTHONUNBUFFERED"] = "1"    # the CLI + ansible-playbook write to a pipe: flush per line
        # colony CLI resolves the registry/bundle from $THEIA_WORKSPACE.
        cmd = ["python3", str(_colony_bin()), rec["kind"], rec["rig"]]
        # REGISTRY-FREE: pass host + role as FLAGS so colony resolves the device
        # from Mender (host) + the S3 manifest slice (role) with no registry file.
        # Everything else (machine_instance, …) rides as -e k=v.
        extra = dict(rec.get("extra") or {})
        role = extra.pop("role", None)
        if rec.get("host"):
            cmd += ["--host", str(rec["host"])]
        if role:
            cmd += ["--role", str(role)]
        if extra:
            ev = [f"{k}={v}" for k, v in extra.items()]
            cmd += ["-e", " ".join(ev)]
        with self._cv:
            sec = getattr(self, "_secrets", {}).pop(rec["id"], None)
        scrub = [v for v in (sec or {}).values() if isinstance(v, str) and len(v) >= 8]
        prog = PlayProgress()
        lines: list[str] = []
        tail = ""
        sec_file = None
        p = None
        timer = None
        timed_out = threading.Event()
        last_spill = _now()
        try:
            if sec:
                fd, sec_file = tempfile.mkstemp(prefix="colony-sec-", suffix=".json")   # mkstemp: 0600
                with os.fdopen(fd, "w") as f:
                    json.dump(sec, f)
                env["COLONY_SECRETS_FILE"] = sec_file
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 stdin=subprocess.DEVNULL, text=True, errors="replace", env=env)

            def _kill() -> None:
                timed_out.set()
                p.kill()
            timer = threading.Timer(_PLAY_TIMEOUT, _kill)
            timer.daemon = True
            timer.start()
            for line in p.stdout:
                for v in scrub:          # a secret never reaches the record, the tail or the journal
                    line = line.replace(v, "***")
                lines.append(line)
                tail = (tail + line)[-_TAIL_BYTES:]
                changed = prog.feed(line)
                with self._cv:
                    rec["log_tail"] = tail
                    if changed:
                        rec["progress"] = prog.snapshot()
                        for k in ("vpn_ip", "pki", "rig_class", "skipped_by_design"):
                            if prog.fields.get(k) is not None:
                                rec[k] = prog.fields[k]
                        if _now() - last_spill >= _SPILL_EVERY:
                            last_spill = _now()
                            self._spill(rec)
            rc = p.wait()
            log = "".join(lines)
            if timed_out.is_set():
                log += "\n[colony-api] TIMEOUT"
                rc = 124
                prog.fail(None, f"timeout after {_PLAY_TIMEOUT} s")
        except Exception as e:  # noqa: BLE001: the worker must survive and the secret file must go
            log = "".join(lines) + f"\n[colony-api] {type(e).__name__}: {e}"
            rc = 125
            prog.fail(prog.current_task, f"colony-api: {type(e).__name__}: {e}")
        finally:
            if timer is not None:
                timer.cancel()
            if p is not None and p.poll() is None:
                p.kill()
                try:
                    p.wait(timeout=10)
                except Exception:  # noqa: BLE001
                    pass
            if sec_file:
                try:
                    os.unlink(sec_file)
                except OSError:
                    pass
        for v in scrub:                  # belt and braces (an exception text may carry one)
            log = log.replace(v, "***")
        rig_host = self._rig_host(rec["rig"])
        stats = _parse_recap(log, rig_host)
        if rc != 0 and stats["failure"] == 0 and stats["success"] == 0:
            stats["failure"] = 1          # nonzero exit, no recap → failure
        prog.finish(ok=stats["success"] == 1 and stats["failure"] == 0, log=log)
        with self._cv:
            for k in ("vpn_ip", "pki", "rig_class", "skipped_by_design"):
                if prog.fields.get(k) is not None:
                    rec[k] = prog.fields[k]
            rec["status"] = FINISHED
            rec["finished"] = _now()
            rec["log"] = log[-65536:]     # keep the tail; full log is large
            rec["log_tail"] = log[-_TAIL_BYTES:]
            rec["progress"] = prog.snapshot()
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

    def _rewrite_journal(self) -> None:
        # Rewrite the JSONL spill from the in-memory map (after a prune).
        # Caller holds the lock.
        try:
            _JOURNAL.parent.mkdir(parents=True, exist_ok=True)
            tmp = _JOURNAL.with_suffix(".jsonl.tmp")
            with tmp.open("w") as f:
                for rec in self._deps.values():
                    f.write(json.dumps(rec) + "\n")
            tmp.replace(_JOURNAL)
        except OSError:
            pass

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
