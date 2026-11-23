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


def onedrive_config() -> str:
    # ip_protocol_version and force_http_11: a parallel A and AAAA lookup, plus
    # HTTP/2, makes --monitor retry one Graph call forever
    # ("Could not resolve hostname on handle"). IPv4 and HTTP/1.1 is the
    # client's documented workaround. These laptops reach Microsoft on IPv4.
    return (
        f'application_id = "{ONEDRIVE_CLIENT_ID}"\n'
        f'azure_tenant_id = "{ONEDRIVE_TENANT_ID}"\n'
        'sync_dir = "~/OneDrive"\n'
        'monitor_interval = "300"\n'
        'disable_notifications = "false"\n'
        # Sign-in shows a short code for microsoft.com/devicelogin (work accounts only).
        'use_device_auth = "true"\n'
        'ip_protocol_version = "1"\n'
        'force_http_11 = "true"\n'
    )


def onedrive_ensure_config_snippet() -> str:
    """Shell function. Writes the network workaround into an existing user config.

    New images get the keys from onedrive_config(). A laptop imaged earlier keeps
    the old file, and the client only reads it at startup.
    """
    return r'''onedrive_ensure_config() {
  local file="$1"
  [ -f "$file" ] || return 0
  _onedrive_set() {
    if grep -q "^$1 " "$file"; then
      sed -i "s|^$1 = .*|$1 = $2|" "$file"
    else
      printf '%s = %s\n' "$1" "$2" >> "$file"
    fi
  }
  _onedrive_set ip_protocol_version '"1"'
  _onedrive_set force_http_11 '"true"'
}
'''


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
    """The OneDrive icon. First time: sign in with a code, then download ~/OneDrive.

    Ubuntu 26.04 ships onedrive 2.5.10. A bare `onedrive` prints the device code, saves
    refresh_token, and exits without copying files. `--sync` and `--monitor` are the
    only modes that download. The packaged user service runs `--monitor` afterwards.
    """
    return (
        "#!/bin/bash\n"
        "# OneDrive for this user. Sign in once; --sync downloads ~/OneDrive. Later logins use onedrive.service.\n"
        "set -u\n"
        + onedrive_ensure_config_snippet()
        + r'''cfg="$HOME/.config/onedrive"
url="https://microsoft.com/devicelogin"
title="OneDrive"

# Start a download. The user service (--monitor) keeps it current. If that unit does not
# stay up, run --sync directly. Never start a second client while one is already running.
# A monitor that is already up but stuck on a dead DNS handle is restarted in place.
ensure_downloading() {
    mkdir -p "$HOME/OneDrive" "$cfg"
    [ -f "$cfg/config" ] || cp /etc/skel/.config/onedrive/config "$cfg/config"
    onedrive_ensure_config "$cfg/config"
    if pgrep -u "$(id -u)" -x onedrive >/dev/null 2>&1; then
        [ -x /usr/local/bin/nextlink-onedrive-unstick ] && /usr/local/bin/nextlink-onedrive-unstick || true
        return 0
    fi
    systemctl --user enable --now onedrive.service >/dev/null 2>&1 || true
    state=$(systemctl --user is-active onedrive.service 2>/dev/null || true)
    case "$state" in
        active|activating) return 0 ;;
    esac
    nohup onedrive --sync >>"$cfg/sync.log" 2>&1 &
    disown || true
}

if [ -s "$cfg/refresh_token" ]; then
    ensure_downloading
    exec xdg-open "$HOME/OneDrive"
fi
mkdir -p "$cfg" "$HOME/OneDrive"
[ -f "$cfg/config" ] || cp /etc/skel/.config/onedrive/config "$cfg/config"
grep -q '^use_device_auth' "$cfg/config" || echo 'use_device_auth = "true"' >> "$cfg/config"
onedrive_ensure_config "$cfg/config"
log=$(mktemp)
# --sync is required. Without it, 2.5.10 authorises and exits with an empty ~/OneDrive.
onedrive --sync > "$log" 2>&1 &
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
zenity --info --title="$title" --width=440 --text="Connect OneDrive to your work account.\n\nA browser window opened at $url\nEnter this code (it is already copied):\n\n<span size='xx-large'><b>$code</b></span>\n\nSign in with your work email and approve it on your phone.\nThis window can be closed. Files download to the OneDrive folder in Home." &
note=$!
opened=0
while kill -0 "$pid" 2>/dev/null; do
    if [ "$opened" = 0 ] && [ -s "$cfg/refresh_token" ]; then
        opened=1
        kill "$note" 2>/dev/null || true
        notify-send -i folder-remote "OneDrive is downloading" "Your files are copying to the OneDrive folder in Home." 2>/dev/null || true
        xdg-open "$HOME/OneDrive" >/dev/null 2>&1 || true
    fi
    sleep 2
done
wait "$pid" || true
kill "$note" 2>/dev/null || true
if [ -s "$cfg/refresh_token" ]; then
    # --sync has released the database, so the login monitor can take over.
    systemctl --user enable --now onedrive.service >/dev/null 2>&1 || true
    if [ "$opened" = 0 ]; then
        notify-send -i folder-remote "OneDrive is connected" "Your files sync to the OneDrive folder in Home." 2>/dev/null || true
        xdg-open "$HOME/OneDrive" >/dev/null 2>&1 || true
    fi
else
    zenity --error --title="$title" --width=420 --text="OneDrive was not connected. Click the OneDrive icon to try again.\n\n$(tail -n 4 "$log")"
fi
rm -f "$log"
'''
    )


def onedrive_monitor_script() -> str:
    """ExecStart for the user service. The packaged unit runs `onedrive --monitor` with the old config."""
    return (
        "#!/bin/bash\n"
        "# Apply the IPv4 and HTTP/1.1 workaround, then run the monitor.\n"
        "set -u\n"
        + onedrive_ensure_config_snippet()
        + 'onedrive_ensure_config "${HOME}/.config/onedrive/config"\n'
        "exec /usr/bin/onedrive --monitor\n"
    )


def onedrive_unstick_script() -> str:
    """Restart a monitor that is retrying a dead curl DNS handle.

    The process stays active, so Restart=on-failure never runs. A fetch that is
    still progressing does not print this error. Do not --resync: the local
    database keeps items already saved.
    """
    return r'''#!/bin/bash
# Restart OneDrive when this start is stuck on "Could not resolve hostname on handle".
set -u
systemctl --user is-active --quiet onedrive.service || exit 0
started=$(systemctl --user show -p ActiveEnterTimestamp --value onedrive.service 2>/dev/null || true)
[ -n "$started" ] || exit 0
start_epoch=$(date -d "$started" +%s 2>/dev/null || echo 0)
now=$(date +%s)
# Give a fresh start time to reach Microsoft before treating a lookup as stuck.
[ $((now - start_epoch)) -ge 180 ] || exit 0
log=$(journalctl --user -u onedrive.service --since "$started" --no-pager -o cat 2>/dev/null || true)
printf '%s\n' "$log" | grep -q 'Could not resolve hostname' || exit 0
exec systemctl --user restart onedrive.service
'''


def onedrive_unstick_service() -> str:
    return (
        "[Unit]\n"
        "Description=Restart a stuck OneDrive monitor\n"
        "\n"
        "[Service]\n"
        "Type=oneshot\n"
        "ExecStart=/usr/local/bin/nextlink-onedrive-unstick\n"
    )


def onedrive_unstick_timer() -> str:
    return (
        "[Unit]\n"
        "Description=Check OneDrive for a stuck DNS handle\n"
        "\n"
        "[Timer]\n"
        "OnStartupSec=3min\n"
        "OnUnitActiveSec=5min\n"
        "AccuracySec=30s\n"
        "\n"
        "[Install]\n"
        "WantedBy=timers.target\n"
    )


def onedrive_service_dropin() -> str:
    return (
        "[Service]\n"
        "ExecStart=\n"
        "ExecStart=/usr/local/bin/nextlink-onedrive-monitor\n"
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
