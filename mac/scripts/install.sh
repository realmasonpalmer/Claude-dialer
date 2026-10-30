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
# Sign with this Mac's own certificate, so macOS remembers permissions across updates.
# Made once by setup-signing.sh; if that can't run, fall back to a temporary signature.
CERT="Clarity Live Coach Signing"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    bash scripts/setup-signing.sh || echo "Couldn't set up the signing certificate. Using a temporary signature."
    if security find-certificate -c "$CERT" >/dev/null 2>&1; then SIGN_IDENTITY="$CERT"; fi
fi
if ! codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"; then
    echo "Signing with the certificate failed. Using a temporary signature."
    codesign --force --sign - "$APP"
fi

# Replace the copy in Applications (quit the old one first).
osascript -e 'quit app "Clarity Live Coach"' >/dev/null 2>&1 || true
sleep 1
rm -rf "/Applications/Clarity Live Coach.app"
cp -R "$APP" /Applications/
open "/Applications/Clarity Live Coach.app"
echo ""
echo "Done. Clarity Live Coach is in your Applications folder and is opening now."
