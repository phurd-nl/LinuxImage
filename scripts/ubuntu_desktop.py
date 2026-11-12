#!/usr/bin/env python3
"""Work desktop for the Ubuntu image: bottom dock, Teams, Outlook, OneDrive.

The files are written for the system, so every account gets the same dock.
Teams and Outlook are Chrome app windows. OneDrive uses the distro client
and finishes sign-in when the employee opens it.
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
# Ubuntu Onedrive app. Public client. No secret.
ONEDRIVE_CLIENT_ID = "ab87c385-2754-4f2e-980b-2384d0fdc9d1"
ONEDRIVE_TENANT_ID = "143673a5-ff46-4d23-8255-b4ef07861814"


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
        # Security review M4: Safe Browsing on and fixed, dangerous downloads blocked, no guest
        # profiles. Extensions stay allowed until there is a company allow list.
        "SafeBrowsingProtectionLevel": 1,
        "DownloadRestrictions": 1,
        "BrowserGuestModeEnabled": False,
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


def onedrive_config() -> str:
    return (
        f'application_id = "{ONEDRIVE_CLIENT_ID}"\n'
        f'azure_tenant_id = "{ONEDRIVE_TENANT_ID}"\n'
        'sync_dir = "~/OneDrive"\n'
        'monitor_interval = "300"\n'
        "disable_notifications = false\n"
        # Sign-in shows a short code for microsoft.com/devicelogin (work accounts only).
        'use_device_auth = "true"\n'
    )


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


def onedrive_connect_script() -> str:
    """The OneDrive icon. First time: sign in with a code, then sync at every login.

    The abraunegg client, with use_device_auth, prints "Enter the following code when
    prompted: XXXX", waits for the approval, saves refresh_token and exits. Its packaged
    user service (onedrive.service, --monitor) then keeps ~/OneDrive in sync.
    """
    return r'''#!/bin/bash
# OneDrive for this user. Sign in once with the work account; it syncs at every login after.
set -u
cfg="$HOME/.config/onedrive"
url="https://microsoft.com/devicelogin"
title="OneDrive"
if [ -s "$cfg/refresh_token" ]; then
    systemctl --user enable --now onedrive.service >/dev/null 2>&1
    mkdir -p "$HOME/OneDrive"
    exec xdg-open "$HOME/OneDrive"
fi
mkdir -p "$cfg"
[ -f "$cfg/config" ] || cp /etc/skel/.config/onedrive/config "$cfg/config"
grep -q '^use_device_auth' "$cfg/config" || echo 'use_device_auth = "true"' >> "$cfg/config"
log=$(mktemp)
onedrive > "$log" 2>&1 &
pid=$!
code=""
for _ in $(seq 1 45); do
    code=$(sed -n 's/.*Enter the following code when prompted: *\([A-Za-z0-9-]*\).*/\1/p' "$log" | head -n 1)
    [ -n "$code" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
done
if [ -z "$code" ]; then
    zenity --error --title="$title" --width=420 --text="OneDrive could not start the sign-in. Check the internet connection and try again.\n\n$(tail -n 4 "$log")"
    rm -f "$log"; exit 1
fi
printf '%s' "$code" | wl-copy 2>/dev/null
xdg-open "$url" >/dev/null 2>&1 &
zenity --info --title="$title" --width=440 --text="Connect OneDrive to your work account.\n\nA browser window opened at $url\nEnter this code (it is already copied):\n\n<span size='xx-large'><b>$code</b></span>\n\nSign in with your work email and approve it on your phone.\nThis window can be closed." &
note=$!
wait "$pid"
kill "$note" 2>/dev/null
if [ -s "$cfg/refresh_token" ]; then
    systemctl --user enable --now onedrive.service >/dev/null 2>&1
    mkdir -p "$HOME/OneDrive"
    notify-send -i folder-remote "OneDrive is connected" "Your files sync to the OneDrive folder in Home." 2>/dev/null
    xdg-open "$HOME/OneDrive"
else
    zenity --error --title="$title" --width=420 --text="OneDrive was not connected. Click the OneDrive icon to try again.\n\n$(tail -n 4 "$log")"
fi
rm -f "$log"
'''


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
