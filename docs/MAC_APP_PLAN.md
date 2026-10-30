# Clarity Live Coach for Mac: plan

Written 2026-10-30. Prices change. Check vendor pages before quoting.

## 1. Recommended architecture: native Swift + SwiftUI

| Option | Verdict |
| --- | --- |
| **Swift + SwiftUI (pick)** | Hearing Chrome's call audio needs Apple's Core Audio "process tap" API. Swift calls it directly. Small app, low CPU and memory, Keychain built in, easy always-on-top window. |
| Electron | ~150 MB app and heavy on memory. It would still need a Swift add-on for the call audio. |
| Tauri | Lighter than Electron, but still needs a native add-on for audio. Two languages for no gain. |

**No backend server.** The app talks straight to the speech-to-text service and to Claude.
Keys live in the Mac Keychain. Campaigns are saved as local files.

The earlier web Call Coach (`server/`) stays as a backup for one-mic speakerphone use.

## 2. Hearing both sides of an Aircall call in Chrome

- **Your side:** your microphone, through Apple's standard audio engine.
- **Prospect's side:** a Core Audio **process tap** on Google Chrome (macOS 14.4+). It copies the sound Chrome plays,
  before it reaches your headset. So it works with Bluetooth, USB and wired headsets, and you still hear the call normally.
- **No virtual audio driver** (like BlackHole) and **no Chrome extension** needed.
- **Who said what is solved by design.** Mic = you, Chrome = prospect. No guessing from voices.
- **Call detection:** Core Audio reports when Chrome is using the mic *and* playing sound at the same time.
  That only happens during a live call, so it's a strong signal. Mic activity alone isn't treated as a call.

Things we must confirm in the audio check (not assumed):
1. Aircall's call audio really plays from Chrome, and not from the Aircall desktop app. The app has a picker in case it doesn't.
2. Chrome's mic plus speaker signal turns on and off cleanly with calls.
3. Bluetooth headsets: macOS drops to call-quality audio when the mic is in use. Fine for transcription, but we'll check it.
4. With laptop speakers instead of a headset, your mic also hears the prospect. Plan: use a headset, or drop
   mic words that overlap with prospect speech.

## 3. What you need to do (setup)

1. **macOS 14.4 or newer.** Check Apple menu > About This Mac.
2. **Xcode Command Line Tools**: run `xcode-select --install` in Terminal.
3. **Permissions** (the app asks the first time):
   - Microphone
   - System Audio Recording (System Settings > Privacy & Security > Screen & System Audio Recording)
4. **A teammate to test with**, who knows the call is a test.
5. Later, for transcription and coaching:
   - A Deepgram API key
   - An Anthropic API key from console.anthropic.com

**Best way to build:** run Claude Code on your Mac, in this repo. I'm in a Linux cloud container,
so I can write the Mac code but can't compile or run it. On your Mac, Claude Code can build, read
errors and fix them in seconds.

## 4. Costs

**Claude Pro vs the API.** Your Pro plan covers you using Claude and Claude Code. It does not pay for the app's
calls to Claude. The app needs an API key from console.anthropic.com, billed separately, pay as you go.

One rep, 100 dials a day. Only call minutes are streamed (about 115 a day, about 75 of them talking).

| Item | Price (verify) | Per rep per month (21 days) |
| --- | --- | --- |
| Deepgram Nova-3 streaming, 2 channels (you + prospect) | ~$0.0077 per minute per channel | ~$37 |
| Claude, Opus 5.5 (best quality) | $4 in / $20 out per million tokens, $0.20 cached | ~$40 to $60 |
| Claude, Sonnet 5.5 | $2 / $10 | ~$20 to $30 |
| Claude, Haiku 5.5 (fastest) | $0.10 / $0.50 | ~$1 to $2 |
| Hosting | none | $0 |

The Claude estimate assumes about 10 coaching requests per connected call and 25 connected calls a day.
We'll replace the estimates with measured numbers in Phase 7.

Ways to cut cost: send only the latest turns plus a small "call state" note (not the whole transcript),
cache the campaign instructions, and stream only while a call is detected.

## 5. Milestones

| # | Milestone | Done when |
| --- | --- | --- |
| 1 | **Audio check** (built, needs your test) | You and the prospect show as two separate streams in a real Aircall test call |
| 2 | Live transcription | Live words for both sides, labeled You and Prospect, measured delay |
| 3 | Claude coaching | One line and one tip, measured from when they stop talking to when you see words |
| 4 | Campaigns | Paste a script, edit it in structured fields, saved on your Mac, coaching follows the campaign's goal |
| 5 | Floating coach window | Big line, small tip, stage, latest prospect statement, pause and reset |
| 6 | Automatic start and reset | Coaching starts when a call connects and clears when it ends |
| 7 | Tuning | 15 test scenarios pass, latency and cost measured |
| 8 | Pilot | Real permitted calls. Does it feel easier? Do more calls turn productive? |

## 6. Privacy and consent

- Nothing is recorded by default. The Phase 1 test recording is manual, local and deletable.
- Transcripts stay in memory and are cleared at the end of every call.
- About a dozen US states need everyone on the call to agree before it's transcribed.
  The rep needs a consent line, and the app will show a reminder at call start.
- API keys go in the Keychain. They never go in logs or files.
