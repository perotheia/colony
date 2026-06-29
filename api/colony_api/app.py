"""colony-api FastAPI app — Mender-Management-API-shaped routes over colony.

Routes (deliberately mirroring the Mender deployments plane so gs-api fans out to
both through one client shape — design §6):

    GET  /rigs                          the deploy targets (≈ Mender devices)
    GET  /deployments                   the run journal (active|scheduled|finished)
    POST /deployments                   {rig, kind, schedule?} → enqueue a play
    GET  /deployments/{id}              one deployment's status + statistics
    GET  /deployments/{id}/log          the Ansible output (tail)
    POST /deployments/{id}/abort        abort a pending/scheduled run

Auth: an optional X-Colony-Key (COLONY_API_KEY) gates the mutating routes, the
same pattern gs-api uses (unset → open for the gs-api-only path).
"""
from __future__ import annotations

import os
import subprocess

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from . import __version__, registry
from .runner import runner


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


def _require_key(x_colony_key: str | None = Header(default=None)) -> None:
    want = os.environ.get("COLONY_API_KEY", "")
    if want and x_colony_key != want:
        raise HTTPException(status_code=401, detail="invalid or missing X-Colony-Key")


class DeployRequest(BaseModel):
    rig: str
    kind: str = "orchestrate"           # provision | orchestrate | cleanup
    host: str | None = None             # explicit IP override (per-device deploy)
    schedule: float | None = None        # unix ts; None = run now
    name: str | None = None


def create_app() -> FastAPI:
    app = FastAPI(title="colony-api",
                  version=__version__,
                  description="Mender-shaped REST over the colony deploy adapter "
                              "(base runtime+services deployments).")
    app.add_middleware(
        CORSMiddleware,
        allow_origins=[o.strip()
                       for o in os.environ.get("COLONY_CORS_ORIGINS", "*").split(",")],
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
        if not registry.rig_exists(req.rig):
            raise HTTPException(status_code=404,
                                detail=f"no rig '{req.rig}' in the registry")
        return runner.create(req.rig, req.kind, req.schedule, req.name, req.host)

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
        cmd = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
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
                                detail=f"set-identity {host} failed: {(out.stderr or out.stdout).strip()[:200]}")
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
    def probe(host: str) -> dict:
        """SSH a host and read its stable identity for enrolment: the eth0 MAC
        (the Mender identity key) + hostname. Uses the mounted rig SSH key. The
        operator types a Host IP in the Create-Target modal; GS proxies here so
        the modal can prefill Controller ID (MAC) + Name (hostname)."""
        user = os.environ.get("COLONY_SSH_USER", "axadmin")
        # one ssh, read both. eth0 first; fall back to the first non-lo iface.
        # read hostname + eth0 MAC (fallback: first non-lo iface) in one ssh.
        remote = (
            "echo hostname=$(hostname); "
            "cat /sys/class/net/eth0/address 2>/dev/null "
            "| sed 's/^/mac=/' || true"
        )
        h, port = _split_hostport(host)
        cmd = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
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
                                detail=f"probe {host} failed: {(out.stderr or out.stdout).strip()[:200]}")
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
                "hostname": info.get("hostname"), "controller_id": str(_uuid.uuid4())}

    return app


app = create_app()
