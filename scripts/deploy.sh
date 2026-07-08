#!/bin/bash
# deploy.sh — install the built tarball to /opt and enable the wizard service.
# For template VMs / new laptops. Do NOT run on an already-encrypted dev machine
# unless you immediately run mark-wizard-complete.sh afterward.
#
# Run: sudo bash scripts/deploy.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT="$REPO/build/linux-encryption-setup.tar.gz"
INSTALL_ROOT="/opt/linux-encryption-setup"

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }

if [ ! -f "$ARTIFACT" ]; then
  echo "Building first…"
  bash "$REPO/scripts/build.sh"
fi

echo "== Extracting to $INSTALL_ROOT =="
mkdir -p /opt
rm -rf "$INSTALL_ROOT"
tar -xzf "$ARTIFACT" -C /opt
mv /opt/staging "$INSTALL_ROOT"

echo "== Installing systemd + kiosk =="
INSTALL_ROOT="$INSTALL_ROOT" bash "$INSTALL_ROOT/scripts/install-setup-wizard.sh"

echo ""
echo "Deploy complete. On golden images, capture after reboot test."
echo "On already-encrypted machines: sudo bash $INSTALL_ROOT/scripts/mark-wizard-complete.sh"