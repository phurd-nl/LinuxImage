#!/usr/bin/env python3
"""Work desktop for the Ubuntu image: bottom dock, Teams, Outlook, OneDrive.

The files are written for the system, so every account gets the same dock.
Teams and Outlook are Chrome app windows. OneDrive is the Microsoft 365
account in Settings > Online Accounts, shown as a drive in Files.
"""
from __future__ import annotations

TEAMS_URL = "https://teams.microsoft.com"
OUTLOOK_URL = "https://outlook.office.com"
CHROME = "google-chrome.desktop"
TEAMS = "teams-pwa.desktop"
OUTLOOK = "outlook-pwa.desktop"
FILES = "org.gnome.Nautilus.desktop"
TEAMS_ICON = "/usr/share/icons/hicolor/256x256/apps/teams-pwa.png"
OUTLOOK_ICON = "/usr/share/icons/hicolor/256x256/apps/outlook-pwa.png"
CHROME_FLAGS = "--no-first-run --no-default-browser-check"
# GNOME's own Microsoft 365 app: what Settings > Online Accounts uses when Client ID is
# left blank. Public client, no secret. It needs tenant-wide admin consent in Entra.
GOA_CLIENT_ID = "b155a604-3c31-4079-93b0-6bb6aa9d5464"
TENANT_ID = "143673a5-ff46-4d23-8255-b4ef07861814"


ONEDRIVE = "nextlink-onedrive.desktop"


def dock_defaults() -> str:
    pins = ", ".join(f"'{name}'" for name in (CHROME, TEAMS, OUTLOOK, ONEDRIVE, FILES))
    return (
        "[org/gnome/shell]\n"
        f"favorite-apps=[{pins}]\n"
        "\n"
        "[org/gnome/shell/extensions/dash-to-dock]\n"
        "dock-position='BOTTOM'\n"
        "extend-height=false\n"
        "dock-fixed=true\n"
        "dash-max-icon-size=48\n"
        "show-apps-at-top=false\n"
        "intellihide=false\n"
    )


def session_defaults() -> str:
    """Dock plus the answers GNOME would have asked on a new laptop."""
    return (
        dock_defaults()
        + "\n"
        + "[org/gnome/desktop/privacy]\n"
        + "report-technical-problems=false\n"
        + "send-software-usage-stats=false\n"
        + "\n"
        + "[org/gnome/system/location]\n"
        + "enabled=false\n"
        + "\n"
        + "[org/gnome/desktop/interface]\n"
        + "color-scheme='prefer-dark'\n"
        + "gtk-theme='Yaru-dark'\n"
    )


def chrome_app_id(url: str, profile: str = "Default") -> str:
    """The name Chrome gives an --app window on Wayland: chrome-<host>_<path, / as _>-<profile>.

    Chrome ignores --class on Wayland, so the launcher's StartupWMClass must be this,
    or GNOME cannot match the window and shows a grey cog instead of the app icon.
    """
    from urllib.parse import urlsplit
    parts = urlsplit(url)
    path = (parts.path or "/").replace("/", "_")
    return f"chrome-{parts.hostname}_{path}-{profile}"


def desktop_file(name: str, url: str, wm_class: str, icon: str) -> str:
    return (
        "[Desktop Entry]\n"
        f"Name={name}\n"
        "Comment=Work app\n"
        f"Exec=google-chrome {CHROME_FLAGS} --app={url} --class={wm_class}\n"
        "Terminal=false\n"
        "Type=Application\n"
        f"Icon={icon}\n"
        f"StartupWMClass={chrome_app_id(url)}\n"
        "Categories=Network;\n"
    )


def chrome_initial_preferences() -> str:
    import json
    return json.dumps({
        "distribution": {
            "skip_first_run_ui": True,
            "suppress_first_run_default_browser_prompt": True,
            "make_chrome_default": True,
            "do_not_create_desktop_shortcut": True,
            "do_not_create_quick_launch_shortcut": True,
            "show_welcome_page": False,
            "import_bookmarks": False,
            "import_history": False,
            "import_search_engine": False,
        }
    }, indent=2) + "\n"


def chrome_managed_policy() -> str:
    import json
    return json.dumps({
        "DefaultBrowserSettingEnabled": False,
        "PromotionalTabsEnabled": False,
        "MetricsReportingEnabled": False,
        "SuppressUnsupportedOSWarning": True,
        # Enhanced Safe Browsing, dangerous downloads blocked, no guest profiles.
        # Extensions stay allowed until there is a company allow list.
        # DNS-over-HTTPS stays off so lookups stay on the corporate resolver.
        "SafeBrowsingProtectionLevel": 2,
        "DownloadRestrictions": 1,
        "BrowserGuestModeEnabled": False,
        "PasswordLeakDetectionEnabled": True,
        "HttpsOnlyMode": "force_enabled",
        "DnsOverHttpsMode": "off",
        "BlockThirdPartyCookies": True,
        "AutofillCreditCardEnabled": False,
        "PaymentMethodQueryEnabled": False,
        "DefaultPopupsSetting": 2,
        "EnableOnlineRevocationChecks": True,
        "SafeBrowsingExtendedReportingEnabled": False,
    }, indent=2) + "\n"


def firefox_policy() -> str:
    """Enterprise policy for the Firefox snap (/etc/firefox/policies/policies.json), review M4."""
    import json
    return json.dumps({"policies": {
        "DisableTelemetry": True,
        "DisableFirefoxStudies": True,
        "DisablePocket": True,
        "DontCheckDefaultBrowser": True,
        "Permissions": {"Camera": {"BlockNewRequests": False}, "Microphone": {"BlockNewRequests": False}},
        # HTTPS-only is on, with per-site exceptions. Camera and mic stay allowed here;
        # the snap plugs stay disconnected, which is the stronger control.
        "HTTPSOnlyMode": "enabled",
        "SSLVersionMin": "tls1.2",
        "DNSOverHTTPS": {"Enabled": False, "Locked": True},
        "EnableTrackingProtection": {
            "Value": True,
            "Locked": True,
            "Cryptomining": True,
            "Fingerprinting": True,
            "EmailTracking": True,
        },
        "PopupBlocking": {"Default": True, "Locked": True},
    }}, indent=2) + "\n"


def skip_new_laptop_questions(root) -> None:
    """Stop GNOME Initial Setup. The image already has language, keyboard, and privacy."""
    import os
    import pwd
    from pathlib import Path

    root = Path(root)
    skel = root / "etc/skel/.config"
    skel.mkdir(parents=True, exist_ok=True)
    (skel / "gnome-initial-setup-done").write_text("")

    unit_dir = root / "etc/systemd/user"
    unit_dir.mkdir(parents=True, exist_ok=True)
    # upgrade-login is 26.04's "Welcome to Ubuntu" tour; it runs because the done file exists.
    for unit in ("gnome-initial-setup-first-login.service", "gnome-initial-setup.service",
                 "gnome-initial-setup-upgrade-login.service"):
        link = unit_dir / unit
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to("/dev/null")

    auto = root / "etc/xdg/autostart"
    auto.mkdir(parents=True, exist_ok=True)
    (auto / "gnome-initial-setup-first-login.desktop").write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=Initial Setup\n"
        "Hidden=true\n"
        "X-GNOME-Autostart-enabled=false\n"
    )

    # nextadmin is hidden, so GDM sees no users and launches Initial Setup as the
    # greeter. With the unit masked above, that fails six times and GDM gives up
    # on a blank panel. Tell GDM not to try.
    import re
    gdm = root / "etc/gdm3/custom.conf"
    gdm.parent.mkdir(parents=True, exist_ok=True)
    text = gdm.read_text() if gdm.is_file() else "[daemon]\n"
    if re.search(r"(?m)^InitialSetupEnable=", text):
        text = re.sub(r"(?m)^InitialSetupEnable=.*$", "InitialSetupEnable=false", text)
    elif re.search(r"(?m)^\[daemon\]$", text):
        text = re.sub(r"(?m)^\[daemon\]$", "[daemon]\nInitialSetupEnable=false", text, count=1)
    else:
        text += "\n[daemon]\nInitialSetupEnable=false\n"
    gdm.write_text(text)

    home = root / "home"
    if not home.is_dir():
        return
    for folder in home.iterdir():
        if not folder.is_dir() or folder.name.startswith("."):
            continue
        cfg = folder / ".config"
        created = not cfg.exists()
        cfg.mkdir(parents=True, exist_ok=True)
        stamp = cfg / "gnome-initial-setup-done"
        stamp.write_text("")
        user_auto = cfg / "autostart" / "gnome-initial-setup-first-login.desktop"
        if user_auto.is_file() or user_auto.is_symlink():
            user_auto.unlink()
        if not created:
            continue
        try:
            ent = pwd.getpwnam(folder.name)
        except KeyError:
            continue
        try:
            os.chown(cfg, ent.pw_uid, ent.pw_gid)
            os.chown(stamp, ent.pw_uid, ent.pw_gid)
        except PermissionError:
            pass


LEGAL_NOTICE = ("Authorized use only. This laptop and its data belong to Nextlink Internet. "
                "Activity may be monitored and recorded.")


def login_banner(employee: str) -> str:
    """Sign-in screen text: the legal notice, plus a welcome line while the laptop is new.
    One line, no quotes: it goes into a dconf string and a sed replacement."""
    name = " ".join((employee or "").replace("'", "").split())
    return f"{LEGAL_NOTICE} Welcome {name}." if name else LEGAL_NOTICE


def onedrive_desktop_file() -> str:
    return (
        "[Desktop Entry]\n"
        "Name=OneDrive\n"
        "Comment=Work files in OneDrive\n"
        "Exec=/usr/local/bin/nextlink-onedrive\n"
        "Terminal=false\n"
        "Type=Application\n"
        "Icon=folder-remote\n"
        "Categories=Network;FileTransfer;\n"
    )


def onedrive_account_autostart() -> str:
    """Runs at every login, so the account is in Settings before the person looks for it."""
    return (
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=Add the Microsoft 365 account\n"
        "Exec=/usr/local/bin/nextlink-onedrive --seed\n"
        "NoDisplay=true\n"
    )


def onedrive_connect_script() -> str:
    """The OneDrive icon, and with --seed the login step.

    Settings > Online Accounts asks for a Tenant ID that no employee knows. This writes
    the account with the tenant already filled in, so Settings shows it with a Sign in
    button. Once signed in, OneDrive is an online drive in Files (gvfs). Nothing is
    copied to the disk.

    Ubuntu's gnome-online-accounts has no system template file, so the entry goes in
    the person's own accounts.conf. The daemon watches that file.
    """
    login = f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0"
    redirect = f"goa-oauth2://localhost/{GOA_CLIENT_ID}"
    return (
        r'''#!/bin/bash
# OneDrive through Settings > Online Accounts. --seed only adds the account.
set -u
email=$(id -un)
conf="$HOME/.config/goa-1.0/accounts.conf"

# Identity must equal the mailbox address Microsoft returns, or the sign-in is refused.
# The Entra sign-in name is that address. Local accounts (nextadmin) have no '@'.
case "$email" in
    *@*) ;;
    *) exit 0 ;;
esac
if ! grep -qs '^Provider=ms_graph$' "$conf"; then
    mkdir -p "$(dirname "$conf")"
    cat >> "$conf" << EOF
[Account nextlink_m365]
Provider=ms_graph
Identity=$email
PresentationIdentity=$email
FilesEnabled=true
MailEnabled=false
CalendarEnabled=false
ContactsEnabled=false
'''
        # gnome-online-accounts 3.58 reads these four values under both spellings.
        f"OAuth2AuthorizationUri={login}/authorize\n"
        f"OAuth2TokenUri={login}/token\n"
        f"OAuth2ClientId={GOA_CLIENT_ID}\n"
        f"OAuth2RedirectUri={redirect}\n"
        f"authorization_uri={login}/authorize\n"
        f"token_uri={login}/token\n"
        f"client_id={GOA_CLIENT_ID}\n"
        f"redirect_uri={redirect}\n"
        r'''EOF
    sleep 1  # the daemon rereads the file 200 ms after it changes
fi
[ "${1:-}" = "--seed" ] && exit 0

# Signed in: open the drive. Not yet: open the account in Settings, on its Sign in button.
uri="onedrive://$email/"
gio mount "$uri" >/dev/null 2>&1
if gio info "$uri" >/dev/null 2>&1; then
    exec nautilus --new-window "$uri"
fi
exec gnome-control-center online-accounts nextlink_m365
'''
    )


def update_policy(codename: str) -> str:
    origin = f"${{distro_id}}:${{distro_codename}}"
    return (
        "Unattended-Upgrade::Allowed-Origins {\n"
        f'    "{origin}";\n'
        f'    "{origin}-security";\n'
        f'    "{origin}-updates";\n'
        "};\n"
        "Unattended-Upgrade::Automatic-Reboot \"false\";\n"
        f"// {codename}\n"
    )
