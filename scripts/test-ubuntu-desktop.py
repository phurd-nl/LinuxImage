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
    onedrive_ensure_config_snippet,
    onedrive_desktop_file,
    onedrive_monitor_script,
    onedrive_service_dropin,
    onedrive_unstick_script,
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
    assert '"SafeBrowsingProtectionLevel": 2' in policy and '"BrowserGuestModeEnabled": false' in policy
    assert '"HttpsOnlyMode": "force_enabled"' in policy
    assert '"DnsOverHttpsMode": "off"' in policy
    assert '"DefaultPopupsSetting": 2' in policy
    firefox = firefox_policy()
    assert '"DisableTelemetry": true' in firefox
    assert '"HTTPSOnlyMode": "enabled"' in firefox
    assert '"SSLVersionMin": "tls1.2"' in firefox
    assert '"DNSOverHTTPS"' in firefox and '"Locked": true' in firefox
    assert '"PopupBlocking"' in firefox
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
    assert "refresh_token" in script
    assert "Enter the following code when prompted" in script  # the client's own device-code line
    assert "microsoft.com/devicelogin" in script
    assert "systemctl --user enable --now onedrive.service" in script
    # 2.5.10 exits after a bare `onedrive` without copying files. --sync is what downloads.
    assert "onedrive --sync" in script
    assert "\nonedrive >" not in script
    assert "is-active" in script
    assert "zenity" in script
    shell = Path(__file__).with_name("ubuntu-desktop.sh").read_text()
    assert "nextlink-onedrive" in shell and "zenity" in shell
    config = onedrive_config()
    assert 'application_id = "ab87c385-2754-4f2e-980b-2384d0fdc9d1"' in config
    assert 'azure_tenant_id = "143673a5-ff46-4d23-8255-b4ef07861814"' in config
    assert 'sync_dir = "~/OneDrive"' in config
    # Dual-stack DNS plus HTTP/2 leaves the monitor retrying one Graph call.
    assert 'ip_protocol_version = "1"' in config
    assert 'force_http_11 = "true"' in config
    assert "secret" not in config.lower()
    # The onedrive client rejects unquoted values ("Malformed config line").
    import re
    assert all(re.fullmatch(r'[a-z0-9_]+ = ".*"', line) for line in config.splitlines()), config
    assert "onedrive_ensure_config" in script
    assert "nextlink-onedrive-unstick" in script
    assert "--resync" not in script
    monitor = onedrive_monitor_script()
    assert "exec /usr/bin/onedrive --monitor" in monitor
    assert 'ip_protocol_version' in monitor and 'force_http_11' in monitor
    unstick = onedrive_unstick_script()
    assert "Could not resolve hostname" in unstick
    assert "systemctl --user restart onedrive.service" in unstick
    assert "--resync" not in unstick
    dropin = onedrive_service_dropin()
    assert "ExecStart=/usr/local/bin/nextlink-onedrive-monitor" in dropin
    assert "ExecStart=\n" in dropin
    shell = Path(__file__).with_name("ubuntu-desktop.sh").read_text()
    assert "nextlink-onedrive-monitor" in shell
    assert "nextlink-onedrive-unstick.timer" in shell
    assert "systemctl --global enable nextlink-onedrive-unstick.timer" in shell
    import subprocess
    import tempfile
    for body in (script, monitor, unstick):
        with tempfile.NamedTemporaryFile("w", suffix=".sh") as fh:
            fh.write(body)
            fh.flush()
            subprocess.run(["bash", "-n", fh.name], check=True)
    # An already-imaged laptop keeps the old config. The patch replaces IPv4+IPv6 and adds HTTP/1.1.
    with tempfile.TemporaryDirectory() as tmp:
        cfg = Path(tmp) / "config"
        cfg.write_text('application_id = "ab87c385-2754-4f2e-980b-2384d0fdc9d1"\nip_protocol_version = "0"\n')
        subprocess.run(
            ["bash", "-c", onedrive_ensure_config_snippet() + f'onedrive_ensure_config "{cfg}"'],
            check=True,
        )
        patched = cfg.read_text().splitlines()
        assert 'ip_protocol_version = "1"' in patched
        assert 'force_http_11 = "true"' in patched
        assert sum(line.startswith("ip_protocol_version") for line in patched) == 1
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
