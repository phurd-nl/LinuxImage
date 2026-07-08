#!/bin/bash
# 06-restore-tpm-autounlock.sh — rebuild the TPM-sealed login-time auto-unlock
# that the firmware update / reinstall wiped out. After this + a reboot, logging
# in should mount the encrypted volume at /home automatically again.
#
# What it restores:
#   * /etc/luks-keyfile.jwe        — a NEW random key, sealed to the CURRENT PCRs
#   * /usr/local/sbin/home-crypt-open  /  home-crypt-close
#   * /usr/local/sbin/sync-luks-passwd /  clevis-reseal
#   * PAM session + password wiring
#   * /etc/kernel/postinst.d/zz-clevis-reseal
#
# What it does NOT do: reformat, migrate /home, or remove ANY keyslot.
# Idempotent — safe to re-run. Run AFTER 05 (so you have a known recovery phrase).
# Run: sudo bash 06-restore-tpm-autounlock.sh
set -euo pipefail

source "$(dirname "$0")/config.sh"
PCR='{"pcr_bank":"sha256","pcr_ids":"0,2,4,7"}'
LOG=/var/log/luks-recover.log
exec > >(tee -a "$LOG") 2>&1
say(){ echo "[$(date +%T)] $*"; }

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }

# ---- Guards -----------------------------------------------------------------
say "Pre-flight checks"
id "$USERNAME" >/dev/null || { echo "ABORT: user $USERNAME not found"; exit 1; }
cryptsetup isLuks "$LUKS_DEV" || { echo "ABORT: $LUKS_DEV is not a LUKS device"; exit 1; }
for c in clevis cryptsetup tpm2_pcrread shred; do
  command -v "$c" >/dev/null || { echo "ABORT: '$c' missing — apt install clevis clevis-tpm2 tpm2-tools cryptsetup"; exit 1; }
done
tpm2_pcrread sha256:0,2,4,7 >/dev/null 2>&1 || { echo "ABORT: cannot read TPM PCRs (TPM not accessible?)"; exit 1; }

say "Secure Boot state:"; mokutil --sb-state 2>/dev/null | sed 's/^/    /' || echo "    (unknown)"
say "Sealing against these CURRENT PCR values:"
tpm2_pcrread sha256:0,2,4,7 | sed 's/^/    /'
echo
say "NOTE: this seals to PCR 0 (firmware) among others, so the NEXT firmware"
say "      update will break auto-unlock again. The kernel hook + clevis-reseal"
say "      handle kernel bumps; after a firmware/UEFI change, re-run THIS script."
echo

# ---- Mint a fresh TPM key + seal to current PCRs ---------------------------
# The old TPM keyslot's secret is unrecoverable (its JWE is gone), so we do NOT
# try to reuse it — we generate a NEW random key, add it as a new keyslot
# (authorised by an existing passphrase = your LOGIN PASSWORD), and seal THAT.
KEY=$(mktemp -p /dev/shm); chmod 600 "$KEY"
trap 'shred -u "$KEY" 2>/dev/null || rm -f "$KEY"' EXIT
dd if=/dev/urandom bs=64 count=1 of="$KEY" status=none

say "Adding the new TPM keyslot."
say "  -> At the prompt 'Enter any existing passphrase', type your LOGIN PASSWORD."
cryptsetup luksAddKey "$LUKS_DEV" "$KEY"

say "Sealing the new key to the TPM (PCRs 0,2,4,7) -> $JWE"
clevis encrypt tpm2 "$PCR" < "$KEY" > "$JWE"
chmod 400 "$JWE"; chown root:root "$JWE"

# Verify: TPM can unseal it now, AND the unsealed key actually opens the volume.
clevis decrypt < "$JWE" | cmp -s - "$KEY" || { echo "ABORT: TPM unseal verification failed — $JWE removed"; rm -f "$JWE"; exit 1; }
say "TPM unseal verified (decrypted blob matches the key)."
cryptsetup luksOpen --test-passphrase --key-file "$KEY" "$LUKS_DEV" \
  || { echo "ABORT: unsealed key does NOT open the volume — $JWE removed"; rm -f "$JWE"; exit 1; }
say "Unsealed key opens the LUKS volume. Seal is good."
shred -u "$KEY"; trap - EXIT

# ---- Login open/close hooks (pam_exec) ------------------------------------
# session-open: TPM unseals key -> open LUKS -> mount /home/$USER -> shred key
# session-close: unmount + close (data encrypted at rest again on logout)
say "Installing login-time open/close hooks"
cat > /usr/local/sbin/home-crypt-open <<'OPEN'
#!/bin/bash
set -e
MNT="/home"
[ "$PAM_USER" = "__USER__" ] || exit 0
findmnt -M "$MNT" >/dev/null 2>&1 && exit 0   # already mounted
K=$(mktemp -p /dev/shm); chmod 600 "$K"
if ! clevis decrypt < /etc/luks-keyfile.jwe > "$K" 2>/dev/null; then
  logger -t home-crypt "TPM withheld key (PCR mismatch?) — /home NOT unlocked for $PAM_USER"
  shred -u "$K"; exit 0
fi
cryptsetup open --key-file "$K" __DEV__ __MAPPER__ 2>/dev/null || \
  logger -t home-crypt "cryptsetup open failed"
shred -u "$K"
if mount /dev/mapper/__MAPPER__ "$MNT" 2>/dev/null; then
  logger -t home-crypt "/home unlocked for $PAM_USER"
  [ -f "$MNT/swap.img" ] && swapon "$MNT/swap.img" 2>/dev/null && \
    logger -t home-crypt "encrypted swap on"
else
  logger -t home-crypt "mount failed for $PAM_USER"
fi
exit 0
OPEN
cat > /usr/local/sbin/home-crypt-close <<'CLOSE'
#!/bin/bash
MNT="/home"
[ "$PAM_USER" = "__USER__" ] || exit 0
# only act when no login sessions for the user remain (reliable for GDM/Wayland)
if loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | grep -qx "__USER__"; then
  exit 0
fi
swapoff "$MNT/swap.img" 2>/dev/null || true
umount "$MNT" 2>/dev/null || true
cryptsetup close __MAPPER__ 2>/dev/null || true
logger -t home-crypt "/home relocked for __USER__"
exit 0
CLOSE
sed -i -e "s/__USER__/$USERNAME/g" -e "s#__DEV__#$LUKS_DEV#g" -e "s/__MAPPER__/$MAPPER/g" \
  /usr/local/sbin/home-crypt-open /usr/local/sbin/home-crypt-close
chmod 700 /usr/local/sbin/home-crypt-open /usr/local/sbin/home-crypt-close
chown root:root /usr/local/sbin/home-crypt-*

# Wire into GDM PAM session (open early, close late).
PAMF=/etc/pam.d/common-session
grep -q home-crypt-open "$PAMF" || \
  echo "session optional pam_exec.so quiet /usr/local/sbin/home-crypt-open"  >> "$PAMF"
grep -q home-crypt-close "$PAMF" || \
  echo "session optional pam_exec.so quiet /usr/local/sbin/home-crypt-close" >> "$PAMF"

# ---- Kernel-update auto-reseal hook ---------------------------------------
say "Installing kernel-update reseal hook + clevis-reseal helper"
cat > /usr/local/sbin/clevis-reseal <<'RESEAL'
#!/bin/bash
# Re-seal the LUKS key to the CURRENT PCR values (after kernel/firmware change).
set -e
JWE=/etc/luks-keyfile.jwe
PCR='{"pcr_bank":"sha256","pcr_ids":"0,2,4,7"}'
TMP=$(mktemp -p /dev/shm); chmod 600 "$TMP"
clevis decrypt < "$JWE" > "$TMP" || { echo "reseal: cannot unseal old key (use recovery)"; shred -u "$TMP"; exit 1; }
clevis encrypt tpm2 "$PCR" < "$TMP" > "$JWE.new" && mv "$JWE.new" "$JWE"
chmod 400 "$JWE"
shred -u "$TMP"
echo "clevis-reseal: OK"
RESEAL
chmod 700 /usr/local/sbin/clevis-reseal
cat > /etc/kernel/postinst.d/zz-clevis-reseal <<'HOOK'
#!/bin/bash
dracut --force 2>/dev/null || true
/usr/local/sbin/clevis-reseal || echo "clevis-reseal: WARNING, reseal manually"
HOOK
chmod +x /etc/kernel/postinst.d/zz-clevis-reseal

# ---- Password-sync hook (keeps keyslot 0 == login password) ---------------
say "Installing password-sync hook"
cat > /usr/local/sbin/sync-luks-passwd <<'SYNC'
#!/bin/bash
[ -z "$PAM_AUTHTOK" ] && exit 0
[ -z "$PAM_OLDAUTHTOK" ] && exit 0
printf '%s\n%s\n' "$PAM_OLDAUTHTOK" "$PAM_AUTHTOK" | \
  cryptsetup luksChangeKey __DEV__ --key-slot 0 --batch-mode 2>/dev/null \
  && logger -t luks-sync "keyslot 0 synced for $PAM_USER" \
  || logger -t luks-sync "WARN sync failed for $PAM_USER"
SYNC
sed -i "s#__DEV__#$LUKS_DEV#g" /usr/local/sbin/sync-luks-passwd
chmod 700 /usr/local/sbin/sync-luks-passwd; chown root:root /usr/local/sbin/sync-luks-passwd
grep -q sync-luks-passwd /etc/pam.d/common-password || \
  echo "password optional pam_exec.so expose_authtok /usr/local/sbin/sync-luks-passwd" >> /etc/pam.d/common-password

say ""
say "━━━ AUTO-UNLOCK RESTORED ━━━"
say "  A new TPM-sealed keyslot + $JWE were created and verified."
say "  Hooks + PAM wiring reinstalled."
say ""
say "  NEXT — test it cleanly:"
say "    1. Close the manual GNOME mount of the volume (so $LUKS_DEV is free)."
say "    2. REBOOT (a fresh boot is the real test, not just re-login)."
say "    3. After login:  findmnt /home      # expect /dev/mapper/$MAPPER"
say "                     journalctl -t home-crypt -b"
say "    4. Re-run: sudo bash verify-encryption.sh"
say "  Only once that passes, optionally run 07-cleanup-stray-slots.sh"
