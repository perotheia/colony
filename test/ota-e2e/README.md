# OTA end-to-end test (isolated, CI-runnable)

Reproduces — hermetically in containers — the full Mender OTA campaign that was
proven live on rpi4 + jetson:

```
provision (colony ansible) → enroll (Mender server) → first install
  → update v2 → deliberate-fail rollback
```

asserting at every step. No physical boards, no host networking; everything runs
on an isolated Docker bridge so it is reproducible in CI.

## Topology

| Container | Role |
| --- | --- |
| `mender-server` | the OSS Mender server stack (brought up by `ground-station/mender/server/up.sh`, joined to the test network as `docker.mender.io`) |
| `ota-controller` | the dev-box/dalek controller — runs colony ansible, `enroll-rig.sh`, `fleet.py` |
| `ota-central` | a Theia rig (systemd) — the demo services slice (com/per/sm/phm/…); **nm runs `run_on_start:false`** so it can't reconfigure the shared host net iface |
| `ota-compute` | a Theia rig (systemd) — the demo apps `p1`–`p4` + `shwa` |

Built from the **demo workspace** (`demo/manifest/split/rig.py`), so the OTA payload
is the full demo release (services + demo apps), and `nm` lands on central — which
exercises the `run_on_start:false` boot-skip (a HW node that would otherwise tear
down the SSH/management interface).

**Host networking** (not a bridge): so host-side `tdb` / `rtdb` / the artheia probe
reach the stack's nodes over raw TIPC, and the two boards share one host TIPC
namespace (disambiguated by `machine_instance` 0/1). Ansible reaches the boards via
the `community.docker.docker` connection (docker exec) — on host net two sshd's
can't both bind :22. etcd is treated as external (the runner's etcd on :2379).

Boards run **systemd as PID 1** (the real flow installs systemd units), so they
need `--privileged` + the cgroup mount — the compose file sets this.

## Run locally

Requires Docker (+ compose v2), the `theia`/`ground-station` repos checked out as
siblings of `colony`, and a Python venv at `theia/.venv` (for `theia`/`artheia`).

```sh
cd colony/test/ota-e2e
./run-e2e.sh                 # full: build → up → flow → assert → teardown
./run-e2e.sh --keep          # leave the stack up for debugging
./run-e2e.sh --no-build      # reuse dist/ from a prior build (skip the bazel stage)
```

Exits non-zero on the first failed assertion; container logs are dumped to
`./logs/` on failure.

## What it builds (`build-artifacts.sh`)

From source, x86_64, **gzip** payloads (portable — boards may lack zstd):

- `theia/dist/manifest/{central,compute}/` + per-machine `.deb` (the colony bundle)
- `dist/roles/{central,compute}-0.2.1.mender` — first install
- `dist/roles/{central,compute}-0.2.2.mender` — the update (stamped with a marker)
- `dist/roles/central-0.2.3-broken.mender` — a corrupt payload (the rollback test)

## CI

`.github/workflows/ota-e2e.yml` — `workflow_dispatch` + nightly (03:00 UTC). It is
the heavy job (bazel build + the trimmed Mender server — ~12 containers / ~1.4GB,
mongo being the floor; the unused gui/deviceconfig/deviceconnect/iot-manager and the
1.3GB qemu client are not pulled); not run per-PR. Logs are
uploaded as an artifact on failure.

## Why this exists

The provisioning + OTA path had real bugs that only a full e2e run surfaces
(application.json slicing, central TIPC bearer, mender_artifacts_dir recursion,
theia_run_src path, the 4.x-client gap, zstd portability, the rollback-target
ordering). This test guards all of them without needing the lab hardware.
```
