#!/bin/bash
# After the first sign-in mounts encrypted /home, remove the plaintext copy.
set -u
STATE=/var/lib/linux-encryption-setup
[ -f "$STATE/completed_at" ] && exit 0
mkdir -p "$STATE"
exec 9>"$STATE/finish.lock"
flock -n 9 || exit 0
bash /opt/linux-encryption-setup/scripts/orchestrate-firstboot.sh
exit 0
