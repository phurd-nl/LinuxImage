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
    onedrive_account_autostart,
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
    # OneDrive: the Microsoft 365 account in Settings > Online Accounts, shown as a drive in Files.
    assert "nextlink-onedrive.desktop" in dock_defaults()
    launcher = onedrive_desktop_file()
    assert "Exec=/usr/local/bin/nextlink-onedrive" in launcher and "Name=OneDrive" in launcher
    assert "Exec=/usr/local/bin/nextlink-onedrive --seed" in onedrive_account_autostart()
    script = onedrive_connect_script()
    assert script.startswith("#!/bin/bash")
    assert "gnome-control-center online-accounts nextlink_m365" in script
    assert "secret" not in script.lower()
    shell = Path(__file__).with_name("ubuntu-desktop.sh").read_text()
    assert "nextlink-onedrive" in shell and "gnome-online-accounts" in shell and "gvfs-backends" in shell
    # The sync client is gone from new images.
    assert "onedrive.service" not in shell and "unstick" not in shell
    assert "install -y onedrive" not in shell and " onedrive " not in shell
    import subprocess
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        stub = home / "bin"
        stub.mkdir()
        (home / "nextlink-onedrive").write_text(script)

        def seed(login: str) -> str:
            (stub / "id").write_text(f"#!/bin/sh\necho '{login}'\n")
            (stub / "id").chmod(0o755)
            env = {**os.environ, "HOME": str(home), "PATH": f"{stub}:{os.environ['PATH']}"}
            subprocess.run(["bash", str(home / "nextlink-onedrive"), "--seed"], check=True, env=env)
            conf = home / ".config/goa-1.0/accounts.conf"
            return conf.read_text() if conf.is_file() else ""

        # nextadmin and other local accounts have no mailbox: nothing is added.
        assert seed("nextadmin") == ""
        conf = seed("zmiller@team.nxlink.com")
        import configparser
        parsed = configparser.ConfigParser(interpolation=None)
        parsed.optionxform = str
        parsed.read_string(conf)
        acct = parsed["Account nextlink_m365"]
        assert acct["Provider"] == "ms_graph"
        assert acct["Identity"] == acct["PresentationIdentity"] == "zmiller@team.nxlink.com"
        assert acct["FilesEnabled"] == "true" and acct["MailEnabled"] == "false"
        tenant = "143673a5-ff46-4d23-8255-b4ef07861814"
        client = "b155a604-3c31-4079-93b0-6bb6aa9d5464"
        assert acct["OAuth2AuthorizationUri"] == f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize"
        assert acct["OAuth2TokenUri"] == f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token"
        assert acct["OAuth2ClientId"] == client
        assert acct["OAuth2RedirectUri"] == f"goa-oauth2://localhost/{client}"
        # The Microsoft 365 provider reads its own copy of the same four values.
        assert acct["authorization_uri"] == acct["OAuth2AuthorizationUri"]
        assert acct["token_uri"] == acct["OAuth2TokenUri"]
        assert acct["client_id"] == client and acct["redirect_uri"] == acct["OAuth2RedirectUri"]
        # Every login runs --seed. A second run must not add a second account.
        assert seed("zmiller@team.nxlink.com") == conf
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
