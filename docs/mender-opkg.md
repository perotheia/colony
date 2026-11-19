# The Mender client on OPKG rigs (TI Arago)

TI Arago / Yocto images (e.g. SK-TDA4VM) have no apt and no Mender package. `colony provision` classifies such a
rig as `rig_class=opkg` (`ansible/tasks/rig-class.yml`) and installs OUR cross-built Mender client from the S3
runtime plane, so the rig becomes a real Mender device (enrols with the fleet server, takes theia OTA artifacts)
exactly like a debian rig. What an opkg rig still skips, by name in the play's last line: `os-packages (apt)`,
`etcd (apt package)`.

## The build

`mender-client-<version>.tar.gz`, built from `perotheia/mender` branch `arago-5.2` (upstream 5.2.0 + build files).
Current pin: `5.2.0-arago-aarch64`, sha256 `692bc586…ec8f1` (`ansible/inventory/hosts`:
`mender_client_opkg_version`, `mender_client_opkg_sha256`).

Contents: `usr/bin/mender-update`, `usr/bin/mender-auth`, the update modules `directory` + `single-file` (no
`rootfs-image`: theia does not use A/B), the systemd units, the D-Bus policy, the stock inventory + identity
scripts, and `usr/share/mender-client-arago/{MANIFEST.sha256,VERSION}`. It ships neither `mender.conf` nor
`artifact_info`.

## Publishing it to the plane

```sh
export THEIA_S3_ENDPOINT=http://<fleet host>:9000
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...     # or S3_ACCESS_KEY / S3_SECRET_KEY
tools/publish-mender-client.sh --dry-run <dir>/mender-client-5.2.0-arago-aarch64.tar.gz   # see what it would do
tools/publish-mender-client.sh <dir>/mender-client-5.2.0-arago-aarch64.tar.gz [<expected sha256>]
```

It writes

```
<bucket>/mender-client/<version>/mender-client-<version>.tar.gz
<bucket>/mender-client/<version>/index.json     {"plane","version","file": <key in bucket>,"sha256","size"}
```

(`<bucket>` = `$THEIA_S3_BUCKET`, default `theia-runtime`). It refuses when the tarball's sha256 differs from the
expected one (argument, else the `<tarball>.sha256` sidecar) or the tarball is not the Arago layout; uploads the
object first and the index last; reads both back anonymously and checks the hash. Credentials come from the
environment only and are never printed. A new build = publish under a new `<version>`, then change the two pins in
`inventory/hosts` in the same commit that is reviewed.

## What provision does on an opkg rig (`ansible/tasks/install-mender-opkg.yml`)

1. The CONTROLLER reads `index.json` over its own path to the plane; the index must name the PINNED sha256.
2. The RIG downloads the tarball over the gateway's TLS (`curl --cacert $THEIA_S3_RIG_CA` from
   `$THEIA_S3_RIG_ENDPOINT`, which must be `https://`) and checks the pinned sha256; a mismatch deletes the file and
   fails before anything is unpacked.
3. `tar -xzf … -C / --no-overwrite-dir`, then `sha256sum -c usr/share/mender-client-arago/MANIFEST.sha256` from `/`.
4. `/etc/mender` 0755, `/var/lib/mender` 0700, `/usr/share/mender/inventory` 0755; `mender-update --version`.
5. The SAME tasks as debian (`mender-client-common.yml`): device_type + artifact_info, the theia update modules
   (theia-swp/theia-app/theia-release, POSIX sh) in `/usr/share/mender/modules/v3`, the Mender→UCM state script,
   the SWP artifact-verify key (controller-fetched, pushed; no key = the provision fails).
6. A fail-closed `mender.conf` (ArtifactVerifyKey) when none exists; `mender-enroll.yml` then writes the server conf.
7. `systemctl daemon-reload`, `systemctl reload dbus` (dbus-broker re-reads the policy),
   `systemctl enable --now mender-authd mender-updated`.
8. A marker `usr/share/mender-client-arago/.colony-installed` = the pinned sha256. A re-run skips 2-3 and 7 while
   the marker matches and the installed files still match the MANIFEST (the identity script excepted: enrol
   replaces it with colony's `device_id=<rig name>`); a tampered file is re-fetched.

## Test without a board

```sh
test/opkg-mender/run.sh          # [--keep] leaves the containers + logs for debugging
```

Syntax-checks `provision.yml`, then runs the production tasks against a container that imitates Arago (no
apt-get/dpkg, an opkg stub, a systemctl stub that records its calls) with a plain-http fake plane staged by
`publish-mender-client.sh --stage`. Plain http is allowed there only through `mender_opkg_test_container=true`,
which also skips executing the aarch64 binaries; never set it for a real rig. Needs Docker and > 8 GB free memory;
removes everything it created.

What only a board proves: the binaries run on Arago (`mender-update --version`: glibc 2.39, libssl.so.3,
libdbus-1.so.3), `reload dbus` makes dbus-broker accept `io.mender.AuthenticationManager`, mender-authd +
mender-updated stay up under systemd, the TLS fetch through the gateway with the real CA, the rig checking in
PENDING with `device_id=<rig name>`, and a signed theia-swp deploy landing (an unsigned one refused).
