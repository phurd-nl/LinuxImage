#!/bin/bash
# verify-wizard.sh — read-only check that the first-boot wizard is installed and healthy.
# Run: sudo bash scripts/verify-wizard.sh
set -euo pipefail

PORT="${WIZARD_PORT:-8765}"
URL="http://127.0.0.1:${PORT}"
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass+1)); }
no(){ printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }

echo "== 1. systemd service =="
systemctl is-active linux-encryption-wizard.service >/dev/null 2>&1 \
  && ok "linux-encryption-wizard.service active" \
  || no "linux-encryption-wizard.service not active"

echo "== 2. HTTP API =="
curl -sf "$URL/api/health" >/dev/null 2>&1 && ok "GET /api/health" || no "GET /api/health"

echo "== 3. Hardware detection =="
if [ "$(id -u)" -eq 0 ]; then
  DETECT=$(bash "$(dirname "$0")/detect-hardware.sh")
  phase=$(echo "$DETECT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('phase','?'))")
  ok "detect-hardware.sh phase=$phase"
else
  no "run as root for detect-hardware.sh"
fi

echo "== 4. Kiosk autostart =="
[ -f /etc/xdg/autostart/linux-encryption-wizard.desktop ] \
  && ok "autostart desktop entry" || no "autostart desktop entry"
[ -x /usr/local/bin/linux-encryption-wizard-kiosk ] \
  && ok "kiosk launcher" || no "kiosk launcher"

echo "== 5. Install root =="
[ -d /opt/linux-encryption-setup/webgui ] \
  && ok "/opt/linux-encryption-setup present" || no "/opt/linux-encryption-setup missing"

printf '\n  PASS=%d  FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]