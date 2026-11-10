#!/bin/bash
# build.sh — validate and package the LinuxEncryption wizard (no disk changes).
# Safe to run on the dev machine; does NOT encrypt anything or install systemd.
#
# Run: bash scripts/build.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO/build/staging"
ARTIFACT="$REPO/build/linux-encryption-setup.tar.gz"
PORT="${BUILD_TEST_PORT:-18765}"
STATE="/tmp/linux-encryption-build-$$"
PID=""

cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  rm -rf "$STATE"
}
trap cleanup EXIT

pass=0; fail=0
ok(){ printf '  \033[32mOK\033[0m   %s\n' "$*"; pass=$((pass+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

say() { echo ""; echo "== $* =="; }

say "1. Bash syntax"
for s in "$REPO"/scripts/*.sh "$REPO"/imaging/*.sh; do
  bash -n "$s" && ok "$(basename "$s")" || no "$(basename "$s")"
done

say "1b. Image baseline contract"
bash "$REPO/scripts/test-harden-baseline.sh" && ok "harden-image-baseline" || no "harden-image-baseline"
bash "$REPO/scripts/test-setup-timeshift.sh" && ok "setup-timeshift" || no "setup-timeshift"
bash "$REPO/scripts/test-setup-entra-authd.sh" && ok "setup-entra-authd" || no "setup-entra-authd"
bash "$REPO/scripts/test-luks-format.sh" && ok "luks-format" || no "luks-format"
bash "$REPO/imaging/test-seed-password.sh" && ok "seed-password" || no "seed-password"
if grep -q 'ChangeMeOnFirstLogin' "$REPO/imaging/ubuntu-26.04-desktop-autoinstall.yaml"; then
  no "shared password still in autoinstall yaml"
else
  ok "no shared autoinstall password"
fi
grep -q '__TEMP_PASSWORD__' "$REPO/imaging/ubuntu-26.04-desktop-autoinstall.yaml" \
  && ok "temp password placeholder" || no "temp password placeholder"

say "2. Python syntax"
python3 -m py_compile "$REPO/webgui/server.py" "$REPO/webgui/setup_engine.py" \
  && ok "webgui/*.py" || no "webgui/*.py"

say "3. Config + password verify helper"
export CONFIG_SKIP_VALIDATE=1
bash "$REPO/scripts/test-config.sh" >/dev/null && ok "test-config.sh" || no "test-config.sh"
bash -n "$REPO/scripts/verify-login-password.sh" && ok "verify-login-password.sh syntax" || no "verify-login-password.sh syntax"
if command -v pamtester >/dev/null 2>&1; then
  ok "pamtester available"
else
  echo "  note: pamtester not on build host (installed by deploy on target)"
fi

say "4. Static assets"
for f in index.html styles.css app.js; do
  [ -f "$REPO/webgui/static/$f" ] && ok "static/$f" || no "static/$f"
done

say "5. Stage package tree"
rm -rf "$BUILD_DIR"
mkdir -p "$REPO/build"
rsync -a --delete \
  --exclude '.git' --exclude 'build' --exclude 'venv' --exclude '.venv' \
  --exclude '__pycache__' --exclude '.claude' \
  "$REPO/" "$BUILD_DIR/"
chmod +x "$BUILD_DIR"/scripts/*.sh "$BUILD_DIR"/webgui/server.py
tar -czf "$ARTIFACT" -C "$REPO/build" staging
ok "artifact $(basename "$ARTIFACT") ($(du -h "$ARTIFACT" | cut -f1))"

say "6. API smoke test (no root, no disk ops)"
mkdir -p "$STATE"
LINUX_ENCRYPTION_REPO="$BUILD_DIR" LINUX_ENCRYPTION_STATE="$STATE" \
  WIZARD_PORT="$PORT" python3 "$BUILD_DIR/webgui/server.py" &
PID=$!
for i in $(seq 1 20); do
  curl -sf "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1 && break
  sleep 0.2
done
curl -sf "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1 && ok "GET /api/health" || no "GET /api/health"
curl -sf "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && ok "GET /" || no "GET /"
curl -sf "http://127.0.0.1:${PORT}/static/app.js" >/dev/null 2>&1 && ok "GET /static/app.js" || no "GET /static/app.js"
STATUS=$(curl -sf "http://127.0.0.1:${PORT}/api/setup/status" || true)
echo "$STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'hardware' in d" 2>/dev/null \
  && ok "GET /api/setup/status" || no "GET /api/setup/status"
DETECT=$(curl -sf "http://127.0.0.1:${PORT}/api/detect" || true)
echo "$DETECT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('disk','').startswith('/dev/')" 2>/dev/null \
  && ok "GET /api/detect" || no "GET /api/detect"
# Wrong password must fail cleanly (not 500)
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:${PORT}/api/setup/start" \
  -H "Content-Type: application/json" -d '{"password":"definitely-wrong-build-test"}')
[ "$CODE" = "400" ] && ok "POST /api/setup/start rejects bad password" || no "POST /api/setup/start (got HTTP $CODE, want 400)"
# Temp-password flow: short new_password must be rejected server-side
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:${PORT}/api/setup/start" \
  -H "Content-Type: application/json" -d '{"password":"temp-pw-test","new_password":"short"}')
[ "$CODE" = "400" ] && ok "POST /api/setup/start rejects short new_password" || no "POST new_password (got HTTP $CODE, want 400)"
kill "$PID" 2>/dev/null; PID=""; wait 2>/dev/null || true

say "SUMMARY"
printf '  PASS=%d  FAIL=%d\n' "$pass" "$fail"
echo "  Artifact: $ARTIFACT"
echo ""
if [ "$fail" -eq 0 ]; then
  echo "BUILD OK — deploy with:"
  echo "  sudo tar -xzf build/linux-encryption-setup.tar.gz -C /opt && sudo mv /opt/staging /opt/linux-encryption-setup"
  echo "  sudo bash /opt/linux-encryption-setup/scripts/install-setup-wizard.sh"
  echo "  # Golden image (template VM only): sudo bash scripts/prepare-ubuntu-image.sh"
  exit 0
fi
echo "BUILD FAILED"
exit 1