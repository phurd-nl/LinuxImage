#!/bin/bash
# The sync script must refuse to delete the recovery slot or the TPM slot.
set -eu
script=$(dirname "$0")/entra-luks-sync.sh
bash -n "$script"
grep -q 'case "$USER_SLOT" in' "$script"
grep -q '1|2)' "$script"
grep -q 'luksKillSlot "$DEV" "$USER_SLOT"' "$script"
grep -q 'open --test-passphrase' "$script"
echo ok
