#!/bin/bash
# mark-wizard-complete.sh — skip the first-boot wizard on an already-encrypted machine.
# Run: sudo bash scripts/mark-wizard-complete.sh
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Run as root"; exit 1; }
mkdir -p /var/lib/linux-encryption-setup
date -Iseconds > /var/lib/linux-encryption-setup/completed_at
touch /var/lib/linux-encryption-setup/purge_done
echo "Wizard will no longer appear at login."