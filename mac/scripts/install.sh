#!/usr/bin/env bash
# Clarity Live Coach has been replaced by Clarity Dialer (dialer/ in this repo).
# Live Coach's own Update button runs this script, so updating Live Coach installs Clarity Dialer,
# closes Live Coach, moves it to the Trash, and opens Clarity Dialer (which imports its logins).
set -euo pipefail
cd "$(dirname "$0")/../../dialer"
bash scripts/install.sh
# Tell Clarity Dialer's updater which version this is, so it doesn't offer the same one again.
SHA="$(curl -fsSL "https://github.com/realmasonpalmer/Claude-dialer/commits/claude/main-update.atom" | grep -oE 'Commit/[0-9a-f]{40}' | head -1 | cut -d/ -f2 || true)"
if [ -n "$SHA" ]; then defaults write io.clarityconsulting.dialer installedSHA "$SHA"; fi
