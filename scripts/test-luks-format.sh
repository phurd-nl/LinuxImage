#!/bin/bash
# test-luks-format.sh — the volume is LUKS2 with a memory-hard passphrase KDF.
# Dry check of the scripts. Does not format a disk.
#
# Run: bash scripts/test-luks-format.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fail=0
ok() { printf '  OK   %s\n' "$*"; }
no() { printf '  FAIL %s\n' "$*"; fail=1; }

cfg="$(cat "$here/config.sh")"
two="$(cat "$here/02-setup-encryption.sh")"

echo "$cfg" | grep -q 'argon2id' && ok "config names argon2id" || no "config names argon2id"
echo "$cfg" | grep -q 'pbkdf-memory 524288' && ok "config pins 512 MiB" || no "config pins 512 MiB"

echo "$two" | grep -q 'sector-size 4096' && ok "4K sectors" || no "4K sectors"
echo "$two" | grep -q 'LUKS_KDF' && ok "format uses the shared KDF" || no "format uses the shared KDF"
echo "$two" | grep -q -- '--hash sha256' && no "pbkdf2 sha256 still on the format" || ok "no pbkdf2 sha256"

for f in 02-setup-encryption.sh 05-add-recovery-passphrase.sh 06-restore-tpm-autounlock.sh; do
  if grep -q 'LUKS_KDF' "$here/$f"; then
    ok "$f uses LUKS_KDF"
  else
    no "$f uses LUKS_KDF"
  fi
done

if grep -q 'argon2id' "$here/08-harden-tpm-pcr7-selfheal.sh"; then
  ok "self-heal adds slots with argon2id"
else
  no "self-heal adds slots with argon2id"
fi

# The new partition must be a whole number of 4K blocks, or luksFormat refuses.
# Replays 01's sizing on a disk image whose free space ends on an odd sector.
one="$(cat "$here/01-create-partition.sh")"
echo "$one" | grep -q 'sgdisk -n "$PARTNUM:0:0"' && no "01 still uses -n N:0:0" || ok "01 does not end on the last sector"
img="$(mktemp)"
truncate -s $(( 200 * 1048576 + 7 * 512 )) "$img"
sgdisk -o -n 1:2048:+50M "$img" >/dev/null
DISK="$img"
start=$(sgdisk -f "$DISK"); end=$(sgdisk -E "$DISK")
eval "$(echo "$one" | grep -E '^end=\$\(\( ')"
sgdisk -n "2:$start:$end" "$img" >/dev/null
sectors=$(sgdisk -i 2 "$img" | sed -n 's/^Partition size: \([0-9]*\) sectors.*/\1/p')
rm -f "$img"
[ $(( sectors % 8 )) -eq 0 ] && ok "partition is whole 4K blocks ($sectors sectors)" || no "partition is $sectors sectors, not a multiple of 8"

# 08 switches home-crypt-open between optional and required. Run its exact sed
# on a sample common-session. A delimiter clash aborts 08 mid-way.
line="$(grep -E '^[[:space:]]*sed -i -E "s.\^session' "$here/08-harden-tpm-pcr7-selfheal.sh")"
PAMS="$(mktemp)"
printf 'session optional pam_exec.so quiet /usr/local/sbin/home-crypt-open\n' > "$PAMS"
OPEN_CTL=required
if (eval "$line") 2>/dev/null && grep -qx 'session required pam_exec.so quiet /usr/local/sbin/home-crypt-open' "$PAMS"; then
  ok "08 flips home-crypt-open to required"
else
  no "08 sed on common-session fails"
fi
rm -f "$PAMS"

exit "$fail"
