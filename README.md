# colony — Theia device fleet & deployment

The **deployment adapter** for a Theia fleet: agentless (Ansible SSH-push)
provisioning + orchestration of rigs from a per-rig bundle the `theia` build emits.

Split out of `theia` by design: deployment tooling is a **swappable adapter**, not
part of the on-device product. `theia`'s responsibility ends at producing the
bundle at a known place; **colony picks it up and drives the rig.** A different
shop can swap colony for Puppet/Salt/Flux behind the SAME bundle contract — the
core never changes.

## The contract (theia emits → colony consumes)

Rooted at `$THEIA_WORKSPACE` (the workspace `theia dist` writes into):

```
dist/manifest/<machine>/          the per-rig bundle (PACKAGES — theia owns)
  ├── executor.json + *.json       supervisor tree + manifest slices
  ├── config/<fc>.json             per-FC config (already merged)
  ├── <machine>.deb                the theia-release runtime/services .deb(s)
  └── certs/                       mTLS material
deploy/registry/<target>.yml       WHICH host: ansible_host + machine slice (DEVICES — operator data)
deploy/config/<target>/            per-target config overrides, deep-merged on top
```

The seam is this filesystem bundle — **not** a code dependency on theia. colony
never imports or builds theia.

## Verbs

```bash
colony provision   <target> [ansible-args]   # OS packages + etcd + mender client
colony orchestrate <target> [ansible-args]   # push the bundle: .deb + executor.json + config
colony cleanup     <target> [ansible-args]   # uninstall (inverse); -e wipe_etcd/wipe_mender=true
```

`<target>` names a rig in `deploy/registry/<target>.yml`. `$THEIA_WORKSPACE` roots
the bundle + registry (defaults to CWD); `$COLONY_ANSIBLE` overrides the playbook
dir (defaults to `ansible/`). The on-device deploy artifacts colony installs (the
`theia-release` Mender update module + the Mender→UCM state-scripts) ship in
theia's runtime `.deb` — colony places them, it does not contain them.

## Layout

| Path | What |
| --- | --- |
| `bin/colony` | the CLI (relocated from theia.py's provision/orchestrate/cleanup verbs) |
| `ansible/provision.yml` | phase 1 — OS pkgs + etcd + mender client (from machine.json) |
| `ansible/orchestrate.yml` | phase 2 — push the bundle (.deb + executor.json + per-FC config) |
| `ansible/cleanup.yml` | uninstall any prior Theia from a rig |
| `ansible/tasks/` | the shared includes (install-bundle, setcap, seed-config, config-override, etcd, mender, tailscale, supervisor-unit) |
| `ansible/templates/theia-supervisor.service.j2` | the systemd unit (ExecStart=theia-run, OTA-correct) |
| `ansible/inventory/hosts` | resolves manifest_dir/registry_dir/config_override_dir from `$THEIA_WORKSPACE` |

The fleet **operations & monitoring** side (Mender GW + operator UX + enrollment)
lives in the sibling **`ground-station`** repo. See theia
`docs/tasks/BACKLOG/repo-separation.md`.
