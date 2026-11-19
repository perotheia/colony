#!/usr/bin/env python3
"""pki-signer.py — the e2e's THROWAWAY fleet signer (TEST ONLY).

Serves the ground station's fleet-PKI routes (POST /api/pki/sign, GET /api/pki/ca,
GET /api/pki/issued) by loading the REAL signer, ground-station
api/gs_api/routers/pki.py, straight from the ground-station checkout: the e2e
certificates are made by the same code that makes a field rig's. Only the app around
it is new: an X-GS-Key gate (as gs-api's) and a bind address.

The CA is created on first use in GS_PKI_DIR (a temp dir inside the controller
container: it dies with the container at teardown). colony provision reaches it
through the NORMAL path: -e gs_pki_url=http://127.0.0.1:<port> makes
tasks/pki-enroll.yml send each rig's CSR here (the controller is the ansible
localhost), and ground-station tools/operator-cert.sh gets the test operator's
client certificate from it.

  GS_PKI_DIR=/tmp/e2e-fleet-ca GS_API_KEY=<k> python3 pki-signer.py [--port 8099]
"""
from __future__ import annotations

import argparse
import hmac
import importlib.util
import os
import sys
from pathlib import Path

GS_DIR = Path(os.environ.get("GROUND_STATION_DIR", "/repo/ground-station"))
PKI_PY = GS_DIR / "api" / "gs_api" / "routers" / "pki.py"


def _load_pki():
    # By path, not `import gs_api…`: the package __init__ pulls the whole gs-api app (Mender client, S3, …);
    # the signer module itself needs only fastapi + pydantic + cryptography.
    spec = importlib.util.spec_from_file_location("gs_pki", PKI_PY)
    if spec is None or spec.loader is None:
        sys.exit(f"pki-signer: cannot load {PKI_PY}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8099)
    a = ap.parse_args()
    if not os.environ.get("GS_PKI_DIR"):
        sys.exit("pki-signer: set GS_PKI_DIR (a throwaway directory for the test CA)")
    key = os.environ.get("GS_API_KEY", "")
    if not key:
        sys.exit("pki-signer: set GS_API_KEY (the signer is gated like gs-api)")

    import uvicorn
    from fastapi import FastAPI, Request
    from fastapi.responses import JSONResponse

    pki = _load_pki()
    app = FastAPI(title="e2e fleet signer (test only)")

    @app.middleware("http")
    async def _gate(request: Request, call_next):
        if not hmac.compare_digest(request.headers.get("x-gs-key", ""), key):
            return JSONResponse({"detail": "missing or wrong X-GS-Key"}, status_code=401)
        return await call_next(request)

    app.include_router(pki.router)
    print(f"pki-signer: {PKI_PY} on http://{a.host}:{a.port} (CA in {os.environ['GS_PKI_DIR']})", flush=True)
    uvicorn.run(app, host=a.host, port=a.port, log_level="warning")
    return 0


if __name__ == "__main__":
    sys.exit(main())
