#!/bin/bash
# 08-harden-tpm-pcr7-selfheal.sh — stop firmware updates from breaking auto-unlock.
#
# THE PROBLEM THIS FIXES
#   The TPM key was sealed to PCRs 0,2,4,7. PCR 0 measures the UEFI firmware code
#   itself, so EVERY firmware/BIOS update changes it and the TPM then withholds
#   the key — exactly the lockout you just recovered from.
#
# WHAT THIS SCRIPT DOES (two layers)
#   1. RE-SEAL TO PCR 7 ONLY. PCR 7 measures Secure Boot state + keys, which do
#      NOT change on firmware/BIOS updates. With Secure Boot enforcing signatures
#      this is still a real trust anchor — booting a different/unsigned OS changes
#      PCR 7 and the TPM stays shut. This single change kills the firmware-update
#      lockout for good.
#   2. SELF-HEAL on the rare remaining drift (a Secure Boot key change or a UEFI
#      'dbx' revocation that fwupd pushes can still move PCR 7). On a login where
#      the TPM withholds the key, the auth-stack hook stashes your just-typed
#      LOGIN PASSWORD (= keyslot 0) into root-only tmpfs; the session hook uses it
#      to mint+seal a fresh key to the CURRENT PCR 7, then shreds the stash. Next
#      boot is automatic again — no manual step.
#
# HONEST TRADEOFF
#   * Dropping PCR 0/2/4 means the seal no longer detects firmware tampering. With
#     Secure Boot ON that is an acceptable, standard choice (it is what
#     systemd-cryptenroll defaults to). Your recovery passphrase remains the floor.
#   * Self-heal needs a VALID keyslot-0 passphrase at heal time. If your login
#     password ever drifts from keyslot 0, self-heal logs that and you fall back to:
#     unlock /home manually (recovery phrase) then run:  sudo clevis-reheal
#   * Each self-heal adds one keyslot and orphans the old TPM keyslot (its JWE is
#     gone, so its random key is unrecoverable = harmless). Run 07 occasionally to
#     prune. LUKS2 has 32 slots, so this is a non-issue for many years.
#
# Idempotent. Safe to re-run (re-sealing reuses the SAME key; it does NOT add a
# keyslot). Run while logged in with /home unlocked:
#   sudo bash 08-harden-tpm-pcr7-selfheal.sh
set -euo pipefail

source "$(dirname "$0")/config.sh"
PCR='{"pcr_bank":"sha256","pcr_ids":"7"}'          # firmware-update-proof binding
STASH=/dev/shm/.home-crypt-authtok                  # transient, root-only, drift-only
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
[ -f "$JWE" ] || { echo "ABORT: $JWE missing — run 06 first, then this."; exit 1; }
tpm2_pcrread sha256:7 >/dev/null 2>&1 || { echo "ABORT: cannot read TPM PCR 7"; exit 1; }

say "Current PCR 7 value the key will be sealed against:"
tpm2_pcrread sha256:7 | sed 's/^/    /'
echo

# ---- STEP 1: re-seal the EXISTING key to PCR 7 only ------------------------
# Re-wrap the SAME key (no new keyslot). Requires the current JWE to still unseal,
# which it does right now (you are booted on the PCRs it was sealed to).
say "Re-sealing $JWE from PCR 0,2,4,7 -> PCR 7 only"
TMP=$(mktemp -p /dev/shm); chmod 600 "$TMP"
trap 'shred -u "$TMP" 2>/dev/null || rm -f "$TMP"' EXIT
if ! clevis decrypt < "$JWE" > "$TMP" 2>/dev/null; then
  echo "ABORT: the current JWE does not unseal on today's PCRs."
  echo "       Unlock /home with your recovery passphrase, then run: sudo clevis-reheal"
  exit 1
fi
cryptsetup luksOpen --test-passphrase --key-file "$TMP" "$LUKS_DEV" 2>/dev/null \
  || { echo "ABORT: unsealed key does not open the volume — JWE/keyslot mismatch. Not changing anything."; exit 1; }
clevis encrypt tpm2 "$PCR" < "$TMP" > "$JWE.new"
clevis decrypt < "$JWE.new" | cmp -s - "$TMP" \
  || { echo "ABORT: re-seal verification failed — $JWE left untouched"; rm -f "$JWE.new"; exit 1; }
mv "$JWE.new" "$JWE"; chmod 400 "$JWE"; chown root:root "$JWE"
shred -u "$TMP"; trap - EXIT
say "JWE now sealed to PCR 7 only and verified (unseal matches, key opens volume)."

# ---- STEP 2: clevis-reseal helper now targets PCR 7 ------------------------
say "Updating /usr/local/sbin/clevis-reseal to PCR 7"
cat > /usr/local/sbin/clevis-reseal <<'RESEAL'
#!/bin/bash
# Re-seal the LUKS key to the CURRENT PCR values (used by the kernel-update hook).
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
chmod 700 /usr/local/sbin/clevis-reseal; chown root:root /usr/local/sbin/clevis-reseal

# ---- STEP 3: manual reheal helper (the explicit fallback) ------------------
# Re-seals to current PCRs using ANY passphrase you can type (login OR recovery).
# Use this if hands-off self-heal could not run (e.g. login pw != keyslot 0).
say "Installing /usr/local/sbin/clevis-reheal (manual fallback)"
cat > /usr/local/sbin/clevis-reheal <<'REHEAL'
#!/bin/bash
set -e
DEV=__DEV__
JWE=/etc/luks-keyfile.jwe
PCR='{"pcr_bank":"sha256","pcr_ids":"7"}'
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo clevis-reheal"; exit 1; }
K=$(mktemp -p /dev/shm); chmod 600 "$K"
trap 'shred -u "$K" 2>/dev/null || rm -f "$K"' EXIT
dd if=/dev/urandom bs=64 count=1 of="$K" status=none
echo ">> At the prompt, type a WORKING passphrase (login password or recovery phrase):"
cryptsetup luksAddKey --pbkdf argon2id --pbkdf-memory 524288 --iter-time 3000 "$DEV" "$K"
clevis encrypt tpm2 "$PCR" < "$K" > "$JWE.new"
clevis decrypt < "$JWE.new" | cmp -s - "$K" || { echo "verify failed — $JWE unchanged"; rm -f "$JWE.new"; exit 1; }
mv "$JWE.new" "$JWE"; chmod 400 "$JWE"; chown root:root "$JWE"
echo "clevis-reheal: OK — resealed to current PCR 7. Reboot to confirm auto-unlock."
REHEAL
sed -i "s#__DEV__#$LUKS_DEV#g" /usr/local/sbin/clevis-reheal
chmod 700 /usr/local/sbin/clevis-reheal; chown root:root /usr/local/sbin/clevis-reheal

# ---- STEP 4: auth-stack stash hook (drift-only credential capture) ---------
# Runs on the PAM auth stack with expose_authtok (password arrives on STDIN).
# Only stashes when the TPM is currently withholding the key (= a drift login),
# so on normal logins nothing is written.
say "Installing auth-stack stash hook /usr/local/sbin/home-crypt-stash"
cat > /usr/local/sbin/home-crypt-stash <<'STASH'
#!/bin/bash
[ "$PAM_USER" = "__USER__" ] || exit 0
JWE=/etc/luks-keyfile.jwe
OUT=/dev/shm/.home-crypt-authtok
# No drift -> TPM still releases the key -> nothing to capture.
clevis decrypt < "$JWE" >/dev/null 2>&1 && exit 0
tok=$(cat)                     # expose_authtok feeds the password on stdin
[ -n "$tok" ] || exit 0
( umask 077; printf '%s' "$tok" > "$OUT" )   # NO trailing newline (must match keyslot 0)
# mtime used by open hook for a 60s TTL (stale stash is shredded, never reused)
exit 0
STASH
sed -i "s/__USER__/$USERNAME/g" /usr/local/sbin/home-crypt-stash
chmod 700 /usr/local/sbin/home-crypt-stash; chown root:root /usr/local/sbin/home-crypt-stash

# ---- STEP 5: session open hook, now self-healing ---------------------------
say "Updating session open hook /usr/local/sbin/home-crypt-open (self-heal + fail-closed)"
cat > /usr/local/sbin/home-crypt-open <<'OPEN'
#!/bin/bash
# Unlock encrypted /home. Exit 1 after purge_done if unlock fails (PAM required).
set -e
MNT="/home"
DEV=__DEV__
MAP=__MAPPER__
JWE=/etc/luks-keyfile.jwe
PCR='{"pcr_bank":"sha256","pcr_ids":"7"}'
STASH=/dev/shm/.home-crypt-authtok
PURGE_DONE=/var/lib/linux-encryption-setup/purge_done
STASH_TTL=60
# Any session, including an Entra authd login, opens the same volume.
# Self-heal still uses only the wizard user's stashed password.
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

use_stash=0
if [ -s "$STASH" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$STASH" 2>/dev/null || echo 0) ))
  if [ "$age" -ge 0 ] && [ "$age" -le "$STASH_TTL" ]; then
    use_stash=1
  else
    logger -t home-crypt "self-heal: discarding stale stash (age ${age}s > ${STASH_TTL}s)"
    shred -u "$STASH" 2>/dev/null || rm -f "$STASH"
  fi
fi

if clevis decrypt < "$JWE" > "$K" 2>/dev/null; then
  cryptsetup open --key-file "$K" "$DEV" "$MAP" 2>/dev/null || fail_unlock "cryptsetup open failed"
else
  logger -t home-crypt "TPM withheld key (PCR drift) — attempting self-heal for $PAM_USER"
  if [ "$use_stash" = 1 ]; then
    dd if=/dev/urandom bs=64 count=1 of="$K" status=none
    if cryptsetup luksAddKey --pbkdf argon2id --pbkdf-memory 524288 --iter-time 3000 --key-file "$STASH" "$DEV" "$K" 2>/dev/null; then
      if clevis encrypt tpm2 "$PCR" < "$K" > "$JWE.new" 2>/dev/null && clevis decrypt < "$JWE.new" | cmp -s - "$K"; then
        mv "$JWE.new" "$JWE"; chmod 400 "$JWE"; chown root:root "$JWE"
        logger -t home-crypt "self-heal: resealed key to current PCR 7 — auto-unlock restored"
      else
        rm -f "$JWE.new"; logger -t home-crypt "self-heal: reseal verify failed (JWE unchanged)"
      fi
      cryptsetup open --key-file "$K" "$DEV" "$MAP" 2>/dev/null || fail_unlock "self-heal: cryptsetup open failed"
    else
      fail_unlock "self-heal: luksAddKey failed (login pw != keyslot 0?)"
    fi
  else
    fail_unlock "no fresh stashed credential"
  fi
fi
shred -u "$K" 2>/dev/null || true

if [ -b "/dev/mapper/$MAP" ]; then
  if mount "/dev/mapper/$MAP" "$MNT" 2>/dev/null; then
    logger -t home-crypt "/home unlocked for $PAM_USER"
    [ -f "$MNT/swap.img" ] && swapon "$MNT/swap.img" 2>/dev/null && logger -t home-crypt "encrypted swap on"
    exit 0
  fi
fi
fail_unlock "mount failed"
OPEN
sed -i -e "s/__USER__/$USERNAME/g" -e "s#__DEV__#$LUKS_DEV#g" -e "s/__MAPPER__/$MAPPER/g" \
  /usr/local/sbin/home-crypt-open
chmod 700 /usr/local/sbin/home-crypt-open; chown root:root /usr/local/sbin/home-crypt-open

# Keep close hook's stash shred in sync (idempotent rewrite of stash cleanup only if missing).
if [ -f /usr/local/sbin/home-crypt-close ] && ! grep -q '\.home-crypt-authtok' /usr/local/sbin/home-crypt-close; then
  sed -i '/swapoff/i shred -u /dev/shm/.home-crypt-authtok 2>/dev/null || rm -f /dev/shm/.home-crypt-authtok' \
    /usr/local/sbin/home-crypt-close || true
fi

# ---- STEP 6: wire the stash hook into the PAM auth stack -------------------
# Placed at the end of common-auth so it runs after pam_unix has validated the
# password. 'optional' => a failure here never blocks login.
PAMA=/etc/pam.d/common-auth
if ! grep -q home-crypt-stash "$PAMA"; then
  echo "auth optional pam_exec.so expose_authtok quiet /usr/local/sbin/home-crypt-stash" >> "$PAMA"
  say "Wired home-crypt-stash into $PAMA"
else
  say "home-crypt-stash already wired into $PAMA"
fi

# session: open is required after purge, optional before (plaintext fallback still exists).
PAMS=/etc/pam.d/common-session
PURGE_DONE=/var/lib/linux-encryption-setup/purge_done
OPEN_CTL=optional
[ -f "$PURGE_DONE" ] && OPEN_CTL=required
if grep -q home-crypt-open "$PAMS"; then
  # '#' delimiter: the pattern itself contains '|' in (optional|required).
  sed -i -E "s#^session[[:space:]]+(optional|required)[[:space:]]+pam_exec\.so[[:space:]]+quiet[[:space:]]+/usr/local/sbin/home-crypt-open#session ${OPEN_CTL} pam_exec.so quiet /usr/local/sbin/home-crypt-open#" "$PAMS"
else
  echo "session ${OPEN_CTL} pam_exec.so quiet /usr/local/sbin/home-crypt-open" >> "$PAMS"
fi
if ! grep -qE "^session[[:space:]]+${OPEN_CTL}[[:space:]]+pam_exec\.so.*home-crypt-open" "$PAMS"; then
  sed -i '/home-crypt-open/d' "$PAMS"
  echo "session ${OPEN_CTL} pam_exec.so quiet /usr/local/sbin/home-crypt-open" >> "$PAMS"
fi
grep -q home-crypt-close "$PAMS" || echo "session optional pam_exec.so quiet /usr/local/sbin/home-crypt-close" >> "$PAMS"
say "PAM home-crypt-open control: $OPEN_CTL"

# ---- Done ------------------------------------------------------------------
say ""
say "━━━ HARDENING DONE ━━━"
say "  * Key re-sealed to PCR 7 only  -> firmware/BIOS updates no longer lock you out."
say "  * Self-heal installed          -> a rare PCR 7 drift fixes itself on next login,"
say "                                    using your login password (shredded immediately)."
say "  * Fallbacks intact             -> recovery passphrase, and: sudo clevis-reheal"
say ""
say "  VERIFY NOW:"
say "    sudo bash verify-encryption.sh"
say "  Then REBOOT and confirm:"
say "    sudo bash after-reboot.sh"
say ""
say "  Watch self-heal if it ever triggers:  journalctl -t home-crypt -b"
