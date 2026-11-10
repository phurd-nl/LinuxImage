#!/bin/bash
# laptop-install.sh — one-shot installer for a target laptop/VM (test or production).
# Copy this script AND build/linux-encryption-setup.tar.gz to the machine, then:
#   sudo bash laptop-install.sh [path-to-tarball]
#
# Guards: refuses on a machine whose /home is already encrypted (use
# mark-wizard-complete.sh there instead). Install itself changes no disks —
# encryption only starts when a user enters a password in the wizard.
set -euo pipefail

TARBALL="${1:-$(dirname "$0")/linux-encryption-setup.tar.gz}"
INSTALL_ROOT=/opt/linux-encryption-setup

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }
[ -f "$TARBALL" ] || { echo "ABORT: tarball not found: $TARBALL"; exit 1; }

if findmnt -no SOURCE /home 2>/dev/null | grep -q '^/dev/mapper/'; then
  echo "ABORT: /home is already encrypted on this machine."
  echo "If the wizard should be skipped here, run: sudo bash $INSTALL_ROOT/scripts/mark-wizard-complete.sh"
  exit 1
fi

echo "== Extracting to $INSTALL_ROOT =="
mkdir -p /opt
rm -rf "$INSTALL_ROOT" /opt/staging
tar -xzf "$TARBALL" -C /opt
mv /opt/staging "$INSTALL_ROOT"

echo "== Installing wizard service + kiosk (needs network for apt) =="
INSTALL_ROOT="$INSTALL_ROOT" bash "$INSTALL_ROOT/scripts/install-setup-wizard.sh"

echo ""
echo "== Pre-flight: what the wizard will see =="
bash "$INSTALL_ROOT/scripts/detect-hardware.sh" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in ("hostname", "disk", "luks_dev", "username", "secure_boot", "tpm", "free_mb", "phase", "ready"):
    print(f"  {k}: {d.get(k)}")
for b in d.get("blockers", []):
    print(f"  BLOCKER: {b}")
'

echo ""
echo "=== Install done ==="
echo "Fix any BLOCKER lines above (BIOS: Secure Boot / TPM; disk: >=50 GB unallocated)."
echo "Then log out and back in — the wizard takes over the screen."
echo "Log if anything fails: /var/log/luks-wizard-orchestrate.log"
