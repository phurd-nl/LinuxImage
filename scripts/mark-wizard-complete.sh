#!/bin/bash
# mark-wizard-complete.sh — skip the first-boot wizard on an already-encrypted machine.
# Refuses to mark complete unless /home is actually the encrypted mapper (or
# FORCE=1 for break-glass imaging). Run: sudo bash scripts/mark-wizard-complete.sh
set -euo pipefail

source "$(dirname "$0")/config.sh"

[ "$EUID" -eq 0 ] || { echo "Run as root"; exit 1; }

STATE_DIR=/var/lib/linux-encryption-setup
src=$(findmnt -n -o SOURCE --target /home 2>/dev/null || true)
jwe_ok=0
[ -f /etc/luks-keyfile.jwe ] && jwe_ok=1

if [ "${FORCE:-}" != "1" ]; then
  if [ "$src" != "/dev/mapper/$MAPPER" ]; then
    echo "ABORT: /home is not /dev/mapper/$MAPPER (source: ${src:-none})."
    echo "       This machine does not look encrypted. Refusing to skip the wizard."
    echo "       To override (imaging only): FORCE=1 sudo bash $0"
    exit 1
  fi
  if [ "$jwe_ok" != 1 ]; then
    echo "ABORT: /etc/luks-keyfile.jwe missing — encryption setup not complete."
    echo "       To override (imaging only): FORCE=1 sudo bash $0"
    exit 1
  fi
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
date -Iseconds > "$STATE_DIR/completed_at"
touch "$STATE_DIR/purge_done"
echo "Wizard will no longer appear at login."
echo "  /home source: ${src:-unknown}"
echo "  JWE present:  $jwe_ok"
