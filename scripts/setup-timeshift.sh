#!/bin/bash
# setup-timeshift.sh — Timeshift for the Ubuntu laptop image.
#
# Rsync snapshots, daily, keep 2, stored on the encrypted /home filesystem.
# Root is the wrong disk: snapshots there filled this machine (about 20 GB on
# a 48 GB root). Logout closes /home, so the timer skips while that volume
# is locked instead of writing onto root.
#
#   bash scripts/setup-timeshift.sh --dry-run
#   sudo IMAGE_HARDEN_CONFIRM=1 bash scripts/setup-timeshift.sh --install
#   sudo WIZARD_AUTO=1 bash scripts/setup-timeshift.sh --bind
#
# --bind runs from the first-boot wizard after /home is the encrypted mapper.
# It refuses to point Timeshift at any other filesystem.
set -euo pipefail

mode=""
case "${1:-}" in
  --dry-run) mode=dry-run ;;
  --install) mode=install ;;
  --bind) mode=bind ;;
  *)
    echo "Use: $0 --dry-run | --install | --bind" >&2
    exit 2
    ;;
esac

if [ "$mode" = dry-run ]; then
  echo "would: timeshift package"
  echo "would: timeshift timer"
  echo "would: snapshots on encrypted /home"
  echo "would: daily keep 2"
  echo "would: skip when /home is locked"
  exit 0
fi

if [ "${IMAGE_HARDEN_CONFIRM:-}" != 1 ] && [ "${WIZARD_AUTO:-}" != 1 ]; then
  echo "Refusing to change this machine. Re-run with IMAGE_HARDEN_CONFIRM=1 on the template or target only." >&2
  exit 1
fi
if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo IMAGE_HARDEN_CONFIRM=1 bash $0 --install" >&2
  exit 1
fi

here="$(cd "$(dirname "$0")" && pwd)"

install_bits() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y timeshift
  install -m 755 "$here/linux-image-timeshift.sh" /usr/local/sbin/linux-image-timeshift
  cat > /etc/systemd/system/linux-image-timeshift.service <<'EOF'
[Unit]
Description=Timeshift daily check when encrypted /home is open
ConditionPathExists=/usr/local/sbin/linux-image-timeshift

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/linux-image-timeshift
EOF
  cat > /etc/systemd/system/linux-image-timeshift.timer <<'EOF'
[Unit]
Description=Hourly Timeshift check (no-ops while /home is locked)

[Timer]
OnCalendar=hourly
Persistent=false
AccuracySec=5min

[Install]
WantedBy=timers.target
EOF
  # Stock cron would try to snapshot while the volume is locked.
  rm -f /etc/cron.d/timeshift /etc/cron.d/timeshift-hourly /etc/cron.hourly/timeshift
  # The installer chroot has no running systemd. A failed systemctl would
  # abort the image. The symlink is what enable would have written.
  systemctl daemon-reload || true
  mkdir -p /etc/systemd/system/timers.target.wants
  ln -sfn /etc/systemd/system/linux-image-timeshift.timer \
    /etc/systemd/system/timers.target.wants/linux-image-timeshift.timer
}

if [ "$mode" = install ]; then
  install_bits
  echo "Timeshift installed. The backup disk is set after encrypted /home is mounted."
  exit 0
fi

# --bind: only the encrypted home filesystem. Never the root partition.
# shellcheck disable=SC1091
source "$here/config.sh"
src="$(findmnt -n -o SOURCE --target /home 2>/dev/null || true)"
if [ "$src" != "/dev/mapper/${MAPPER}" ]; then
  echo "ABORT: /home is '${src:-missing}', not /dev/mapper/${MAPPER}. Not writing Timeshift config." >&2
  exit 1
fi
backup_uuid="$(blkid -s UUID -o value "/dev/mapper/${MAPPER}")"
root_src="$(findmnt -n -o SOURCE /)"
parent_uuid="$(blkid -s UUID -o value "$root_src")"
if [ -z "$backup_uuid" ] || [ -z "$parent_uuid" ]; then
  echo "ABORT: could not read filesystem UUIDs for Timeshift" >&2
  exit 1
fi

install_bits
install -d -m 755 /etc/timeshift
python3 - "$backup_uuid" "$parent_uuid" "$USERNAME" <<'PY'
import json, sys
backup, parent, user = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = {
    "backup_device_uuid": backup,
    "parent_device_uuid": parent,
    "do_first_run": "false",
    "btrfs_mode": "false",
    "include_btrfs_home_for_backup": "false",
    "include_btrfs_home_for_restore": "false",
    "stop_cron_emails": "true",
    "schedule_monthly": "false",
    "schedule_weekly": "false",
    "schedule_daily": "true",
    "schedule_hourly": "false",
    "schedule_boot": "false",
    "count_monthly": "2",
    "count_weekly": "3",
    "count_daily": "2",
    "count_hourly": "6",
    "count_boot": "5",
    "snapshot_size": "0",
    "snapshot_count": "0",
    "date_format": "%Y-%m-%d %H:%M:%S",
    "exclude": [f"/home/{user}/**", "/home/timeshift/**"],
    "exclude-apps": [],
}
with open("/etc/timeshift/timeshift.json", "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
PY
chmod 644 /etc/timeshift/timeshift.json
echo "Timeshift will keep 2 daily snapshots on /dev/mapper/${MAPPER} (${backup_uuid})."
if ! timeshift --check --scripted --yes --quiet; then
  echo "WARNING: first Timeshift check failed. Config is in place; the hourly timer will retry while /home is open." >&2
fi
