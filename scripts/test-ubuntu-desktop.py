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
    firefox_policy,
    dock_defaults,
    login_banner,
    onedrive_config,
    onedrive_connect_script,
    onedrive_desktop_file,
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
    assert "color-scheme='prefer-dark'" in session
    assert "gtk-theme='Yaru-dark'" in session
    teams = desktop_file("Microsoft Teams", TEAMS_URL, "teams-pwa", TEAMS_ICON)
    outlook = desktop_file("Outlook", OUTLOOK_URL, "outlook-pwa", OUTLOOK_ICON)
    assert f"--app={TEAMS_URL}" in teams
    assert f"--app={OUTLOOK_URL}" in outlook
    assert "--no-first-run" in teams
    assert f"Icon={TEAMS_ICON}" in teams
    assert f"Icon={OUTLOOK_ICON}" in outlook
    # Wayland: Chrome ignores --class and names an --app window chrome-<host>_<path>-<profile>.
    # The launcher must carry that name or GNOME shows a grey cog instead of the icon.
    assert "StartupWMClass=chrome-teams.microsoft.com__-Default" in teams
    assert "StartupWMClass=chrome-outlook.office.com__-Default" in outlook
    prefs = chrome_initial_preferences()
    assert "skip_first_run_ui" in prefs
    policy = chrome_managed_policy()
    assert "PromotionalTabsEnabled" in policy
    assert '"SafeBrowsingProtectionLevel": 1' in policy and '"BrowserGuestModeEnabled": false' in policy
    assert '"DisableTelemetry": true' in firefox_policy()
    assert "etc/firefox/policies" in Path(__file__).with_name("ubuntu-desktop.sh").read_text()
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
        # 26.04 runs a "Welcome to Ubuntu 26.04" wizard exactly when the done file above exists.
        upgrade = root / "etc/systemd/user/gnome-initial-setup-upgrade-login.service"
        assert upgrade.is_symlink() and os.readlink(upgrade) == "/dev/null"
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
    # OneDrive: sign in once with a device code, then it syncs at every login.
    assert "use_device_auth = \"true\"" in onedrive_config()
    assert "nextlink-onedrive.desktop" in dock_defaults()
    launcher = onedrive_desktop_file()
    assert "Exec=/usr/local/bin/nextlink-onedrive" in launcher and "Name=OneDrive" in launcher
    script = onedrive_connect_script()
    assert script.startswith("#!/bin/bash")
    assert "refresh_token" in script                          # already connected: just open the folder
    assert "Enter the following code when prompted" in script  # the client's own device-code line
    assert "microsoft.com/devicelogin" in script
    assert "systemctl --user enable --now onedrive.service" in script
    assert "zenity" in script
    shell = Path(__file__).with_name("ubuntu-desktop.sh").read_text()
    assert "nextlink-onedrive" in shell and "zenity" in shell
    config = onedrive_config()
    assert 'application_id = "ab87c385-2754-4f2e-980b-2384d0fdc9d1"' in config
    assert 'azure_tenant_id = "143673a5-ff46-4d23-8255-b4ef07861814"' in config
    assert 'sync_dir = "~/OneDrive"' in config
    assert "secret" not in config.lower()
    # Legal notice always (review H2); the welcome line is added when the laptop has a person.
    legal = login_banner("   ")
    assert legal.startswith("Authorized use only.") and "Welcome" not in legal
    assert login_banner("  Zachariah   Miller ") == legal + " Welcome Zachariah Miller."
    assert "'" not in legal and "\n" not in legal
    policy = update_policy("resolute")
    assert "-security" in policy
    assert "-updates" in policy
    assert 'Automatic-Reboot "false"' in policy
    print("ok")


if __name__ == "__main__":
    main()
