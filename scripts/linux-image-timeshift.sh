#!/bin/bash
# linux-image-timeshift.sh — create the daily snapshot only while encrypted
# /home is mounted. Exit 0 when the volume is locked so the timer stays quiet.
set -euo pipefail

CONFIG=/opt/linux-encryption-setup/scripts/config.sh
[ -f "$CONFIG" ] || exit 0
# shellcheck disable=SC1090
CONFIG_SKIP_VALIDATE=1 source "$CONFIG"

src="$(findmnt -n -o SOURCE --target /home 2>/dev/null || true)"
[ "$src" = "/dev/mapper/${MAPPER}" ] || exit 0
[ -s /etc/timeshift/timeshift.json ] || exit 0
if grep -q '"backup_device_uuid"[[:space:]]*:[[:space:]]*""' /etc/timeshift/timeshift.json; then
  exit 0
fi
exec timeshift --check --scripted --yes --quiet
