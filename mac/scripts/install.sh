#!/usr/bin/env bash
# One command to build Clarity Live Coach, put it in Applications and open it.
# Run it from the mac folder:  bash scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Build outside the project folder: macOS can block build files in Downloads or Documents.
WORK="$HOME/Library/Caches/ClarityLiveCoach-build"
echo "Building. This takes 1 to 3 minutes..."
swift build -c release --scratch-path "$WORK"

APP="$WORK/Clarity Live Coach.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/release/ClarityLiveCoach" "$APP/Contents/MacOS/ClarityLiveCoach"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

# Replace the copy in Applications (quit the old one first).
osascript -e 'quit app "Clarity Live Coach"' >/dev/null 2>&1 || true
sleep 1
rm -rf "/Applications/Clarity Live Coach.app"
cp -R "$APP" /Applications/
open "/Applications/Clarity Live Coach.app"
echo ""
echo "Done. Clarity Live Coach is in your Applications folder and is opening now."
