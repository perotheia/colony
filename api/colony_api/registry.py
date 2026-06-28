"""The deploy registry — colony's analogue of Mender's device inventory.

Each `deploy/registry/<target>.yml` names a rig (ansible_host + machine slice +
runtime knobs). GET /rigs surfaces these as the deploy targets the operator can
run base deployments against. Rooted at $THEIA_WORKSPACE (the bundle workspace),
mirroring the colony CLI's WORKSPACE resolution.
"""
from __future__ import annotations

import os
from pathlib import Path

import yaml


def _workspace() -> Path:
    return Path(os.environ.get("THEIA_WORKSPACE") or os.getcwd())


def _registry_dir() -> Path:
    # $COLONY_REGISTRY overrides (mirrors the CLI); else <ws>/deploy/registry.
    return Path(os.environ.get("COLONY_REGISTRY")
                or (_workspace() / "deploy" / "registry"))


# The non-secret registry fields worth surfacing to the operator UI. We do NOT
# echo the whole file (it may grow secrets); pick the deploy-relevant knobs.
_PUBLIC_FIELDS = (
    "ansible_host", "machine", "arch", "deb_arch", "runtime_version",
    "s3_endpoint", "s3_runtime_bucket", "mender_role", "mender_device_type",
    "boards", "tipc_scope", "machine_instance",
)


def list_rigs() -> list[dict]:
    """Every rig in the registry, as {name, <public fields>}. Empty if the dir
    is absent (a workspace with no registry yet)."""
    rdir = _registry_dir()
    out: list[dict] = []
    if not rdir.is_dir():
        return out
    for f in sorted(rdir.glob("*.yml")):
        try:
            data = yaml.safe_load(f.read_text()) or {}
        except yaml.YAMLError as e:
            out.append({"name": f.stem, "_error": str(e)})
            continue
        rig = {"name": f.stem}
        rig.update({k: data[k] for k in _PUBLIC_FIELDS if k in data})
        out.append(rig)
    return out


def get_rig(name: str) -> dict | None:
    """One rig's public view, or None if no such registry entry."""
    return next((r for r in list_rigs() if r.get("name") == name), None)


def rig_exists(name: str) -> bool:
    return (_registry_dir() / f"{name}.yml").is_file()
