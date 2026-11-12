#!/usr/bin/env python3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import json
import tempfile
from ubuntu_apps import apps_from_file, decision_queries, image_plan, plan, serials_from


def main() -> None:
    body = plan(["chrome", "firefox", "putty", "unifi-vpn", "winscp", "nope"])
    assert body["apt"] == ["firefox", "putty-tools"], body
    assert body["debs"] == [
        {"id": "chrome", "url": "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"}
    ]
    skipped = {row["id"] for row in body["skipped"]}
    assert skipped == {"unifi-vpn", "winscp", "nope"}, skipped
    always = image_plan([])
    assert always["debs"][0]["id"] == "chrome"
    earth = plan(["earth-pro"])
    assert earth["debs"][0]["id"] == "earth-pro"
    tools = plan(["angry-ip", "winbox", "dude"])
    assert {row["id"] for row in tools["debs"]} == {"angry-ip", "winbox"}
    assert "zenmap" in tools["apt"]
    with tempfile.TemporaryDirectory() as tmp:
        path = f"{tmp}/saved.json"
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"apps": ["putty", "wireshark"]}, handle)
        assert apps_from_file(path) == ["putty", "wireshark"]
    assert serials_from("Default string", "quiet kiosk.serial=J0DTRV3 ---") == ["J0DTRV3"]
    assert serials_from("J0DTRV3", "kiosk.serial=J0DTRV3") == ["J0DTRV3"]
    assert serials_from(None, "") == []
    queries = decision_queries(["4C:EA:41:69:4B:F4", "00:00:00:00:00:00"], ["J0DTRV3"])
    assert queries == ["mac=4c:ea:41:69:4b:f4", "serial=J0DTRV3"], queries
    late = Path(__file__).resolve().parents[1] / "imaging" / "late-install-linux-encryption.sh"
    text = late.read_text()
    # Entra setup and the report run in the background (Type=simple) and retry on failure;
    # a oneshot in multi-user.target held the boot and starved AteraAgent (11 Nov).
    assert "TimeoutStartSec=0" not in text
    assert text.count("Type=simple") >= 2
    assert text.count("Restart=on-failure") >= 2
    assert "Before=display-manager" not in text
    assert "gdm.service.d/wait-for-entra.conf << " not in text
    assert "journal+console" in text
    # GNOME Shell 50 is Wayland-only, and modeset=0 drops acceleration.
    assert "sed -i '/^\\[daemon\\]/a WaylandEnable=false'" not in text
    assert "i915.enable_psr=0" in text
    assert "for flag in i915.enable_psr=0; do" in text
    assert "99-nextlink-panel.cfg" in text
    # snap install fails with "device not yet seeded" before snapd.seeded.
    assert "After=snapd.seeded.service" in text
    # The old home-encryption wizard is not installed on the TPM-FDE image (review M6).
    assert "install-setup-wizard.sh" not in text
    assert "webgui" not in text
    assert 'for extra in ubuntu_apps.py ubuntu-desktop.sh ubuntu_desktop.py install-windows-agents.sh' in text
    assert 'if [ ! -f "$INSTALL_ROOT/scripts/$extra" ]' not in text
    agents = Path(__file__).with_name("install-windows-agents.sh").read_text()
    assert "kiosk.serial=" in agents
    assert "--data-urlencode" in agents
    print("ok")


if __name__ == "__main__":
    main()
