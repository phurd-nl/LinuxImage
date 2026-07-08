#!/bin/bash
# 07-cleanup-stray-slots.sh — remove keyslots / tokens that are NOT part of the
# restored design. RUN LAST, only AFTER 06 + a successful reboot test.
#
# This design unlocks via the external /etc/luks-keyfile.jwe, so any clevis LUKS
# *token* embedded in the header is stray (e.g. the slot-4 `clevis luks bind`
# that appeared after the firmware/reinstall event). We unbind those.
#
# SAFETY: refuses to remove anything unless a passphrase you know still opens the
# volume (you'll be asked to type it). It will NOT auto-kill plain passphrase
# slots it can't identify — it prints them with the exact command so YOU decide.
# Run: sudo bash 07-cleanup-stray-slots.sh
set -euo pipefail

source "$(dirname "$0")/config.sh"
LOG=/var/log/luks-recover.log
exec > >(tee -a "$LOG") 2>&1
say(){ echo "[$(date +%T)] $*"; }

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }
cryptsetup isLuks "$LUKS_DEV" || { echo "ABORT: $LUKS_DEV is not a LUKS device"; exit 1; }

# ---- Lockout guard: prove a known passphrase still opens the volume --------
say "LOCKOUT GUARD — type a passphrase you KNOW (login password or your NEW recovery phrase):"
cryptsetup open --test-passphrase "$LUKS_DEV" \
  || { echo "ABORT: that passphrase did not open the volume. Fix that before removing slots."; exit 1; }
say "Confirmed a working passphrase. Safe to proceed."

# ---- Confirm the TPM auto-unlock path is the JWE, not a LUKS token ---------
if [ ! -f /etc/luks-keyfile.jwe ]; then
  echo "ABORT: /etc/luks-keyfile.jwe missing — run 06 first. Refusing to remove the clevis token,"
  echo "       which might be your only TPM path right now."
  exit 1
fi
if ! clevis decrypt < /etc/luks-keyfile.jwe >/dev/null 2>&1; then
  echo "ABORT: the JWE does not unseal on the CURRENT PCRs — run 06 to reseal first."
  echo "       Not removing anything until the file-based TPM path works."
  exit 1
fi
say "JWE-based TPM unlock verified working — the in-header clevis token is redundant."

# ---- Show full slot map ----------------------------------------------------
say "Current keyslots:"
cryptsetup luksDump "$LUKS_DEV" | grep -E '^[[:space:]]+[0-9]+: luks2' | sed 's/^/    /' || true
say "Clevis tokens (stray under this design):"
clevis luks list -d "$LUKS_DEV" 2>/dev/null | sed 's/^/    /' || echo "    (none)"

# ---- Unbind clevis LUKS tokens (the stray bind) ---------------------------
mapfile -t CSLOTS < <(clevis luks list -d "$LUKS_DEV" 2>/dev/null | grep -oP '^[0-9]+' || true)
if [ "${#CSLOTS[@]}" -eq 0 ]; then
  say "No clevis LUKS tokens to remove."
else
  for s in "${CSLOTS[@]}"; do
    read -rp "Unbind stray clevis token on slot $s? [y/N] " a
    if [ "$a" = y ] || [ "$a" = Y ]; then
      if clevis luks unbind -d "$LUKS_DEV" -s "$s" -f; then
        say "Removed clevis token + keyslot $s."
      else
        echo "  unbind failed; manual: cryptsetup luksKillSlot $LUKS_DEV $s"
      fi
    else
      say "Left slot $s in place."
    fi
  done
fi

# ---- Report remaining slots for manual review ------------------------------
echo
say "Remaining keyslots after cleanup:"
cryptsetup luksDump "$LUKS_DEV" | grep -E '^[[:space:]]+[0-9]+: luks2' | sed 's/^/    /' || true
cat <<EOF

There may still be plain-passphrase slots whose purpose is unknown (e.g. the old
lost recovery phrase, or an orphaned old TPM key). This script does NOT remove
those automatically — losing the wrong one is irreversible.

To remove one yourself, AFTER confirming you still have a working passphrase:
    sudo cryptsetup luksKillSlot $LUKS_DEV <slot-number>
You will be asked for a DIFFERENT, still-valid passphrase to authorise it.

Keep at minimum: keyslot 0 (login password), your NEW recovery phrase, and the
slot 06 created for the TPM key. When unsure, leave it and ask first.
EOF
say "Done."
