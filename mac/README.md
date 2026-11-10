# Clarity Caller: Mac app source

See the main [README](../README.md) for what the app does, and [HANDOFF.md](../HANDOFF.md)
for the full picture (files, setup state, next tasks).

## Build

- **Fastest install (new teammates):** open Terminal, paste this and press Enter. It installs Apple's free tools if needed, downloads, builds and opens the app:

  ```bash
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/realmasonpalmer/Claude-dialer/claude/confident-gates-ji8r2l/mac/scripts/get.sh)"
  ```

  Then click the gear, then Setup, and follow the 7 steps.
- Needs macOS 14.4+ and Apple's free command line tools (`xcode-select --install`).
- From this folder: `bash scripts/install.sh`. It builds into `~/Library/Caches/ClarityLiveCoach-build`,
  signs with a local certificate (`scripts/setup-signing.sh`, made once so macOS remembers
  permissions across updates), replaces `/Applications/Clarity Caller.app`, and opens it.
- After the first install, updates come from the in-app **Update** button (`Updater.swift`).

## Permissions the app asks for

Microphone, System Audio Recording (to hear the call), control of Google Chrome (to read the
Salesforce tab and click Next/phone numbers; also turn on Chrome's View > Developer >
Allow JavaScript from Apple Events), and the Keychain (saved keys).
