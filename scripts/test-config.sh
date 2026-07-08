#!/bin/bash
# test-config.sh — proves config.sh derives LUKS_DEV correctly for the disk
# naming schemes we care about. Run: bash scripts/test-config.sh
set -euo pipefail
export CONFIG_SKIP_VALIDATE=1
here="$(dirname "$0")"

check(){ # DISK PARTNUM expected-LUKS_DEV
  DISK=$1 PARTNUM=$2 USERNAME=x MAPPER=m
  source "$here/config.sh"
  [ "$LUKS_DEV" = "$3" ] || { echo "FAIL: DISK=$1 PART=$2 -> '$LUKS_DEV', expected '$3'"; exit 1; }
  echo "ok: $1 + $2 -> $LUKS_DEV"
}

check /dev/nvme0n1 4 /dev/nvme0n1p4
check /dev/sda     2 /dev/sda2
check /dev/mmcblk0 1 /dev/mmcblk0p1
check /dev/vdb     3 /dev/vdb3
echo "ALL PASS"
