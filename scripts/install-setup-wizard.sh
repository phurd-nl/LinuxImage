#!/bin/bash
# install-setup-wizard.sh — install the Ubuntu first-boot LUKS password box wizard.
# Installs systemd API (root), kiosk autostart, and blocks desktop until setup completes.
#
# Run: sudo bash scripts/install-setup-wizard.sh
set -euo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-/opt/linux-encryption-setup}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# When invoked from /opt/linux-encryption-setup, do not rsync over ourselves
if [ "$REPO" = "$INSTALL_ROOT" ] || [ "$(readlink -f "$REPO")" = "$(readlink -f "$INSTALL_ROOT" 2>/dev/null || echo "")" ]; then
  SKIP_RSYNC=1
fi
STATE_DIR="/var/lib/linux-encryption-setup"
SERVICE_NAME="linux-encryption-wizard"
PORT="${WIZARD_PORT:-8765}"

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }

say() { echo "[$(date +%T)] $*"; }

say "Installing Ubuntu packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3 curl gdisk cryptsetup clevis clevis-tpm2 tpm2-tools mokutil pamtester \
  chromium-browser 2>/dev/null \
  || DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3 curl gdisk cryptsetup clevis clevis-tpm2 tpm2-tools mokutil pamtester chromium

if [ "${SKIP_RSYNC:-}" != "1" ]; then
  say "Installing to $INSTALL_ROOT"
  mkdir -p "$INSTALL_ROOT"
  rsync -a --delete \
    --exclude '.git' --exclude 'build' --exclude 'venv' --exclude '.venv' --exclude '__pycache__' \
    "$REPO/" "$INSTALL_ROOT/"
else
  say "Using existing tree at $INSTALL_ROOT"
fi

chmod +x "$INSTALL_ROOT"/scripts/*.sh
chmod +x "$INSTALL_ROOT"/webgui/server.py

say "Creating state directory"
mkdir -p "$STATE_DIR"
chmod 755 "$STATE_DIR"

say "Installing systemd service (runs as root)"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Ubuntu /home encryption first-boot wizard
After=network.target local-fs.target
Before=graphical.target
Wants=network.target

[Service]
Type=simple
User=root
Group=root
Environment=LINUX_ENCRYPTION_REPO=$INSTALL_ROOT
Environment=LINUX_ENCRYPTION_STATE=$STATE_DIR
Environment=WIZARD_HOST=127.0.0.1
Environment=WIZARD_PORT=$PORT
# Set when Ansible server is ready:
# Environment=ANSIBLE_API_URL=https://ansible.example.com
ExecStart=/usr/bin/python3 $INSTALL_ROOT/webgui/server.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"

say "Installing kiosk launcher (reopens until setup complete)"
cat > /usr/local/bin/linux-encryption-wizard-kiosk <<KIOSK
#!/bin/bash
# Mandatory fullscreen LUKS setup box — relaunches if closed before completion.
set -euo pipefail

URL="http://127.0.0.1:${PORT}"
MARKER="\${HOME}/.cache/linux-encryption-wizard-dismissed"

[ -f "\$MARKER" ] && exit 0

for i in \$(seq 1 45); do
  curl -sf "\$URL/api/health" >/dev/null 2>&1 && break
  sleep 1
done

is_complete() {
  curl -sf "\$URL/api/setup/status" 2>/dev/null | grep -q '"complete": true'
}

is_complete && exit 0

if command -v chromium-browser >/dev/null 2>&1; then B=chromium-browser
elif command -v chromium >/dev/null 2>&1; then B=chromium
elif command -v firefox >/dev/null 2>&1; then B=firefox
else
  notify-send "Disk Encryption" "Install chromium-browser for the setup wizard." 2>/dev/null || true
  exit 1
fi

launch() {
  if [[ "\$B" == firefox ]]; then
    "\$B" -kiosk "\$URL" &
  else
    "\$B" --kiosk --app="\$URL" --no-first-run --disable-infobars \
      --disable-session-crashed-bubble --overscroll-history-navigation=0 \
      --disable-features=TranslateUI &
  fi
  echo \$! > "\${HOME}/.cache/linux-encryption-wizard.pid"
}

# Relaunch loop: if user kills browser before setup completes, bring it back
while ! is_complete; do
  launch
  pid=\$(cat "\${HOME}/.cache/linux-encryption-wizard.pid" 2>/dev/null || echo "")
  if [ -n "\$pid" ]; then
    while kill -0 "\$pid" 2>/dev/null; do
      is_complete && kill "\$pid" 2>/dev/null && exit 0
      sleep 2
    done
  fi
  sleep 3
done
KIOSK
chmod 755 /usr/local/bin/linux-encryption-wizard-kiosk

say "Installing autostart (all users)"
cat > /etc/xdg/autostart/linux-encryption-wizard.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Disk Encryption Setup
Comment=Required — encrypt /home with your login password
Exec=/usr/local/bin/linux-encryption-wizard-kiosk
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=2
NoDisplay=false
Categories=System;
StartupNotify=false
X-KDE-autostart-after=panel
EOF

cat > /usr/local/bin/linux-encryption-wizard-dismiss <<'DISMISS'
#!/bin/bash
mkdir -p "$HOME/.cache"
touch "$HOME/.cache/linux-encryption-wizard-dismissed"
pidfile="$HOME/.cache/linux-encryption-wizard.pid"
[ -f "$pidfile" ] && kill "$(cat "$pidfile")" 2>/dev/null || true
rm -f "$pidfile"
DISMISS
chmod 755 /usr/local/bin/linux-encryption-wizard-dismiss

say "Waiting for API"
for i in $(seq 1 20); do
  curl -sf "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1 && break
  sleep 1
done

say "Running verify-wizard"
bash "$INSTALL_ROOT/scripts/verify-wizard.sh" || true

echo ""
echo "=== Ubuntu encryption wizard installed ==="
echo "  API:       http://127.0.0.1:${PORT}"
echo "  Service:   systemctl status ${SERVICE_NAME}"
echo "  Verify:    sudo bash scripts/verify-wizard.sh"
echo "  Image:     sudo bash scripts/prepare-ubuntu-image.sh  (before capturing)"
echo ""
echo "Golden image must leave ≥50 GB unallocated at end of boot disk."
echo "First boot: user enters Ubuntu login password in the LUKS box — everything else is automatic."