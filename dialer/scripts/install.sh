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
# Sign with a certificate that stays the same on this Mac, so macOS remembers permissions
# (control Chrome, microphone, Keychain) across updates. Reuses Live Coach's if it's here.
CERT=""
for NAME in "Clarity Dialer Signing" "Clarity Live Coach Signing"; do
    if security find-certificate -c "$NAME" >/dev/null 2>&1; then CERT="$NAME"; break; fi
done
if [ -z "$CERT" ]; then
    bash scripts/setup-signing.sh "Clarity Dialer Signing" && CERT="Clarity Dialer Signing" || true
fi
if [ -z "$CERT" ] || ! codesign --force --sign "$CERT" "$APP"; then
    echo "Couldn't sign with the certificate; using a temporary signature (permissions may be asked again)."
    codesign --force --sign - "$APP"
fi

osascript -e 'quit app "Clarity Dialer"' >/dev/null 2>&1 || true
sleep 1
rm -rf "/Applications/Clarity Dialer.app"
cp -R "$APP" /Applications/
# Clarity Dialer replaces Clarity Live Coach: close it and move it to the Trash (recoverable).
# Its saved logins and Aircall settings are carried over the first time Clarity Dialer opens.
if [ -d "/Applications/Clarity Live Coach.app" ]; then
    osascript -e 'quit app "Clarity Live Coach"' >/dev/null 2>&1 || true
    sleep 1
    pkill -f "Clarity Live Coach.app/Contents/MacOS" >/dev/null 2>&1 || true
    osascript -e 'tell application "Finder" to delete POSIX file "/Applications/Clarity Live Coach.app"' >/dev/null 2>&1 \
        || mv "/Applications/Clarity Live Coach.app" "$HOME/.Trash/" 2>/dev/null || true
fi
open "/Applications/Clarity Dialer.app"
echo "Done. Clarity Dialer is open. Press Command-comma for Settings."
