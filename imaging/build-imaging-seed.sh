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
SEED="${SEED_OUT:-$REPO/imaging/seed/nocloud}"
EXTRAS="$SEED/extras"
user_data_only=0
if [ "${1:-}" = "--user-data-only" ]; then
  user_data_only=1
fi

if [ "$user_data_only" -eq 0 ]; then
  echo "== Building LinuxEncryption package =="
  # Avoid port clash if preview-wizard.sh is running (default WIZARD_PORT=8765).
  BUILD_TEST_PORT="${BUILD_TEST_PORT:-28765}" bash "$REPO/scripts/build.sh"
fi

echo "== Assembling NoCloud seed =="
if [ -z "${SEED_OUT:-}" ]; then
  rm -rf "$REPO/imaging/seed"
fi
mkdir -p "$EXTRAS"

if [ "$user_data_only" -eq 0 ]; then
  cp "$REPO/build/linux-encryption-setup.tar.gz" "$EXTRAS/"
  cp "$REPO/imaging/late-install-linux-encryption.sh" "$EXTRAS/"
  for extra in ubuntu_apps.py ubuntu_desktop.py ubuntu-desktop.sh setup-entra-authd.sh install-windows-agents.sh; do
    cp "$REPO/scripts/$extra" "$EXTRAS/"
  done
  mkdir -p "$EXTRAS/icons"
  cp "$REPO/imaging/icons/"*.png "$EXTRAS/icons/"
  chmod 755 "$EXTRAS/late-install-linux-encryption.sh" "$EXTRAS/ubuntu-desktop.sh" "$EXTRAS/setup-entra-authd.sh" "$EXTRAS/install-windows-agents.sh"
fi

# user-data must start with #cloud-config for NoCloud datasource.
# The yaml holds a placeholder so the git tree has no shared login password.
# Autoinstall requires a passwd hash. The plaintext stays in TECH-PASSWORD.txt.
yaml="$REPO/imaging/ubuntu-26.04-desktop-autoinstall.yaml"
if ! grep -q '__TEMP_PASSWORD__' "$yaml"; then
  echo "ABORT: $yaml is missing the __TEMP_PASSWORD__ placeholder" >&2
  exit 1
fi
TEMP_PASSWORD="${TEMP_PASSWORD:-$(openssl rand -hex 12)}"
HASH="$(printf '%s' "$TEMP_PASSWORD" | openssl passwd -6 -stdin)"
case "$HASH" in
  \$6\$*) ;;
  *) echo "ABORT: openssl did not return a sha512-crypt hash" >&2; exit 1 ;;
esac
python3 - "$yaml" "$SEED/user-data" "$TEMP_PASSWORD" "$HASH" <<'PY'
import pathlib, sys
yaml, dest, plain, hashed = sys.argv[1:]
text = pathlib.Path(yaml).read_text()
out = "#cloud-config\n" + text.replace("__TEMP_PASSWORD__", hashed)
if plain in out:
    raise SystemExit("plaintext password landed in user-data")
if "stable/ubuntu-$REL" in out:
    raise SystemExit("literal refresh channel landed in user-data")
pathlib.Path(dest).write_text(out)
PY
install -m 600 /dev/null "$SEED/TECH-PASSWORD.txt"
printf '%s\n' "$TEMP_PASSWORD" > "$SEED/TECH-PASSWORD.txt"
chmod 600 "$SEED/TECH-PASSWORD.txt"

cp "$REPO/imaging/meta-data" "$SEED/meta-data"

echo ""
echo "=== Imaging seed ready ==="
echo "  $SEED/"
echo "  user-data          $(wc -l < "$SEED/user-data") lines"
echo "  TECH-PASSWORD.txt  (one-time login; not printed here)"
echo "  meta-data"
if [ "$user_data_only" -eq 0 ]; then
  echo "  extras/linux-encryption-setup.tar.gz ($(du -h "$EXTRAS/linux-encryption-setup.tar.gz" | cut -f1))"
  echo "  extras/late-install-linux-encryption.sh"
fi
echo ""
echo "Copy seed to USB (folder must be named nocloud at USB root):"
echo "  sudo cp -a $REPO/imaging/seed/nocloud /media/USB/"
echo ""
echo "Boot Ubuntu 26.04 Desktop ISO. If autoinstall does not start, add kernel args:"
echo "  autoinstall ds=nocloud;s=/cdrom/nocloud/"
echo ""
echo "Or serve user-data/meta-data via HTTP during PXE/OEM install."