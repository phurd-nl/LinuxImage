#!/bin/bash
# late-install-linux-encryption.sh — run INSIDE the installed system (curtin in-target).
# Extracts the bundled tarball and enables the first-boot LUKS wizard.
set -euo pipefail

ARTIFACT=/opt/linux-encryption-setup.tar.gz
INSTALL_ROOT=/opt/linux-encryption-setup
URL="${LINUX_ENCRYPTION_ARTIFACT_URL:-}"

if [ ! -f "$ARTIFACT" ] && [ -n "$URL" ]; then
  echo "Downloading LinuxEncryption artifact from $URL"
  curl -fsSL "$URL" -o "$ARTIFACT"
fi

if [ ! -f "$ARTIFACT" ]; then
  echo "ABORT: $ARTIFACT missing. Copy imaging/extras/linux-encryption-setup.tar.gz to the USB."
  exit 1
fi

mkdir -p /var/lib/linux-encryption-setup /tmp/kiosk-scripts
fetch_extra() {
  name="$1"
  dest="$2"
  tmp="$(mktemp)"
  if curl -fsSL "http://192.168.26.106:8090/nocloud/extras/${name}" -o "$tmp"; then
    mkdir -p "$(dirname "$dest")"
    cp "$tmp" "$dest"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  echo "WARN: ${name} was not refreshed"
  return 1
}
fetch_extra ubuntu_apps.py /tmp/kiosk-scripts/ubuntu_apps.py || true
if [ -f /tmp/kiosk-scripts/ubuntu_apps.py ]; then
  echo "== Saving the kiosk software list while the imaging cable is up =="
  python3 /tmp/kiosk-scripts/ubuntu_apps.py --save /var/lib/linux-encryption-setup/kiosk-selection.json || echo "WARN: kiosk list not saved"
fi
# Disk encryption is done by the installer (TPM-backed full disk). Nothing to fetch here.

echo "== Extracting LinuxEncryption =="
tar -xzf "$ARTIFACT" -C /opt
mv /opt/staging "$INSTALL_ROOT"
if curl -fsSL "http://192.168.26.106:8090/nocloud/extras/02-setup-encryption.sh" -o "$INSTALL_ROOT/scripts/02-setup-encryption.sh"; then
  chmod 755 "$INSTALL_ROOT/scripts/02-setup-encryption.sh"
else
  echo "WARN: encryption setup script was not refreshed"
fi
if curl -fsSL "http://192.168.26.106:8090/nocloud/extras/setup_engine.py" -o "$INSTALL_ROOT/webgui/setup_engine.py"; then
  chmod 644 "$INSTALL_ROOT/webgui/setup_engine.py"
else
  echo "WARN: encryption wizard was not refreshed"
fi

echo "== Installing wizard service + kiosk autostart =="
# The published tarball still apt-installs chromium-browser. That package is
# a snap shim and its postinst fails in this chroot. Drop only that apt
# fallback. The launcher may still look for the browser by name.
if [ -f "$INSTALL_ROOT/scripts/install-setup-wizard.sh" ]; then
  python3 - << 'PY'
from pathlib import Path
path = Path("/opt/linux-encryption-setup/scripts/install-setup-wizard.sh")
text = path.read_text()
old = """DEBIAN_FRONTEND=noninteractive apt-get install -y \\
  python3 curl gdisk cryptsetup clevis clevis-tpm2 tpm2-tools mokutil pamtester \\
  chromium-browser 2>/dev/null \\
  || DEBIAN_FRONTEND=noninteractive apt-get install -y \\
  python3 curl gdisk cryptsetup clevis clevis-tpm2 tpm2-tools mokutil pamtester chromium"""
new = """DEBIAN_FRONTEND=noninteractive apt-get install -y \\
  python3 curl gdisk cryptsetup clevis clevis-tpm2 tpm2-tools mokutil pamtester"""
if old in text:
    path.write_text(text.replace(old, new, 1))
    print("wizard apt no longer installs chromium")
else:
    print("wizard apt already avoids chromium")
PY
fi
INSTALL_ROOT="$INSTALL_ROOT" bash "$INSTALL_ROOT/scripts/install-setup-wizard.sh" || echo "WARN: encryption wizard was not fully installed"
# The employee signs in with Entra. Do not open the password kiosk.
rm -f /etc/xdg/autostart/linux-encryption-wizard.desktop
rm -f /etc/systemd/system/multi-user.target.wants/linux-encryption-wizard.service
# Hide nextadmin before the first login. The Entra snap itself waits until
# the real boot, because snapd is not running in this installer.
install -d /etc/dconf/profile /etc/dconf/db/gdm.d /var/lib/AccountsService/users
if [ ! -f /etc/dconf/profile/gdm ]; then
  printf 'user-db:user\nsystem-db:gdm\nfile-db:/usr/share/gdm/greeter-dconf-defaults\n' > /etc/dconf/profile/gdm
fi
cat > /etc/dconf/db/gdm.d/01-entra-login << 'EOF'
[org/gnome/login-screen]
disable-user-list=true
EOF
cat > /var/lib/AccountsService/users/nextadmin << 'EOF'
[User]
SystemAccount=true
EOF
dconf update || true
echo "== Office Wi-Fi =="
if fetch_extra setup-wifi.sh "$INSTALL_ROOT/scripts/setup-wifi.sh"; then
  bash "$INSTALL_ROOT/scripts/setup-wifi.sh" || echo "WARN: Wi-Fi not configured"
fi
fetch_extra imaging-firstboot.sh "$INSTALL_ROOT/scripts/imaging-firstboot.sh" || true
chmod 755 "$INSTALL_ROOT/scripts/imaging-firstboot.sh" 2>/dev/null || true
cat > /etc/systemd/system/imaging-firstboot.service << 'UNIT'
[Unit]
Description=File the disk recovery key and send the imaging report
After=network-online.target snapd.seeded.service nextlink-entra-authd.service
Wants=network-online.target
ConditionPathExists=!/var/lib/linux-encryption-setup/report-sent
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/opt/linux-encryption-setup/scripts/imaging-firstboot.sh
Restart=on-failure
RestartSec=120

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sfn /etc/systemd/system/imaging-firstboot.service /etc/systemd/system/multi-user.target.wants/imaging-firstboot.service

echo "== Applying laptop baseline (firewall, no discovery listeners, Timeshift) =="
for extra in harden-image-baseline.sh setup-timeshift.sh; do
  curl -fsSL "http://192.168.26.106:8090/nocloud/extras/$extra" -o "$INSTALL_ROOT/scripts/$extra" || true
done
chmod 755 "$INSTALL_ROOT/scripts/harden-image-baseline.sh" "$INSTALL_ROOT/scripts/setup-timeshift.sh" 2>/dev/null || true
IMAGE_HARDEN_CONFIRM=1 bash "$INSTALL_ROOT/scripts/harden-image-baseline.sh" --apply || echo "WARN: laptop baseline did not finish"

# UbuntuOauth public client. No client secret. Override with the env vars.
export ENTRA_TENANT_ID="${ENTRA_TENANT_ID:-143673a5-ff46-4d23-8255-b4ef07861814}"
export ENTRA_CLIENT_ID="${ENTRA_CLIENT_ID:-699c85ff-50ac-4b83-bfbc-3cc270cd306c}"

if [ -n "${ENTRA_TENANT_ID:-}" ] && [ -n "${ENTRA_CLIENT_ID:-}" ]; then
  echo "== Enabling Entra ID login (authd) =="
  fetch_extra setup-entra-authd.sh "$INSTALL_ROOT/scripts/setup-entra-authd.sh" || true
  chmod 755 "$INSTALL_ROOT/scripts/setup-entra-authd.sh" || true
  if [ ! -f "$INSTALL_ROOT/scripts/setup-entra-authd.sh" ]; then
    echo "WARN: Entra login script was not downloaded"
  else
  # snapd is not running in the installer chroot. Installing the broker
  # here aborts the image. The first real boot runs it once snapd is up.
  cat > /etc/systemd/system/nextlink-entra-authd.service <<EOF
[Unit]
Description=Install Entra login
After=snapd.seeded.service network-online.target linux-encryption-unattended.service
Wants=snapd.seeded.service network-online.target
ConditionPathExists=!/var/lib/linux-encryption-setup/entra-authd-installed

[Service]
Type=oneshot
Environment=IMAGE_HARDEN_CONFIRM=1
Environment=ENTRA_TENANT_ID=$ENTRA_TENANT_ID
Environment=ENTRA_CLIENT_ID=$ENTRA_CLIENT_ID
ExecStartPre=/bin/sh -c 'echo "Installing sign-in." >/dev/console'
ExecStart=/opt/linux-encryption-setup/scripts/setup-entra-authd.sh --apply
ExecStartPost=/usr/bin/touch /var/lib/linux-encryption-setup/entra-authd-installed
RemainAfterExit=yes
TimeoutStartSec=300
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sfn /etc/systemd/system/nextlink-entra-authd.service /etc/systemd/system/multi-user.target.wants/nextlink-entra-authd.service
  rm -f /etc/systemd/system/gdm.service.d/wait-for-entra.conf
  echo "Entra login does not hold the sign-in screen"
  fi
else
  echo "== Entra login skipped (set ENTRA_TENANT_ID and ENTRA_CLIENT_ID to enable) =="
fi

# Optional Ansible recovery passphrase server (edit URL for your environment)
if [ -n "${ANSIBLE_API_URL:-}" ]; then
  mkdir -p /etc/systemd/system/linux-encryption-wizard.service.d
  cat > /etc/systemd/system/linux-encryption-wizard.service.d/ansible.conf <<EOF
[Service]
Environment=ANSIBLE_API_URL=${ANSIBLE_API_URL}
Environment=ANSIBLE_PUSH_URL=${ANSIBLE_PUSH_URL:-${ANSIBLE_API_URL}}
EOF
  systemctl daemon-reload
fi

echo "== Installing the software checked on the kiosk =="
mkdir -p "$INSTALL_ROOT/scripts"
for extra in ubuntu_apps.py ubuntu-desktop.sh ubuntu_desktop.py install-windows-agents.sh; do
  fetch_extra "$extra" "$INSTALL_ROOT/scripts/$extra" || true
done
chmod 755 "$INSTALL_ROOT/scripts/ubuntu-desktop.sh" "$INSTALL_ROOT/scripts/install-windows-agents.sh" 2>/dev/null || true
APP_PY="$INSTALL_ROOT/scripts/ubuntu_apps.py"
if [ ! -f "$APP_PY" ] && [ -f /tmp/kiosk-scripts/ubuntu_apps.py ]; then
  APP_PY=/tmp/kiosk-scripts/ubuntu_apps.py
fi
if [ -f "$APP_PY" ]; then
  if [ -f /var/lib/linux-encryption-setup/kiosk-selection.json ]; then
    python3 "$APP_PY" --apply --from-file /var/lib/linux-encryption-setup/kiosk-selection.json || echo "WARN: one or more Ubuntu apps did not install"
  else
    python3 "$APP_PY" --apply || echo "WARN: one or more Ubuntu apps did not install"
  fi
else
  echo "WARN: ubuntu_apps.py missing"
fi

echo "== Work desktop, OneDrive, OS updates, and driver updates =="
if [ -f "$INSTALL_ROOT/scripts/ubuntu-desktop.sh" ]; then
  bash "$INSTALL_ROOT/scripts/ubuntu-desktop.sh" || echo "WARN: desktop setup did not finish"
fi
if ! python3 - << 'PY'
import json, pathlib, sys
sys.path.insert(0, "/opt/linux-encryption-setup/scripts")
try:
    from ubuntu_desktop import login_banner
except Exception:
    raise SystemExit(0)
saved = pathlib.Path("/var/lib/linux-encryption-setup/kiosk-selection.json")
if not saved.is_file():
    raise SystemExit(0)
employee = ""
try:
    employee = json.loads(saved.read_text()).get("employee") or ""
except Exception:
    raise SystemExit(0)
text = login_banner(employee)
if not text:
    raise SystemExit(0)
dconf = pathlib.Path("/etc/dconf/db/gdm.d/01-entra-login")
lines = dconf.read_text().splitlines() if dconf.is_file() else ["[org/gnome/login-screen]", "disable-user-list=true"]
lines = [line for line in lines if not line.startswith("banner-message-")]
if not any(line.startswith("[org/gnome/login-screen]") for line in lines):
    lines.insert(0, "[org/gnome/login-screen]")
lines.append("banner-message-enable=true")
lines.append("banner-message-text='%s'" % text)
dconf.parent.mkdir(parents=True, exist_ok=True)
dconf.write_text("\n".join(lines) + "\n")
post = pathlib.Path("/etc/gdm3/PostLogin")
post.mkdir(parents=True, exist_ok=True)
(post / "Default").write_text("""#!/bin/bash
name="${1:-${USER:-}}"
if [ -z "$name" ] || [ "$name" = "nextadmin" ]; then
  exit 0
fi
file=/etc/dconf/db/gdm.d/01-entra-login
if [ -f "$file" ]; then
  sed -i '/^banner-message-/d' "$file"
  dconf update || true
fi
exit 0
""")
(post / "Default").chmod(0o755)
PY
then
  echo "WARN: welcome line was not written"
fi
dconf update || true
if [ -f "$INSTALL_ROOT/scripts/install-windows-agents.sh" ]; then
  bash "$INSTALL_ROOT/scripts/install-windows-agents.sh" || echo "WARN: agent setup did not finish"
fi

# Panel self-refresh off on the Iris Xe panels. Do not add i915.modeset=0:
# it leaves GNOME on the firmware framebuffer with no acceleration or backlight.
install -d /etc/default/grub.d
cat > /etc/default/grub.d/99-nextlink-panel.cfg << 'EOF'
for flag in i915.enable_psr=0; do
  case " $GRUB_CMDLINE_LINUX_DEFAULT " in
    *" $flag "*) ;;
    *) GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT $flag" ;;
  esac
done
EOF
update-grub || echo "WARN: the installed boot line was not updated"

# GNOME Shell 50 (Ubuntu 26.04) is Wayland-only. WaylandEnable=false leaves GDM
# with no way to draw the sign-in screen, so the panel goes blank. Leave it on.

# ponytail: temporary. Sends this boot's journal to the imaging host every
# 2 minutes while the Dell blank sign-in screen is being diagnosed. Remove
# this block and laptop-log-drop on the host once it is solved.
cat > /usr/local/sbin/nextlink-boot-log << 'EOF'
#!/bin/sh
{
  echo "== $(hostname) $(cat /proc/cmdline)"
  echo "== systemctl --failed"; systemctl --failed --no-pager
  echo "== loginctl"; loginctl list-sessions --no-pager
  echo "== /etc/gdm3/custom.conf"; cat /etc/gdm3/custom.conf
  echo "== drm"; ls -l /sys/class/drm/ /dev/dri/ 2>&1
  echo "== journalctl -b"; journalctl -b --no-pager -o short-precise
} 2>&1 | curl -fsS -m 60 --data-binary @- http://192.168.26.106:5514/
EOF
chmod 755 /usr/local/sbin/nextlink-boot-log
cat > /etc/systemd/system/nextlink-boot-log.service << 'EOF'
[Unit]
Description=Send boot log to the imaging host
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nextlink-boot-log
EOF
cat > /etc/systemd/system/nextlink-boot-log.timer << 'EOF'
[Unit]
Description=Send boot log to the imaging host
[Timer]
OnBootSec=90
OnUnitActiveSec=120
[Install]
WantedBy=timers.target
EOF
mkdir -p /etc/systemd/system/timers.target.wants
ln -sfn /etc/systemd/system/nextlink-boot-log.timer /etc/systemd/system/timers.target.wants/nextlink-boot-log.timer

mkdir -p /var/lib/linux-encryption-setup
echo "pending" > /var/lib/linux-encryption-setup/image-prepared

echo "== LinuxEncryption wizard installed for first boot =="