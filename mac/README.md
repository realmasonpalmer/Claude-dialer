# Clarity Live Coach: Mac app source

See the main [README](../README.md) for what the app does, and [HANDOFF.md](../HANDOFF.md)
for the full picture (files, setup state, next tasks).

## Build

- Needs macOS 14.4+ and Apple's free command line tools (`xcode-select --install`).
- From this folder: `bash scripts/install.sh`. It builds into `~/Library/Caches/ClarityLiveCoach-build`,
  signs with a local certificate (`scripts/setup-signing.sh`, made once so macOS remembers
  permissions across updates), replaces `/Applications/Clarity Live Coach.app`, and opens it.
- After the first install, updates come from the in-app **Update** button (`Updater.swift`).

## Permissions the app asks for

Microphone, System Audio Recording (to hear the call), control of Google Chrome (to read the
Salesforce tab and click Next/phone numbers; also turn on Chrome's View > Developer >
Allow JavaScript from Apple Events), and the Keychain (saved keys).
