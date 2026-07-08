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

echo "== Extracting LinuxEncryption =="
tar -xzf "$ARTIFACT" -C /opt
mv /opt/staging "$INSTALL_ROOT"

echo "== Installing wizard service + kiosk autostart =="
INSTALL_ROOT="$INSTALL_ROOT" bash "$INSTALL_ROOT/scripts/install-setup-wizard.sh"

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

mkdir -p /var/lib/linux-encryption-setup
echo "pending" > /var/lib/linux-encryption-setup/image-prepared

echo "== LinuxEncryption wizard installed for first boot =="