# A container that imitates a TI Arago (opkg) rig ENOUGH for install-mender-opkg.yml: no apt-get / dpkg, an opkg
# stub, a systemctl stub that records its calls, and what the play needs on a real Arago image (python3 for the
# ansible modules, curl, sha256sum, GNU tar, openssl). Not systemd: the stub stands in for it. Also serves as the fake S3
# plane (python3 -m http.server) in run.sh.
FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 curl ca-certificates openssl \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /usr/bin/apt /usr/bin/apt-get /usr/bin/apt-cache /usr/bin/apt-config /usr/bin/apt-mark /usr/bin/dpkg
COPY stubs/opkg stubs/systemctl /usr/bin/
CMD ["sleep", "infinity"]
