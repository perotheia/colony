"""colony-api FastAPI app — Mender-Management-API-shaped routes over colony.

Routes (deliberately mirroring the Mender deployments plane so gs-api fans out to
both through one client shape — design §6):

    GET  /rigs                          the deploy targets (≈ Mender devices)
    GET  /deployments                   the run journal (active|scheduled|finished)
    POST /deployments                   {rig, kind, schedule?} → enqueue a play
                                        (409 {detail, id, status} while the rig has one pending/in progress)
    GET  /deployments/{id}              one deployment's status + statistics + live progress/log_tail
    GET  /deployments/{id}/log          the Ansible output (tail)
    POST /deployments/{id}/abort        abort a pending/scheduled run

Auth: an optional X-Colony-Key (COLONY_API_KEY) gates the mutating routes, the
same pattern gs-api uses (unset → open for the gs-api-only path).
"""
from __future__ import annotations

import hmac
import re
import os
import subprocess

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from . import __version__, registry
from .runner import RigBusy, runner


def _split_hostport(host: str):
    """Split an operator-entered 'ip[:port]' into (host, port). A local test rig
    is a container on the dalek host net at a distinct SSH port (central :2201,
    compute :2202); a real rig is ip:22. Returns (host, None) when no port given."""
    h = (host or "").strip()
    if h.count(":") == 1 and "]" not in h:        # ipv4 'host:port' (not ipv6)
        a, _, b = h.partition(":")
        if b.isdigit():
            return a, b
    return h, None


_VALID_KINDS = {"provision", "orchestrate", "cleanup"}


def _key_ok(got: str | None) -> bool:
    want = os.environ.get("COLONY_API_KEY", "")
    return bool(want) and bool(got) and hmac.compare_digest(got.encode(), want.encode())


def _require_key(x_colony_key: str | None = Header(default=None)) -> None:
    if not _key_ok(x_colony_key):
        raise HTTPException(status_code=401, detail="invalid or missing X-Colony-Key")


# ssh to a rig: host keys are RECORDED on first contact (enrollment) in a persistent file and ENFORCED after
# (accept-new = trust on first use, then strict): a changed key fails instead of being accepted silently.
_KNOWN_HOSTS = os.environ.get("COLONY_KNOWN_HOSTS", "/var/lib/colony/known_hosts")
_SSH_TRUST = ["-o", f"UserKnownHostsFile={_KNOWN_HOSTS}", "-o", "StrictHostKeyChecking=accept-new"]
_HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.\-]{0,252}(:[0-9]{1,5})?\Z")
_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:\-]{0,63}\Z")
_USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}\Z")    # a POSIX login name (ssh user)
# A deployment request reaches ansible-playbook as extra vars on the controller (root, the fleet ssh key): every
# value is checked here, and the runner hands them to ansible as ONE JSON object (never a space-joined k=v string,
# which ansible splits into more variables: role="master ansible_ssh_common_args=..." was an injection).
_RIG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
_ROLE_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}\Z")
_EXTRA_KEY_RE = re.compile(r"^[a-z_][a-z0-9_]{0,63}\Z")
# a string value: no whitespace, quotes, '=', '/', braces ('{{' is templated by ansible on the controller) or a
# leading '-'
_EXTRA_STR_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:+@-]{0,127}\Z")
_SECRET_STR_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:+@-]{0,1023}\Z")
_EXTRA_PER_KEY = {                       # tighter shapes for the keys the GS sends
    "role": _ROLE_RE,
    "ansible_user": _USER_RE,
    "mender_device_id": _RIG_RE,
    "runtime_version": re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,79}\Z"),
}
# set by the CLI from rig/host/role, or connection-level ansible vars: never from a request
_EXTRA_RESERVED = {"target", "machine", "registry_dir", "manifest_dir", "config_override_dir"}
_EXTRA_ANSIBLE_OK = {"ansible_user"}


def _check(kind: str, value: str, rx: re.Pattern) -> str:
    if not isinstance(value, str) or not rx.match(value):
        raise HTTPException(status_code=422, detail=f"{kind}: not a valid value")
    return value


def _check_vars(kind: str, d: dict | None, str_re: re.Pattern, per_key: dict | None = None) -> None:
    """Extra / secret ansible vars: keys [a-z_][a-z0-9_]*, no reserved or connection-level (ansible_*) key,
    values a bool, an int or a tight string (per key where known). 422 naming the key, never the value."""
    if d is None:
        return
    if not isinstance(d, dict):
        raise HTTPException(status_code=422, detail=f"{kind}: an object of variables")
    for k, v in d.items():
        if not isinstance(k, str) or not _EXTRA_KEY_RE.match(k):
            raise HTTPException(status_code=422, detail=f"{kind}: not a valid variable name")
        if k in _EXTRA_RESERVED or (k.startswith("ansible_") and k not in _EXTRA_ANSIBLE_OK):
            raise HTTPException(status_code=422, detail=f"{kind}.{k}: a reserved variable")
        if isinstance(v, bool) or (isinstance(v, int) and abs(v) < 2 ** 31):
            continue
        rx = (per_key or {}).get(k, str_re)
        if not isinstance(v, str) or not rx.match(v):
            raise HTTPException(status_code=422, detail=f"{kind}.{k}: not a valid value")


class DeployRequest(BaseModel):
    model_config = {"extra": "forbid"}   # an unknown field (e.g. `secrets` sent to an old image) is a 422
    rig: str
    kind: str = "orchestrate"           # provision | orchestrate | cleanup
    extra: dict | None = None           # extra ansible vars, e.g. the cleanup
                                        # scope {clean_app, clean_runtime, clean_mender}
    host: str | None = None             # explicit IP override (per-device deploy)
    secrets: dict | None = None         # secret ansible vars (e.g. vpn_authkey): passed as a 0600 vars
                                        # file, held in memory only: never journaled, logged or returned
    schedule: float | None = None        # unix ts; None = run now
    name: str | None = None


def create_app() -> FastAPI:
    app = FastAPI(title="colony-api",
                  version=__version__,
                  description="Mender-shaped REST over the colony deploy adapter "
                              "(base runtime+services deployments).")
    if not os.environ.get("COLONY_API_KEY"):
        raise RuntimeError("COLONY_API_KEY is not set: colony-api drives root ssh to the fleet and refuses to "
                           "start without an API key")

    @app.exception_handler(RequestValidationError)
    async def _validation_error(request, exc: RequestValidationError):
        """A 422 that never echoes the request: FastAPI's default puts the offending `input` in the body (an
        old image answered the GS `secrets` field with the VPN auth key in it). Only type, loc and msg."""
        from fastapi.responses import JSONResponse
        errs = [{k: e.get(k) for k in ("type", "loc", "msg")} for e in exc.errors()]
        return JSONResponse(status_code=422, content={"detail": errs})

    @app.middleware("http")
    async def _gate(request, call_next):          # EVERY route except /health needs the key (fail closed)
        if request.url.path != "/health" and not _key_ok(request.headers.get("x-colony-key")):
            from fastapi.responses import JSONResponse
            return JSONResponse(status_code=401, content={"detail": "invalid or missing X-Colony-Key"})
        return await call_next(request)

    app.add_middleware(
        CORSMiddleware,
        allow_origins=[o.strip()
                       for o in os.environ.get("COLONY_CORS_ORIGINS", "").split(",") if o.strip()],
        allow_methods=["*"], allow_headers=["*"], allow_credentials=False,
    )

    @app.get("/health", tags=["meta"])
    def health() -> dict:
        return {"status": "ok", "service": "colony-api", "version": __version__}

    @app.get("/rigs", tags=["rigs"])
    def rigs() -> dict:
        return {"rigs": registry.list_rigs()}

    @app.get("/rigs/{name}", tags=["rigs"])
    def rig(name: str) -> dict:
        r = registry.get_rig(name)
        if not r:
            raise HTTPException(status_code=404, detail=f"no rig '{name}'")
        return r

    @app.get("/deployments", tags=["deployments"])
    def deployments() -> dict:
        return {"deployments": runner.list()}

    @app.post("/deployments", tags=["deployments"],
              dependencies=[Depends(_require_key)])
    def create_deployment(req: DeployRequest) -> dict:
        if req.kind not in _VALID_KINDS:
            raise HTTPException(status_code=400,
                                detail=f"kind must be one of {sorted(_VALID_KINDS)}")
        _check("rig", req.rig, _RIG_RE)
        if req.host is not None:
            _check("host", req.host, _HOST_RE)
        _check_vars("extra", req.extra, _EXTRA_STR_RE, _EXTRA_PER_KEY)
        _check_vars("secrets", req.secrets, _SECRET_STR_RE)
        # registry-free: a request carrying an explicit host (the device's Mender
        # reachable_ip, + role in extra) needs NO registry entry — colony resolves
        # everything from Mender + the S3 manifest. Only a bare CLI-style request
        # (no host) must match a registry rig.
        if not req.host and not registry.rig_exists(req.rig):
            raise HTTPException(status_code=404,
                                detail=f"no rig '{req.rig}' in the registry "
                                       "(and no host — pass host for registry-free)")
        try:
            return runner.create(req.rig, req.kind, req.schedule, req.name, req.host, req.extra,
                                 secrets=req.secrets)
        except RigBusy as e:             # one pending/in-progress deployment per rig (the GS refuses first)
            from fastapi.responses import JSONResponse
            return JSONResponse(status_code=409, content={"detail": str(e), "id": e.did,
                                                          "status": e.status})

    @app.delete("/deployments", tags=["deploy"])
    def prune_deployments(rig: str | None = None,
                          finished_only: bool = True) -> dict:
        """Prune journal entries: default the FINISHED ones for `rig` (the GS
        clear-actions button). In-flight are kept. Returns the removed count."""
        n = runner.prune(rig, finished_only)
        return {"pruned": n, "rig": rig}


    @app.get("/deployments/{did}", tags=["deployments"])
    def get_deployment(did: str) -> dict:
        d = runner.get(did)
        if not d:
            raise HTTPException(status_code=404, detail="no such deployment")
        return d

    @app.get("/deployments/{did}/log", tags=["deployments"])
    def get_log(did: str) -> dict:
        lg = runner.log(did)
        if lg is None:
            raise HTTPException(status_code=404, detail="no such deployment")
        return {"id": did, "log": lg}

    @app.post("/deployments/{did}/abort", tags=["deployments"],
              dependencies=[Depends(_require_key)])
    def abort_deployment(did: str) -> dict:
        if not runner.abort(did):
            raise HTTPException(status_code=409,
                                detail="cannot abort (already running or finished)")
        return runner.get(did) or {"id": did, "status": "finished"}

    @app.post("/normalize-key", tags=["enrol"])
    def normalize_key(body: dict) -> dict:
        """Normalize a public key to the PEM SubjectPublicKeyInfo Mender wants.
        Accepts openssh ('ssh-rsa AAAA..', 'ssh-ed25519 ..') OR any PEM. colony-api
        has ssh-keygen; gs-api (distroless) does not, so it proxies here."""
        import tempfile, os as _os
        key = (body.get("key") or "").strip()
        if not key:
            raise HTTPException(status_code=400, detail="empty key")
        if "BEGIN PUBLIC KEY" in key:
            return {"pem": key}                 # already SubjectPublicKeyInfo PEM
        # openssh or PKCS1/other PEM → convert via ssh-keygen -e -m PKCS8
        d = tempfile.mkdtemp()
        try:
            kp = _os.path.join(d, "k.pub")
            with open(kp, "w") as f:
                f.write(key if key.endswith("\n") else key + "\n")
            out = subprocess.run(["ssh-keygen", "-e", "-m", "PKCS8", "-f", kp],
                                 capture_output=True, text=True, timeout=10)
            if out.returncode != 0 or "BEGIN PUBLIC KEY" not in out.stdout:
                raise HTTPException(status_code=400,
                    detail=f"unrecognized key (give an openssh 'ssh-rsa ..' line or a "
                           f"PEM public key): {(out.stderr or '').strip()[:160]}")
            return {"pem": out.stdout.strip()}
        finally:
            import shutil; shutil.rmtree(d, ignore_errors=True)

    @app.post("/set-identity", tags=["enrol"])
    def set_identity(body: dict) -> dict:
        """Set a device's mender IDENTITY to a fixed UUID (so Mender matches by
        device_id, consistent with preauth). SSHes the host, writes an identity
        script that echoes device_id=<uuid>, restarts mender-auth. We're already
        connected (the probe path), so this is the place to do it."""
        host = body.get("host"); cid = body.get("controller_id")
        if not host or not cid:
            raise HTTPException(status_code=400, detail="host and controller_id required")
        _check("host", host, _HOST_RE)
        _check("controller_id", cid, _ID_RE)      # goes into a root-run script: identifiers only
        user = os.environ.get("COLONY_SSH_USER", "axadmin")
        # write the identity script (idempotent) + restart mender-auth. The script
        # path is the mender default; we point the symlink target at our script.
        script = ("#!/bin/sh\necho device_id=" + cid + "\n")
        remote = (
            "sudo install -d /etc/mender/identity /usr/share/mender/identity && "
            "printf '%s' '" + script.replace("'", "'\\''") + "' | "
            "sudo tee /etc/mender/identity/mender-device-identity >/dev/null && "
            "sudo chmod 0755 /etc/mender/identity/mender-device-identity && "
            "sudo ln -sf /etc/mender/identity/mender-device-identity "
            "/usr/share/mender/identity/mender-device-identity && "
            "(sudo systemctl restart mender-authd 2>/dev/null || "
            " sudo systemctl restart mender-auth 2>/dev/null || true) && "
            "echo set-identity-ok"
        )
        h, port = _split_hostport(host)
        cmd = ["ssh", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR", *_SSH_TRUST,
               "-o", "ConnectTimeout=8", "-i", "/root/.ssh/id_rsa"]
        if port:
            cmd += ["-p", port]
        cmd += [f"{user}@{h}", remote]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        except Exception as e:  # noqa: BLE001
            raise HTTPException(status_code=502, detail=f"set-identity {host}: {e}")
        if out.returncode != 0 or "set-identity-ok" not in out.stdout:
            raise HTTPException(status_code=502,
                                detail=f"set-identity {host} failed: {(out.stderr or out.stdout).strip()[-300:]}")
        return {"host": host, "controller_id": cid, "status": "identity-set"}

    @app.get("/pubkey", tags=["enrol"])
    def pubkey() -> dict:
        """OUR SSH public key — the operator hands this to the 3rd party who
        installed a (preauthorized) device, to add to the device's authorized_keys
        so colony can SSH it for provision/orchestrate. Derived from the mounted
        rig private key."""
        try:
            out = subprocess.run(
                ["ssh-keygen", "-y", "-f", "/root/.ssh/id_rsa"],
                capture_output=True, text=True, timeout=10)
        except Exception as e:  # noqa: BLE001
            raise HTTPException(status_code=500, detail=f"pubkey: {e}")
        if out.returncode != 0:
            raise HTTPException(status_code=500,
                                detail=f"pubkey: {out.stderr.strip()[:200]}")
        return {"pubkey": out.stdout.strip()}

    @app.get("/probe", tags=["enrol"])
    def probe(host: str, user: str | None = None) -> dict:
        """SSH a host and read its stable identity for enrolment: the eth0 MAC
        (the Mender identity key) + hostname. Uses the mounted rig SSH key. The
        operator types a Host IP in the Create-Target modal; GS proxies here so
        the modal can prefill Controller ID (MAC) + Name (hostname)."""
        _check("host", host, _HOST_RE)
        # the ssh user the operator typed (GS Connect modal), else the default
        user = _check("user", user, _USER_RE) if user else os.environ.get("COLONY_SSH_USER", "axadmin")
        # one ssh, read both. eth0 first; fall back to the first non-lo iface.
        # read hostname + eth0 MAC (fallback: first non-lo iface) in one ssh.
        # sudo= : can this user become root without a password (provision needs it)? root needs no sudo
        # (opkg images have none); `sudo -n` never prompts. The GS preflight maps sudo=no to `no-sudo`.
        remote = (
            "echo hostname=$(hostname); "
            "cat /sys/class/net/eth0/address 2>/dev/null "
            "| sed 's/^/mac=/' || true; "
            "if [ \"$(id -u)\" = 0 ]; then echo sudo=root; "
            "elif sudo -n true >/dev/null 2>&1; then echo sudo=ok; else echo sudo=no; fi"
        )
        h, port = _split_hostport(host)
        cmd = ["ssh", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR", *_SSH_TRUST,
               "-o", "ConnectTimeout=8", "-i", "/root/.ssh/id_rsa"]
        if port:
            cmd += ["-p", port]
        cmd += [f"{user}@{h}", remote]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        except Exception as e:  # noqa: BLE001
            raise HTTPException(status_code=502, detail=f"probe {host}: {e}")
        if out.returncode != 0:
            raise HTTPException(status_code=502,
                                detail=f"probe {host} failed: {(out.stderr or out.stdout).strip()[-300:]}")
        info = {}
        for line in out.stdout.splitlines():
            if "=" in line:
                k, _, v = line.partition("=")
                info[k.strip()] = v.strip()
        import uuid as _uuid
        # MAC is OPTIONAL now — identity is the minted UUID (a host-net container
        # has no eth0). We still surface the MAC when present (real rigs), but a
        # missing one never blocks enrolment.
        # mint a UUID the operator uses as the Controller ID (consistent with
        # preauth); /set-identity writes it onto the device at Save.
        return {"host": host, "mac": info.get("mac"),
                "hostname": info.get("hostname"), "controller_id": str(_uuid.uuid4()),
                "sudo": info.get("sudo")}          # root | ok | no (None: the rig printed nothing)

    return app


app = create_app()
