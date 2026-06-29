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
        cmd = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
               "-o", "ConnectTimeout=8", "-i", "/root/.ssh/id_rsa",
               f"{user}@{host}", remote]
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
        if not info.get("mac"):
            raise HTTPException(status_code=502, detail=f"probe {host}: no MAC read")
        return {"host": host, "mac": info.get("mac"), "hostname": info.get("hostname")}

    return app


app = create_app()
