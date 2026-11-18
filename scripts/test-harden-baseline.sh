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
  "ufw keep martian logging" \
  "mask ModemManager when this laptop has no WWAN modem" \
  "cups web interface off" \
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

# 17 Nov laptop audit. Dry-run does not print file bodies, so check the script text.
for needle in \
  'net.ipv4.conf.all.secure_redirects = 0' \
  'install dccp /bin/true' \
  'install sctp /bin/true' \
  'install rds /bin/true' \
  'install tipc /bin/true' \
  'WaylandEnable=true' \
  'ForwardAgent no' \
  'WebInterface No'
do
  if grep -q "$needle" "$script"; then
    ok "contains $needle"
  else
    no "missing text: $needle"
  fi
done
if grep -q 'net/ipv4/conf/all/log_martians' "$script" \
  && grep -q 'net/ipv4/conf/default/log_martians' "$script" \
  && grep -q '${key}=1' "$script"; then
  ok "ufw martian lines set to 1"
else
  no "ufw martian lines set to 1"
fi
if grep -q 'for key in AutomaticLoginEnable TimedLoginEnable WaylandEnable' "$script"; then
  no "WaylandEnable is still forced off with autologin"
else
  ok "WaylandEnable is not forced off"
fi
if grep -q 'install usb-storage /bin/true' "$script" || grep -q 'install bluetooth /bin/true' "$script" || grep -q 'install squashfs /bin/true' "$script"; then
  no "usb-storage, bluetooth, or squashfs blocked"
else
  ok "usb-storage, bluetooth, and squashfs stay available"
fi

exit "$fail"
