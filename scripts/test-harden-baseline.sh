#!/bin/bash
# test-harden-baseline.sh — contract for the laptop image lockdown script.
# Dry-run only. Does not install packages, change the firewall, or touch disks.
#
# Run: bash scripts/test-harden-baseline.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/harden-image-baseline.sh"
fail=0

ok() { printf '  OK   %s\n' "$*"; }
no() { printf '  FAIL %s\n' "$*"; fail=1; }

if [ ! -f "$script" ]; then
  echo "FAIL missing $script"
  exit 1
fi

bash -n "$script" && ok "syntax" || no "syntax"

out="$(bash "$script" --dry-run)"
for line in \
  "ufw default deny incoming" \
  "disable ssh" \
  "disable avahi" \
  "disable rpcbind" \
  "disable wsdd" \
  "timeshift on encrypted home" \
  "unattended-upgrades" \
  "gdm no autologin" \
  "tmpfs /tmp" \
  "sysctl lockdown" \
  "disable apport" \
  "pwquality" \
  "no core dumps" \
  "journald cap"
do
  if grep -q "$line" <<<"$out"; then
    ok "$line"
  else
    no "missing: $line"
  fi
done

if bash "$script" --apply; then
  no "--apply without IMAGE_HARDEN_CONFIRM should fail"
else
  ok "--apply without confirm fails"
fi

exit "$fail"
