#!/bin/bash
# 05-add-recovery-passphrase.sh — add a FRESH recovery passphrase to a free
# keyslot. RUN THIS FIRST, while the volume is unlocked.
#
# Why: the original offline recovery passphrase (keyslot 1) was lost. Before we
# touch any TPM/clevis state, we re-establish a KNOWN offline fallback so you can
# never be locked out, even if the TPM path breaks again.
#
# Non-destructive: it only ADDS a keyslot. It never removes or changes one.
# Run: sudo bash 05-add-recovery-passphrase.sh
set -euo pipefail

source "$(dirname "$0")/config.sh"
LOG=/var/log/luks-recover.log
exec > >(tee -a "$LOG") 2>&1
say(){ echo "[$(date +%T)] $*"; }

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }
cryptsetup isLuks "$LUKS_DEV" || { echo "ABORT: $LUKS_DEV is not a LUKS device"; exit 1; }

say "Current keyslots on $LUKS_DEV:"
cryptsetup luksDump "$LUKS_DEV" | grep -E '^[[:space:]]+[0-9]+: luks2' | sed 's/^/    /' || true

cat <<'EOF'

You will be prompted twice:
  1) "Enter any existing passphrase" -> type your LOGIN PASSWORD (keyslot 0).
  2) "Enter new passphrase" (twice)  -> choose a STRONG recovery phrase and
     WRITE IT DOWN / put it in your password manager RIGHT NOW. This is your
     offline fallback the next time the TPM withholds the key.

EOF
read -rp "Ready to add a new recovery passphrase? [y/N] " a
[ "$a" = y ] || [ "$a" = Y ] || { echo "aborted (nothing changed)"; exit 1; }

cryptsetup luksAddKey "$LUKS_DEV"

say "Keyslot added. Verify it works — type the NEW recovery passphrase at the prompt:"
if cryptsetup open --test-passphrase "$LUKS_DEV"; then
  say "NEW recovery passphrase VERIFIED. Store it offline now."
else
  echo "WARNING: could not verify the new passphrase. Re-run before relying on it."
  exit 1
fi

say "Keyslots now:"
cryptsetup luksDump "$LUKS_DEV" | grep -E '^[[:space:]]+[0-9]+: luks2' | sed 's/^/    /' || true
say "Done. Next: sudo bash 06-restore-tpm-autounlock.sh"
