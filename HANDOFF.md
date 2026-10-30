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

Older, unused parts of the repo: `salesforce/` (an Open CTI dialer) and `server/` (a web coach). Leave them alone unless asked.

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
