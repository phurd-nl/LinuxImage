#!/bin/bash
# preview-wizard.sh — run the wizard UI locally (no install, no disk changes).
# Run: bash scripts/preview-wizard.sh
# Then open: http://127.0.0.1:8765
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${WIZARD_PORT:-8765}"
STATE="/tmp/linux-encryption-preview"

fuser -k "${PORT}/tcp" 2>/dev/null || true
mkdir -p "$STATE"

echo "Wizard preview: http://127.0.0.1:${PORT}"
echo "Press Ctrl+C to stop."
echo "(Encrypt button disabled until installed as root on a target VM)"

LINUX_ENCRYPTION_REPO="$REPO" LINUX_ENCRYPTION_STATE="$STATE" \
  WIZARD_PORT="$PORT" exec python3 "$REPO/webgui/server.py"