# Clarity Live Coach: how "picked up" is counted (audit pack)

## What to review
The app shows a **Pickup rate** = pickups / dials (Touchpoints card). Please check whether that number is right, and list every way it can be wrong.

There are three different "picked up" definitions in the code:
1. **Touchpoints `.pickup`** (the Pickup rate): at call end, the prospect side had at least one final transcript turn, no voicemail was seen, and no call screener was active.
2. **`DialHistory.logPickup`** (stops the call plan): the same, minus calls where only a gatekeeper talked.
3. **Salesforce "Picked Up Cold Call" checkbox**: the same, plus a real conversation (3+ prospect turns, or 45+ seconds since the prospect first spoke).

The denominator is **`touchpoints.log(.dial)`** in `startCall()`, logged on every call start, including redials.

## Questions for reviewers
1. Is the rate's numerator and denominator the right pair? Should it be people or dials? What about redials, quick fails (bad numbers) and phone trees?
2. Can a phone tree, voicemail greeting, ringback or echo of the rep's voice count as a pickup?
3. `sawVoicemail` can be set by Claude's STAGE output (`CoachModel+Lines.swift`). Could the Haiku vs Sonnet test change the pickup rate?
4. Is the 45 s conversation timer measured correctly? It runs from the first prospect words to `nextCall()`, not to hang-up.
5. Any double counting, or calls never counted (app quit mid-call, an Aircall failure after `startCall`)?
6. Gatekeeper-only calls count in the Pickup rate but not in DialHistory. Is that the right call?

## Known issues found in a first scan (please confirm or reject)
- **A. Phone trees can count as pickups.** The bad-number/phone-tree path calls `nextCall()`, which logs `.pickup` whenever the menu audio produced a prospect turn. `badNumberThisCall` is not checked.
- **B. The denominator counts non-calls.** Quick fails (< 12 s, nobody spoke), bad numbers and phone trees are logged as dials, so the rate reads low.
- **C. Redials count as extra dials.** "Call twice" doubles dials for non-answers, so the rate is per dial, not per person. The card doesn't say which.
- **D. Voicemail depends partly on the model.** Voicemail is detected by keyword/beep rules and by Claude's STAGE = Voicemail. A missed greeting counts as a pickup, and Haiku and Sonnet might differ.
- **E. The screener check is end-state only.** `!screenerActive` is read at call end. A screener that was cleared with no human after it counts as a pickup.
- **F. The conversation time is overstated.** `talked` = now minus the first prospect words, measured at `nextCall()`, which can run after the wrap-up, not at hang-up.
- **G. The definitions differ.** The rate uses definition 1, but the call plan and Salesforce use 2 and 3. The numbers won't match Salesforce reports.

## Code

### CoachModel+Call.swift (lines 25-40)
```swift
        if !leads.isActive, status == .ready, !dialing, let key = recordKey(), RemovedList.contains(key),
           foreignSkippedID != key {
            foreignSkippedID = key
            ActivityLog.add("\(calling ?? key) is off the list (non-US number or removed): skipping")
            problem = "Off your list. Skipped, on to the next person."
            skipNext(why: "off the list")
            return
        }
        guard status == .ready, !dialing, leads.isActive, let d = leads.details, !d.doNotCall,
              let n = d.foreignNumber, foreignSkippedID != d.id else { return }
        foreignSkippedID = d.id // once per person, so Back can still show them
        ActivityLog.add("\(d.name) isn't a US or Canada number (\(n)): skipping and removing from the list")
        RemovedList.add(d.id)
        problem = "Not a US or Canada number. Skipped, on to the next person."
        skipNext(why: "not a US or Canada number")
    }
```

### CoachModel+Call.swift (lines 600-645)
```swift

    /// Skip break, or the break is over: auto dial back on, new block, next call.
    func endBreak() {
        autoDial = autoDialBeforeBreak
        breakUntil = nil
        blockStartedAt = Date()
        ActivityLog.add("Block: break over, calling again")
        if autoDial { startNextSequence() }
    }

    /// Skip to the next person, but never run away: 3 skips in a row with no call stops auto dial
    /// and says why, instead of flipping through the list opening and closing pages.
    func skipNext(why: String) {
        skipsInARow += 1
        if skipsInARow >= 3 {
            ActivityLog.problem("Skipped \(skipsInARow) people in a row (last: \(why)). Auto dial stopped so the app doesn't flip through your list.")
            problem = "Skipped \(skipsInARow) people in a row: \(why). Auto dial stopped. Check the call list settings, then press Next."
            Prefs.autoDial = false
            skipsInARow = 0
            return
        }
        nextLead(dial: Prefs.autoDial)
    }

    func startCall() {
        skipsInARow = 0
        problem = nil
        redialRightAway = false
        autoHungUpThisCall = false
        phoneTreeThisCall = false
        phoneTreeActive = false
        phoneTreeTask?.cancel()
        keysMessage = nil
        guard startAudio() else { return }
        if !leads.isActive { callList.markCurrentCalled() } // so Next skips them today (Chrome list)
        if let key = recordKey() {
            currentAttemptKey = key
            attempts[key, default: 0] += 1
        }
        touchpoints.log(.dial)
        callMessage = nil
        pendingDialSince = nil // this dial is now the live call
        BeepDetector.shared.reset()
        CallTrace.beginCall(lead: calling, attempt: currentAttempts)
        questionTracker = QuestionTracker()
        objectionTracker = ObjectionTracker()
```

### CoachModel+Call.swift (lines 140-170)
```swift

    /// The End call button: hangs up the phone for real (Aircall's own button), then resets the app.
    func hangUpAndEnd() {
        guard status != .ready else { return }
        autoHungUpThisCall = true
        // Reset right now, don't wait for Aircall: the hang-up click happens in the background.
        if AircallPhone.isOn { Task { _ = await AircallPhone.shared.hangUp() } }
        endCall()
    }

    /// How long to let it ring: 20 s only on the first dial when "Call twice" is on (a redial follows).
    /// Any other dial rings until their voicemail answers, so the drop can wait for the end of the greeting.
    var ringLimit: TimeInterval {
        currentAttempts < maxAttempts ? 20 : .infinity
    }

    /// 20 seconds of ringing and nobody spoke: hang up, then the normal flow (redial, or the next person).
    func hangUpUnanswered() {
        autoHungUpThisCall = true
        ActivityLog.add("Rang 20 s with no answer for \(calling ?? "?"): hanging up")
        Task { [weak self] in
            guard let self, self.status == .live else { return }
            let done = await AircallPhone.shared.hangUp()
            guard done else { ActivityLog.problem("Ringing hang-up: couldn't find Aircall's hang-up button"); return }
            for _ in 0..<4 {
                try? await Task.sleep(for: .seconds(1))
                if await Aircall.lineIsOnCall() == false { break }
            }
            if self.status == .live { self.endCall() }
        }
    }
```

### CoachModel+Call.swift (lines 183-320)
```swift
    func endCall() {
        guard status != .ready else { return }
        SpaceKey.callLive = false
        // A possible opt-out still waiting when the call ends is an opt-out: write it now, for this lead (Fix 1b).
        if let p = pendingAmbiguousOptOut, !doNotCall {
            pendingAmbiguousOptOut = nil
            pendingOptOutTask?.cancel()
            // Include words still in progress ("...until Tuesday" not final yet when they hung up).
            let later = (uncoached + " " + (interim[.prospect] ?? "")).trimmingCharacters(in: .whitespaces)
            if PendingOptOut.resolve(pending: p, later: later, utteranceEnded: false, callEnded: true, secondsWaited: 0) == .optOut {
                CallTrace.event("optout.flushed", ["said": p, "why": "the call ended before the full pause"])
                handleOptOut((p + " " + later).trimmingCharacters(in: .whitespaces))
            }
        }
        CallTrace.endCall(["lead": calling ?? "?", "seconds": Int(Date().timeIntervalSince(callStartedAt)),
                           "voicemail": sawVoicemail, "they_spoke": turns.contains { $0.speaker == .prospect },
                           "turns": turns.count, "last_line": suggestion.say])
        let hadVoicemail = sawVoicemail // for the log
        if hadVoicemail, !(currentAttempts < maxAttempts && autoDial), !autoHungUpThisCall, repWordsInCall >= 8,
           let key = currentAttemptKey,
           Cadence.leavesVoicemail(for: key),
           let said = voicemailScript?.say, voicemailFor == calling {
            DialHistory.logVoicemail(key, body: said)
        }
        // Didn't connect: over in under 12 seconds, nobody talked, no voicemail. That's a bad
        // number's beeping tone or a dropped call, not a person who didn't pick up (that rings 20+ s).
        let quickFail = !badNumberThisCall && !startedByHand && !sawVoicemail
            && Date().timeIntervalSince(callStartedAt) < 12
            && !turns.contains { $0.speaker == .prospect }
        ActivityLog.add("Call ended: \(calling ?? "?") after \(Int(Date().timeIntervalSince(callStartedAt))) s. voicemail=\(sawVoicemail) theySpoke=\(turns.contains(where: { $0.speaker == .prospect })) bad=\(badNumberThisCall)")
        if !turns.isEmpty {
            let words = turns.map { "\($0.speaker == .rep ? "Rep" : "Them"): \($0.text)" }.joined(separator: " | ")
            ActivityLog.add("Transcript: \(words.prefix(6000))")
        }
        if quickFail, let key = currentAttemptKey {
            outcomeSaved.insert(String(key.prefix(15))) // nothing to rate
            let fails = DialHistory.logFailedConnect(key)
            if fails >= 2 { markNotQualityProspect(key, reason: "didn't connect twice") }
            nextCall()
            waitingForNewCall = true
            endedAt = Date()
            followUp = nil
            lastCallAnswered = true // no redial
            problem = fails >= 2 ? "Didn't connect again. Bad number: taken off your list." : "Didn't connect (bad number or network). Moving on."
            afterHangUp { [weak self] in self?.startNextSequence() }
            return
        }
        if badNumberThisCall {
            // Number doesn't work: no voicemail, no text, no redial. Off the list, on to the next.
            badNumberThisCall = false
            if let key = currentAttemptKey { outcomeSaved.insert(String(key.prefix(15))) }
            nextCall()
            waitingForNewCall = true
            endedAt = Date()
            followUp = nil
            lastCallAnswered = true
            problem = phoneTreeThisCall ? "Phone tree. Disqualified and taken off your list." : "Bad number. Taken off your list."
            afterHangUp { [weak self] in self?.startNextSequence() }
            return
        }
        // 2nd try went to voicemail: they've had both calls. Move on by itself.
        let moveOn = sawVoicemail && currentAttempts >= maxAttempts
        nextCall()
        waitingForNewCall = true
        endedAt = Date()
        // Didn't reach them (no answer or voicemail): the text and LinkedIn card shows after
        // every such call, even when the voicemail greeting wasn't caught.
        if !lastCallAnswered, followUp == nil || followUp?.key != currentAttemptKey {
            startFollowUp()
            ActivityLog.add("Follow-up card for \(calling ?? "?") (voicemail heard: \(hadVoicemail))")
        }
        if let key = currentAttemptKey, RemovedList.contains(key) {
            // Marked Unqualified (or Not Quality Prospect / Negative) during the call: no text, no redial.
            ActivityLog.add("Call ended for someone taken off the list: on to the next person")
            followUp = nil
            waitingForText = false
            afterHangUp { [weak self] in self?.startNextSequence() }
        } else if shouldOfferRedial, autoDial {
            // 1st try, no answer: "Calling Jane Doe again in 3", then redial the same person.
            startAutoRedial()
        } else if !shouldOfferRedial, !lastCallAnswered, let f = followUp {
            // Done with them for now (both dials): send the text, then the next call starts.
            // No wait when no text can go out: none due today, already sent, a phone tree, or no
            // Mobile (landline only). An empty phone box always means no Mobile, so the text is skipped.
            let noMobile = f.noMobile || f.phone.trimmingCharacters(in: .whitespaces).isEmpty
            if f.textDue, !f.textDone, noMobile {
                followUp?.noMobile = true
                applyPlan() // hides the text and says why
                ActivityLog.add("No Mobile for \(calling ?? "?"): text skipped, on to the next person")
            }
            if f.textDone || !f.textDue || noMobile || phoneTreeThisCall {
                afterHangUp { [weak self] in self?.startNextSequence() }
            } else if autoDial, Aircall.isSetUp, Prefs.autoText, !f.text.isEmpty {
                // The text goes out in the background while the next person loads. No waiting.
                sendTextInBackground(f)
                afterHangUp { [weak self] in self?.startNextSequence() }
            } else {
                waitingForText = true
                startTextCountdown() // waits for its words, then sends by itself in 5 seconds (or the rep sends it)
            }
        } else if lastCallAnswered, autoDial, currentAttemptKey != nil {
            // A real talk just ended: Claude fills "How did it go?" from the transcript (you can change it),
            // then 10 seconds, then the next person. Wait stops it.
            autoOutcome()
            afterHangUp { [weak self] in self?.startMoveOn(after: 10) }
        } else if moveOn {
            afterHangUp { [weak self] in self?.startNextSequence() }
        }
    }

    /// Reached a recording (100% sure: words only a machine says) and auto-dial is on:
    /// - 1st try: hang up, then redial in 1 s.
    /// - Last try on a no-voicemail day: hang up, then on to the next person (after the text, if one is due).
    /// Clicks Aircall's hang-up button and waits until Aircall says the line is free.
    /// If anything is off (no button, line still busy), it does nothing and the rep hangs up as usual.
    func autoHangUpForRedial(why: String = "beep words") {
        guard autoDial, AircallPhone.isOn, !autoHangingUp, !autoHungUpThisCall, !voicemailDropStarted, // the drop is playing
              !phoneTreeActive, !phoneTreeThisCall, // never hang up on a phone menu
              let key = currentAttemptKey, !RemovedList.contains(key) else { return }
        let redialNext = currentAttempts < maxAttempts && !DialHistory.isMaxed(key)
        let noVoicemailToday = !Cadence.leavesVoicemail(for: key)
        guard redialNext || noVoicemailToday else { return } // a voicemail day's last try: leave the message
        autoHangingUp = true
        autoHungUpThisCall = true
        ActivityLog.add(redialNext ? "Recording for sure (\(why)) on the 1st try for \(calling ?? "?"): hanging up to redial"
                                   : "Recording (\(why)) on the last try, no voicemail today, for \(calling ?? "?"): hanging up, on to the next person")
        Task { [weak self] in
            guard let self, self.status == .live else { self?.autoHangingUp = false; return }
            var done = await AircallPhone.shared.hangUp()
            if done {
                // Only end the call on our side once Aircall says the line is free (up to 5 s).
                done = false
                for _ in 0..<5 {
                    try? await Task.sleep(for: .seconds(1))
                    if await Aircall.lineIsOnCall() == false { done = true; break }
                }
            }
            self.autoHangingUp = false
```

### CoachModel+Call.swift (lines 735-800)
```swift
    }

    /// Stages that only happen with the actual prospect, not a front desk or assistant.
    static let prospectStages: Set<String> = ["Discovery", "Value", "Objection", "Closing", "Goal reached"]

    /// Counts the call that just ended. Picked up = a real person talked (not voicemail, not
    /// only a screener). Conversation = they kept talking: 3+ turns, or 45+ seconds after pickup.
    func logTouchpoints(answered: Bool) {
        if sawVoicemail { touchpoints.log(.voicemail) }
        guard answered else { return }
        touchpoints.log(.pickup)
        NSSound(named: "Tink")?.play() // a soft sound: someone picked up
        let prospectTurns = turns.filter { $0.speaker == .prospect }.count
        let talked = firstProspectAt.map { Date().timeIntervalSince($0) } ?? 0
        let conversation = prospectTurns >= 3 || talked >= 45
        if conversation { touchpoints.log(.conversation) }
        if goalHit { touchpoints.log(.meeting) }
        // Only a front desk or assistant talked: not the prospect. Keep them on the plan, no checkbox.
        let gatekeeperOnly = stagesSeen.contains("Gatekeeper") && stagesSeen.isDisjoint(with: Self.prospectStages)
        guard let key = currentAttemptKey, !gatekeeperOnly else {
            if gatekeeperOnly { ActivityLog.add("Front desk only for \(calling ?? "?"): stays on the plan, Picked Up Cold Call not checked") }
            return
        }
        DialHistory.logPickup(key) // the prospect picked up: the call plan stops for them
        // A real conversation with the prospect: check "Picked Up Cold Call" in Salesforce.
        guard conversation else {
            ActivityLog.add("Short pickup for \(calling ?? key) (\(prospectTurns) turns, \(Int(talked)) s): Picked Up Cold Call not checked")
            return
        }
        guard Salesforce.objectFor(id: key) != nil else {
            ActivityLog.problem("Couldn't check Picked Up Cold Call for \(calling ?? key): no Salesforce record on screen")
            return
        }
        guard Salesforce.isConnected else {
            ActivityLog.problem("Couldn't check Picked Up Cold Call: Salesforce isn't connected")
            return
        }
        let who = calling ?? key
        Task {
            do {
                try await Salesforce.markPickedUp(key)
                ActivityLog.add("Picked Up Cold Call checked for \(who)")
            } catch {
                ActivityLog.problem("Couldn't check Picked Up Cold Call for \(who): \(error.localizedDescription)")
            }
        }
    }

    /// Clears everything about this prospect and gets the next opener ready.
    func nextCall() {
        SpaceKey.callLive = false // Space is normal again everywhere
        yesShowTask?.cancel()
        openerWaitTask?.cancel()
        testLineCounted = false
        followPausedUntilQuiet = false
        // The call is over: the next person starts clean, before their opener is prepared below (round 3).
        doNotCall = false
        pendingAmbiguousOptOut = nil
        pendingOptOutTask?.cancel()
        if status != .ready {
            // Reached a person = they spoke, and it wasn't a voicemail or only a screener.
            let theySpoke = turns.contains { $0.speaker == .prospect }
            lastCallAnswered = theySpoke && !sawVoicemail && !screenerActive
            logTouchpoints(answered: lastCallAnswered)
        }
        history = []
```

### Touchpoints.swift (lines 1-211)
```swift
import SwiftUI

/// Counts every touchpoint on this Mac (no Salesforce needed): dials, pickups, conversations,
/// voicemails, texts, LinkedIn notes and meetings booked. Filled in automatically by the coach.
@MainActor
final class Touchpoints: ObservableObject {
    enum Kind: String, Codable, CaseIterable {
        case dial, pickup, conversation, voicemail, text, linkedin, linkedinMessage, meeting
    }
    struct Event: Codable {
        let kind: Kind
        let at: Date
        /// The campaign it happened in (older events have none).
        var campaign: String? = nil
    }

    /// The campaign being worked right now; every touchpoint is tagged with it.
    var currentCampaign: String?
    /// Which campaign the card shows: nil = all campaigns.
    @Published var showCampaign: String?

    /// Campaigns that have touchpoints, for the card's picker.
    var campaignNames: [String] { Array(Set(events.compactMap(\.campaign))).sorted() }

    enum Period: String, CaseIterable, Identifiable {
        case today = "Today", week = "This week", month = "This month", all = "All time"
        var id: String { rawValue }
    }

    @Published private(set) var events: [Event] = []

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClarityLiveCoach", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("touchpoints.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([Event].self, from: data) {
            events = saved
        }
    }

    func log(_ kind: Kind) {
        events.append(Event(kind: kind, at: Date(), campaign: currentCampaign))
        // Keep about two years, so the file stays small.
        let cutoff = Calendar.current.date(byAdding: .day, value: -730, to: Date()) ?? .distantPast
        if events.first.map({ $0.at < cutoff }) == true { events.removeAll { $0.at < cutoff } }
        if let data = try? JSONEncoder().encode(events) { try? data.write(to: Self.file, options: .atomic) }
    }

    /// Wipes today's counts (all campaigns). Older days stay.
    func resetToday() {
        let start = Self.start(of: .today)
        events.removeAll { $0.at >= start }
        if let data = try? JSONEncoder().encode(events) { try? data.write(to: Self.file, options: .atomic) }
    }

    /// Every contact today, across all campaigns (dials + texts + LinkedIn), for the daily goal.
    func totalAll(in period: Period) -> Int {
        let start = Self.start(of: period)
        let contacts: Set<Kind> = [.dial, .text, .linkedin, .linkedinMessage]
        return events.filter { contacts.contains($0.kind) && $0.at >= start }.count
    }

    /// Every contact since a time, across all campaigns, for the hourly goal.
    func contacts(since start: Date) -> Int {
        let contacts: Set<Kind> = [.dial, .text, .linkedin, .linkedinMessage]
        return events.filter { contacts.contains($0.kind) && $0.at >= start }.count
    }

    private static let contactKinds: Set<Kind> = [.dial, .text, .linkedin, .linkedinMessage]

    /// Contacts in each clock hour today, from the first busy hour (or now) to this hour. At most 12.
    func contactsByHourToday() -> [Int] {
        let cal = Calendar.current
        let now = Date()
        let today = events.filter { Self.contactKinds.contains($0.kind) && cal.isDateInToday($0.at) }
        let thisHour = cal.component(.hour, from: now)
        let firstHour = today.map { cal.component(.hour, from: $0.at) }.min() ?? thisHour
        var counts = Array(repeating: 0, count: thisHour - firstHour + 1)
        for e in today { counts[cal.component(.hour, from: e.at) - firstHour] += 1 }
        return Array(counts.suffix(12))
    }

    /// The last day before today with any contacts: its name ("yesterday", "Friday") and its total.
    func lastDay() -> (name: String, total: Int)? {
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: Date())
        guard let last = events.last(where: { Self.contactKinds.contains($0.kind) && $0.at < startToday }) else { return nil }
        let day = cal.startOfDay(for: last.at)
        let total = events.filter { Self.contactKinds.contains($0.kind) && $0.at >= day && $0.at < startToday
                                    && cal.isDate($0.at, inSameDayAs: day) }.count
        let name = cal.isDateInYesterday(day) ? "yesterday" : day.formatted(.dateTime.weekday(.wide))
        return (name, total)
    }

    /// Meetings booked this week, all campaigns.
    func meetingsThisWeek() -> Int {
        let start = Self.start(of: .week)
        return events.filter { $0.kind == .meeting && $0.at >= start }.count
    }

    func count(_ kind: Kind, in period: Period) -> Int {
        let start = Self.start(of: period)
        return events.filter { $0.kind == kind && $0.at >= start && (showCampaign == nil || $0.campaign == showCampaign) }.count
    }

    /// Every way you reached out: dials + texts + LinkedIn notes + LinkedIn messages.
    func total(in period: Period) -> Int {
        count(.dial, in: period) + count(.text, in: period) + count(.linkedin, in: period) + count(.linkedinMessage, in: period)
    }

    private static func start(of period: Period) -> Date {
        let cal = Calendar.current
        let now = Date()
        switch period {
        case .today: return cal.startOfDay(for: now)
        case .week: return cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        case .month: return cal.dateInterval(of: .month, for: now)?.start ?? cal.startOfDay(for: now)
        case .all: return .distantPast
        }
    }
}

/// The Touchpoints card: pick a time period, see the numbers that matter.
struct TouchpointsCard: View {
    @ObservedObject var touchpoints: Touchpoints
    @AppStorage(PrefKey.touchpointsPeriod) private var periodRaw = Touchpoints.Period.today.rawValue
    @AppStorage(PrefKey.touchpointsOpen) private var open = false
    @State private var confirmReset = false

    private var period: Touchpoints.Period { Touchpoints.Period(rawValue: periodRaw) ?? .today }

    var body: some View {
        let t = touchpoints
        let dials = t.count(.dial, in: period)
        let pickups = t.count(.pickup, in: period)
        let meetings = t.count(.meeting, in: period)
        VStack(alignment: .leading, spacing: 8) {
            // Folded: one line. Click to see everything.
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
                    Text(open ? "My numbers" : "My numbers \(period.rawValue.lowercased()): \(dials) calls · \(meetings) meetings")
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
            HStack {
                // Compare campaigns: each list + script on its own.
                Picker("", selection: $touchpoints.showCampaign) {
                    Text("All call lists").tag(String?.none)
                    ForEach(touchpoints.campaignNames, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Picker("", selection: $periodRaw) {
                    ForEach(Touchpoints.Period.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(t.total(in: period))").font(.title.weight(.semibold)).monospacedDigit()
                Text("calls, texts and notes").font(.callout).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { stat("Calls", dials); stat("Picked up", pickups) }
                GridRow { stat("Conversations", t.count(.conversation, in: period)); stat("Voicemails", t.count(.voicemail, in: period)) }
                GridRow { stat("Texts", t.count(.text, in: period)); stat("LinkedIn notes", t.count(.linkedin, in: period)) }
                GridRow { stat("LinkedIn messages", t.count(.linkedinMessage, in: period)); stat("Meetings booked", meetings) }
                GridRow { stat("Pickup rate", percent(pickups, of: dials)); Color.clear.frame(height: 1) }
            }
            if meetings > 0 {
                Text("\(dials / max(meetings, 1)) calls per meeting").font(.caption).foregroundStyle(.secondary)
            }
            Button("Set today back to zero") { confirmReset = true }
                .buttonStyle(.link).font(.caption)
                .confirmationDialog("Set today's numbers back to zero?", isPresented: $confirmReset) {
                    Button("Set to zero", role: .destructive) { touchpoints.resetToday() }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard(radius: 10)
    }

    private func stat(_ label: String, _ value: Int) -> some View { stat(label, "\(value)") }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func percent(_ part: Int, of whole: Int) -> String {
        whole == 0 ? "–" : "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
    }
}
```

### DialHistory.swift (lines 1-135)
```swift
import AppKit
import Foundation

/// Every call to each person, saved on this Mac. After the max number of tries with no
/// pickup (Settings: 3, 4 or 5), they come off the call list, like Not Quality Prospect.
enum DialHistory {
    struct Person: Codable {
        var dials: [Date] = []
        var pickups = 0
        var texts: [Date] = []
        /// The words of every text sent to them, oldest first.
        var textBodies: [String] = []
        var linkedIns: [Date] = []
        var linkedInMessages: [Date] = []
        /// The words of every LinkedIn message copied for them, oldest first.
        var linkedInMessageBodies: [String] = []
        /// Voicemails left for them (when, and the words), oldest first.
        var voicemails: [Date] = []
        var voicemailBodies: [String] = []
        /// Calls where they actually talked to us.
        var talked: [Date] = []
        /// The carrier said the number doesn't work.
        var badNumber = false
        /// Calls that ended in seconds with nobody on the line (beeping tone, no connection).
        var failedConnects = 0

        init() {}

        // Older saves don't have texts or LinkedIn yet: read what's there.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dials = try c.decodeIfPresent([Date].self, forKey: .dials) ?? []
            pickups = try c.decodeIfPresent(Int.self, forKey: .pickups) ?? 0
            texts = try c.decodeIfPresent([Date].self, forKey: .texts) ?? []
            textBodies = try c.decodeIfPresent([String].self, forKey: .textBodies) ?? []
            linkedIns = try c.decodeIfPresent([Date].self, forKey: .linkedIns) ?? []
            linkedInMessages = try c.decodeIfPresent([Date].self, forKey: .linkedInMessages) ?? []
            linkedInMessageBodies = try c.decodeIfPresent([String].self, forKey: .linkedInMessageBodies) ?? []
            voicemails = try c.decodeIfPresent([Date].self, forKey: .voicemails) ?? []
            voicemailBodies = try c.decodeIfPresent([String].self, forKey: .voicemailBodies) ?? []
            talked = try c.decodeIfPresent([Date].self, forKey: .talked) ?? []
            badNumber = try c.decodeIfPresent(Bool.self, forKey: .badNumber) ?? false
            failedConnects = try c.decodeIfPresent(Int.self, forKey: .failedConnects) ?? 0
        }
    }

    private static var cache: [String: Person]?

    private static let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClarityLiveCoach", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dial-history.json")
    }()

    private static var all: [String: Person] {
        get {
            if let cache { return cache }
            var loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Person].self, from: $0) } ?? [:]
            // Once: forget voicemails the old rule logged without one being left (no drop, no words read).
            if !UserDefaults.standard.bool(forKey: "voicemailLogReset1") {
                UserDefaults.standard.set(true, forKey: "voicemailLogReset1")
                for (k, var p) in loaded where !p.voicemails.isEmpty && !p.voicemailBodies.contains("(recorded voicemail dropped)") {
                    p.voicemails = []
                    p.voicemailBodies = []
                    loaded[k] = p
                }
                if let data = try? JSONEncoder().encode(loaded) { try? data.write(to: file, options: .atomic) }
            }
            cache = loaded
            return loaded
        }
        set {
            cache = newValue
            scheduleSave()
        }
    }

    // Saving: changes come in bursts (a dial, then a voicemail, then a text), so the file is
    // written once, a second after the last change, off the main thread. Quitting saves right away.
    private static var saveWork: DispatchWorkItem?
    private static let saveQueue = DispatchQueue(label: "DialHistory.save", qos: .utility)
    private static var savesOnQuit: NSObjectProtocol?

    private static func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        if savesOnQuit == nil {
            savesOnQuit = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in
                saveWork?.cancel()
                guard let cache, let data = try? JSONEncoder().encode(cache) else { return }
                try? data.write(to: file, options: .atomic) // quitting: write now, not later
            }
        }
    }

    private static func save() {
        saveWork = nil
        guard let cache, let data = try? JSONEncoder().encode(cache) else { return }
        saveQueue.async { try? data.write(to: file, options: .atomic) }
    }

    private static func key(_ id: String) -> String { String(id.prefix(15)) }

    /// 3, 4 or 5. 0 = never take anyone off for this.
    static var maxDials: Int {
        get { UserDefaults.standard.object(forKey: PrefKey.maxDials) as? Int ?? 4 }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.maxDials) }
    }

    static func person(_ id: String) -> Person { all[key(id)] ?? Person() }

    static func logDial(_ id: String) {
        var p = person(id)
        p.dials.append(Date())
        all[key(id)] = p
    }

    static func logPickup(_ id: String) {
        var p = person(id)
        p.pickups += 1
        all[key(id)] = p
    }

    static func logText(_ id: String, body: String = "") {
        var p = person(id)
        p.texts.append(Date())
        if !body.isEmpty { p.textBodies.append(body) }
        all[key(id)] = p
    }

```

### Cadence.swift (lines 25-40)
```swift

    /// The days they were called on, oldest first: this Mac's calls plus the team's calls in Salesforce.
    static func callDates(_ id: String) -> [Date] {
        var seen = Set<Date>()
        for d in DialHistory.person(id).dials { seen.insert(cal.startOfDay(for: d)) }
        for d in CallHistory.callDays(id) { seen.insert(cal.startOfDay(for: d)) }
        return seen.sorted()
    }

    /// They picked up before: on this Mac, or Picked Up Cold Call is checked in Salesforce.
    static func pickedUp(_ id: String) -> Bool {
        DialHistory.person(id).pickups > 0 || CallHistory.pickedUp(id)
    }

    /// Days to wait after the last call day before each step: 1 day (to day 2), 3 (to day 5),
    /// 3 (to day 8), 8 (to day 16).
```

### CallHistory.swift (lines 1-80)
```swift
import Foundation

/// Calls the whole team made, from Salesforce: Aircall logs every outbound call as a Task
/// (Type "Call", Call Type "Outbound") on the Lead or Contact. Plus the Picked Up Cold Call box.
/// Merged with this Mac's own calls, so the 5 day plan is right on a new install and when
/// teammates call the same list. Saved on this Mac, and refreshed when a list loads.
enum CallHistory {
    private static var d: UserDefaults { .standard }
    private static let lock = NSLock()
    private static var loaded = false
    /// Record Id (first 15 characters) -> the days anyone called them, start of each day here.
    private static var days: [String: [Date]] = [:]
    /// Record Ids with Picked Up Cold Call checked.
    private static var picked: Set<String> = []
    /// Record Ids with no Mobile and no Phone: nothing to call, so they're kept off the list.
    private static var noNumbers: Set<String> = []
    /// When each person was last looked up while the app has been open.
    private static var checkedAt: [String: Date] = [:]

    /// How far back to read calls. The plan takes 16 days; this is plenty, and keeps queries small.
    private static let lookBackDays = 120
    /// Ask Salesforce about the same person at most this often.
    private static let refreshEvery: TimeInterval = 600

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func key(_ id: String) -> String { String(id.prefix(15)) }

    private static func loadSaved() {
        guard !loaded else { return }
        loaded = true
        let saved = (d.dictionary(forKey: PrefKey.sfCallDays) as? [String: [String]]) ?? [:]
        days = saved.mapValues { $0.compactMap { dayFormat.date(from: $0) } }
        picked = Set(d.stringArray(forKey: PrefKey.sfPickedUp) ?? [])
        noNumbers = Set(d.stringArray(forKey: PrefKey.sfNoNumber) ?? [])
    }

    /// Salesforce has no Mobile and no Phone for them.
    static func noNumber(_ id: String) -> Bool {
        lock.withLock {
            loadSaved()
            return noNumbers.contains(key(id))
        }
    }

    static func markNoNumber(_ id: String) {
        let saved: [String] = lock.withLock {
            loadSaved()
            noNumbers.insert(key(id))
            return Array(noNumbers)
        }
        d.set(saved, forKey: PrefKey.sfNoNumber)
    }

    /// The days anyone on the team called them (from Salesforce), oldest first.
    static func callDays(_ id: String) -> [Date] {
        lock.withLock {
            loadSaved()
            return days[key(id)] ?? []
        }
    }

    /// Picked Up Cold Call is checked on their record.
    static func pickedUp(_ id: String) -> Bool {
        lock.withLock {
            loadSaved()
            return picked.contains(key(id))
        }
    }

    /// Reads call days and the Picked Up Cold Call box for everyone on a list (100 at a time).
    static func load(ids: [String], object: String) async {
        guard Salesforce.isConnected, ["Lead", "Contact"].contains(object) else { return }
```

### Salesforce.swift (lines 345-370)
```swift
            _ = try await send("PATCH", "/services/data/\(apiVersion)/composite/sobjects",
                               body: ["allOrNone": false, "records": records])
        }
    }

    /// Checks "Picked Up Cold Call" on the Lead or Contact (a real person answered).
    static func markPickedUp(_ id: String) async throws {
        guard id.allSatisfy({ $0.isLetter || $0.isNumber }), let object = objectFor(id: id) else { return }
        _ = try await send("PATCH", "/services/data/\(apiVersion)/sobjects/\(object)/\(id)",
                           body: ["Picked_Up_Cold_Call__c": true])
    }

    /// Everyone on a list view (up to 2,000), in the list's own order. `key` is the list view Id
    /// or its API name, as in the address bar's filterName.
    static func fullList(object: String, key: String) async throws -> [Row] {
        let views = try await listViews()
        guard let view = views.first(where: {
            $0.object == object && ($0.id.prefix(15) == key.prefix(15) || $0.developerName == key)
        }) else { throw SFError(message: "Couldn't find that list view in Salesforce.") }
        let rows = try await allRows(of: view)
        return await withCompanyNames(rows, object: object)
    }

    /// How many people are on a list view, without loading them: the list's own query as a COUNT().
    static func count(object: String, key: String) async throws -> Int {
        guard let view = try await listViews().first(where: {
```

### CoachModel+Audio.swift (lines 160-200)
```swift
                CallTrace.event(isFinal ? "transcript.final" : "transcript.partial", [
                    "speaker": speaker == .rep ? "rep" : "prospect", "text": text, "speech_final": speechFinal,
                    "audio_start": audioStart, "audio_end": audioStart + audioDuration, "confidence": confidence])
            }
            if speechFinal { CallTrace.event("turn.end", ["speaker": speaker == .rep ? "rep" : "prospect", "by": "speech_final"]) }
            if speaker == .prospect {
                // Check the recent words together, so a phrase split across chunks still matches.
                let recent = String(((turns.last { $0.speaker == .prospect }?.text ?? "") + " " + text).suffix(400))
                let early = repWordsInCall < 3 && Date().timeIntervalSince(firstProspectAt ?? Date()) < 15
                let firstWords = turns.contains { $0.speaker == .rep } ? "" : (prospectSoFar + " " + text)
                if BadNumber.detects(recent) {
                    if !badNumberThisCall { markBadNumber() }
                } else if phoneTreeActive {
                    // In a phone menu: no voicemail card, no auto hang-up. Only a real mailbox ends it.
                    if Voicemail.recordingPrompt(recent) {
                        phoneTreeActive = false
                        phoneTreeTask?.cancel()
                        showVoicemail(mailboxFull: Voicemail.mailboxFull(recent))
                    }
                } else if !badNumberThisCall, !phoneTreeThisCall, repWordsInCall < 5,
                          !Voicemail.recordingPrompt(recent), PhoneTree.detects(prospectSoFar + " " + text) {
                    // Work through it by default. Old behavior (disqualify + hang up) behind a setting.
                    if Prefs.hangUpPhoneTrees { markPhoneTree() } else { enterPhoneTree() }
                } else if !voicemailActive, screenerActive || stagesSeen.contains("Screener") || Screener.detects(prospectSoFar),
                          Voicemail.unavailableAfterScreen(recent) || Voicemail.numberCantTakeCall(recent) {
                    // The call screener says they won't take it: same as no answer. Hang up (redial on the
                    // 1st try, next person on a no-voicemail day). A voicemail day's last try waits for the beep.
                    ActivityLog.add("Screener said not available for \(calling ?? "?")")
                    showVoicemail(mailboxFull: false)
                    autoHangUpForRedial(why: "screener said not available")
                } else if Voicemail.detects(recent, earlyInCall: early)
                    || (!screenerActive && !Screener.detects(firstWords) && Voicemail.longGreeting(firstWords, earlyInCall: early)) {
                    if !voicemailActive || (Voicemail.mailboxFull(recent) && !mailboxFullShown) {
                        showVoicemail(mailboxFull: Voicemail.mailboxFull(recent))
                    }
                    // Surely a recording, and the rep hasn't started talking: hang up now, before the beep
                    // (redial on the 1st try; on to the next person on a no-voicemail day's last try).
                    if repWordsInCall < 3, !screenerActive, !autoHungUpThisCall,
                       let why = Voicemail.hangUpReason(recent, firstWords: firstWords, earlyInCall: early) {
                        autoHangUpForRedial(why: why)
                    }
```

### CoachModel+Audio.swift (lines 275-305)
```swift
            }
            reconnects += 1
            useKeyterms = false // reconnect with the plainest settings
            streams.replace(speaker, with: openStream(speaker, key: key))
        }
    }

    /// The rep clicked "Voicemail": the app missed it, so show the message now.
    func markVoicemail() {
        guard status == .live, !voicemailActive else { return }
        showVoicemail(mailboxFull: false)
    }

    func addFinal(_ text: String, from speaker: Speaker) {
        lastWordsAt = Date()
        defer { scheduleStillWithMe() }
        defer { if speaker == .rep { prepareWhileRepTalks(text); prepareYesBranch(text) } } // runs after the turn is recorded
        if speaker == .rep {
            let count = text.split(separator: " ").count
            repWordsSinceShown += count
            repWordsInCall += count
            lastRepFinal = text
            lastRepFinalAt = Date()
            recentRepChunks = Array((recentRepChunks + [text]).suffix(2))
        }
        if speaker == .prospect, firstProspectAt == nil { firstProspectAt = Date() }
        ActivityLog.add("Heard \(speaker == .rep ? "Rep" : "Them") (final): \(text)")
        if speaker == .rep, pending != nil, text.contains("?") { repAskedSinceQueue = true }
        if speaker == .rep, text.contains("?") || QueuedLine.repPivoted(text) { lastRepQuestionAt = Date() }
        if speaker == .rep { repTextSinceAsk += " " + text }
        if speaker == .rep, status == .live, !suggestion.say.isEmpty {
```

### CoachModel+FollowUp.swift (lines 95-115)
```swift
        }
    }

    /// Instant voicemail card: the script written before the call, or "mailbox full, move on".
    func showVoicemail(mailboxFull: Bool) {
        yesShowTask?.cancel()
        if !sawVoicemail { UserDefaults.standard.set(UserDefaults.standard.integer(forKey: PrefKey.voicemailsSeen) + 1, forKey: PrefKey.voicemailsSeen) }
        voicemailActive = true
        sawVoicemail = true
        screenerActive = false
        coachTask?.cancel()
        thinking = false
        specTimer?.cancel()
        holdTask?.cancel()
        pending = nil
        specBasis = nil
        uncoached = ""
        seq += 1
        startFollowUp()
        if mailboxFull {
            mailboxFullShown = true
```

### CoachModel+Lines.swift (lines 160-175)
```swift
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, !Task.isCancelled else { return }
                    self.showScreenerLineNow()
                }
            }
            return
        }
        screenerRetries = 0
        screenerActive = true
        coachTask?.cancel()
        thinking = false
        holdTask?.cancel()
        pending = nil
        if kind == .opener { openerBeforeScreener = suggestion }
        seq += 1
        show(Suggestion(say: Screener.line(calling: calling),
```

### CoachModel+Lines.swift (lines 1060-1072)
```swift
        if s.stage == "Closing" { availability.refreshIfOlder() } // fresh times while booking
        // A closing line on screen is only a pending goal; the prospect's words confirm it (N4).
        if s.stage == "Goal reached", !goalHit {
            goalPending = true
            goalPendingTurns = 2
            // They often agree first ("Tuesday works") and the closing line follows: check their last words too.
            if let last = turns.last(where: { $0.speaker == .prospect }) { confirmGoalIfAgreed(last.text, checkingEarlierTurn: true) }
        }
        if s.stage == "Voicemail" { sawVoicemail = true }
    }

    func scheduleStillWithMe() {
        stillWithMeTask?.cancel()
```

### CoachModel+PhoneTree.swift (lines 1-30)
```swift
import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// Phone menus and bad numbers.
extension CoachModel {
    /// A phone menu answered: disqualify (Not Quality Prospect / Unqualified), hang up in the
    /// in-app phone, and move on. No voicemail, text or redial. If the hang-up button can't be
    /// found, the rep hangs up and the next call still starts by itself.
    func markPhoneTree() {
        badNumberThisCall = true
        phoneTreeThisCall = true
        coachTask?.cancel()
        thinking = false
        voicemailActive = false
        sawVoicemail = false
        followUp = nil
        if let key = currentAttemptKey {
            RemovedList.add(key) // off the app's list; Salesforce isn't changed
            ActivityLog.add("Phone tree for \(calling ?? "?"): hanging up and skipping them")
        }
        seq += 1
        show(Suggestion(say: "Phone tree. Hanging up. The next call starts by itself.", cue: "Skipped: phone menus aren't worth working.",
                        stage: "Exit", sayComplete: true), id: seq, kind: .reply)
        guard AircallPhone.isOn else { return }
        Task { [weak self] in
            guard let self, self.status == .live else { return }
            guard await AircallPhone.shared.hangUp() else {
```

### CoachModel+PhoneTree.swift (lines 100-160)
```swift
        Task { [weak self] in
            let ok = await AircallPhone.shared.sendDigits(keys)
            guard let self else { return }
            ActivityLog.add("Phone tree: pressed \(keys) (\(ok ? "sent" : "didn't go through"))")
            self.keysMessage = ok ? "Pressed \(keys)." : "Couldn't press keys from the app. Use the Aircall keypad."
        }
    }

    /// A phone menu answered: how to get through to the person. Press 0 for an operator, or dial
    /// by name with the first letters of their last name as keypad digits.
    func showPhoneTreeTips() {
        phoneTreeThisCall = true
        coachTask?.cancel()
        thinking = false
        let full = Screener.fullName(calling)
        let last = full?.split(separator: " ").last.map(String.init) ?? ""
        let keys: [Character: Character] = Dictionary(uniqueKeysWithValues: Array(zip("abcdefghijklmnopqrstuvwxyz",
                                                                                        "22233344455566677778889999")))
        let digits = String(last.lowercased().compactMap { keys[$0] }.prefix(4))
        let byName = digits.isEmpty ? "" : " Dial by name: \(digits) (\(last.prefix(4)))."
        ActivityLog.add("Phone tree for \(calling ?? "?"): showing how to get through")
        seq += 1
        var tips = Suggestion(say: "Phone tree. Press 0 for the operator.\(byName)",
                              cue: "Listening to the menu for a better route. When a person answers: \"Hi, could you put me through to \(full ?? "them")?\"",
                              stage: "Phone tree", sayComplete: true)
        tips.keys = "0"
        show(tips, id: seq, kind: .reply)
    }

    func markBadNumber() {
        badNumberThisCall = true
        coachTask?.cancel()
        thinking = false
        voicemailActive = false
        sawVoicemail = false
        followUp = nil
        if let key = currentAttemptKey { markNotQualityProspect(key, reason: "carrier says the number can't take calls") }
        seq += 1
        show(Suggestion(say: "Bad number. Hanging up. The next call starts by itself.", cue: "The carrier says this number doesn't work. Taken off your list.",
                        stage: "Exit", sayComplete: true), id: seq, kind: .reply)
        ActivityLog.add("Bad number for \(calling ?? "?"): hanging up and removing from the list")
        guard AircallPhone.isOn else { return }
        Task { [weak self] in
            guard let self, self.status == .live, await AircallPhone.shared.hangUp() else { return }
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(1))
                if await Aircall.lineIsOnCall() == false, self.status == .live { self.endCall(); return }
            }
        }
    }

    /// Bad number: off the call list for good (in the app), and marked in Salesforce as
    /// Not Quality Prospect (Contacts) or Unqualified (Leads). Nothing is deleted in Salesforce.
    func markNotQualityProspect(_ id: String, reason: String) {
        DialHistory.markBadNumber(id)
        RemovedList.add(id)
        callList.refreshUpNext()
        guard let object = Salesforce.objectFor(id: id) else { return }
        let value = object == "Lead" ? "Unqualified" : "Not Quality Prospect"
        ActivityLog.add("Off the list (\(reason)): \(calling ?? id), marking \(value)")
        guard Salesforce.isConnected else { return }
```
