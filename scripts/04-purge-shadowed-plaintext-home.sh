#!/bin/bash
# 04-purge-shadowed-plaintext-home.sh
# IRREVERSIBLE. Removes the original PLAINTEXT copy of /home that still sits,
# shadowed, on the UNENCRYPTED root partition (nvme0n1p1) underneath the
# encrypted /home mount.
#
# This SUPERSEDES 03-finalize-wipe-old-home.sh, which assumed the encrypted
# volume mounts at /home/$USER and must be CLOSED first. Our design mounts the
# whole tree at /home, so we instead bind-mount the real root filesystem to
# reach the shadowed copy WITHOUT unmounting anything. Run it normally while
# logged in with the encrypted /home mounted.
#
# Run ONLY after: reboot + login confirms /home is /dev/mapper/home_crypt, and
# a logout/login cycle survived. Make sure your step-0 backup is intact first.
set -euo pipefail

source "$(dirname "$0")/config.sh"
LIVE_HOME=/home
BIND_ROOT=/mnt/root          # where we expose the real p1 root filesystem
SHADOW_HOME="$BIND_ROOT/home" # the plaintext copy hidden under the /home mount

cleanup() {
  mountpoint -q "$BIND_ROOT" && umount "$BIND_ROOT" 2>/dev/null || true
  [ -d "$BIND_ROOT" ] && rmdir "$BIND_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }

# Guard 1: setup actually happened.
[ -f /etc/luks-keyfile.jwe ] || { echo "ABORT: no /etc/luks-keyfile.jwe — encryption setup not done."; exit 1; }

# Guard 2: the LIVE /home must currently be the encrypted mapper. If it isn't,
# /home is showing the plaintext directly and we'd be about to delete the ONLY
# copy. This is the single most important safety check.
src=$(findmnt -n -o SOURCE --target "$LIVE_HOME" 2>/dev/null || true)
if [ "$src" != "/dev/mapper/$MAPPER" ]; then
  echo "ABORT: $LIVE_HOME is not the encrypted volume (source: ${src:-none})."
  echo "       Log in normally so the encrypted /home is mounted, then re-run."
  exit 1
fi

# Guard 3: live data sanity — the encrypted copy must contain the user's home.
[ -d "$LIVE_HOME/$USERNAME" ] && [ -n "$(ls -A "$LIVE_HOME/$USERNAME" 2>/dev/null)" ] || {
  echo "ABORT: $LIVE_HOME/$USERNAME is missing or empty on the encrypted volume."; exit 1; }

# Expose the real root filesystem. A plain --bind (NOT --rbind) deliberately
# does NOT replay submounts, so $SHADOW_HOME is the p1 directory the encrypted
# volume is mounted OVER — i.e. the old plaintext copy.
mkdir -p "$BIND_ROOT"
mount --bind / "$BIND_ROOT"

# Guard 4: the shadow must live on a DIFFERENT device than the live /home.
# If they're equal, the bind did not expose a separate underlying dir (e.g.
# encrypted home not really mounted) — refuse rather than risk live data.
live_dev=$(stat -c %D "$LIVE_HOME")
shadow_dev=$(stat -c %D "$SHADOW_HOME")
if [ "$live_dev" = "$shadow_dev" ]; then
  echo "ABORT: shadowed dir is on the same device as live /home (dev $live_dev)."
  echo "       Safety check failed — nothing deleted."
  exit 1
fi

# Nothing to do?
if [ -z "$(ls -A "$SHADOW_HOME" 2>/dev/null)" ]; then
  echo "Shadowed plaintext /home is already empty. Nothing to remove."
  exit 0
fi

echo "Live (encrypted) /home : dev $live_dev  ($(du -sh "$LIVE_HOME/$USERNAME" 2>/dev/null | cut -f1) in /$USERNAME)"
echo "Shadowed PLAINTEXT copy: dev $shadow_dev on unencrypted root, $(du -sh "$SHADOW_HOME" 2>/dev/null | cut -f1):"
du -sh "$SHADOW_HOME"/* 2>/dev/null | sed 's/^/    /' || true
echo
if [ "${WIZARD_AUTO:-}" != "1" ]; then
  read -r -p "Type WIPE to permanently delete the plaintext copy on unencrypted root: " ans
  [ "$ans" = "WIPE" ] || { echo "Aborted. Nothing deleted."; exit 1; }
else
  echo "WIZARD_AUTO=1: wiping shadowed plaintext /home (guards passed)"
fi

# Remove contents, keep $SHADOW_HOME itself (it is the /home mountpoint on p1).
find "$SHADOW_HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
sync
echo "Plaintext copy removed. Root free space now: $(df -h --output=avail "$BIND_ROOT" | tail -1 | tr -d ' ')"

# Optional: overwrite the freed blocks so the plaintext isn't trivially
# recoverable from p1's free space. Best-effort on SSD (wear-leveling). This
# fills the root fs to near-full briefly; ext4's reserve protects the system.
echo
if [ "${WIZARD_AUTO:-}" = "1" ]; then
  z="y"
else
  read -r -p "Overwrite freed space to scrub remnants? (slow; recommended) [y/N]: " z
fi
if [ "$z" = "y" ] || [ "$z" = "Y" ]; then
  echo "Overwriting freed space on root..."
  dd if=/dev/zero of="$BIND_ROOT/zero.fill" bs=1M status=progress 2>/dev/null || true
  sync; rm -f "$BIND_ROOT/zero.fill"; sync
  echo "Scrub complete."
fi

mkdir -p /var/lib/linux-encryption-setup
date -Iseconds > /var/lib/linux-encryption-setup/purge_done
echo "Done. The only copy of your home data now lives on the encrypted volume."
