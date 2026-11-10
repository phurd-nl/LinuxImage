#!/usr/bin/env python3
"""Save this laptop's install password. The password is never printed."""
from __future__ import annotations

import os
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

IMAGING = os.environ.get("IMAGING_KIOSK", "http://192.168.26.106:8091").rstrip("/")
STATE = Path(os.environ.get("LINUX_ENCRYPTION_STATE", "/var/lib/linux-encryption-setup"))


def local_macs() -> list[str]:
    root = Path("/sys/class/net")
    found = []
    if not root.is_dir():
        return found
    for nic in sorted(root.iterdir()):
        if nic.name == "lo":
            continue
        try:
            mac = (nic / "address").read_text().strip().lower()
        except OSError:
            continue
        if mac and mac != "00:00:00:00:00:00":
            found.append(mac)
    return found


def main() -> int:
    dest = STATE / "install-password"
    if dest.is_file() and dest.stat().st_size > 0:
        return 0
    for mac in local_macs():
        url = f"{IMAGING}/api/install-password?{urllib.parse.urlencode({'mac': mac})}"
        try:
            with urllib.request.urlopen(url, timeout=10) as response:
                data = response.read()
        except (OSError, urllib.error.URLError):
            continue
        if not data.strip():
            continue
        STATE.mkdir(parents=True, exist_ok=True)
        os.chmod(STATE, 0o700)
        tmp = dest.with_suffix(".tmp")
        if not data.endswith(b"\n"):
            data += b"\n"
        tmp.write_bytes(data)
        os.chmod(tmp, 0o400)
        tmp.replace(dest)
        os.chmod(dest, 0o400)
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
