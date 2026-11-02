# Clarity Live Coach: handoff (2026-10-30)

Read this first in a new chat. Repo: `realmasonpalmer/claude-dialer`, branch `claude/confident-gates-ji8r2l`.

## Who the user is and how to talk to them

- Mason Palmer, Clarity Consulting (Salesforce + Anthropic partner). Does ~100 cold dials a day; books meetings on Oliver's calendar.
- Write at a 5th-grade reading level, short, for an ADHD brain. No jargon. Plain numbered steps.
- Zero coding experience. Every install/update needs click-by-click steps.
- Prefers buttons, not keyboard shortcuts.
- Wants the most efficient dialer + texter + LinkedIn sender possible, with as little manual work as possible.
- Can't compile here: this cloud session is Linux. All Swift is unverified until Mason builds on his Mac. Say so. If he pastes build errors, fix them first.

## What the product is

A native macOS app, **Clarity Live Coach** (`mac/`, Swift + SwiftUI, macOS 14.4+). A floating window that:
- hears both sides of a call (mic = rep; Core Audio process tap on Chrome or the Aircall desktop app = prospect),
- live transcribes with Deepgram (two streams, so who-said-what is known by source),
- asks Claude for one line to say next plus a short tip,
- works through the rep's Salesforce lead list and dials.

**Scope:** the app coaches and helps work the list. Calls still go through Aircall; leads still live in Salesforce.
Earlier ideas were deleted from the repo on purpose and are out of scope: a Salesforce phone widget (Open CTI + Twilio)
meant to replace Aircall, a Twilio dialer server, and a web-page coach. Don't rebuild them unless Mason asks.

## How Mason installs and updates

- Install: download the branch ZIP from GitHub, unzip, `cd` into the `mac` folder (drag the folder into Terminal), run `bash scripts/install.sh`. It builds into `~/Library/Caches`, signs with a local certificate (`scripts/setup-signing.sh`, made once), copies to /Applications, and opens the app.
- In-app updater (`Updater.swift`): checks GitHub for a new commit on the branch and shows a blue **Update** button between calls. It downloads, builds, and relaunches. Mason may still need one Terminal install to get the version that has this button.
- Keys live in one Keychain item (`Keychain.swift`).

## Main files (mac/Sources/ClarityLiveCoach)

| File | What it does |
| --- | --- |
| `App.swift` | App entry, windows, the audio-check walkthrough (first run) |
| `CoachView.swift` | Main screen: status pill, stage bar, script card, transcript, follow-up card, Back/Call/Redial/Next bar, settings menu, help |
| `Coach.swift` | The coach brain: prompts, Claude calls, line pacing (a line stays until the rep says it), voicemail and screener detection, opener rotation, scoring, double dial, call start/end, lead-list integration |
| `Claude.swift` | Raw HTTPS streaming to the Claude API; speed setting (Opus 5.5 / Sonnet 5.5 / Haiku 5.5) |
| `Deepgram.swift` | Live transcription websocket (nova-3, keyterms) |
| `ProcessTap.swift`, `AudioPipeline.swift`, `CoreAudioHelpers.swift` | Audio capture |
| `Campaign.swift`, `CampaignEditor.swift` | Campaigns (script, goal, sections); Claude sorts a pasted script |
| `Openers.swift` | 5 research-backed openers, Thompson-sampling rotation, scoreboard |
| `CallLab.swift`, `ScriptLabView.swift` | Call scoring + Claude script suggestions |
| `Availability.swift`, `CalendarFeed.swift`, `Calendly.swift` | Booking times (Calendly link `https://calendly.com/clarity_consulting`, or an iCal/Google link); the app picks two times to offer and rotates them when declined |
| `Aircall.swift` | Aircall API: send text (`POST /v1/numbers/:id/messages/native/send {to, body}`, confirmed in Aircall docs), call status (`GET /v1/calls`), start call (`POST /v1/users/:id/calls {number_id, to}`, only works with the Aircall desktop app) |
| `Salesforce.swift`, `LeadQueue.swift` | Optional Salesforce connection (OAuth PKCE via an External Client App, callback `claritylivecoach://oauth/callback`). Reads list views and record details, read-only. |
| `CallList.swift`, `SalesforceTab.swift` | Chrome version: reads the Salesforce tab (shadow-DOM aware, finds the SF tab in any window), learns the list, opens the next lead, clicks the phone number (`lightning-click-to-dial`) so the Aircall panel dials |
| `Screener.swift` | Instant call-screener and voicemail phrase detection |
| `Updater.swift`, `Keychain.swift` | Self-update; secrets |

## Current behavior (latest build)

- Calls end when Aircall says so (API polled every 2 s; two "no call" answers end it), when Chrome lets go, or when the rep clicks **End call**. No silence-based guessing.
- **Double dial:** the first try with no answer or voicemail shows **Redial [name]**; the second try shows **Call [next person]**. First-try voicemail card says "hang up and Redial"; the second try shows the script.
- Voicemail: pre-written per lead, plus a follow-up **text** (Send text via Aircall) and a **LinkedIn note** (opens the profile from the record's LinkedIn field with the note copied). The rep clicks Connect and pastes; LinkedIn's terms forbid automating that click.
- Follow-up texts end with "I'll send you a quick text so you have my number" (no email; no sending domains yet).

## What Mason has set up / confirmed

- Audio check passed (Chrome + headset). Coaching works.
- Deepgram + Anthropic keys saved. Gear menu > Speed (recommended: Best/Opus).
- Calendly connected: `https://calendly.com/clarity_consulting` (Oliver won't share his Google calendar publicly).
- Aircall API keys saved; Mason has API access. Texting endpoint fixed to native/send. **Not yet confirmed that a test text sent successfully.**
- Mason chose: Aircall desktop app = yes; Leads + Contacts; Next = load and dial; double dial with Redial.
- **Not done yet:** Salesforce External Client App + "Connect Salesforce", Aircall desktop app install, "Calls are made as: Mason Palmer" pick in Aircall settings. Offered to create the External Client App via the Salesforce MCP; needs Mason's explicit yes.

## Salesforce org facts (clarityconsultingllc, Enterprise, production)

- Lead LinkedIn field `Linkedin__c`, Contact `LinkedIn__c` (URL). About 82% of open leads have one. Values look like `http://www.linkedin.com/in/...`.
- Aircall logs calls as Tasks owned by the shared **Leadership** user; the person is in `aircall__Made_By__c` (e.g. "Mason Palmer"). Dashboard formulas (`Call_Connect__c`, `Call_Outcome__c`, ...) require `aircall__CallId__c`.
- Shared logins exist (Leadership, Consultant). Mason is not a Salesforce user.

## Done 2026-10-30 (second chat)

- After any voicemail: the follow-up card shows a **Send text** button and an **Open profile + copy note** button. No auto-send (the old toggle is gone; Mason wants buttons). A 2nd-try card keeps what the 1st try already sent, so no double texts.
- After a **2nd-try voicemail**, when the call ends, a bar says "Calling [next] in 5" and counts down, then runs Next. A **Wait** button stops it. Any Redial/Next/Back click cancels it.
- Help text and cues now name buttons, not keyboard shortcuts.

- **Mobile only:** the app never dials or texts the Phone field. In-app list drops anyone with no Mobile or Do Not Call; Contacts with no Mobile and a blank `Relationship_Status__c` get "Not Quality Prospect" (only write the app makes). Open question: what to do with Leads with no Mobile (Leads have no Relationship Status field).
- **Calls start from the app, not Salesforce:** Chrome version reads the Mobile number off the page and calls it through the Aircall API (`startCall`), which rings out in the Aircall desktop app. It only clicks the number in Salesforce if Aircall calling isn't set up. New big **Call [name]** button for the lead open in Salesforce.

- **Aircall phone inside the coach** (`AircallPhone.swift`): a WKWebView with Aircall Workspace (`https://workspace.aircall.io`), signed in once, kept tiny at the bottom of the coach (Show/Hide). Dials go through the REST API `startCall` and ring there. The coach hears it through WebKit helper processes (`AudioProcess.isAppPhone`, matched to this app via `responsibility_get_pid_responsible_for_pid`). Gear > "Aircall phone inside the coach" (on by default). Unverified: whether Aircall Workspace runs in WKWebView, Google sign-in in an embedded view, and whether API dials ring the embedded Workspace. Fallbacks: Aircall desktop app, or turn the toggle off.
- **Double call seen:** with Aircall signed in both in the Salesforce panel and in the coach, one API dial rang out from both. Fix: Mason logs out of the Aircall panel in Salesforce. The app now warns if both are on a call at once.

## Next tasks (Mason said yes to 1 and 2)

1. **After a 2nd-try voicemail:** send the follow-up text automatically, then move on to the next lead when the call ends. (There's already an optional "Send the text by itself" toggle in Aircall settings, off by default because of texting rules; Mason wants less manual work. Keep a way to skip Do Not Call.)
2. **Call from the in-app Salesforce list** (built: `LeadQueue`, `Salesforce.swift`, Call/Redial/Next bar). It needs setup help: the External Client App, Connect Salesforce, the Aircall desktop app, and picking himself in Aircall. Walk him through it, or create the External Client App with permission.
3. Fix any build errors Mason reports (much of the code has never been compiled).
4. Confirm the Aircall test text works; the error messages are plain words now.
5. Earlier idea: always use Opus for pre-written openers and voicemails, even when live replies use a faster model.

## Conventions

- Commit to `claude/confident-gates-ji8r2l` and push. Don't open a PR unless asked.
- End commit messages with the attribution lines given in the session's system reminder.
- Never put API keys in code or chat. Mason once pasted something that looked like a password; it was flagged and not used.

## Done 2026-11-02

- **Fix: "No mobile number" when the number is on the page.** When Salesforce's click-to-dial is off (crossed-out phone icon), the number isn't a clickable link, so the old finder missed it. `SalesforceChrome.mobileNumber()` now also reads `lightning-formatted-phone`, the element's `value` or text, and as a last resort the visible `[field-label="Mobile"]` field's text, then pulls the number out with a regex. Call/Redial no longer say "no mobile number" when the app is just busy dialing.
- **Voicemails always use Haiku** (`CoachSpeed.fastest`), in `prepareVoicemail()` and in `ask(.voicemail, ...)`, whatever the Speed setting is. Mason asked for it so the message is ready fast.
- **Better voicemail catching (straight to VM, redials):**
  - Listens 1 s after dialing from the app (was up to 8 s). While ringing, the quiet-ends-the-call rule waits until call audio has shown up once (`heardCallAudio`) or 45 s.
  - ~45 more voicemail phrases in `Voicemail.strong` (carrier recordings, "record your message", "press pound", forwarded, etc.). "not available right now" phrases are early-only.
  - Long-talk rule `Voicemail.longGreeting`: 18+ prospect words before the rep speaks, early in the call, and not a screener = voicemail.
  - **Voicemail** button in the top bar during a live call (`markVoicemail()`) for when the app misses it.
- **Relationship Status card** (`RelationshipCard` in CoachView, under the follow-up/LinkedIn card): shows when the open record is a Contact (`003` Id). All 11 `Contact.Relationship_Status__c` values as round radio buttons in two columns, plus **Save**. Save PATCHes the Contact via the Salesforce API (`Salesforce.setRelationshipStatus`), so it needs **Sign in to Salesforce** done. "Not Quality Prospect" or "Negative" adds the Id to `RemovedList` (UserDefaults), which both list kinds skip on Next; the API list view load also drops Contacts with those statuses. Leads have no Relationship Status field, so the card doesn't show for Leads (asked Mason if Leads should get Lead Status = Unqualified instead; no answer yet).
- **Leads get the same card with Lead Status** (New, Contacted, Nurturing, Interested, AE Engaged, Qualified, Unqualified). "Unqualified" takes a Lead off the list, like Not Quality Prospect / Negative for Contacts. Code is generic now: `Salesforce.status(of:)`, `setStatus(of:to:)`, `objectFor(id:)` (003 = Contact, 00Q = Lead); Coach `statusRecordID`, `recordStatus`, `saveStatus`.
- **Fix: text stuck on "Sending..."**: `Aircall.sendText` now races the request against a 20 s timer and throws a plain message ("check the Aircall app to see if it went out") so the card never hangs and the button works again. Root cause of the slow reply from Aircall unknown.
- **Touchpoints card** (`Touchpoints.swift`): counts saved on the Mac in `~/Library/Application Support/ClarityLiveCoach/touchpoints.json`, kept 2 years. Period picker: Today / This week / This month / All time. Shows total (calls + texts + LinkedIn), calls, picked up, conversations, voicemails, texts, LinkedIn notes, meetings booked, pickup rate, calls per meeting. Shown between calls; gear menu toggle "Show touchpoints". Logged automatically: dial in `startCall()`; pickup/conversation/voicemail/meeting in `logTouchpoints` at call end (pickup = prospect spoke, not voicemail, not only a screener; conversation = 3+ prospect turns or 45 s+; meeting = coach reached "Goal reached"); text on successful send; LinkedIn once per person on "Open profile + copy note".
- **Salesforce sign-in goes through Chrome** (`ChromeLogin.swift`): opens the OAuth authorize page in Google Chrome (where the shared Salesforce login already lives), listens on `http://localhost:53682/callback` (loopback only, NWListener), shows "Signed in, close this tab", 5 min timeout. Redirect URI is now `http://localhost:53682/callback`, so the External Client App's Callback URL must be that (not `claritylivecoach://oauth/callback`). `WebLogin` is no longer used.
- **Chrome list is the default even when signed in to Salesforce.** The "Pick a list" header only shows if a list view was chosen via gear menu > "Use a Salesforce list instead of Chrome" (with "Go back to my Chrome list" = `LeadQueue.close()`).
- **Auto-skip removed people:** when a record on the call list opens between calls and it's in `RemovedList` or its status (loaded via API) is Not Quality Prospect / Negative / Unqualified, the app moves to the next person without dialing (`skipRemoved`). Records opened by hand that aren't on the list are left alone.
- **Gear menu has 3 items only:** Setup (x of 7 done)..., Settings and tools..., How to use.
  - `SetupView.swift`: one checklist for onboarding: name, AI keys, audio check, Chrome setting, Salesforce, Aircall, booking calendar. Each row opens that step's existing screen; green check when done.
  - `SettingsPane.swift`: speed, toggles, call list (Chrome or a Salesforce list view), reset called today, pause/start listening, Script Lab, scoreboard, debug info, updates.
- **Updater fixes:** the update script now closes the old copy by PID if the polite quit didn't work and opens the new one (likely cause of "stuck on Updating": the old copy stayed open). The app watches the update log and shows "The update didn't finish (reason)" or a 10-minute timeout instead of "Updating" forever.
- **Next call waits for follow-ups:** after a 2nd-try voicemail, if the follow-up card isn't done, `waitingForFollowUp` shows "Send the text and LinkedIn note. The next call starts after." with a "Skip and call next" button. When both are done or the card is closed, the 5 s countdown starts. Starting a call to a different person clears the old person's follow-up card.
- Build note: Mason's Mac uses a Swift 6 compiler (strict actor checks even in Swift 5 mode for some things). Static members of `@MainActor` types used from non-isolated code need `nonisolated`.
- **Per-person call tracking** (`DialHistory.swift`, saved in `~/Library/Application Support/ClarityLiveCoach/dial-history.json`): every dial and pickup per Lead/Contact Id (15-char). Settings > Calling > "Take someone off after" 3 / 4 (default) / 5 calls / Never. Maxed = that many dials and zero pickups: skipped by Next in both list kinds, auto-skipped when opened from the list, and no Redial offered on the last try. Status card header shows "Calls: 2 of 4" or "Calls: 3 · picked up". "Reset everyone's call counts" in Settings. Counts start from this version (earlier calls weren't saved per person).
- **No double follow-ups in a day:** `DialHistory.Person` also stores texts and LinkedIn dates (custom decoder reads older saves). The follow-up card starts with Text / LinkedIn checked if already done today for that person ("Already texted today"); Send text refuses a second send the same day; LinkedIn only counts once per person per day.
- **Window height:** the coach column is pinned to the screen height minus 72 pt (title bar), and the middle (stage bar through touchpoints) scrolls. Top bar and bottom buttons stay fixed.
- **LinkedIn message (3rd follow-up):** Claude also writes `LINKEDIN MESSAGE:` (direct message for people already connected, under 400 chars). Card has a third row "Open profile + copy message". Card is done when the text is sent plus either the note or the message. Tracked per person per day (`DialHistory.linkedInMessages`) and in Touchpoints as "LinkedIn messages" (counts toward total).
- **Hang-up tone stutter:** `stopAudio()` now closes the Deepgram streams right away but removes the Core Audio tap 3 s later (`pendingStop`), so the tap isn't torn down while Aircall plays the hang-up tone. `startAudio()` cancels a pending stop. Unconfirmed fix: ask Mason if the stutter is gone.
- **Script is ready before the phone rings:** `prepareOpener()` first shows an instant opener (the opener template filled with first name, rep name, "Clarity"), then asks Claude for the personal one. Chrome Next sets `calling` from the up-next name before the page loads, so the instant opener has the right name at dial time; `detailsPending` re-reads the page when it loads. Claude's opener won't replace the on-screen one once anyone has spoken on a live call.
- **Crackly call audio:** the process tap's IO block used to convert audio, write files and send to Deepgram on the audio thread of an aggregate device that includes the rep's output device; any overrun crackles the call. Now the IO block only memcpy's the samples into a fresh buffer and hands it to a serial `work` queue. Unconfirmed: ask Mason if the crackle and the hang-up stutter are gone.
- **Right person every time (Chrome mode):** `syncRecord()` (was inline in `tick()`) now also runs inside `callFromPage()` right before every dial, so the opener, voicemail and follow-ups are for the record actually open. The ready-made voicemail is tagged with who it was written for (`voicemailFor`); it's only used/filled into the follow-up card if it matches `calling`, otherwise a fresh one is written. Follow-up phone falls back to reading Mobile off the page. Next uses the opened record's own name (not the cached up-next name).
- **Dial gate (Chrome mode):** `callWhenReady()` won't dial until `readyToDial`: the Salesforce tab shows the same record as `calling`, the page details were read, the voicemail/follow-ups were written for this person from their page (`voicemailFor`, `voicemailUsedDetails`), and Claude's personal opener for them is on screen (`personalOpenerFor`; after 10 s the instant opener is accepted). Used by auto-dial after Next and by the Call button; the button reads "Getting Burcin's script ready..." meanwhile. Gives up after 25 s with a message, never dials the wrong script. Adds ~3-5 s before each dial.
- **Moving on after a call (text is the cue):** after a call with no redial due (2nd-try voicemail, or answered) and a follow-up card, the banner says "Send the text..." (`waitingForText`). Sending the text (or Skip text / closing the card) runs `startNextSequence()`: clears the card, opens the next person in Chrome (`openNextInChrome()`), waits for the dial gate (`readyToDial`), then a 5 s countdown "Calling [name] in 5" with Wait, re-checks, then dials. If the text was already sent today, the sequence starts right when the call ends.
- **Layout:** status card on top, then follow-up card with LinkedIn note, LinkedIn message, and Text last.
- **Auto-dial checkbox** next to "Aircall phone" (same setting as "Next calls right away", key `nextDials`). Off: sending the text only loads the next person.
- **Bad numbers:** `BadNumber.detects` (Screener.swift) spots carrier messages ("not in service", "cannot be completed as dialed", ...), checked before voicemail. The call shows "Bad number. Hang up.", no voicemail/follow-up, `DialHistory.markBadNumber` takes the person off the list (isMaxed), and when the call ends `startNextSequence()` loads the next person and auto-dials (gate + countdown).
- **Didn't connect (silent bad numbers):** in `endCall()`, a call that ends under 12 s after listening started, with no prospect words and no voicemail (and not started by hand), is a failed connect: no redial, no follow-up, `DialHistory.logFailedConnect`, then `startNextSequence()`. Two failed connects = off the list (`isMaxed`). One failure only skips for today, in case it was a network blip.
- **Hang-up tone skip (try 2):** the 3 s tap delay didn't fix it. Now all hang-up work (Chrome reads, next-person loading, `startNextSequence`) waits 2 s via `afterHangUp` (skipped if the rep acts first: `hangUpGen` bumps in `cancelAutoNext`). Still unconfirmed; if it persists, next suspects are the mic capture (AVAudioEngine) holding the input while Aircall releases it, or Bluetooth headset profile switching. Mason hasn't said which headset.
- **Bluetooth fix:** Mason uses Bluetooth headphones. The coach's mic capture (`MicCapture`) now opens the Mac's built-in mic (`builtInMicrophoneID()`) instead of the default input, so Aircall is the only app on the headset mic (two apps on a Bluetooth mic cause profile switching glitches, worst at hang-up). Setting: Settings and tools > Audio > "Coach hears you with the Mac's built-in mic" (key `coachBuiltInMic`, default on). Falls back to the default mic if there's no built-in one.
- **Setup instructions:** every row in Setup has a "How to set this up" dropdown with numbered steps and links (`SetupView.guides`): name, AI keys (Anthropic + Deepgram console steps), audio check and macOS permissions, Chrome Apple Events + Automation permission, Salesforce (existing "Clarity Power Dialer" External Client App, Consumer Key, Chrome sign-in), Aircall (Dashboard > Integrations & API > API Keys, number + user pick, in-app phone sign-in), booking calendar (Calendly link or Google iCal secret address). The first-run keys screen shows the same key steps. Menu names in third-party consoles are from memory: fix if Mason says a step doesn't match.
- **One-command install:** `mac/scripts/get.sh` (installs Command Line Tools if missing and waits, downloads the branch ZIP, runs install.sh, writes installedSHA so the updater doesn't offer the same version). Command is in mac/README.md. Recommended next step: Apple Developer ID ($99/yr) + GitHub Actions building a signed, notarized DMG, so installs/updates need no building.
- **Countdowns are 3 s** (next-person countdown and `startAutoNext`). **Auto redial:** after a 1st-try no answer/voicemail, with Auto-dial on, "Calling [name] again in 3" then `redial()`. Wait cancels.
- **Updates only at the top:** Update button in the top bar (shows "Updating..." while it runs); the Updates section was removed from Settings and tools. The app checks every 2 minutes and whenever it becomes active, using an ETag so GitHub's 304 answers don't use up the 60-requests-an-hour limit.
