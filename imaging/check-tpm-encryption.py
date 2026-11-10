#!/usr/bin/env python3
"""Stop the Ubuntu install early when TPM-backed disk encryption is not available.

Runs as an autoinstall early-command. Asks snapd (running in the live installer)
what the installer will see. Without this, the installer treats "encrypted" as a
preference and quietly installs an unencrypted laptop.

Exit 0: encryption available. Exit 1: not available; the reason is printed on the
console. Any other problem (snapd not answering) exits 0 and lets the installer decide.
"""
import json
import socket
import sys

SYSTEM = "enhanced-secureboot-desktop"  # the 26.04 desktop ISO's TPM-backed install system


def snapd_get(path: str, sock_path: str = "/run/snapd.socket") -> dict:
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(60)
        sock.connect(sock_path)
        sock.sendall(f"GET {path} HTTP/1.0\r\nHost: snapd\r\n\r\n".encode())
        data = b""
        while chunk := sock.recv(65536):
            data += chunk
    return json.loads(data.split(b"\r\n\r\n", 1)[1])


def verdict(details: dict) -> tuple[bool, str]:
    enc = (details.get("result") or {}).get("storage-encryption") or {}
    if enc.get("support") == "unavailable":
        return False, str(enc.get("unavailable-reason") or "no reason given")
    return True, str(enc.get("support") or "unknown")


def main() -> int:
    try:
        ok, why = verdict(snapd_get(f"/v2/systems/{SYSTEM}"))
    except Exception as exc:  # cannot tell; do not block the install on our own check
        print(f"TPM encryption check skipped: {exc}")
        return 0
    if ok:
        print(f"TPM-backed disk encryption: {why}")
        return 0
    message = (
        "\n*** Nextlink imaging stopped: this laptop cannot use TPM disk encryption. ***\n"
        f"Reason: {why}\n"
        "Fix: in the BIOS, clear the TPM (Dell: Security > TPM 2.0 Security > Clear;\n"
        "Lenovo: Security > Security Chip > Clear), keep Secure Boot on, then image again.\n"
    )
    print(message)
    try:
        with open("/dev/console", "w") as console:
            console.write(message)
    except OSError:
        pass
    return 1


if __name__ == "__main__":
    sys.exit(main())
