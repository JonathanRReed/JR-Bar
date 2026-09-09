#!/bin/zsh
# Restarts the built app: kills any running JR-Bar.app and opens the fresh one.
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$APP_DIR/build/JR-Bar.app"
[[ -d "$BUNDLE" ]] || "$APP_DIR/scripts/build-app.sh"
pkill -x "JR-Bar" 2>/dev/null || true
sleep 0.3
open "$BUNDLE"
echo "launched $BUNDLE"
