#!/usr/bin/env bash
# Builds "Clarity Live Coach.app" into mac/build/.
# Optional: SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" keeps macOS
# permissions across rebuilds. Without it the app is ad-hoc signed and macOS may
# ask for mic and audio permission again after each rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

# Build outside the project folder: macOS can block build files in Downloads or Documents.
SCRATCH="$HOME/Library/Caches/ClarityLiveCoach-build"
swift build -c release --scratch-path "$SCRATCH"

APP="build/Clarity Live Coach.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/release/ClarityLiveCoach" "$APP/Contents/MacOS/ClarityLiveCoach"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built: $(pwd)/$APP"
