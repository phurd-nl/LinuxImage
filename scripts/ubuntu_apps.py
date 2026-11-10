#!/usr/bin/env python3
"""Install the kiosk's checked apps on Ubuntu.

Windows-only tools are skipped and written to the log. A failure of one
package does not hide the others.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import urllib.parse
import urllib.request

HOST = "http://192.168.26.106:8091"
# Read by imaging-firstboot.sh for the NextDesk report.
RESULT = pathlib.Path("/var/lib/linux-encryption-setup/apps-result.json")
# Apt names in Ubuntu 26.04. Chrome is a deb because it is not in the archive.
APT = {
    "firefox": ["firefox"],
    "keepass": ["keepassxc"],
    "putty": ["putty-tools"],
    "wireshark": ["wireshark"],
    "dude": ["zenmap"],
}
DEB = {
    "chrome": "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb",
    "earth-pro": "https://dl.google.com/dl/earth/client/current/google-earth-pro-stable_current_amd64.deb",
    "angry-ip": "https://github.com/angryip/ipscan/releases/download/3.12.1/ipscan_3.12.1_amd64.deb",
}
ZIP = {
    "winbox": "https://download.mikrotik.com/routeros/winbox/4.5/WinBox_Linux.zip",
}
SKIP = {
    "unifi-vpn": "included in the UniFi Endpoint package",
    "nextdesk-endpoint": "no Ubuntu package yet",
    "atera": "installed by the Linux agent step",
    "wazuh": "installed by the Linux agent step",
    "unifi-identity": "included in the UniFi Endpoint package",
    "winscp": "no Linux version; FileZilla is installed instead",
    "mobaxterm": "no Linux version; Remmina is installed instead",
    "ubuntu-wsl": "this machine is already Ubuntu",
    "unifi-wifiman": "installed at a user sign-in on Windows",
}


def image_plan(selected: list[str]) -> dict:
    """Chrome is always installed. Teams and Outlook open in it."""
    ids = ["chrome"]
    ids.extend(selected or [])
    return plan(ids)


def plan(selected: list[str]) -> dict:
    apt: list[str] = []
    debs: list[dict] = []
    skipped: list[dict] = []
    seen: set[str] = set()
    for raw in selected or []:
        if not isinstance(raw, str):
            continue
        ident = raw.strip()
        if not ident or ident in seen:
            continue
        seen.add(ident)
        if ident in SKIP:
            skipped.append({"id": ident, "reason": SKIP[ident]})
        elif ident in DEB:
            debs.append({"id": ident, "url": DEB[ident]})
        elif ident in ZIP:
            debs.append({"id": ident, "url": ZIP[ident], "kind": "zip"})
        elif ident in APT:
            apt.extend(APT[ident])
        else:
            skipped.append({"id": ident, "reason": "no Ubuntu package"})
    return {"apt": apt, "debs": debs, "skipped": skipped}


def _install_winbox(url: str) -> int:
    import pathlib
    import tempfile
    dest = pathlib.Path("/usr/local/bin/winbox")
    with tempfile.TemporaryDirectory() as tmp:
        archive = pathlib.Path(tmp) / "winbox.zip"
        fetch = subprocess.run(["curl", "-fL", "--retry", "3", "-o", str(archive), url], check=False)
        if fetch.returncode != 0:
            return fetch.returncode
        unpacked = subprocess.run(["unzip", "-o", str(archive), "-d", tmp], check=False)
        if unpacked.returncode != 0:
            return unpacked.returncode
        files = [path for path in pathlib.Path(tmp).rglob("*") if path.is_file() and path.suffix.lower() not in {".zip", ".txt", ".md"}]
        named = [path for path in files if "winbox" in path.name.lower()]
        binary = named[0] if named else (max(files, key=lambda path: path.stat().st_size) if files else None)
        if binary is None:
            return 1
        dest.write_bytes(binary.read_bytes())
        dest.chmod(0o755)
    desktop = pathlib.Path("/usr/share/applications/winbox.desktop")
    desktop.write_text(
        "[Desktop Entry]\nName=WinBox\nExec=/usr/local/bin/winbox\n"
        "Terminal=false\nType=Application\nCategories=Network;\n"
    )
    return 0


_PLACEHOLDER_SERIALS = {
    "",
    "none",
    "default string",
    "to be filled by o.e.m.",
    "system serial number",
    "not specified",
    "0",
}


def serials_from(dmi: str | None, cmdline: str) -> list[str]:
    """BIOS serial, then the serial the imaging boot line recorded."""
    found: list[str] = []

    def add(value: str) -> None:
        text = (value or "").strip().strip("\x00")
        if not text or text.lower() in _PLACEHOLDER_SERIALS or text in found:
            return
        found.append(text)

    if dmi is not None:
        add(dmi)
    for token in (cmdline or "").split():
        if token.startswith("kiosk.serial="):
            add(token.split("=", 1)[1])
    return found


def decision_queries(macs: list[str], serials: list[str]) -> list[str]:
    """Ask by each NIC, then by serial. The imaging cable is not the laptop."""
    out: list[str] = []
    seen: set[str] = set()
    for mac in macs or []:
        text = (mac or "").strip().lower()
        if not text or text == "00:00:00:00:00:00" or text in seen:
            continue
        seen.add(text)
        out.append(f"mac={text}")
    for serial in serials or []:
        text = (serial or "").strip()
        key = f"serial:{text.lower()}"
        if not text or text.lower() in _PLACEHOLDER_SERIALS or key in seen:
            continue
        seen.add(key)
        out.append("serial=" + urllib.parse.quote(text))
    return out


def _decision_from_host() -> dict | None:
    for query in decision_queries(_macs(), _serials()):
        url = f"{HOST}/api/decision?{query}"
        try:
            with urllib.request.urlopen(url, timeout=12) as response:
                payload = json.load(response)
        except Exception:
            continue
        if payload.get("ready") and isinstance(payload.get("apps"), list):
            return payload
    return None


def save_selection(path: str) -> bool:
    """Write the list only after the imaging host answers. A miss leaves no file."""
    import pathlib
    payload = _decision_from_host()
    if payload is None:
        return False
    employee = payload.get("employee") if isinstance(payload.get("employee"), str) else ""
    pathlib.Path(path).write_text(json.dumps({
        "apps": [str(item) for item in payload["apps"]],
        "employee": employee.strip(),
    }))
    return True


def apps_from_file(path: str) -> list[str]:
    import pathlib
    payload = json.loads(pathlib.Path(path).read_text())
    return [str(item) for item in payload.get("apps") or [] if isinstance(item, str)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ids", default="")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--save", default="")
    parser.add_argument("--from-file", default="")
    args = parser.parse_args()
    if args.save:
        return 0 if save_selection(args.save) else 1
    selected = [part for part in args.ids.split(",") if part]
    if args.from_file:
        selected = apps_from_file(args.from_file)
    elif args.apply and not selected:
        selected = _selected_from_host()
    body = image_plan(selected) if args.apply or args.from_file else plan(selected)
    print(json.dumps(body))
    if not args.apply:
        return 0
    failed = []
    if body["apt"]:
        run = subprocess.run(
            ["apt-get", "install", "-y", *body["apt"]],
            check=False,
        )
        if run.returncode != 0:
            failed.extend(body["apt"])
    for deb in body["debs"]:
        if deb.get("kind") == "zip":
            if _install_winbox(deb["url"]) != 0:
                failed.append(deb["id"])
            continue
        path = f"/tmp/{deb['id']}.deb"
        fetch = subprocess.run(["curl", "-fL", "--retry", "3", "-o", path, deb["url"]], check=False)
        if fetch.returncode != 0:
            failed.append(deb["id"])
            continue
        inst = subprocess.run(["apt-get", "install", "-y", path], check=False)
        if inst.returncode != 0:
            failed.append(deb["id"])
    wanted = list(body["apt"]) + [deb["id"] for deb in body["debs"]]
    try:
        RESULT.parent.mkdir(parents=True, exist_ok=True)
        RESULT.write_text(json.dumps({"ok": [a for a in wanted if a not in failed], "failed": failed}))
    except OSError:
        pass
    if failed:
        print("FAILED " + ",".join(failed))
        return 1
    return 0


def _selected_from_host() -> list[str] | None:
    payload = _decision_from_host()
    if payload is None:
        return None
    return [str(item) for item in payload["apps"]]


def _serials() -> list[str]:
    import pathlib

    dmi = None
    path = pathlib.Path("/sys/class/dmi/id/product_serial")
    if path.is_file():
        try:
            dmi = path.read_text(errors="replace")
        except OSError:
            dmi = None
    cmdline = ""
    cmd = pathlib.Path("/proc/cmdline")
    if cmd.is_file():
        try:
            cmdline = cmd.read_text(errors="replace")
        except OSError:
            cmdline = ""
    return serials_from(dmi, cmdline)


def _macs() -> list[str]:
    import pathlib

    found = []
    net = pathlib.Path("/sys/class/net")
    if not net.is_dir():
        return found
    for iface in sorted(net.iterdir()):
        if iface.name == "lo":
            continue
        addr = iface / "address"
        if not addr.is_file():
            continue
        mac = addr.read_text().strip().lower()
        if mac and mac != "00:00:00:00:00:00":
            found.append(mac)
    return found


if __name__ == "__main__":
    raise SystemExit(main())
