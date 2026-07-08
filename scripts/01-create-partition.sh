#!/bin/bash
# 01-create-partition.sh
# Creates /dev/nvme0n1p4 in the free space after nvme0n1p3.
# SAFE BY DESIGN: only allocates unused free space; refuses if p4 already
# exists; never touches p1/p2/p3. Run: sudo bash 01-create-partition.sh
set -euo pipefail

source "$(dirname "$0")/config.sh"
NEWPART="$LUKS_DEV"

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }

echo "== Current layout =="
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT "$DISK"

# Guard 1: p4 must NOT already exist (don't clobber anything)
if [ -b "$NEWPART" ]; then
  echo "ABORT: $NEWPART already exists. Refusing to touch it."
  exit 1
fi

# Guard 2: disk must be GPT
command -v sgdisk >/dev/null || apt-get install -y gdisk
if ! sgdisk -p "$DISK" >/dev/null 2>&1; then
  echo "ABORT: $DISK is not a readable GPT disk."
  exit 1
fi

echo
echo "== Free space on $DISK =="
sgdisk -p "$DISK" | sed -n '1,12p'
echo
echo "About to create partition 4 using the largest free block (the ~882 GB"
echo "after nvme0n1p3). Existing partitions are NOT modified."
if [ "${WIZARD_AUTO:-}" != "1" ]; then
  read -r -p "Type CREATE to proceed: " ans
  [ "$ans" = "CREATE" ] || { echo "Aborted."; exit 1; }
else
  echo "WIZARD_AUTO=1: creating partition in largest free block on $DISK"
fi

# -n 4:0:0  => partition 4, start at first aligned free sector, end at last
# -t 4:8300 => Linux filesystem type code
sgdisk -n "$PARTNUM:0:0" -t "$PARTNUM:8300" -c "$PARTNUM:$MAPPER" "$DISK"
partprobe "$DISK"
sleep 1

echo
echo "== New layout =="
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT "$DISK"
[ -b "$NEWPART" ] && echo "OK: $NEWPART created." || { echo "ERROR: $NEWPART missing after partprobe — reboot and re-check."; exit 1; }
echo "Next: enable Secure Boot (if not done), then run 02-setup-encryption.sh"
