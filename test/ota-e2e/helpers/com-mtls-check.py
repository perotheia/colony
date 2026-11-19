#!/usr/bin/env python3
"""com-mtls-check.py — regression checks: com on a deployed rig serves MUTUAL TLS only.

Runs in the controller (on the ota-e2e bridge, grpcio + cryptography installed). Talks
to com's SupervisorView with a generic unary call, so no generated stubs are needed:
ListMachines takes an empty message and answers a MachineList.

  com-mtls-check.py --target central:7700 --ca ca.crt --cert operator.crt --key operator.key
                    [--address 172.x.y.z:7700]

Named checks (each prints PASS/FAIL; exit 1 when any fails):
  mtls_operator_list_machines   operator cert from the fleet CA, rig verified by its name -> ListMachines OK
  mtls_by_address_fleet_name    the same by ADDRESS, verifying the fleet name rig.fleet.theia -> OK
  plaintext_refused             a plaintext (insecure) channel -> refused
  tls_without_client_cert_refused   TLS, CA pinned, no client certificate -> refused
  foreign_ca_client_cert_refused    a self-signed client cert named fleet-gs (not from the fleet CA) -> refused
  wrong_rig_name_refused        operator cert, but the client expects another rig's name -> handshake fails

The positive check runs first (with retries: com's servers start a little after the
supervisor), so the refusals below are refusals by TLS, not an absent listener.
"""
from __future__ import annotations

import argparse
import datetime as dt
import sys
import time

import grpc

METHOD = "/services.com.SupervisorView/ListMachines"
RESULTS: list[tuple[str, bool, str]] = []


def _varint(b: bytes, i: int) -> tuple[int, int]:
    n = s = 0
    while True:
        c = b[i]; i += 1
        n |= (c & 0x7F) << s; s += 7
        if not c & 0x80:
            return n, i


def _fields(b: bytes):
    i = 0
    while i < len(b):
        tag, i = _varint(b, i)
        f, wt = tag >> 3, tag & 7
        if wt == 0:
            v, i = _varint(b, i)
        elif wt == 2:
            ln, i = _varint(b, i); v = b[i:i + ln]; i += ln
        elif wt == 5:
            v = b[i:i + 4]; i += 4
        elif wt == 1:
            v = b[i:i + 8]; i += 8
        else:
            raise ValueError(f"wire type {wt}")
        yield f, wt, v


def machines(raw: bytes) -> list[str]:
    """MachineList{ repeated MachineInfo machines = 1 }, MachineInfo{ name = 2, role = 5, present = 3 }."""
    out = []
    for f, wt, v in _fields(raw):
        if f == 1 and wt == 2:
            name = role = ""; present = False
            for g, wt2, w in _fields(v):
                if g == 2 and wt2 == 2: name = w.decode(errors="replace")
                elif g == 5 and wt2 == 2: role = w.decode(errors="replace")
                elif g == 3 and wt2 == 0: present = bool(w)
            out.append(f"{name}({role or '-'}{', present' if present else ''})")
    return out


def call(channel: grpc.Channel, timeout: float = 5.0) -> bytes:
    fn = channel.unary_unary(METHOD)   # no serializers: request/response are raw bytes
    return fn(b"", timeout=timeout)


def tls(target: str, ca: bytes, key: bytes | None = None, cert: bytes | None = None,
        name: str | None = None) -> grpc.Channel:
    creds = grpc.ssl_channel_credentials(root_certificates=ca, private_key=key, certificate_chain=cert)
    opts = [("grpc.ssl_target_name_override", name)] if name else []
    return grpc.secure_channel(target, creds, options=opts)


def record(name: str, ok: bool, detail: str) -> None:
    RESULTS.append((name, ok, detail))
    print(f"[mtls] {'PASS' if ok else 'FAIL'} {name}: {detail}", flush=True)


def expect_ok(name: str, mk, retries: int = 1) -> bool:
    last = ""
    for i in range(retries):
        ch = mk()
        try:
            ms = machines(call(ch))
            record(name, bool(ms), f"ListMachines -> {', '.join(ms) or 'EMPTY'}")
            return bool(ms)
        except grpc.RpcError as e:
            last = f"{e.code().name}: {e.details()}"
        finally:
            ch.close()
        if i + 1 < retries:
            time.sleep(3)
    record(name, False, f"ListMachines failed: {last}")
    return False


def expect_refused(name: str, mk) -> None:
    ch = mk()
    try:
        ms = machines(call(ch))
        record(name, False, f"ACCEPTED (ListMachines -> {', '.join(ms) or 'EMPTY'}) — com must refuse this client")
    except grpc.RpcError as e:
        record(name, True, f"refused ({e.code().name}: {(e.details() or '').splitlines()[0][:120]})")
    finally:
        ch.close()


def self_signed(cn: str) -> tuple[bytes, bytes]:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
    k = ec.generate_private_key(ec.SECP256R1())
    n = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn),
                   x509.NameAttribute(NameOID.ORGANIZATION_NAME, "perotheia fleet"),
                   x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, "gs")])
    now = dt.datetime.now(dt.timezone.utc)
    c = (x509.CertificateBuilder().subject_name(n).issuer_name(n).public_key(k.public_key())
         .serial_number(x509.random_serial_number()).not_valid_before(now - dt.timedelta(minutes=5))
         .not_valid_after(now + dt.timedelta(days=1))
         .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH]), critical=False)
         .add_extension(x509.SubjectAlternativeName([x509.UniformResourceIdentifier(f"theia:gs:{cn}"),
                                                     x509.DNSName(cn)]), critical=False)
         .sign(k, hashes.SHA256()))
    return (k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption()),
            c.public_bytes(serialization.Encoding.PEM))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True, help="the rig by NAME, e.g. central:7700")
    ap.add_argument("--address", default="", help="the rig by ADDRESS, e.g. 172.18.0.3:7700 (optional)")
    ap.add_argument("--ca", required=True)
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--fleet-name", default="rig.fleet.theia")
    ap.add_argument("--retries", type=int, default=20)
    a = ap.parse_args()
    ca, cert, key = (open(p, "rb").read() for p in (a.ca, a.cert, a.key))

    up = expect_ok("mtls_operator_list_machines", lambda: tls(a.target, ca, key, cert), retries=a.retries)
    if not up:
        print("[mtls] com did not answer a valid mutual-TLS client — the refusal checks would prove nothing",
              file=sys.stderr)
        return 1
    if a.address:
        expect_ok("mtls_by_address_fleet_name", lambda: tls(a.address, ca, key, cert, name=a.fleet_name))
    expect_refused("plaintext_refused", lambda: grpc.insecure_channel(a.target))
    expect_refused("tls_without_client_cert_refused", lambda: tls(a.target, ca))
    fk, fc = self_signed("fleet-gs")
    expect_refused("foreign_ca_client_cert_refused", lambda: tls(a.target, ca, fk, fc))
    expect_refused("wrong_rig_name_refused", lambda: tls(a.target, ca, key, cert, name="not-this-rig"))

    bad = [n for n, ok, _ in RESULTS if not ok]
    print(f"[mtls] {len(RESULTS) - len(bad)}/{len(RESULTS)} checks passed" + (f"; FAILED: {', '.join(bad)}" if bad else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
