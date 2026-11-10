# Clarity Live Coach: architecture and cleanup plan (2026-11-02, updated 2026-11-10)

## Layout after the 2026-11-10 cleanup

- `Coach.swift`: `CoachModel`'s stored properties only, plus `use`/`activate`/`onAppear`. Every job lives in an extension:
  `CoachModel+Lines` (asking Claude, showing and holding lines), `+Leads` (record on screen, status, Next/Back, dial gate),
  `+Call` (tick, start/end, auto redial/next), `+Audio` (capture, Deepgram, words), `+PhoneTree` (menus, bad numbers),
  `+FollowUp` (voicemail, text/LinkedIn card, plan), `+Script` (lines straight from the campaign script).
- `CoachPrompt.swift` (all prompts), `CoachTypes.swift` (`Suggestion`, `Prospect`, `FollowUp`, `Turn`, `StreamBox`, `LiveTranscript`).
- `Prospect` holds the person on screen (name, page text, opener-for, voicemail-for); `meet(_:)` switches person.
- `CoachModel.phase` is the one-word call state (Idle, Getting ready, Dialing, Counting down, On a call...), logged on change.
- `CalledToday` is the one "called today" list for both call lists. `CalledToday.isCallable(id)` is the one "can we call them" rule.
- `Prefs.swift`: every saved setting's name (`PrefKey`) and typed reads (`Prefs`).
- `SalesforceChrome` keeps a background snapshot of the tab's address and title (all AppleScript on one queue);
  `url(live: true)` / `currentRecord(live: true)` read Chrome right now, used only right before dialing or saving page text.
- `ClaudeClient` has `idleTimeout`/`totalTimeout` (live lines: 10 s / 30 s) and `json(system:user:)`.
- `Connections.shared` publishes Salesforce/Aircall connection state so labels update.
- `.github/workflows/build.yml` builds the app on a Mac for every push.


Two read-only reviews (call wiring, and UX/UI) were run on the whole app. This file is the plan. HANDOFF.md has the history.

## How it's wired today

- `CoachModel` (Coach.swift, ~1,900 lines, `@MainActor`) owns almost everything: the call lifecycle, the person on screen, coaching lines, voicemail and follow-ups, status saves, auto-dial and countdowns. A 0.5 s `Timer` runs `tick()`.
- The person on screen is the Chrome tab: `SalesforceTab.currentRecord()` (tab title) and `SalesforceChrome.url()` (record Id), read with AppleScript on the main thread.
- Per-person state is spread across many properties (`calling`, `recordDetails`, `detailsTried`, `voicemailScript/For/Key/UsedDetails`, `personalOpenerFor`, `followUp`, `statusRecordID`, `recordStatus`, `savingStatusFor`, `currentAttemptKey`). Async results check one of these before writing.
- The call state is many flags (`status`, `dialing`, `pendingDialSince`, `waitingForNewCall`, `gettingReady`, `autoNextIn/Name`, `waitingForText`, `hangUpGen`) and several tasks (`readyTask`, `autoNextTask`, `detailsTask`, `voicemailTask`, `coachTask`).
- Saved on the Mac: `DialHistory` (per person: dials, pickups, texts, LinkedIn, bad number), `RemovedList`, `Touchpoints`, `ActivityLog`.

## Fixed in this pass

Call wiring:
- Stale `pendingDialSince` could start a fake call right after hang-up (counted as a failed connect). Cleared in `startCall`; only set if still `.ready`.
- Aircall polling could end live calls at ~8 s. It now only trusts "no call" after the API has listed this call (`aircallSawCall`).
- The auto-dial page loop couldn't be cancelled (Wait didn't stop it; two loops could skip a good person). It's now `readyTask`. A page that never opens shows a message instead of skipping.
- Flip-back to the previous person while the next page loads: `openingID` makes `syncRecord` ignore the old page (and wait up to 3 s for the title); page text is only read if the address still matches.
- Up-next no longer recounts from a page that's still loading.
- Next person's voicemail text could fill the last person's card (and be texted to them): `fillFollowUp` checks `voicemailKey` against the card's key. Text send results only mark the card they came from.
- A late status save can't skip the person now loading. Status saves are per person with a 15 s limit.
- Answered 2nd try no longer waits for a voicemail text. Auto-redial keeps the ready voicemail. Failed voicemails can be retried. `thinking` no longer sticks after voicemail/screener/bad number.
- Mic: fresh `AVAudioEngine` per start; built-in mic falls back to the default mic; listening failures are shown and logged.

UI:
- Help text matches current behavior (3 s countdown, auto redial, text is the cue, Auto-dial checkbox).
- Next's reasons ("open your list", "Chrome setting", "everyone called") show as a line above the buttons, not squeezed into a 120 pt button.
- Stage bar only during a call. Script card says when the Anthropic key is missing.
- Status card: labels wrap, warns "takes them off your list", says to sign in when Salesforce isn't connected, resets per person.
- Follow-up card: "Last call: Name" when it's for someone else; LinkedIn buttons are plain, Send text stays the clear action.
- Settings: duplicate auto-dial toggle removed, Tools in two rows, "Copy help info", confirm before resetting call counts, note shown next to Tools. Setup and Settings sheets fit the 380 pt window. Chrome step only checks off after a list was actually read.
- Back/Cancel from the keys screen and audio check when opened from Setup.
- Dead code removed: status pill, unused sheets/alert/settings in CoachView, `WebLogin`, a duplicate LinkedIn block.

## Next, in order (value vs risk)

1. **One person session** (medium, ~300 lines). `ProspectSession` keyed by the 15-char Salesforce Id: name, details, opener (+ for whom), voicemail, follow-up card, status/saving, attempts (from `DialHistory`; drop the in-memory `attempts`). `@Published var prospect`. Every async result writes through `sessions[id]`. Switching people is one assignment; most "wrong person" bugs become impossible.
2. **Chrome reads off the main thread** (small-medium). One cached AppleScript returning a snapshot (address, title, record Id, Mobile), run on a background thread about once a second and published. Today the tick and the dial gate run 3-5 fresh AppleScripts per beat on the main thread; a busy Chrome can freeze the app.
3. **Timeouts everywhere** (small). One `withTimeout` helper. Claude has none today (add ~10 s to first token, 30 s total).
4. **A call state machine** (medium-large, after #1): `idle → preparing → countdown → dialing → live → ended(outcome) → awaitingText`, one `currentTask` cancelled on every change, every transition logged. Replaces the flags and tasks listed above.
5. **Published "what's connected" state** (small): Salesforce/Aircall connection is read from statics SwiftUI doesn't watch, so some labels stay stale until something else redraws.
6. **Smaller UI**: one banner at a time above the buttons; Touchpoints collapsed to one line between calls; `callingName` on the model instead of parsing quotes in views; a real `sendingText` flag instead of comparing "Sending...".

Don't switch the package to Swift 6 language mode until the audio/Deepgram callbacks and static caches are marked `@Sendable`/`nonisolated`.
