# Fleet VPN: Tailscale tailnet, tags, and rig enrollment

The fleet runs on its **own tailnet**, separate from the developers' tailnet: the ground station /
provisioning server and every rig join it, nothing else needs to. Access is governed by **tags**,
not by user accounts: a device's tag is fixed by the pre-authorised auth key it joined with.

| Tag | Who | May reach |
| --- | --- | --- |
| `tag:fleet-gs` | ground station + provisioning server (colony, Mender GW, S3 behind the GW) | rigs: `tcp:22` (Ansible), `tcp:7700` (com gRPC) |
| `tag:fleet-rig` | every rig (BeagleBone AI-64, SK-TDA4VM, ...) | the GS only, `tcp:443` (Mender + the S3 plane over TLS); **never another rig**, never the GS's ssh / web / plain S3 |
| tailnet members | operators' machines | their own devices; the GS on `tcp:22,443,8088`; rigs on `tcp:22` only |

MAVLink (`udp:14550-14560`) is not granted until its trust-boundary design exists (perotheia-hardening C5).

The policy is versioned here: [`tailscale-fleet-policy.hujson`](tailscale-fleet-policy.hujson). Both tags are
owned by `autogroup:admin` (`tagOwners`), so only tailnet admins (and API tokens they create) can mint
keys that carry them. The policy's `tests` block is checked by Tailscale on every save.

Apply or update it with the API token (see below):

    T=$(cat ~/.config/colony-fleet/ts_api_token)
    curl -u "$T:" -X POST -H 'Content-Type: application/hujson' \
         --data-binary @docs/tailscale-fleet-policy.hujson https://api.tailscale.com/api/v2/tailnet/-/acl/validate   # {} = valid
    curl -u "$T:" -X POST -H 'Content-Type: application/hujson' \
         --data-binary @docs/tailscale-fleet-policy.hujson https://api.tailscale.com/api/v2/tailnet/-/acl

## The API token (TS_API_TOKEN)

ground-station's `enroll/tailscale_client.py` mints per-rig auth keys through the Tailscale API.
Create the token in the fleet tailnet's admin console, **Settings > Keys > Generate access token**
(max 90 days), and store it **only on the provisioning server**, mode 600:

    ~/.config/colony-fleet/ts_api_token

Never in git, the bundle, or a chat. Renew before it expires (the console shows the date).

## Enrollment flow (day 0)

1. **Mint** a per-rig key on the provisioning server: single-use, pre-authorised, tagged, short-lived:

       TS_API_TOKEN=$(cat ~/.config/colony-fleet/ts_api_token) python3 -c "
       import tailscale_client as t
       print(t.TailscaleClient().create_authkey(reusable=False, preauthorized=True,
             tags=['tag:fleet-rig'], expiry_seconds=3600, description='rig-enroll <machine>'))"

   `rig_enroll.py` does this for you when it provisions a rig over com gRPC.
2. **Deliver** it to the rig at `/etc/theia/manifest/<machine>/certs/vpn.authkey` (mode 600): through
   com's `Provision()` (`rig_enroll.py`), or out-of-band (scp) for a rig without com yet.
3. **Join**: colony's `ansible/tasks/install-tailscale.yml` (included by `colony provision` when the GS passes
   `vpn_authkey` or `vpn_join=true`; before branch fleet-design NO playbook included it) installs
   Tailscale and runs `tailscale up --auth-key file:<key file> --hostname <machine> --accept-routes=false --accept-dns=false`.
   It skips `up` when the rig is already Running (idempotent) and when no key is present yet.

The ground station itself joins the same way with a `tag:fleet-gs` key.

### Rigs without apt (TI Arago / Yocto)

Tailscale's `install.sh` only supports distributions with a package repo. On rigs without
`/usr/bin/apt-get` the task installs Tailscale's official **static build**, pinned by
`tailscale_version` (default `1.104.4`): `tailscaled` + `tailscale` + its systemd unit and defaults,
then enables `tailscaled`. Verified on the SK-TDA4VM (TI PSDK 11.02.02.05 Arago, systemd 255, aarch64).

### Internet for rigs

A rig must reach `login.tailscale.com` (and, for apt rigs, `pkgs.tailscale.com`). On a bench switch
without its own uplink give the rigs a gateway (NAT through the bench host) and DNS. Prefer IPv4 when
the network has no IPv6 route (`curl -4`).

## Verified (2026-11-19, bench: panzer + AI-64 + SK)

| Device | Tag | Path |
| --- | --- | --- |
| panzer (GS / provisioning) | `tag:fleet-gs` | `tailscale up --authkey` with a GS key |
| ai64-proto (BeagleBone AI-64, Debian 13.5) | `tag:fleet-rig` | colony task, apt path; re-run = no change |
| sk-tda4vm (SK-TDA4VM, TI Arago 11.02) | `tag:fleet-rig` | colony task, static path |

Policy behaviour: GS -> rig :22 open; rig -> rig :22 blocked; rig -> GS :22 blocked; rig -> GS :443 reachable.

## Known issues / follow-ups

- `tailscale_client.create_authkey()` defaults to `reusable=True` with a 90-day expiry: a leaked per-rig
  key could enroll any number of devices for three months. Per-rig keys should default to single-use,
  short-lived (callers in this doc pass them explicitly).
- The apt path pipes the unpinned `install.sh` into `sh`; the static path is pinned. Consider pinning the
  apt path to a version too.
- `rig_enroll.py` needs com gRPC on the rig; rigs without the Theia runtime yet use the out-of-band path.
