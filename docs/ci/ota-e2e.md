# OTA end-to-end CI — setup, flow, and strategy

The **nightly OTA e2e** is colony's integration gate: it reproduces the *real* field
workflow — build a versioned platform, push it to S3, provision two boards from S3,
then deliver user apps over Mender OTA — entirely in containers, on every nightly,
on a stock GitHub-hosted runner. If a colony provisioning/orchestration change, a
theia packaging change, or a ground-station enroll/OTA change breaks the field flow,
this catches it before the hardware does.

It lives in **colony** (`test/ota-e2e/`) because colony owns the deploy adapter —
the provision/orchestrate contract this test exercises. The compose + board images
are colony's; they drive the `theia` build and the `ground-station` Mender/OTA side.

- Workflow: [`.github/workflows/ota-e2e.yml`](https://github.com/perotheia/colony/blob/main/.github/workflows/ota-e2e.yml)
- Driver: [`test/ota-e2e/run-full-story.sh`](https://github.com/perotheia/colony/blob/main/test/ota-e2e/run-full-story.sh)
- Status: **green on `ubuntu-latest`**, 9/9 steps, ~20 min cached. Schedule `0 3 * * *` + `workflow_dispatch`.

---

## TL;DR — the 9-step story

```
1  fresh theia (+ submodules)
2  build runtime+services from manifest.services.services_rig  → debs        (bazel)
3  release those debs → S3 (MinIO)  theia-runtime/<ver>/
4  colony provision+orchestrate split_rig FROM S3              central = the singletons (com/per/sm/phm/vucm/…)
   (NO rebuild — just serialized manifests, arch/os per board)  compute = ucm + shwa
5  theia init --with-services in demo/   (the USER workspace)
6  build demo/dist                       central = services, compute = p1-p4 + shwa
7  release the demo USER APPS → S3 / .mender artifacts
8  colony orchestrate the demo apps over Mender OTA            central = services, compute = p1,p2,p3,p4,shwa
9  RF audit/consistency over the live composer's TIPC
```

---

## Strategy — why it's built this way

### 1. Build the platform ARTIFACT once; reuse manifests for placement

A board's runtime/services binaries are a function of **(arch, os, version)** — nothing
rig-specific. So:

- **Build once** (step 2) from `manifest.services.services_rig` (the full 16-FC set,
  arch-agnostic source) → versioned `.deb`s → **S3** (`theia-runtime/<ver>/`). One
  build per arch×os. **Never rebuilt because a rig's placement differs.**
- **Provision** (step 4) consumes `serialize-manifest manifest.services.split_rig`
  — pure manifest *data* (`machines.json` + per-machine slices), parametrized by
  `--arch`/`--os` per board. colony installs the **same S3 `.deb`s**, sliced per
  machine. This is identical whether the boards are rpi4+jetson or two
  docker-compose containers — **the only difference is the arch/os the manifest is
  serialized for.**

This keeps the three concerns cleanly separated, each at its proper cadence:

| Concern | Cadence | Source |
| --- | --- | --- |
| **Build** runtime+services | once / (arch, os, version) | `services_rig` → S3 |
| **Provision/orchestrate** | per deploy, no rebuild | serialized `split_rig` (--arch/--os) → S3 debs |
| **Day-2 user apps** | per app release/update | `demo/` (user ws) → S3 → Mender OTA |

> An earlier shortcut built everything from the demo's split rig in one `theia dist`.
> It worked but **rebuilt runtime+services per rig type** — wrong: the manifest
> defines placement, not content. The current split fixes that.

### 2. Per-machine `--arch` / `--os` — one rig, mixed fleet

`serialize-manifest --arch aarch64,aarch64 --os bookworm,focal` sets arch+os **per
machine** (sorted name order), so ONE `split_rig` serializes for a real
rpi4(bookworm)+jetson(focal) split — no duplicate per-arch rig file. The `os` lands
in `machine.json`, so colony derives the versioned runtime key `theia-runtime/<ver>-
<os>-<arch>` per board. (artheia commit: per-machine `--arch`/`--os`.)

### 3. Day-2 apps stay a separate, user-owned layer

Steps 5–8 run from `demo/` — the consuming workspace a real user owns. The user
defines their own services+apps split and their own **executor / supervision tree**.
The Mender OTA delivers the app *binaries* (flips `current → <app>-ver`); the
*supervision tree* is pushed by the orchestrate config step (the supervisor reads a
FIXED `/opt/theia/config/executor.json`, not one inside the release). So step 8 is
"OTA the binaries **+** orchestrate the user's executor.json" — two concerns by design.

### 4. Bridge networking — the real-board model, and CI-safe

The boards run on a **bridge network**, not host networking. This matters for both
fidelity and where it can run:

| | host net (rejected) | **bridge (chosen)** |
| --- | --- | --- |
| TIPC | 1 shared namespace (host+containers) | **separate per-board namespaces** |
| cross-board | automatic (same ns) | **real `tipc bearer enable media eth eth0`** over the bridge L2 — the rpi4↔jetson model |
| GUI gRPC | binds host :7700 (collides) | **mapped ports** 7700/7710/7711 |
| etcd | collides with host etcd | own netns, no collision |
| on a shared runner | collides with its services | **isolated — runs clean on dalek** |
| exercises the eth bearer | no | **yes** |

So the container test validates the genuine cross-namespace TIPC link (broadcast-link
up; compute sees central's `per_manager:0`, central sees compute's `ucm:1`), the
`machine_instance` 0/1 addressing, and the GUI gRPC surface — none of which the
host-net model exercised. See [Container TIPC](#how-containers-handle-tipc).

### 5. RF audit as the consistency gate (step 9)

After the composer is up, rf-theia's consistency engine runs: the artheia netgraph
is well-formed (system.art resolves), and **the live cluster nametable on central
shows compute's demo app (p1 counter :1) cross-board** — the deployed graph is
genuinely on the wire, over the real bearer, not just consistent on paper.

---

## Topology

```
  ┌─────────────┐   docker exec (ansible community.docker)   ┌──────────────┐
  │ controller  │ ─────────────────────────────────────────► │  central     │  inst 0
  │ colony +    │                                             │  systemd     │  services + etcd
  │ fleet.py +  │ ── fleet.py (Mender API) ──► mender-server  │  :7700 gRPC  │
  │ enroll-rig  │                              (joined to     └──────┬───────┘
  └─────┬───────┘                               the bridge)          │ TIPC eth bearer
        │ aws (S3 push)                                              (broadcast-link)
        ▼                                                            │
   ┌──────────┐  install-runtime-s3 ◄── boards pull by name   ┌──────┴───────┐
   │  minio   │  theia-runtime/<ver>/ + user-software/         │  compute     │  inst 1
   │  (S3)    │                                                │  p1-p4 +shwa │
   └──────────┘                                                └──────────────┘
        ▲  bridge: ota-e2e ; mender-server uses its OWN seaweedfs (internal)
```

- **MinIO** = the THEIA artifact S3 (runtime plane + app plane). Distinct from the
  Mender server's internal seaweedfs.
- **mender-server** = the OSS stack (ground-station `up.sh`), *trimmed* to ~1.4GB
  (gui/deviceconfig/deviceconnect/iot-manager + the 1.3GB qemu client dropped — none
  on the OTA path), joined to the `ota-e2e` bridge as `docker.mender.io`.
- Boards reached via the **docker connection** (ansible `community.docker.docker`,
  `docker exec`) — no sshd, no keys/ports.

---

## How containers handle TIPC

**TIPC lives in the network namespace.** On the bridge each board container has its
own netns → its own TIPC namespace (the rpi4/jetson model):

- the cross-board link is a real **eth bearer** (`tipc bearer enable media eth device
  eth0`) over the bridge L2, enabled on **both ends** by colony's `tipc-bearer.yml`
  (registries set `tipc_bearer: eth0`);
- **`machine_instance` separates the boards**: the supervisor injects `:instance`
  into every node's `--tipc` arg (central `per_manager=0x80010016:0`; compute
  `counter=0xd0010001:1`) — same type, different instance, no collision;
- the **TIPC kernel module must be loaded on the HOST/runner** (`sudo modprobe tipc`)
  — a privileged container can't load it. This is the one fragile runner dependency
  (see CI notes).

---

## CI setup (GitHub-hosted `ubuntu-latest`)

Both `colony` and `theia` are **public** → **unlimited Actions minutes**, so the cold
bazel build's wall-clock is free. The real constraints are the runner **disk (14GB)**
and the **job timeout (75 min)** — both handled.

The workflow steps, in order:

1. **Free disk** — drop ~25-30GB of pre-loaded toolchains (android/dotnet/ghc/boost).
2. **TIPC preflight** — `sudo modprobe tipc`; **fail LOUD** (`::error`) if the runner
   image ever drops `linux-modules-extra`. The error points to a self-hosted runner
   (dalek) as the fallback.
3. **Checkouts** — colony + theia (submodules) + ground-station, side by side.
4. **Python venv** — `pip install -e artheia/` + `-e .` + **`nanopb`** (the FC proto
   codegen the bazel build shells out to; not a declared dep).
5. **C++ deps** — `build-essential cmake … libnftables-dev` (idsm) + the 24.04 nanopb
   header symlink. `awscli` is NOT apt-installed (removed from 24.04; the runner ships
   aws v2).
6. **Bazelisk** — `ubuntu-latest` has no bazel.
7. **mender-artifact** — the host-side `.mender` packer (step 7).
8. **bazel cache** — `~/.cache/bazel` keyed on the BUILD files.
9. **Run** `test/ota-e2e/run-full-story.sh` (sources `theia/env.sh` so
   `theia`/`artheia`/`tdb` are on PATH).
10. **Upload logs** on failure.

### The runner-vs-builder gotchas (all build-host/OS-match issues)

The runner is **Ubuntu 24.04**; getting green meant matching the build host's
`(arch, os, version)` everywhere it leaks:

| Gotcha | Fix |
| --- | --- |
| `awscli` removed from 24.04 apt | drop it; runner ships aws v2 |
| board image ABI (24.04 host links `.so.32`, not 22.04's `.so.23`) | `Dockerfile.board` `ARG BASE`; `run-full-story.sh` sets `BOARD_BASE=ubuntu:<host VERSION_ID>`; use unversioned `-dev` packages |
| `nanopb_generator: command not found` | `pip install nanopb` into the venv |
| stale `theia-services_0.2.0` deb (6 FCs) picked by `find\|head -1` | pick the deb matching the current `_VERSION`; guard ≥10 FCs |
| deb `Depends: libgrpc++1` (22.04) vs board's `libgrpc++1.51t64` (24.04) | build with `--define distro=ubuntu24` on a 24.04 host |
| MinIO bucket private → 403 on the anonymous `install-runtime-s3` fetch | `push-runtime-s3.sh` sets the bucket public-read (matches dalek) |
| `mender-artifact` not on the runner | install the pinned deb (noble, jammy fallback) |

---

## Running it locally

Requires Docker (+ compose v2), the `theia`/`ground-station` repos as siblings of
`colony`, a Python venv at `theia/.venv`, bazel, and `tipc` loadable on the host.

```sh
cd colony/test/ota-e2e
./run-full-story.sh            # full 9 steps, teardown at the end
./run-full-story.sh --keep     # leave the stack up to inspect
```

Inspect the live composer: `127.0.0.1:7700` (com gRPC), or `tipc nametable show`
inside `ota-central` / `ota-compute`.

---

## Where it runs — and the fallback

- **GitHub-hosted `ubuntu-latest` is the nightly runner.** Proven green, free
  (public repos), self-contained. Schedule + manual dispatch.
- **dalek is the documented fallback.** The only fragile dependency is the `tipc`
  kernel module on the runner image. If a future image drops it, the preflight fails
  loud and points to a self-hosted runner — register dalek (it controls its kernel,
  has the bazel cache warm, and the bridge model means no host collisions).

---

## Related

- Compose + board/controller images + driver: `colony/test/ota-e2e/`
- The deploy-adapter contract this exercises: `colony` README + ansible playbooks.
- theia: `manifest.services.{services_rig,split_rig}`, `theia release`/`dist`,
  per-machine `serialize-manifest --arch/--os`, the `theia-release` Mender module.
- ground-station: `mender/server/up.sh`, `enroll-rig.sh`, `fleet.py`.
