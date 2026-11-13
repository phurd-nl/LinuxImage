#!/bin/bash
# test-setup-entra-authd.sh — contract for Entra login on the image.
# Dry-run only. Does not install authd or contact Microsoft.
#
# Run: bash scripts/test-setup-entra-authd.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/setup-entra-authd.sh"
fail=0
tenant=11111111-1111-1111-1111-111111111111
client=22222222-2222-2222-2222-222222222222

ok() { printf '  OK   %s\n' "$*"; }
no() { printf '  FAIL %s\n' "$*"; fail=1; }

if [ ! -f "$script" ]; then
  echo "FAIL missing $script"
  exit 1
fi

bash -n "$script" && ok "syntax" || no "syntax"

if ENTRA_TENANT_ID="$tenant" ENTRA_CLIENT_ID="$client" bash "$script"; then
  no "missing mode should fail"
else
  ok "missing mode fails"
fi

if bash "$script" --dry-run; then
  no "dry-run without ids should fail"
else
  ok "dry-run without ids fails"
fi

out="$(ENTRA_TENANT_ID="$tenant" ENTRA_CLIENT_ID="$client" bash "$script" --dry-run)"
for line in \
  "authd package" \
  "authd-msentraid snap" \
  "entra password login" \
  "allow every Entra user" \
  "do not lock the first login as owner" \
  "device registers on the imaging login" \
  "offline local password" \
  "disk unlock stays the wizard password" \
  "login screen asks for the Entra name" \
  "hide the imaging account"
do
  if grep -q "$line" <<<"$out"; then
    ok "$line"
  else
    no "missing: $line"
  fi
done

if grep -q 'NL_ALLOWED="ALL"' "$script" && grep -q "NL_OWNER='\"\"'" "$script"; then
  ok "fleet access is in the apply path"
else
  no "apply path missing allowed_users or empty owner"
fi

if grep -q 'banner-message-' "$script"; then
  ok "entra setup keeps the welcome line"
else
  no "entra setup drops the welcome line"
fi

if ENTRA_TENANT_ID="$tenant" ENTRA_CLIENT_ID="$client" bash "$script" --apply; then
  no "--apply without confirm should fail"
else
  ok "--apply without confirm fails"
fi

for f in 02-setup-encryption.sh 06-restore-tpm-autounlock.sh 08-harden-tpm-pcr7-selfheal.sh; do
  if awk '/home-crypt-open <<.OPEN./,/^OPEN$/' "$here/$f" | grep -q 'PAM_USER.*=.*__USER__'; then
    no "$f open hook still limited to one user"
  else
    ok "$f opens /home for any session"
  fi
done

if grep -q 'systemctl restart gdm' "$script" && grep -q 'loginctl list-sessions' "$script"; then
  ok "login screen restarts after Entra installs when nobody is signed in"
else
  no "login screen keeps its old broker list after Entra installs"
fi

exit "$fail"
