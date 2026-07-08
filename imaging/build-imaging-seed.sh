#!/bin/bash
# build-imaging-seed.sh — build tarball + populate imaging/extras for USB/ISO seeding.
#
# Run: bash imaging/build-imaging-seed.sh
#
# Output USB folder layout:
#   imaging/seed/nocloud/
#     user-data
#     meta-data
#     extras/linux-encryption-setup.tar.gz
#     extras/late-install-linux-encryption.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SEED="$REPO/imaging/seed/nocloud"
EXTRAS="$SEED/extras"

echo "== Building LinuxEncryption package =="
# Avoid port clash if preview-wizard.sh is running (default WIZARD_PORT=8765).
BUILD_TEST_PORT="${BUILD_TEST_PORT:-28765}" bash "$REPO/scripts/build.sh"

echo "== Assembling NoCloud seed =="
rm -rf "$REPO/imaging/seed"
mkdir -p "$EXTRAS"

cp "$REPO/build/linux-encryption-setup.tar.gz" "$EXTRAS/"
cp "$REPO/imaging/late-install-linux-encryption.sh" "$EXTRAS/"
chmod 755 "$EXTRAS/late-install-linux-encryption.sh"

# user-data must start with #cloud-config for NoCloud datasource
{
  echo "#cloud-config"
  cat "$REPO/imaging/ubuntu-26.04-desktop-autoinstall.yaml"
} > "$SEED/user-data"

cp "$REPO/imaging/meta-data" "$SEED/meta-data"

echo ""
echo "=== Imaging seed ready ==="
echo "  $SEED/"
echo "  user-data          $(wc -l < "$SEED/user-data") lines"
echo "  meta-data"
echo "  extras/linux-encryption-setup.tar.gz ($(du -h "$EXTRAS/linux-encryption-setup.tar.gz" | cut -f1))"
echo "  extras/late-install-linux-encryption.sh"
echo ""
echo "Copy seed to USB (folder must be named nocloud at USB root):"
echo "  sudo cp -a $REPO/imaging/seed/nocloud /media/USB/"
echo ""
echo "Boot Ubuntu 26.04 Desktop ISO. If autoinstall does not start, add kernel args:"
echo "  autoinstall ds=nocloud;s=/cdrom/nocloud/"
echo ""
echo "Or serve user-data/meta-data via HTTP during PXE/OEM install."