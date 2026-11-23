#!/usr/bin/env bash
# Builds Clarity Dialer and installs it as its own app, next to (never over) Clarity Live Coach.
# Run from the dialer folder:  bash scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$HOME/Library/Caches/ClarityDialer-build"
echo "Building Clarity Dialer (1 to 3 minutes)..."
swift build -c release --scratch-path "$WORK"

APP="$WORK/Clarity Dialer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/release/ClarityDialer" "$APP/Contents/MacOS/ClarityDialer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

osascript -e 'quit app "Clarity Dialer"' >/dev/null 2>&1 || true
sleep 1
rm -rf "/Applications/Clarity Dialer.app"
cp -R "$APP" /Applications/
open "/Applications/Clarity Dialer.app"
echo "Done. Clarity Dialer is open. Press Command-comma for Settings."
