# Clarity Dialer: first-principles refactor

## What the app actually is

Strip away the coach and Clarity is a **power dialer**:

1. Pick a Salesforce list view.
2. Work it top to bottom: show the person, show the script, dial them through Aircall.
3. When the call ends, record what happened (outcome, status, note) back to Salesforce.
4. Apply the outbound rules (call twice, voicemail drop, follow-up text, time zones, mobile only, cadence) without being asked.
5. Go to the next person.

Everything else in today's 25,000 lines either serves the live coach or works around the
fact that the app learns who is on screen by **scraping Chrome with AppleScript**.

## Why it's spaghetti today

| Root cause | Symptom |
|---|---|
| Live coaching (Deepgram, Claude, mic + system-audio taps, turn-taking, THINK/SAY lines) | `CoachCore` (1,341 lines), `CoachModel+Lines` (1,178), `+Audio`, `ProcessTap`, `BeepDetector`, `LiveCoach`, `CoachPrompt`, `Guardrail`, 30 test files of call replays |
| Chrome is the source of truth for "who's next" | `SalesforceTab`, `SalesforceChrome`, `ChromeLogin`, `ChromeGuide`, `openingID` races, `syncRecord`, "wrong person" bugs, main-thread freezes |
| Call state is ~10 flags + 5 tasks + a 0.5 s timer | `tick()`, `pendingDialSince`, `waitingForNewCall`, `autoNextTask`, `hangUpGen`... (the existing ARCHITECTURE.md lists these as the #1 and #4 fixes) |
| One god object | `CoachModel` and its 7 extensions; `CoachView` is 2,266 lines |
| Many small local stores of the same fact | `DialHistory`, `CallHistory`, `CalledToday`, `Touchpoints`, `ActivityLog`, `CallAttemptStore`, `PickedUpSync`, `RemovedList` |
| Features that drifted in | LinkedIn bot, Calendly/calendar booking, local lunch, Script Lab, Call Lab, call library, opener scoring, daily goals, tour, bug reporter |

## The new shape

Three ideas remove almost all of it:

1. **Salesforce API is the source of truth.** Load the list view over REST (the app already
   has OAuth, `listViews()`, `fullList()` and `details()`). No Chrome, no AppleScript.
   "Open in Salesforce" is just a link.
2. **One state machine owns the call.** Every transition is a function; one cancellable task
   per state; no timer polling flags.
3. **Everything else is a plain value or a thin client.** Services are stateless structs
   behind protocols so the session can be tested with fakes.

```
Sources/Dialer/
  App.swift              // window, menu, inject services            ~60
  Models.swift           // Lead, Outcome, Script, Settings          ~150
  Session.swift          // the state machine (only @Observable)     ~300
  Rules.swift            // pure outbound rules: queue order,        ~200
                         //   time zones, cadence, call twice
  Salesforce.swift       // OAuth + list views + leads + log call    ~250
  Aircall.swift          // REST: users, numbers, dial, text,        ~200
                         //   call status; webphone for audio/VM drop
  Metrics.swift          // Attempt log + pure summaries           ~150
  Store.swift            // one JSON file: settings + scripts +      ~80
                         //   today's attempts; Keychain for tokens
  Views/
    DialerView.swift     // the one screen                           ~250
    ScriptView.swift     // paste / edit script, {{merge}} fields    ~100
    SettingsView.swift   // connections + outbound settings           ~200
    MetricsView.swift    // today/week/all-time, breakdowns, funnel ~150
Tests/DialerTests/       // Rules + Session with fake services
```

**~2,000 lines, 10 files, 3 dependencies (Foundation, SwiftUI, WebKit).** About 92% smaller.

### Models (all value types)

```swift
struct Lead: Identifiable, Codable {
    let id: String                 // Salesforce Id
    let object: SFObject           // .lead / .contact
    var name, company, title: String
    var phone, mobile: String?
    var city, state: String?
    var status: String
    var zone: CallZone? { Rules.zone(for: self) }
}

enum Outcome: String, Codable, CaseIterable {
    case connected, voicemail, noAnswer, badNumber, notInterested, meetingBooked
}

struct Script: Codable, Identifiable {
    var id = UUID(); var name: String; var body: String   // markdown + {{FirstName}} {{Company}}
    func render(for lead: Lead) -> String
}

struct OutboundSettings: Codable {
    var fromNumberID: Int?          // Aircall number calls go out from
    var textNumberID: Int?          // number texts go out from (nil = same)
    var autoDial = true             // dial next lead after wrap-up
    var countdown = 3               // seconds before auto-dial
    var callTwice = false           // redial once if unanswered
    var mobileOnly = false
    var voicemailDrop = false       // drop recorded VM on beep
    var textAfterVoicemail = false
    var textTemplate = ""           // {{FirstName}} merge fields
    var callingHours = 8...17       // in the lead's local time
    var eastToWest = true           // queue order
    var maxAttemptsPerDay = 2
    var cadenceDays = [0, 2, 5, 9, 14]
}
```

### The state machine

```swift
enum CallState: Equatable {
    case idle
    case ready(Lead)                       // showing lead, not dialing
    case countdown(Lead, secondsLeft: Int) // auto-dial
    case dialing(Lead, attempt: Int)
    case live(Lead, since: Date)
    case wrapUp(Lead, CallResult)          // pick outcome, note, status
    case done                              // list finished
}

@Observable @MainActor final class Session {
    private(set) var state: CallState = .idle
    private(set) var queue: [Lead] = []
    private var task: Task<Void, Never>?   // exactly one, cancelled on every transition

    func load(_ view: ListView) async      // Salesforce -> Rules.order -> .ready(first)
    func dial()                            // .ready/.countdown -> .dialing
    func hangUp()                          // .live -> .wrapUp
    func log(_ outcome: Outcome, note: String, status: String?) async
                                           // -> Salesforce Task + status, Rules -> next
    func skip()                            // -> next
    func pause()                           // cancel task -> .ready
}
```

Transitions are driven by Aircall call events (poll `/calls` every 2 s only while
`.dialing`/`.live`, or a webhook later). `Rules.afterCall(result, settings)` decides the
follow-on: redial (call twice), drop voicemail, send text, or advance. That function is
pure, so every outbound rule is a one-line unit test.

### Salesforce sync (what's written back)

- On wrap-up: one `Task` (Subject "Call", `CallDisposition`, `Description` = note,
  `CallDurationInSeconds`, `WhoId`), plus status update if changed. Bad number -> clear
  the field. That replaces `PickedUpSync`, `sfCallDays`, `sfPickedUp`, `sfNoNumber`, and
  the local `DialHistory`/`Touchpoints` stores: **cadence reads past call Tasks from
  Salesforce**, so history follows the rep across machines.
- Offline/failed writes go into a small retry queue in `Store`.

### Aircall (all the outbound settings)

Keep what works: REST `startCall` on the chosen user + number, the WKWebView phone for
audio and the voicemail-drop button, `sendText`. Drop the audio capture JS (it only fed the
coach). Beep detection for voicemail drop uses Aircall's own drop flow or a manual
"Drop VM" button (one keystroke) instead of a custom audio detector.

### Metrics (one event log, everything derived)

No counters anywhere. Every dial appends one immutable record, and every number is a
pure function over those records. Nothing can drift or be double-counted.

```swift
struct Attempt: Codable, Identifiable {        // one per dial, append-only
    let id: UUID
    let leadID: String, listID: String, scriptID: UUID
    let attemptNumber: Int                     // 1st, 2nd... touch on this lead
    let isRedial: Bool                         // call-twice second dial
    let fromNumber: String, leadZone: CallZone?
    let dialedAt: Date
    var answeredAt: Date?, endedAt: Date?
    var outcome: Outcome?
    var voicemailDropped = false, textSent = false
    var statusBefore: String, statusAfter: String?
    var aircallCallID: Int?, salesforceTaskID: String?
    var talkSeconds: Int { ... }               // answered -> ended
    var isConversation: Bool { talkSeconds >= 30 }
}

enum Metrics {                                 // pure, fully unit-tested
    static func summary(_ a: [Attempt], in range: DateInterval) -> Summary
    static func by<K: Hashable>(_ a: [Attempt], _ key: (Attempt) -> K) -> [K: Summary]
}
struct Summary {
    dials, uniqueLeads, connects, conversations, voicemails, meetings, badNumbers
    connectRate, conversationRate, meetingRate      // per dial and per lead
    talkTime, avgTalkTime, dialsPerHour, activeTime // idle gaps > 10 min excluded
    dialsPerMeeting
}
```

- **Storage:** `attempts.jsonl` (one line per attempt, append-only, survives crashes),
  each one mirrored to its Salesforce Task (with `aircallCallID`) so team reporting
  works in Salesforce dashboards too. Aircall's call record backfills true duration.
- **Breakdowns for free** via `Metrics.by`: per day/week, per list, per script (A/B
  your scripts), per hour of the lead's local time (best time to call), per time
  zone, per attempt number (does touch #3 still pay?), per from-number, first dial
  vs call-twice redial.
- **Live in the UI:** a slim strip on the dialer, `42 dials · 9 connects (21%) · 2 mtgs
  · 1h12m`, and a Metrics tab with today / week / all-time, the breakdowns above as
  sortable tables, and a funnel (dials → connects → conversations → meetings).
- **Export:** CSV of attempts in one click.

## The user experience

One window, one screen, one primary button.

```
┌──────────────────────────────────────────────────────────────┐
│  Q4 Portland CFOs ▾            14 of 82 · 3:42pm their time  │
├──────────────────────────────┬───────────────────────────────┤
│  Dana Whitfield              │  SCRIPT                        │
│  CFO · Northwind Freight     │  Hi Dana, it's Mason with      │
│  (503) 555-0142  mobile      │  Clarity. I'll be quick...     │
│  Status: Working             │                                │
│  Last call: 4 days ago, VM   │  (scrolls, merge fields filled)│
├──────────────────────────────┴───────────────────────────────┤
│            [ ● Call  ⏎ ]      Skip →     Open in Salesforce  │
└──────────────────────────────────────────────────────────────┘

After hang-up the bottom bar becomes:
   Connected · Voicemail · No answer · Bad number · Meeting   [note…]   Status ▾   ⏎ Log & next
```

- **Keyboard first:** `⏎` call / log & next, `space` hang up, `1-6` outcome, `S` skip,
  `V` drop voicemail.
- **Setup is three rows** in Settings: Connect Salesforce, Connect Aircall, Paste script.
  The app is usable the moment all three are green; no tour needed.
- **Outbound settings** are one grouped form (the `OutboundSettings` struct above, one
  control per field).

## Cut list

Removed outright: `CoachCore/*`, `Coach*`, `LiveCoach`, `Think*`, `Deepgram`, `Claude`,
`AudioPipeline`, `ProcessTap`, `CoreAudioHelpers`, `AudioDebug`, `BeepDetector`,
`Guardrail`, `LineGate`, `Openers`, `ScriptMaker`, `ScriptLab*`, `ScriptSkeleton`,
`ScriptTemplates`, `ColdCallBackbone`, `BuiltInSegments`, `CallLab`, `CallLibrary`,
`CallLessons`, `CallTrace`, `ProofModel`, `Screener`, `LinkedInBot`, `LocalLunch`,
`Calendly`, `CalendarFeed`, `Availability`, `DailyGoal`, `Tour`, `ChromeGuide`,
`ChromeLogin`, `SalesforceTab`, `SpaceKey`, `BugReporter`, `TeamKeys`, `ListProfile`,
`coach-audit/`, and all 30 coach test files.

Merged: list/queue/cadence/time-zone/mobile-only -> `Rules.swift`. All local history
stores -> Salesforce Tasks + `Store.swift`. `Campaign` (14 coach fields) -> `Script`
(name + body). `Prefs` (55 keys) -> `OutboundSettings` (13 fields).

Kept but tightened: Salesforce OAuth/PKCE, Aircall REST client, Aircall web phone,
Keychain, Updater, `CallZone` area-code tables.

## Decisions to confirm

- **Salesforce Tasks as history** (recommended) vs keeping local dial history.
- **Voicemail drop:** manual `V` key (simple, reliable) vs keeping automatic beep detection.
- **LinkedIn / Calendly:** cut here; could return later as optional add-ons.

## Build order

1. New `Dialer` target beside the old one; `Models`, `Rules` + tests (pure, no UI).
2. `Salesforce` + `Aircall` clients lifted from today's files, trimmed.
3. `Session` state machine with fake services + tests for every outbound rule.
4. Views. Ship behind a separate app name; delete the old target once it's used for a day.
