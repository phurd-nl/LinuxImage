#!/bin/bash
# after-reboot.sh — confirm /home auto-unlocked on this boot. Read-only.
# Run after rebooting + logging in:  sudo bash scripts/after-reboot.sh
source "$(dirname "$0")/config.sh"
echo "=== where is /home mounted from? ==="
findmnt /home || echo "(/home is NOT a separate mount -> still plaintext, hook did not fire)"
echo
echo "=== home-crypt journal for THIS boot ==="
journalctl -t home-crypt -b --no-pager 2>&1 || echo "(no entries)"
echo
src=$(findmnt -no SOURCE /home 2>/dev/null || true)
if [ "$src" = "/dev/mapper/$MAPPER" ]; then
  echo ">>> SUCCESS: /home is the encrypted volume. Auto-unlock is working."
else
  echo ">>> NOT YET: /home source is '${src:-none}'. Paste this output to debug."
fi
