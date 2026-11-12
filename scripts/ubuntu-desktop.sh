#!/bin/bash
# Work desktop, OneDrive, and ongoing OS and driver updates.
# Safe to re-run. A missing package is logged and does not stop the image.
set -u
export DEBIAN_FRONTEND=noninteractive
log() { echo "[ubuntu-desktop] $*"; }

here="$(cd "$(dirname "$0")" && pwd)"
apps="$here"

apt-get update -qq || log "apt update failed"
apt-get install -y google-chrome-stable unattended-upgrades ubuntu-drivers-common fwupd onedrive nautilus \
  || apt-get install -y unattended-upgrades ubuntu-drivers-common fwupd || log "base packages incomplete"
apt-get install -y onedrive || log "OneDrive package is not in this Ubuntu archive"
apt-get install -y nautilus || log "Files was not installed"
# The OneDrive icon shows its sign-in code with zenity and copies it with wl-copy.
apt-get install -y zenity wl-clipboard libnotify-bin || log "zenity / wl-clipboard did not install"
# Remmina replaces MobaXterm. FileZilla replaces WinSCP. Neither has a Linux build.
apt-get install -y remmina filezilla || log "Remmina or FileZilla did not install"

install -d /usr/share/icons/hicolor/256x256/apps
icon_base="http://192.168.26.106:8090/nocloud/extras/icons"
for name in teams-pwa outlook-pwa; do
  curl -fsSL "${icon_base}/${name}.png" -o "/usr/share/icons/hicolor/256x256/apps/${name}.png" \
    || log "icon ${name} was not downloaded"
done

python3 - "$here" << 'PY'
import pathlib, sys
sys.path.insert(0, sys.argv[1])
from ubuntu_desktop import (
    OUTLOOK_ICON, OUTLOOK_URL, TEAMS_ICON, TEAMS_URL,
    chrome_initial_preferences, chrome_managed_policy, desktop_file,
    firefox_policy, onedrive_config, onedrive_connect_script, onedrive_desktop_file,
    session_defaults, skip_new_laptop_questions, update_policy,
)

root = pathlib.Path("/")
apps = root / "usr/share/applications"
apps.mkdir(parents=True, exist_ok=True)
(apps / "teams-pwa.desktop").write_text(desktop_file("Microsoft Teams", TEAMS_URL, "teams-pwa", TEAMS_ICON))
(apps / "outlook-pwa.desktop").write_text(desktop_file("Outlook", OUTLOOK_URL, "outlook-pwa", OUTLOOK_ICON))
# OneDrive icon: first click signs in with a code, then OneDrive syncs at every login.
connect = root / "usr/local/bin/nextlink-onedrive"
connect.parent.mkdir(parents=True, exist_ok=True)
connect.write_text(onedrive_connect_script())
connect.chmod(0o755)
(apps / "nextlink-onedrive.desktop").write_text(onedrive_desktop_file())

db = root / "etc/dconf/db/local.d"
db.mkdir(parents=True, exist_ok=True)
(db / "01-nextlink-dock").write_text(session_defaults())
profile = root / "etc/dconf/profile"
profile.mkdir(parents=True, exist_ok=True)
(profile / "user").write_text("user-db:user\nsystem-db:local\n")

# OneDrive is configured for ~/OneDrive but not started until the person clicks the OneDrive
# icon (nextlink-onedrive) and signs in; that enables onedrive.service for later logins.
skel = root / "etc/skel/.config/onedrive"
skel.mkdir(parents=True, exist_ok=True)
(skel / "config").write_text(onedrive_config())
wants = root / "etc/skel/.config/systemd/user/default.target.wants/onedrive.service"
if wants.is_symlink() or wants.is_file():
    wants.unlink()

chrome = root / "etc/opt/chrome"
chrome.mkdir(parents=True, exist_ok=True)
(chrome / "initial_preferences").write_text(chrome_initial_preferences())
managed = chrome / "policies/managed"
managed.mkdir(parents=True, exist_ok=True)
(managed / "nextlink.json").write_text(chrome_managed_policy())
firefox = root / "etc/firefox/policies"
firefox.mkdir(parents=True, exist_ok=True)
(firefox / "policies.json").write_text(firefox_policy())
skip_new_laptop_questions(root)

codename = "resolute"
osrel = pathlib.Path("/etc/os-release")
if osrel.is_file():
    for line in osrel.read_text().splitlines():
        if line.startswith("VERSION_CODENAME="):
            codename = line.split("=", 1)[1].strip().strip('"')
conf = root / "etc/apt/apt.conf.d"
conf.mkdir(parents=True, exist_ok=True)
(conf / "20auto-upgrades").write_text(
    'APT::Periodic::Update-Package-Lists "1";\n'
    'APT::Periodic::Unattended-Upgrade "1";\n'
    'APT::Periodic::AutocleanInterval "7";\n'
)
(conf / "52nextlink-unattended").write_text(update_policy(codename))
PY

dconf update || log "dconf update failed"
systemctl enable --now fwupd-refresh.timer 2>/dev/null || log "fwupd timer not enabled"

cat > /etc/systemd/system/nextlink-driver-update.service << 'EOF'
[Unit]
Description=Install updated Ubuntu drivers and refresh firmware metadata
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/ubuntu-drivers install
ExecStart=/usr/bin/fwupdmgr refresh
EOF
cat > /etc/systemd/system/nextlink-driver-update.timer << 'EOF'
[Unit]
Description=Weekly driver and firmware refresh

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now nextlink-driver-update.timer || log "driver timer not enabled"
ubuntu-drivers install || log "no extra drivers installed on this pass"
log "desktop ready"
