#!/bin/bash
# One command to install (or reinstall) Clarity Live Coach on a Mac:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/realmasonpalmer/Claude-dialer/claude/confident-gates-ji8r2l/mac/scripts/get.sh)"
set -euo pipefail
REPO="realmasonpalmer/Claude-dialer"
BRANCH="claude/confident-gates-ji8r2l"

echo ""
echo "Installing Clarity Live Coach..."

# 1. Apple's free developer tools (needed to build the app). Installed once.
if ! xcode-select -p >/dev/null 2>&1; then
    echo ""
    echo "First, macOS needs Apple's free Command Line Tools."
    echo "A window will pop up: click Install, then Agree. It takes about 5 to 10 minutes."
    xcode-select --install >/dev/null 2>&1 || true
    until xcode-select -p >/dev/null 2>&1; do sleep 10; done
    echo "Command Line Tools are installed."
fi

# 2. Download the newest version.
WORK="$HOME/Library/Caches/ClarityLiveCoach-get"
rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"
echo "Downloading..."
curl -fsSL -o code.zip "https://github.com/$REPO/archive/refs/heads/$BRANCH.zip"
ditto -x -k code.zip .
cd "$(find . -maxdepth 2 -type d -name mac | head -1)"

# 3. A teammate's setup command carries the team's keys (they're never on GitHub).
#    Leave them for the app: it saves them in the Keychain when it opens, then deletes this copy.
if [ -n "${CLARITY_TEAM_CODE:-}" ]; then
    defaults write io.clarityconsulting.livecoach pendingTeamCode -string "$CLARITY_TEAM_CODE"
    echo "Your team's keys will be added when the app opens."
fi

# 4. Build, put it in Applications and open it.
bash scripts/install.sh

# 5. Tell the in-app updater which version this is, so it doesn't offer the same one again.
SHA="$(curl -fsSL "https://api.github.com/repos/$REPO/commits/$BRANCH" | sed -n 's/^  "sha": "\(.*\)",$/\1/p' | head -1)"
[ -n "$SHA" ] && defaults write io.clarityconsulting.livecoach installedSHA "$SHA"

echo ""
echo "All set. Clarity Live Coach is open. Click the gear, then Setup, and follow the 7 steps."
