#!/bin/bash
# orchestrate-firstboot.sh — unattended, guarded encryption pipeline for Ubuntu.
# Called ONLY by the setup wizard API (runs as root). Uses password files in
# tmpfs — never logs passphrases.
set -euo pipefail

here="$(dirname "$0")"
LOG=/var/log/luks-wizard-orchestrate.log
STATE_DIR=/var/lib/linux-encryption-setup
PROGRESS="$STATE_DIR/orchestrate.progress"
LOGIN_FILE="${WIZARD_LOGIN_PW_FILE:-}"
RECOVERY_FILE="${WIZARD_RECOVERY_PW_FILE:-}"

exec > >(tee -a "$LOG") 2>&1
say(){ echo "[$(date +%T)] $*"; }

on_err() {
  write_progress "error" "Setup failed — see $LOG" 0
}
trap on_err ERR

[ "$EUID" -eq 0 ] || { echo "ABORT: root required"; exit 1; }

write_progress() { # phase message [pct]
  mkdir -p "$STATE_DIR"
  python3 -c 'import json,sys; print(json.dumps({"phase":sys.argv[1],"message":sys.argv[2],"pct":int(sys.argv[3]),"ts":sys.argv[4]}))' \
    "$1" "$2" "${3:-0}" "$(date -Iseconds)" > "$PROGRESS"
}

# ---- Auto-detect ----------------------------------------------------------------
say "Detecting hardware"
DETECT=$(bash "$here/detect-hardware.sh")
DISK=$(echo "$DETECT" | python3 -c "import json,sys; print(json.load(sys.stdin)['disk'])")
PARTNUM=$(echo "$DETECT" | python3 -c "import json,sys; print(json.load(sys.stdin)['partnum'])")
USERNAME=$(echo "$DETECT" | python3 -c "import json,sys; print(json.load(sys.stdin)['username'])")
MAPPER=$(echo "$DETECT" | python3 -c "import json,sys; print(json.load(sys.stdin)['mapper'])")
PHASE=$(echo "$DETECT" | python3 -c "import json,sys; print(json.load(sys.stdin)['phase'])")
READY=$(echo "$DETECT" | python3 -c "import json,sys; print(json.load(sys.stdin)['ready'])")

export DISK PARTNUM USERNAME MAPPER
source "$here/config.sh"

[ "${WIZARD_PHASE:-}" != "" ] && PHASE="$WIZARD_PHASE"
say "Phase=$PHASE device=$LUKS_DEV disk=$DISK user=$USERNAME"

# Only gate fresh installs on full pre-flight
case "$PHASE" in
  needs_partition|needs_encrypt|needs_encrypt_hooks)
    [ "$READY" = "True" ] || [ "$READY" = "true" ] || {
      echo "$DETECT" | python3 -c "import json,sys; d=json.load(sys.stdin); print('ABORT:', '; '.join(d.get('blockers',[])))"
      write_progress "error" "Pre-flight checks failed" 0
      exit 1
    }
    ;;
  needs_reboot)
    write_progress "reboot" "Restart required — encrypted /home unlocks at next login" 70
    say "Waiting for user reboot"
    exit 0
    ;;
  complete)
    write_progress "done" "Setup complete" 100
    date -Iseconds > "$STATE_DIR/completed_at"
    exit 0
    ;;
esac

needs_pw=false
case "$PHASE" in
  needs_partition|needs_encrypt|needs_encrypt_hooks) needs_pw=true ;;
esac

if [ "$needs_pw" = true ]; then
  [ -f "$LOGIN_FILE" ] || { write_progress "error" "Internal error: login password file missing" 0; exit 1; }
  [ -f "$RECOVERY_FILE" ] || { write_progress "error" "Internal error: recovery password file missing" 0; exit 1; }
  chmod 600 "$LOGIN_FILE" "$RECOVERY_FILE"
  say "Verifying login password for $USERNAME"
  bash "$here/verify-login-password.sh" "$USERNAME" "$LOGIN_FILE" \
    || { write_progress "error" "Login password verification failed" 0; exit 1; }
fi

# ---- Partition ------------------------------------------------------------------
if [ "$PHASE" = "needs_partition" ]; then
  write_progress "partition" "Creating encrypted home partition…" 15
  WIZARD_AUTO=1 bash "$here/01-create-partition.sh"
  PHASE="needs_encrypt"
fi

# ---- Encrypt --------------------------------------------------------------------
if [ "$PHASE" = "needs_encrypt" ] || [ "$PHASE" = "needs_encrypt_hooks" ]; then
  write_progress "encrypt" "Encrypting /home and sealing to TPM…" 40
  WIZARD_AUTO=1 WIZARD_LOGIN_PW_FILE="$LOGIN_FILE" WIZARD_RECOVERY_PW_FILE="$RECOVERY_FILE" \
    bash "$here/02-setup-encryption.sh"
  write_progress "reboot" "Encryption installed — restart to continue" 70
  say "Pausing for reboot"
  exit 0
fi

# ---- Post-reboot: verify + harden ------------------------------------------------
if [ "$PHASE" = "needs_harden" ]; then
  write_progress "verify" "Verifying encrypted /home…" 75
  bash "$here/after-reboot.sh" || true
  if ! bash "$here/verify-encryption.sh"; then
    write_progress "error" "Verification failed — see $LOG" 0
    exit 1
  fi
  write_progress "harden" "Hardening TPM seal (PCR 7)…" 85
  WIZARD_AUTO=1 bash "$here/08-harden-tpm-pcr7-selfheal.sh"
  PHASE="needs_purge"
fi

# ---- Purge plaintext shadow -----------------------------------------------------
if [ "$PHASE" = "needs_purge" ]; then
  write_progress "purge" "Removing old plaintext /home copy…" 92
  WIZARD_AUTO=1 bash "$here/04-purge-shadowed-plaintext-home.sh"
  date -Iseconds > "$STATE_DIR/purge_done"
  write_progress "done" "Setup complete" 100
  date -Iseconds > "$STATE_DIR/completed_at"
  say "━━━ FIRST-BOOT SETUP COMPLETE ━━━"
fi

# Shred password files
[ -f "$LOGIN_FILE" ] && shred -u "$LOGIN_FILE" 2>/dev/null || rm -f "$LOGIN_FILE"
[ -f "$RECOVERY_FILE" ] && shred -u "$RECOVERY_FILE" 2>/dev/null || rm -f "$RECOVERY_FILE"
# Remove tmpfs parent if empty
rmdir "$(dirname "$LOGIN_FILE")" 2>/dev/null || true