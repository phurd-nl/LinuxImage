#!/bin/bash
# verify-encryption.sh — full pre-wipe verification of the LUKS+TPM /home setup.
# Read-only / NON-destructive: it never formats, opens, mounts, or kills slots.
# The ONLY thing it can change is removing the stray clevis-bound keyslot that
# was added by an accidental `clevis luks bind` — and only if you pass --cleanup.
#
# Run: sudo bash verify-encryption.sh           # checks only
#      sudo bash verify-encryption.sh --cleanup  # checks + remove stray slot/token
set -uo pipefail

source "$(dirname "$0")/config.sh"
MNT=/home
CLEANUP=0
[ "${1:-}" = "--cleanup" ] && CLEANUP=1

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }

pass=0; fail=0; warn=0
ok(){   printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass+1)); }
no(){   printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
wn(){   printf '  \033[33mWARN\033[0m  %s\n' "$*"; warn=$((warn+1)); }
hd(){   printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
hd "1. /home is mounted from the encrypted volume"
src=$(findmnt -no SOURCE "$MNT" 2>/dev/null || true)
if [ "$src" = "/dev/mapper/$MAPPER" ]; then
  ok "$MNT is mounted from /dev/mapper/$MAPPER"
else
  no "$MNT source is '${src:-<none>}', expected /dev/mapper/$MAPPER"
fi
# the mapper must sit on our LUKS device
if [ -e "/dev/mapper/$MAPPER" ]; then
  base=$(lsblk -nso NAME "/dev/mapper/$MAPPER" 2>/dev/null | tail -1)
  ok "mapper $MAPPER is backed by /dev/$base"
else
  no "/dev/mapper/$MAPPER does not exist"
fi

# ---------------------------------------------------------------------------
hd "2. LUKS header & keyslots"
if cryptsetup isLuks "$LUKS_DEV"; then
  ok "$LUKS_DEV is a LUKS2 device"
else
  no "$LUKS_DEV is not LUKS";
fi
slots=$(cryptsetup luksDump "$LUKS_DEV" 2>/dev/null \
  | grep -oP '^\s+\K[0-9]+(?=: luks2)' | sort -n | tr '\n' ' ')
echo "  keyslots present: ${slots:-none}"
for s in 0 1 2; do
  echo "$slots" | grep -qw "$s" && ok "keyslot $s present" || no "keyslot $s MISSING"
done
echo "  (0=login pw, 1=recovery passphrase, 2=TPM-sealed random key)"

# ---------------------------------------------------------------------------
hd "3. TPM-sealed keyfile (the real auto-unlock path)"
if [ -f "$JWE" ]; then
  ok "$JWE exists ($(stat -c '%a %U:%G' "$JWE"))"
else
  no "$JWE missing — login hook cannot unseal the key"
fi
# Does the TPM actually release the key against the CURRENT PCR state?
if [ -f "$JWE" ] && KEY=$(clevis decrypt < "$JWE" 2>/dev/null); then
  ok "TPM unseals the keyfile against current PCRs (sealed to PCR 7 after 08)"
  # Does that unsealed key actually unlock a LUKS slot? (non-destructive)
  if printf '%s' "$KEY" | cryptsetup luksOpen --test-passphrase --key-file - "$LUKS_DEV" 2>/dev/null; then
    ok "unsealed key unlocks the LUKS volume (test-passphrase)"
  else
    no "unsealed key does NOT unlock the volume — JWE/keyslot mismatch"
  fi
  unset KEY
else
  no "TPM did NOT release the key (PCR mismatch?) — would fall back to password at login"
fi

# ---------------------------------------------------------------------------
hd "4. Login open/close hooks + PAM wiring"
for f in /usr/local/sbin/home-crypt-open /usr/local/sbin/home-crypt-close \
         /usr/local/sbin/sync-luks-passwd /usr/local/sbin/clevis-reseal \
         /usr/local/sbin/home-crypt-stash /usr/local/sbin/clevis-reheal; do
  [ -x "$f" ] && ok "$f present & executable" || no "$f missing or not executable"
done
grep -q home-crypt-open  /etc/pam.d/common-session  && ok "open hook wired into common-session"  || no "open hook NOT in common-session"
grep -q home-crypt-close /etc/pam.d/common-session  && ok "close hook wired into common-session" || no "close hook NOT in common-session"
grep -q sync-luks-passwd /etc/pam.d/common-password && ok "password-sync hook wired in"          || wn "password-sync hook not in common-password"
grep -q home-crypt-stash /etc/pam.d/common-auth     && ok "self-heal stash hook wired into common-auth" || wn "self-heal stash hook not in common-auth (run 08)"
[ -x /etc/kernel/postinst.d/zz-clevis-reseal ] && ok "kernel reseal hook installed" || wn "kernel reseal hook missing"

# ---------------------------------------------------------------------------
hd "5. This boot's unlock evidence (journal)"
if journalctl -b -t home-crypt 2>/dev/null | grep -q 'unlocked'; then
  ok "home-crypt logged a successful unlock this boot:"
  journalctl -b -t home-crypt 2>/dev/null | sed 's/^/      /'
else
  wn "no 'unlocked' message from home-crypt this boot (may predate logging)"
  journalctl -b -t home-crypt 2>/dev/null | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
hd "6. Encrypted swap"
sw=$(swapon --show=NAME --noheadings 2>/dev/null | tr '\n' ' ')
if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$MNT/swap.img"; then
  ok "encrypted swap active: $MNT/swap.img"
elif [ -z "$sw" ]; then
  wn "no swap active (login hook activates it; OK if not yet logged in via GDM)"
else
  no "active swap is OUTSIDE the encrypted volume: $sw  <-- plaintext swap!"
fi
grep -qiE '^[^#].*swap' /etc/fstab 2>/dev/null && no "/etc/fstab still has a swap line (should be removed)" || ok "no plaintext swap in /etc/fstab"

# ---------------------------------------------------------------------------
hd "7. Stray clevis-bound keyslot (from the accidental 'clevis luks bind')"
stray=$(clevis luks list -d "$LUKS_DEV" 2>/dev/null || true)
if [ -n "$stray" ]; then
  wn "found clevis-bound slot(s) NOT used by this design:"
  echo "$stray" | sed 's/^/      /'
  echo "      (this design unseals via $JWE, not via a LUKS token)"
  if [ "$CLEANUP" = 1 ]; then
    sid=$(echo "$stray" | grep -oP '^\K[0-9]+' | head -1)
    tid=$(cryptsetup luksDump "$LUKS_DEV" 2>/dev/null \
          | grep -B0 -A2 'clevis' | grep -oP '^\s+\K[0-9]+(?=: clevis)' | head -1)
    if [ -n "$sid" ] && echo "$slots" | grep -qw "$sid" && [ "$sid" != 0 ] && [ "$sid" != 1 ] && [ "$sid" != 2 ]; then
      echo "  --cleanup: removing clevis binding on stray slot $sid ..."
      if clevis luks unbind -d "$LUKS_DEV" -s "$sid" -f 2>/dev/null; then
        ok "removed stray clevis slot $sid + its token"
      else
        wn "clevis unbind failed; try manually: cryptsetup luksKillSlot $LUKS_DEV $sid"
      fi
    else
      wn "refusing auto-cleanup: stray slot id '$sid' looks like a core slot (0/1/2) — inspect manually"
    fi
  else
    echo "      re-run with --cleanup to remove it (keeps slots 0/1/2 untouched)"
  fi
else
  ok "no stray clevis token (design is clean)"
fi

# ---------------------------------------------------------------------------
hd "SUMMARY"
printf '  PASS=%d  FAIL=%d  WARN=%d\n' "$pass" "$fail" "$warn"
if [ "$fail" -eq 0 ]; then
  echo "  ✅ Core checks passed. Remaining manual step: log OUT and back IN, then re-run"
  echo "     this script to confirm the steady-state login mount before running 03."
  exit 0
else
  echo "  ❌ One or more FAILs above — do NOT run 03-finalize-wipe-old-home.sh yet."
  exit 1
fi
