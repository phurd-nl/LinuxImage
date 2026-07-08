#!/bin/bash
# 02-setup-encryption.sh  — run AFTER Secure Boot is enabled and 01 created p4.
# Encrypts nvme0n1p4, migrates /home into it, seals the unlock key to the TPM,
# and installs the login-time open/close + maintenance hooks.
# DOES NOT delete the original /home — that is step 03, after you verify.
# Run: sudo bash 02-setup-encryption.sh
set -euo pipefail

source "$(dirname "$0")/config.sh"
PCR='{"pcr_bank":"sha256","pcr_ids":"0,2,4,7"}'
LOG=/var/log/luks-setup.log
exec > >(tee -a "$LOG") 2>&1
say(){ echo "[$(date +%T)] $*"; }

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }

# ---- Guards -----------------------------------------------------------------
say "Pre-flight checks"
id "$USERNAME" >/dev/null || { echo "ABORT: user $USERNAME not found"; exit 1; }
[ -b "$LUKS_DEV" ] || { echo "ABORT: $LUKS_DEV missing — run 01-create-partition.sh"; exit 1; }
findmnt -S "$LUKS_DEV" >/dev/null 2>&1 && { echo "ABORT: $LUKS_DEV in use"; exit 1; }

# Refuse to format anything that already has a filesystem/LUKS signature.
if [ -n "$(blkid -o value -s TYPE "$LUKS_DEV" 2>/dev/null || true)" ]; then
  echo "ABORT: $LUKS_DEV already has a signature ($(blkid -o value -s TYPE "$LUKS_DEV")). Refusing to overwrite."
  exit 1
fi

# Secure Boot must be ON (you chose SB-first; PCR 7 depends on it).
if ! mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
  echo "ABORT: Secure Boot is not enabled. Enable it in UEFI first (see RUNBOOK step 1)."
  exit 1
fi

# ---- Packages ---------------------------------------------------------------
say "Installing packages (clevis-tpm2 pulls the correct tss2 libs on 26.04)"
apt-get update -qq
apt-get install -y \
  cryptsetup clevis clevis-luks clevis-tpm2 tpm2-tools \
  aide aide-common dmidecode

tpm2_getcap properties-fixed >/dev/null 2>&1 || { echo "ABORT: TPM 2.0 not accessible"; exit 1; }
say "TPM 2.0 OK, Secure Boot enabled"

# ---- LUKS format + migrate /home ------------------------------------------
say "Formatting $LUKS_DEV (LUKS2, AES-XTS-512)."
if [ "${WIZARD_AUTO:-}" = "1" ]; then
  [ -f "${WIZARD_LOGIN_PW_FILE:-}" ] || { echo "ABORT: WIZARD_LOGIN_PW_FILE missing"; exit 1; }
  say "  -> Using login password from wizard (keyslot 0)"
  cryptsetup luksFormat --type luks2 --batch-mode \
    --cipher aes-xts-plain64 --key-size 512 \
    --hash sha256 --iter-time 3000 \
    "$LUKS_DEV" "${WIZARD_LOGIN_PW_FILE}"
else
  say "  -> At the prompt, enter YOUR LOGIN PASSWORD. It becomes keyslot 0 and is"
  say "     kept in sync with your login password by the password hook below."
  cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 \
    --hash sha256 --iter-time 3000 "$LUKS_DEV"
fi

if [ "${WIZARD_AUTO:-}" = "1" ]; then
  cryptsetup open "$LUKS_DEV" "$MAPPER" --key-file "${WIZARD_LOGIN_PW_FILE}"
else
  cryptsetup open "$LUKS_DEV" "$MAPPER"
fi
mkfs.ext4 -L home "/dev/mapper/$MAPPER"
mount "/dev/mapper/$MAPPER" /mnt
say "Copying /home into the encrypted volume (original is left intact)"
rsync -aHAX --info=progress2 /home/ /mnt/
say "Creating an 8 GiB swapfile INSIDE the encrypted volume (encrypted at rest)"
dd if=/dev/zero of=/mnt/swap.img bs=1M count=8192 status=none
chmod 600 /mnt/swap.img
mkswap /mnt/swap.img >/dev/null
sync
umount /mnt
cryptsetup close "$MAPPER"

# ---- Recovery passphrase (keyslot 1) --------------------------------------
if [ "${WIZARD_AUTO:-}" = "1" ]; then
  [ -f "${WIZARD_RECOVERY_PW_FILE:-}" ] || { echo "ABORT: WIZARD_RECOVERY_PW_FILE missing"; exit 1; }
  say "Adding recovery passphrase from wizard/Ansible (keyslot 1)"
  cryptsetup luksAddKey "$LUKS_DEV" "${WIZARD_RECOVERY_PW_FILE}" --key-file "${WIZARD_LOGIN_PW_FILE}"
else
  say "Add a RECOVERY passphrase now. Store it OFFLINE (printed / password mgr)."
  say "  -> This is your only way in if the TPM is ever cleared."
  cryptsetup luksAddKey "$LUKS_DEV"
fi

# ---- TPM-sealed keyfile (keyslot 1) ---------------------------------------
# The plaintext key NEVER touches disk: it lives in tmpfs, is added to LUKS,
# sealed to the TPM as a JWE blob, then shredded. Only the JWE is stored.
say "Generating key, adding as keyslot, sealing to TPM PCRs 0,2,4,7"
KEY=$(mktemp -p /dev/shm)
chmod 600 "$KEY"
dd if=/dev/urandom bs=64 count=1 of="$KEY" status=none
if [ "${WIZARD_AUTO:-}" = "1" ]; then
  cryptsetup luksAddKey "$LUKS_DEV" "$KEY" --key-file "${WIZARD_LOGIN_PW_FILE}"
else
  cryptsetup luksAddKey "$LUKS_DEV" "$KEY"          # authorise with a passphrase above
fi
clevis encrypt tpm2 "$PCR" < "$KEY" > "$JWE"
chmod 400 "$JWE"; chown root:root "$JWE"
# sanity: TPM can unseal right now
clevis decrypt < "$JWE" | cmp -s - "$KEY" && say "TPM seal verified (unseal matches)" \
  || { echo "ABORT: TPM unseal verification failed"; shred -u "$KEY"; exit 1; }
shred -u "$KEY"

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

# ---- AIDE -----------------------------------------------------------------
say "Configuring AIDE baseline"
if ! grep -q '^!/home' /etc/aide/aide.conf 2>/dev/null; then
cat >> /etc/aide/aide.conf <<'AIDE'
!/var/log
!/var/cache
!/var/lib/apt
!/var/lib/dpkg
!/var/lib/systemd
!/run
!/tmp
!/proc
!/sys
!/home
!/root/.bash_history
AIDE
fi
aideinit -y -f || aideinit
[ -f /var/lib/aide/aide.db.new ] && mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db

# ---- Encrypted swap -------------------------------------------------------
# The swapfile lives INSIDE the encrypted volume (created during migration as
# /mnt/swap.img -> /home/swap.img once mounted). The login open hook runs
# `swapon` only AFTER the volume is unlocked, and the close hook runs `swapoff`
# before unmount — so swap is active only while the volume is open = encrypted
# at rest. Activating it at boot (multi-user.target) would write to plaintext
# /home, which is why the old systemd service was removed.
say "Removing any plaintext swap; encrypted swap is handled by the login hooks"
swapoff -a 2>/dev/null || true
sed -i '/swap/d' /etc/fstab
# No hibernation/suspend-to-disk: a plaintext RAM image must never hit disk.
systemctl mask sleep.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target 2>/dev/null || true

say ""
say "━━━ SETUP DONE (original /home still intact) ━━━"
say "  Keyslot 0: login password   Keyslot 1: recovery passphrase   Keyslot 2: TPM-sealed key"
say "  NOW: reboot, log in, and verify:"
say "    findmnt /home      # should be /dev/mapper/$MAPPER"
say "    sudo journalctl -t home-crypt --since today"
say "  Only after that works across a reboot, run 03-finalize-wipe-old-home.sh"
