#!/usr/bin/env python3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ubuntu_desktop import (
    OUTLOOK_ICON,
    OUTLOOK_URL,
    TEAMS_ICON,
    TEAMS_URL,
    chrome_initial_preferences,
    chrome_managed_policy,
    desktop_file,
    dock_defaults,
    login_banner,
    onedrive_config,
    session_defaults,
    skip_new_laptop_questions,
    update_policy,
)


def main() -> None:
    dock = dock_defaults()
    assert "dock-position='BOTTOM'" in dock
    assert "extend-height=false" in dock
    assert "google-chrome.desktop" in dock
    assert "teams-pwa.desktop" in dock
    assert "outlook-pwa.desktop" in dock
    assert "org.gnome.Nautilus.desktop" in dock
    session = session_defaults()
    assert "report-technical-problems=false" in session
    assert "enabled=false" in session
    teams = desktop_file("Microsoft Teams", TEAMS_URL, "teams-pwa", TEAMS_ICON)
    outlook = desktop_file("Outlook", OUTLOOK_URL, "outlook-pwa", OUTLOOK_ICON)
    assert f"--app={TEAMS_URL}" in teams
    assert f"--app={OUTLOOK_URL}" in outlook
    assert "--no-first-run" in teams
    assert f"Icon={TEAMS_ICON}" in teams
    assert f"Icon={OUTLOOK_ICON}" in outlook
    prefs = chrome_initial_preferences()
    assert "skip_first_run_ui" in prefs
    policy = chrome_managed_policy()
    assert "PromotionalTabsEnabled" in policy
    shell = Path(__file__).with_name("ubuntu-desktop.sh").read_text()
    assert "onedrive.service" in shell
    assert "symlink_to" not in shell
    assert "skip_new_laptop_questions" in shell
    assert "extras/icons" in shell
    assert "teams-pwa" in shell
    import os
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        autostart = root / "home" / "nextadmin" / ".config" / "autostart"
        autostart.mkdir(parents=True)
        (autostart / "gnome-initial-setup-first-login.desktop").write_text("Exec=gnome-initial-setup\n")
        skip_new_laptop_questions(root)
        assert (root / "etc/skel/.config/gnome-initial-setup-done").is_file()
        assert (root / "home/nextadmin/.config/gnome-initial-setup-done").is_file()
        assert not (autostart / "gnome-initial-setup-first-login.desktop").exists()
        link = root / "etc/systemd/user/gnome-initial-setup-first-login.service"
        assert link.is_symlink()
        assert os.readlink(link) == "/dev/null"
        # GDM still launches Initial Setup when no user is visible. Masked, it fails and the panel stays blank.
        gdm = (root / "etc/gdm3/custom.conf").read_text()
        assert "[daemon]\nInitialSetupEnable=false\n" in gdm
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "etc/gdm3").mkdir(parents=True)
        (root / "etc/gdm3/custom.conf").write_text("[daemon]\nAutomaticLoginEnable=false\nInitialSetupEnable=true\n\n[security]\n")
        skip_new_laptop_questions(root)
        gdm = (root / "etc/gdm3/custom.conf").read_text()
        assert gdm == "[daemon]\nAutomaticLoginEnable=false\nInitialSetupEnable=false\n\n[security]\n"
    config = onedrive_config()
    assert 'application_id = "ab87c385-2754-4f2e-980b-2384d0fdc9d1"' in config
    assert 'azure_tenant_id = "143673a5-ff46-4d23-8255-b4ef07861814"' in config
    assert 'sync_dir = "~/OneDrive"' in config
    assert "secret" not in config.lower()
    assert login_banner("  Zachariah   Miller ") == "Welcome Zachariah Miller"
    assert login_banner("   ") == ""
    policy = update_policy("resolute")
    assert "-security" in policy
    assert "-updates" in policy
    assert 'Automatic-Reboot "false"' in policy
    print("ok")


if __name__ == "__main__":
    main()
