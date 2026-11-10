#!/bin/bash
# Make the encrypted /home passphrase match the password just used to sign in.
# A failure here must not block login. The password is never written to the log.
# Slot 1 is the recovery passphrase. Slot 2 is the TPM key. Neither is removed.
set -u
STATE=/var/lib/linux-encryption-setup
DEV_FILE=$STATE/luks.dev
SLOT_FILE=$STATE/user-slot
INSTALL_KEY=$STATE/install.key
JWE=/etc/luks-keyfile.jwe

[ -f "$DEV_FILE" ] || exit 0
DEV=$(tr -d '\r\n' < "$DEV_FILE")
[ -b "$DEV" ] || exit 0

if [ -n "${PAM_AUTHTOK:-}" ]; then
  NEW=$PAM_AUTHTOK
else
  NEW=$(cat 2>/dev/null || true)
fi
[ -n "${NEW:-}" ] || exit 0

opens() {
  printf '%s' "$1" | cryptsetup open --test-passphrase "$DEV" >/dev/null 2>&1
}

if opens "$NEW"; then
  exit 0
fi

NEWF=$(mktemp -p /dev/shm)
AUTH=$(mktemp -p /dev/shm)
chmod 600 "$NEWF" "$AUTH"
printf '%s' "$NEW" > "$NEWF"
cleanup() { shred -u "$NEWF" "$AUTH" 2>/dev/null || rm -f "$NEWF" "$AUTH"; }
trap cleanup EXIT

if [ -n "${PAM_OLDAUTHTOK:-}" ] && opens "$PAM_OLDAUTHTOK"; then
  OLDF=$(mktemp -p /dev/shm)
  chmod 600 "$OLDF"
  printf '%s' "$PAM_OLDAUTHTOK" > "$OLDF"
  if cryptsetup luksChangeKey "$DEV" --key-file "$OLDF" "$NEWF" >/dev/null 2>&1; then
    shred -u "$OLDF" 2>/dev/null || rm -f "$OLDF"
    logger -t luks-sync "passphrase updated for ${PAM_USER:-unknown}"
    exit 0
  fi
  shred -u "$OLDF" 2>/dev/null || rm -f "$OLDF"
fi

if [ -f "$INSTALL_KEY" ] && cryptsetup open --test-passphrase --key-file "$INSTALL_KEY" "$DEV" >/dev/null 2>&1; then
  cp "$INSTALL_KEY" "$AUTH"
elif [ -f "$JWE" ] && clevis decrypt < "$JWE" > "$AUTH" 2>/dev/null; then
  :
else
  logger -t luks-sync "no way to authorize a passphrase change"
  exit 0
fi

USER_SLOT=0
if [ -f "$SLOT_FILE" ]; then
  USER_SLOT=$(tr -d '\r\n' < "$SLOT_FILE")
fi
case "$USER_SLOT" in
  1|2)
    logger -t luks-sync "refusing to replace protected slot $USER_SLOT"
    exit 0
    ;;
esac

NEW_SLOT=""
for s in 0 3 4 5 6 7; do
  [ "$s" = "$USER_SLOT" ] && continue
  if cryptsetup luksAddKey --key-slot "$s" --key-file "$AUTH" "$DEV" "$NEWF" >/dev/null 2>&1; then
    NEW_SLOT=$s
    break
  fi
done
if [ -z "$NEW_SLOT" ]; then
  logger -t luks-sync "could not add the signed-in passphrase"
  exit 0
fi
if ! opens "$NEW"; then
  cryptsetup luksKillSlot "$DEV" "$NEW_SLOT" --key-file "$AUTH" >/dev/null 2>&1 || true
  logger -t luks-sync "new passphrase did not open the volume; change rolled back"
  exit 0
fi
cryptsetup luksKillSlot "$DEV" "$USER_SLOT" --key-file "$NEWF" >/dev/null 2>&1 || \
  logger -t luks-sync "previous passphrase slot $USER_SLOT was left in place"
printf '%s\n' "$NEW_SLOT" > "$SLOT_FILE"
chmod 400 "$SLOT_FILE"
if [ -f "$INSTALL_KEY" ]; then
  shred -u "$INSTALL_KEY" 2>/dev/null || rm -f "$INSTALL_KEY"
fi
logger -t luks-sync "encrypted home passphrase now matches the signed-in password"
exit 0
