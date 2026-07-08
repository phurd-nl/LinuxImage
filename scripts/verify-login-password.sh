#!/bin/bash
# verify-login-password.sh — confirm a password matches the user's login password.
# Uses pamtester (PAM), which works on Python 3.13+ where crypt/spwd were removed.
#
# Usage:
#   echo -n 'password' | bash scripts/verify-login-password.sh USERNAME
#   bash scripts/verify-login-password.sh USERNAME /path/to/password-file
#
# Exit 0 = match, 1 = wrong password, 2 = missing dependency
set -euo pipefail

USER="${1:?username required}"
PASSFILE="${2:-}"

command -v pamtester >/dev/null 2>&1 || {
  echo "ABORT: install pamtester (apt install pamtester)" >&2
  exit 2
}

id "$USER" >/dev/null 2>&1 || { echo "ABORT: user $USER not found" >&2; exit 1; }

if [ -n "$PASSFILE" ]; then
  [ -f "$PASSFILE" ] || { echo "ABORT: password file missing" >&2; exit 1; }
  pamtester login "$USER" authenticate < "$PASSFILE"
else
  pamtester login "$USER" authenticate
fi