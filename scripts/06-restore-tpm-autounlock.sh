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
# PCR 7 only — matches 08-harden (firmware/BIOS updates must not lock out).
# Secure Boot ON is still required so PCR 7 is a real trust anchor.
PCR='{"pcr_bank":"sha256","pcr_ids":"7"}'
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
tpm2_pcrread sha256:7 >/dev/null 2>&1 || { echo "ABORT: cannot read TPM PCR 7 (TPM not accessible?)"; exit 1; }
if ! mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
  echo "ABORT: Secure Boot is not enabled. PCR-7 sealing requires SB (see RUNBOOK)."
  exit 1
fi

say "Secure Boot state:"; mokutil --sb-state 2>/dev/null | sed 's/^/    /' || echo "    (unknown)"
say "Sealing against CURRENT PCR 7 (firmware-update-proof; same policy as 08):"
tpm2_pcrread sha256:7 | sed 's/^/    /'
echo
say "NOTE: seal is PCR 7 only. After a Secure Boot key/dbx change, re-run this"
say "      or: sudo clevis-reheal / sudo clevis-reseal"
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

say "Sealing the new key to the TPM (PCR 7) -> $JWE"
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
# Baseline open/close (fail-closed aware). Self-heal is installed by 08 below.
say "Installing login-time open/close hooks (PCR-7; 08 adds self-heal next)"
cat > /usr/local/sbin/home-crypt-open <<'OPEN'
#!/bin/bash
set -e
MNT="/home"
MAP=__MAPPER__
PURGE_DONE=/var/lib/linux-encryption-setup/purge_done
STASH=/dev/shm/.home-crypt-authtok
[ "$PAM_USER" = "__USER__" ] || exit 0
K=$(mktemp -p /dev/shm); chmod 600 "$K"
cleanup(){ shred -u "$K" "$STASH" 2>/dev/null || rm -f "$K" "$STASH"; }
trap cleanup EXIT
if findmnt -M "$MNT" >/dev/null 2>&1; then
  src=$(findmnt -n -o SOURCE --target "$MNT" 2>/dev/null || true)
  [ "$src" = "/dev/mapper/$MAP" ] && exit 0
fi
fail_unlock() {
  logger -t home-crypt "$1 — /home NOT unlocked for $PAM_USER"
  if [ -f "$PURGE_DONE" ]; then
    logger -t home-crypt "FAIL-CLOSED (purge done): denying session — recovery + sudo clevis-reheal"
    exit 1
  fi
  exit 0
}
if ! clevis decrypt < /etc/luks-keyfile.jwe > "$K" 2>/dev/null; then
  fail_unlock "TPM withheld key (PCR mismatch?)"
fi
cryptsetup open --key-file "$K" __DEV__ "$MAP" 2>/dev/null || fail_unlock "cryptsetup open failed"
shred -u "$K" 2>/dev/null || true
if mount "/dev/mapper/$MAP" "$MNT" 2>/dev/null; then
  logger -t home-crypt "/home unlocked for $PAM_USER"
  [ -f "$MNT/swap.img" ] && swapon "$MNT/swap.img" 2>/dev/null && \
    logger -t home-crypt "encrypted swap on"
  exit 0
fi
fail_unlock "mount failed"
OPEN
cat > /usr/local/sbin/home-crypt-close <<'CLOSE'
#!/bin/bash
MNT="/home"
STASH=/dev/shm/.home-crypt-authtok
[ "$PAM_USER" = "__USER__" ] || exit 0
if loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | grep -qx "__USER__"; then
  exit 0
fi
shred -u "$STASH" 2>/dev/null || rm -f "$STASH"
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

PAMF=/etc/pam.d/common-session
OPEN_CTL=optional
[ -f /var/lib/linux-encryption-setup/purge_done ] && OPEN_CTL=required
if grep -q home-crypt-open "$PAMF"; then
  sed -i -E "s|^session[[:space:]]+(optional|required)[[:space:]]+pam_exec\.so[[:space:]]+quiet[[:space:]]+/usr/local/sbin/home-crypt-open|session ${OPEN_CTL} pam_exec.so quiet /usr/local/sbin/home-crypt-open|" "$PAMF"
else
  echo "session ${OPEN_CTL} pam_exec.so quiet /usr/local/sbin/home-crypt-open" >> "$PAMF"
fi
grep -q home-crypt-close "$PAMF" || \
  echo "session optional pam_exec.so quiet /usr/local/sbin/home-crypt-close" >> "$PAMF"

# ---- Kernel-update auto-reseal hook ---------------------------------------
say "Installing kernel-update reseal hook + clevis-reseal helper (PCR 7)"
cat > /usr/local/sbin/clevis-reseal <<'RESEAL'
#!/bin/bash
# Re-seal the LUKS key to the CURRENT PCR 7 (after Secure Boot policy change).
set -e
JWE=/etc/luks-keyfile.jwe
PCR='{"pcr_bank":"sha256","pcr_ids":"7"}'
TMP=$(mktemp -p /dev/shm); chmod 600 "$TMP"
clevis decrypt < "$JWE" > "$TMP" || { echo "reseal: cannot unseal old key (use recovery / clevis-reheal)"; shred -u "$TMP"; exit 1; }
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
[ "$PAM_USER" = "__USER__" ] || exit 0
[ -z "$PAM_AUTHTOK" ] && exit 0
[ -z "$PAM_OLDAUTHTOK" ] && exit 0
printf '%s\n%s\n' "$PAM_OLDAUTHTOK" "$PAM_AUTHTOK" | \
  cryptsetup luksChangeKey __DEV__ --key-slot 0 --batch-mode 2>/dev/null \
  && logger -t luks-sync "keyslot 0 synced for $PAM_USER" \
  || logger -t luks-sync "WARN sync failed for $PAM_USER"
SYNC
sed -i -e "s#__DEV__#$LUKS_DEV#g" -e "s/__USER__/$USERNAME/g" /usr/local/sbin/sync-luks-passwd
chmod 700 /usr/local/sbin/sync-luks-passwd; chown root:root /usr/local/sbin/sync-luks-passwd
grep -q sync-luks-passwd /etc/pam.d/common-password || \
  echo "password optional pam_exec.so expose_authtok /usr/local/sbin/sync-luks-passwd" >> /etc/pam.d/common-password

# Install self-heal + PCR-7 policy helpers. 08 re-wraps the SAME key (no new
# keyslot) and replaces open with the self-heal-aware version. Safe: JWE just
# verified unseals on current PCRs.
here="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$here/08-harden-tpm-pcr7-selfheal.sh" ]; then
  say "Installing self-heal hooks via 08-harden-tpm-pcr7-selfheal.sh"
  # shellcheck disable=SC1091
  if bash "$here/08-harden-tpm-pcr7-selfheal.sh"; then
    say "Self-heal installed."
  else
    echo "WARNING: 08 failed — auto-unlock JWE is OK but self-heal may be missing."
    echo "         Re-run: sudo bash $here/08-harden-tpm-pcr7-selfheal.sh"
  fi
fi

say ""
say "━━━ AUTO-UNLOCK RESTORED ━━━"
say "  A new TPM-sealed keyslot + $JWE were created and verified (PCR 7)."
say "  Hooks + PAM wiring reinstalled (self-heal via 08 when available)."
say ""
say "  NEXT — test it cleanly:"
say "    1. Close the manual GNOME mount of the volume (so $LUKS_DEV is free)."
say "    2. REBOOT (a fresh boot is the real test, not just re-login)."
say "    3. After login:  findmnt /home      # expect /dev/mapper/$MAPPER"
say "                     journalctl -t home-crypt -b"
say "    4. Re-run: sudo bash verify-encryption.sh"
say "  Only once that passes, optionally run 07-cleanup-stray-slots.sh"
