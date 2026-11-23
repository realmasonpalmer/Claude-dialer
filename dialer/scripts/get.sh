#!/bin/bash
# One command to install (or update) the Clarity Dialer test build on a Mac:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/realmasonpalmer/Claude-dialer/claude/dazzling-bohr-812mfr/dialer/scripts/get.sh)"
# Installs "Clarity Dialer" separately from "Clarity Live Coach": different app, settings and keychain.
set -euo pipefail
REPO="realmasonpalmer/Claude-dialer"
BRANCH="${BRANCH:-claude/dazzling-bohr-812mfr}"

if ! xcode-select -p >/dev/null 2>&1; then
    echo "macOS needs Apple's free Command Line Tools. Click Install in the window that pops up."
    xcode-select --install >/dev/null 2>&1 || true
    until xcode-select -p >/dev/null 2>&1; do sleep 10; done
fi

WORK="$HOME/Library/Caches/ClarityDialer-get"
rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"
echo "Downloading Clarity Dialer..."
# Pin to one exact version, so the Update button knows what's installed.
SHA="${SHA:-$(curl -fsSL "https://github.com/$REPO/commits/$BRANCH.atom" | grep -oE 'Commit/[0-9a-f]{40}' | head -1 | cut -d/ -f2)}"
if [ -n "$SHA" ]; then URL="https://github.com/$REPO/archive/$SHA.zip"; else URL="https://github.com/$REPO/archive/refs/heads/$BRANCH.zip"; fi
curl -fsSL -o code.zip "$URL"
ditto -x -k code.zip .
cd "$(find . -maxdepth 2 -type d -name dialer | head -1)"
bash scripts/install.sh
if [ -n "$SHA" ]; then defaults write io.clarityconsulting.dialer installedSHA "$SHA"; fi
echo "Installed version ${SHA:0:7}."
