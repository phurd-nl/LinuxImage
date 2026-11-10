#!/bin/bash
# test-setup-timeshift.sh — contract for image Timeshift setup.
# Dry-run only. Does not install packages or write /etc/timeshift.
#
# Run: bash scripts/test-setup-timeshift.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/setup-timeshift.sh"
fail=0

ok() { printf '  OK   %s\n' "$*"; }
no() { printf '  FAIL %s\n' "$*"; fail=1; }

if [ ! -f "$script" ]; then
  echo "FAIL missing $script"
  exit 1
fi

bash -n "$script" && ok "syntax" || no "syntax"

out="$(bash "$script" --dry-run)"
for line in \
  "timeshift package" \
  "timeshift timer" \
  "snapshots on encrypted /home" \
  "daily keep 2" \
  "skip when /home is locked"
do
  if grep -q "$line" <<<"$out"; then
    ok "$line"
  else
    no "missing: $line"
  fi
done

if bash "$script" --install; then
  no "--install without confirm should fail"
else
  ok "--install without confirm fails"
fi

if bash "$script" --bind; then
  no "--bind without confirm should fail"
else
  ok "--bind without confirm fails"
fi

exit "$fail"
