# colony-api

A thin REST service over the colony deploy adapter, **shaped like the Mender
Management API** so the Ground Station drives **base** (runtime+services)
deployments the same way it drives **app** (user-software) deployments through
Mender. One operator surface, two authorities — see
[ground-station/docs/design/gs-ux-design.md §6](../../ground-station/docs/design/gs-ux-design.md).

## Endpoints (Mender-shaped)

| Method | Path | ≈ Mender | Action |
|---|---|---|---|
| `GET` | `/rigs` | `GET /devices` | deploy targets from `deploy/registry/*.yml` |
| `GET` | `/rigs/{name}` | — | one rig's public knobs |
| `GET` | `/deployments` | `GET /deployments` | the run journal |
| `POST` | `/deployments` | `POST /deployments` | `{rig, kind, schedule?}` → enqueue a play |
| `GET` | `/deployments/{id}` | same | status + statistics |
| `GET` | `/deployments/{id}/log` | — | the Ansible output (tail) |
| `POST` | `/deployments/{id}/abort` | abort | abort a pending/scheduled run |

`kind` ∈ `provision | orchestrate | cleanup`. **Status vocabulary is aligned to
Mender** — `pending | scheduled | inprogress | finished` + a
`statistics.status` `{success, failure, pending, …}` dict parsed from the Ansible
PLAY RECAP — so gs-api's `RolloutBar`/`StatusBadge` render colony rows unchanged.

## How it runs the play

`POST /deployments` enqueues a record; a single worker thread shells
`python3 /colony/bin/colony <kind> <rig>` (the same CLI a human runs) with
`$THEIA_WORKSPACE` pointing at the mounted bundle. Scheduled runs wait for their
timestamp. The PLAY RECAP for the rig host → a 1-hot Mender statistics dict
(`failed/unreachable>0 → failure:1`, else `success:1`). History spills to a JSONL
journal so a restart keeps it.

## Container mounts (compose)

The image is `python:3.12-slim` + `ansible-core` + `openssh-client`. It runs the
plays **inside the container**, so it mounts:

- `/colony` — the colony repo (playbooks + `bin/colony`), read-only.
- `/workspace` — the bundle (`deploy/registry/*` + `dist/manifest/*`), `$THEIA_WORKSPACE`.
- `/root/.ssh/id_*` — a key authorized on the rigs (agentless SSH push), read-only.
- `colony-journal:/var/lib/colony` — deployment history.

Wired in `ground-station/docker-compose.yml` as `colony-api` on the `mender`
network. Override the host paths with `COLONY_DIR`, `THEIA_WS_DIR`, `SSH_KEY` in
`.env`. `COLONY_API_KEY` (X-Colony-Key header) gates the mutating routes.

## Local dev

```sh
python3 -m venv .venv && .venv/bin/pip install -e .
THEIA_WORKSPACE=../../theia COLONY_ANSIBLE=../ansible \
  .venv/bin/uvicorn colony_api.app:app --port 8081
curl localhost:8081/rigs
```

**Verified (2026-06-28):** dockerized `POST /deployments {rig: central, kind:
orchestrate}` ran the real Ansible play from inside the container, SSH'd to the
rpi4, and finished `success:1, rc=0` (PLAY RECAP `central ok=32 failed=0`); the
rpi4 ended in the proven state (supervisor + 14 services). Schedule + abort +
404/400 validation all green.
