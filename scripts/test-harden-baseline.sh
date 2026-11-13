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
  "no timeshift timer" \
  "faillock" \
  "locked desktop policy" \
  "disable cups-browsed" \
  "disable crash and news phone-home" \
  "disable serial console login" \
  "disable kdump and openvpn" \
  "remove telnet ftp and unchecked network tools" \
  "nextadmin out of lxd" \
  "ssh client gssapi off" \
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

# Template instances (serial-getty@ttyS0) are not in list-unit-files, so masking must not depend on it.
if awk '/^mask_listeners\(\)/,/^}/' "$here/harden-image-baseline.sh" | grep -q 'list-unit-files'; then
  no "mask_listeners skips template instances such as serial-getty@ttyS0"
else
  ok "mask_listeners masks template instances"
fi

exit "$fail"
