#!/bin/bash
# prepare-ubuntu-image.sh — bake the encryption wizard into an Ubuntu golden image.
# Run INSIDE the image chroot (or on the template VM) before capturing the image.
#
# Imaging requirement: leave ≥50 GB unallocated free space at the END of the boot
# disk. The wizard creates the encrypted /home partition there automatically.
# Standard Ubuntu manual partitioning: shrink the last partition or leave "free space".
#
# Run: sudo bash scripts/prepare-ubuntu-image.sh
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"

chmod +x "$here"/*.sh "$here/../webgui/server.py" 2>/dev/null || true

echo "== Building wizard package =="
bash "$here/build.sh"

echo "== Installing encryption wizard into this Ubuntu image =="
bash "$here/deploy.sh"

echo "== Installing encryption packages (pulled at runtime too) =="
apt-get install -y gdisk cryptsetup clevis clevis-tpm2 tpm2-tools mokutil pamtester

# Mark image as needing first-boot encryption
mkdir -p /var/lib/linux-encryption-setup
echo "pending" > /var/lib/linux-encryption-setup/image-prepared

echo ""
echo "=== Image prepared ==="
echo "  1. Capture this disk image the normal way."
echo "  2. On first boot, users see the LUKS password box."
echo "  3. They enter their Ubuntu login password — setup is automatic."
echo "  4. Ensure the captured image has ~50 GB+ unallocated at end of boot disk."