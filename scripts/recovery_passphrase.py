#!/usr/bin/env python3
"""Move this laptop's recovery phrase to the imaging host.

The phrase is unique per laptop. The host files it and mails a NextPass
link. This script never prints the phrase.
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

IMAGING = os.environ.get("IMAGING_KIOSK", "http://192.168.26.106:8091").rstrip("/")
STATE = Path(os.environ.get("LINUX_ENCRYPTION_STATE", "/var/lib/linux-encryption-setup"))
_PHRASE = re.compile(r"^[A-Za-z0-9_-]{43,128}$")


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


def read_phrase(path: Path) -> str:
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return ""
    for line in lines:
        line = line.strip()
        if line and not line.startswith("#") and _PHRASE.fullmatch(line):
            return line
    return ""


def write_phrase(state: Path, phrase: str) -> None:
    state.mkdir(parents=True, exist_ok=True)
    os.chmod(state, 0o700)
    path = state / "recovery-passphrase"
    tmp = path.with_suffix(".tmp")
    tmp.write_text(
        "# LUKS recovery passphrase\n"
        "# Filed with the imaging host. Removed after the keyslot is added.\n"
        f"{phrase}\n"
    )
    os.chmod(tmp, 0o400)
    tmp.replace(path)
    os.chmod(path, 0o400)
    marker = state / "recovery-filed"
    marker.write_text("host\n")
    os.chmod(marker, 0o600)


def _http_get(mac: str) -> str:
    url = f"{IMAGING}/api/recovery?{urllib.parse.urlencode({'mac': mac})}"
    request = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.read().decode()


def _http_post(mac: str, phrase: str) -> bool:
    payload = json.dumps({"mac": mac, "passphrase": phrase}).encode()
    request = urllib.request.Request(
        f"{IMAGING}/api/recovery",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        body = json.loads(response.read().decode())
    return isinstance(body, dict) and body.get("ok") is True


def pull(state: Path, macs: list[str] | None = None, get=None) -> bool:
    getter = get or _http_get
    for mac in local_macs() if macs is None else macs:
        try:
            phrase = getter(mac).strip()
        except (OSError, urllib.error.URLError, TimeoutError):
            continue
        if _PHRASE.fullmatch(phrase):
            write_phrase(state, phrase)
            return True
    return False


def push_phrase(phrase: str, macs: list[str] | None = None, post=None) -> bool:
    if not _PHRASE.fullmatch(phrase):
        return False
    sender = post or _http_post
    for mac in local_macs() if macs is None else macs:
        try:
            if sender(mac, phrase):
                return True
        except (OSError, urllib.error.URLError, TimeoutError, json.JSONDecodeError):
            continue
    return False


def main(argv: list[str]) -> int:
    if "--pull" in argv:
        if pull(STATE):
            print("recovery phrase filed from the imaging host")
            return 0
        print("WARN: imaging host has no recovery phrase for this laptop")
        return 1
    if "--push" in argv:
        phrase = read_phrase(STATE / "recovery-passphrase")
        if phrase and push_phrase(phrase):
            write_phrase(STATE, phrase)
            print("recovery phrase filed on the imaging host")
            return 0
        print("WARN: recovery phrase stayed on this laptop")
        return 1
    print("usage: recovery_passphrase.py --pull|--push")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
