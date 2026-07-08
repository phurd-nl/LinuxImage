#!/bin/bash
# check.sh — quick post-06 sanity check (read-only). Run: sudo bash scripts/check.sh
echo "=== JWE present ==="
ls -l /etc/luks-keyfile.jwe 2>&1
echo "=== TPM unseals on current PCRs? ==="
if clevis decrypt < /etc/luks-keyfile.jwe >/dev/null 2>&1; then
  echo "YES - TPM releases the key"
else
  echo "NO - seal failed"
fi
echo "=== hooks ==="
ls -l /usr/local/sbin/home-crypt-open /usr/local/sbin/home-crypt-close \
      /usr/local/sbin/clevis-reseal /usr/local/sbin/sync-luks-passwd 2>&1
echo "=== PAM wiring ==="
grep -n home-crypt /etc/pam.d/common-session
