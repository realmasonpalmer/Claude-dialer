import AppKit
import Foundation
import Observation

/// The phone side of a call. Live: Aircall's API + the in-app Aircall phone. Tests: a fake.
@MainActor protocol Phone {
    func dial(_ to: String, user: Int, number: Int) async throws
    func latestCall(user: Int, number: Int, since: Date) async throws -> Aircall.Call?
    func sendText(_ body: String, to: String, from number: Int) async throws
    func hangUp() async -> Bool
    func dropVoicemail(named: String) async -> Bool
    /// The phone's own screen shows a call in progress (nil = can't tell).
    func callInProgress() async -> Bool?
}

/// The CRM side. Live: Salesforce's REST API. Tests: a fake.
@MainActor protocol CRM {
    func leads(of view: Salesforce.ListView) async throws -> [Lead]
    func callHistory(_ ids: [String]) async throws -> [String: [Date]]
    func statuses(_ object: SFObject) async -> [String]
    func logCall(_ a: Attempt) async throws -> String
    func setStatus(leadID: String, to value: String) async throws
}

struct LivePhone: Phone {
    func dial(_ to: String, user: Int, number: Int) async throws { try await Aircall.dial(to, user: user, number: number) }
    func latestCall(user: Int, number: Int, since: Date) async throws -> Aircall.Call? {
        try await Aircall.latestCall(user: user, number: number, since: since)
    }
    func sendText(_ body: String, to: String, from number: Int) async throws { try await Aircall.sendText(body, to: to, from: number) }
    func hangUp() async -> Bool { await AircallPhone.shared.hangUp() }
    func dropVoicemail(named: String) async -> Bool { await AircallPhone.shared.dropVoicemail(named: named) }
    func callInProgress() async -> Bool? { await AircallPhone.shared.hangUpButtonVisible() }
}

struct LiveCRM: CRM {
    func leads(of view: Salesforce.ListView) async throws -> [Lead] { try await Salesforce.leads(of: view) }
    func callHistory(_ ids: [String]) async throws -> [String: [Date]] { try await Salesforce.callHistory(ids) }
    func statuses(_ object: SFObject) async -> [String] { await Salesforce.statuses(object) }
    func logCall(_ a: Attempt) async throws -> String { try await Salesforce.logCall(a) }
    func setStatus(leadID: String, to value: String) async throws { try await Salesforce.setStatus(leadID: leadID, to: value) }
}

/// Where the dialer is. One value; the UI is a function of it.
enum CallState: Equatable {
    case idle               // no list loaded
    case loading
    case ready              // showing a person, waiting for the rep
    case countdown(Int)     // auto-dial in N seconds
    case dialing
    case live
    case wrapUp             // call over: pick an outcome
    case finished           // nobody left to call
}

struct SkippedLead: Identifiable {
    let lead: Lead
    let reason: Skip
    var id: String { lead.id }
}

/// The dialer. The only object with behavior: every change goes through `go(_:)`, which cancels
/// whatever the last state was doing. Rules decide; Store records; Phone and CRM do I/O.
@Observable @MainActor
final class Session {
    let store: Store
    private let phone: Phone
    private let crm: CRM
    /// Seconds between Aircall status checks while a call is up.
    var pollInterval: Duration = .milliseconds(1500)
    /// Give up waiting for Aircall to report the call after this long.
    var dialTimeout: TimeInterval = 45

    private(set) var state: CallState = .idle
    private(set) var list: Salesforce.ListView?
    private(set) var queue: [Lead] = []
    private(set) var index = 0
    private(set) var skipped: [SkippedLead] = []
    private(set) var history = History()
    private(set) var attempt: Attempt?
    private(set) var statusOptions: [String] = []
    var message: String?
    /// Auto-dialing is off until the rep presses Start auto-dialing; Stop turns it off again
    /// (the current call finishes, then it stays on the next person).
    private(set) var paused = true

    private var task: Task<Void, Never>?
    private var voicemailDropped = false
    /// Real phone and Salesforce (false in tests: no Chrome, no LinkedIn).
    private let isLive: Bool
    /// This call reached voicemail and was hung up at the beep to redial (call twice).
    private var hungUpAtBeep = false

    init(store: Store, phone: Phone? = nil, crm: CRM? = nil) {
        self.store = store
        self.phone = phone ?? LivePhone()
        self.crm = crm ?? LiveCRM()
        isLive = phone == nil
        if phone == nil {
            AircallPhone.shared.onBeep = { [weak self] _, _ in self?.heardBeep() }
            AircallPhone.shared.onRepSpeech = { [weak self] in self?.repSpeaking() }
            ScreenerListener.shared.onText = { [weak self] text in self?.otherSideSaid(text) }
        }
    }

    var lead: Lead? { queue.indices.contains(index) ? queue[index] : nil }
    var remaining: Int { max(0, queue.count - index) }
    var settings: OutboundSettings { store.settings }

    private func go(_ s: CallState) {
        task?.cancel()
        task = nil
        if s != state { Log.add("call", "\(state) -> \(s)" + (lead.map { " (\($0.name))" } ?? "")) }
        state = s
    }

    // MARK: List

    /// The list loaded last, reopened at launch.
    static var lastList: Salesforce.ListView? {
        get { UserDefaults.standard.data(forKey: "lastList").flatMap { try? JSONDecoder().decode(Salesforce.ListView.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "lastList") }
    }

    func load(_ view: Salesforce.ListView) async {
        go(.loading)
        list = view
        Self.lastList = view
        message = nil
        do {
            let leads = try await crm.leads(of: view)
            let sf = (try? await crm.callHistory(leads.map(\.id))) ?? [:]
            history = History(salesforce: sf, attempts: store.attempts)
            statusOptions = await crm.statuses(view.object)
            var callable: [Lead] = []
            skipped = []
            for l in leads {
                if let why = Rules.skip(l, settings, history) { skipped.append(SkippedLead(lead: l, reason: why)) } else { callable.append(l) }
            }
            queue = Rules.order(callable, settings, history)
            index = 0
            go(queue.isEmpty ? .finished : .ready)
            leadShown()
        } catch {
            message = error.localizedDescription
            go(.idle)
        }
    }

    // MARK: Calling

    func call(isRedial: Bool = false) {
        guard let lead, [.ready, .wrapUp].contains(state) || isCountdown || isRedial else { return }
        guard let number = lead.dialNumber else { return advance() }
        let dialsToday = history.dates(lead.id).filter { Calendar.current.isDateInToday($0) }.count
        guard dialsToday < Rules.maxDialsPerDay else {
            message = "\(lead.name) was already called \(dialsToday) times today. Moving on."
            return advance()
        }
        guard let user = settings.aircallUserID, let from = settings.fromNumberID else {
            message = "Pick your Aircall user and number in Settings."
            return go(.ready)
        }
        let fresh = Attempt(
            leadID: lead.id, leadName: lead.name, listID: list?.id ?? "", listName: list?.label ?? "",
            scriptID: store.script?.id, scriptName: store.script?.name ?? "",
            attemptNumber: history.dates(lead.id).count + 1, isRedial: isRedial,
            fromNumber: settings.fromNumberDigits, leadZone: lead.zone, dialedAt: Date(),
            statusBefore: lead.status)
        var started = fresh
        started.cadenceStep = todayStep(for: lead)
        started.linkedInSent = linkedInSentToday(lead)
        let a = started
        attempt = a
        voicemailDropped = false
        hungUpAtBeep = false
        repSpoke = false
        screened = false
        phoneTree = false
        badNumber = false
        vmAt = nil
        vmTask?.cancel(); vmTask = nil
        heardText = ""
        heardAt = .distantPast
        beepAt = nil
        if isLive, !ScreenerListener.authorized {
            Log.add("call", "speech recognition is NOT allowed: the app can't tell voicemail from a person, so it won't hang up or drop by itself (System Settings > Privacy & Security > Speech Recognition)")
        }
        message = nil
        store.save(a)
        history.add(lead.id, at: a.dialedAt)
        go(.dialing)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                Log.add("call", "dialing \(lead.name) \(number)\(isRedial ? " (call twice: 2nd dial)" : "")")
                // Right after a call, Aircall can still have the line busy for a few seconds (wrap-up):
                // keep trying for ~20 s instead of giving up on the second call.
                var tries = 0
                while true {
                    do { try await phone.dial(number, user: user, number: from); break } catch {
                        tries += 1
                        guard tries < 8, error.localizedDescription.contains("Available"), !Task.isCancelled else { throw error }
                        Log.add("call", "Aircall line still busy from the last call, retrying in 2.5s (try \(tries))")
                        try? await Task.sleep(for: .milliseconds(2500))
                    }
                }
            } catch {
                Log.add("call", "dial failed: \(error.localizedDescription)")
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
                return go(.ready)
            }
            await watch(user: user, number: from, since: a.dialedAt)
        }
    }

    private var isCountdown: Bool { if case .countdown = state { return true } else { return false } }

    /// Follows the call in Aircall until it's over.
    private func watch(user: Int, number: Int, since: Date) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled, attempt != nil else { return }
            let c = try? await phone.latestCall(user: user, number: number, since: since)
            guard !Task.isCancelled, var a = attempt else { return }
            guard let c else {
                if Date().timeIntervalSince(since) > dialTimeout {
                    // Never give up on a call that's still up (on hold with a screener, a long ring):
                    // only when Aircall's own phone shows no call either.
                    if await phone.callInProgress() == true {
                        if Int(Date().timeIntervalSince(since)) % 30 < 2 { Log.add("call", "Aircall's server hasn't listed the call yet, but the phone shows it's still up: waiting") }
                        continue
                    }
                    Log.add("call", "no call reported by Aircall after \(Int(dialTimeout))s and none on the phone: logging no answer")
                    message = "Aircall didn't report this call; logged as no answer. Change it under Last call if needed."
                    a.endedAt = Date()
                    attempt = a
                    return log(.noAnswer)
                }
                continue
            }
            if a.aircallCallID == nil || (c.answeredAt != nil) != (a.answeredAt != nil) || c.isOver {
                Log.add("aircall", "call \(c.id): status=\(c.status) answered=\(c.answeredAt != nil)")
            }
            a.aircallCallID = c.id
            a.answeredAt = c.answeredAt
            attempt = a
            if c.answeredAt != nil, state == .dialing { state = .live }
            if c.isOver {
                a.endedAt = c.endedAt ?? Date()
                a.needsSync = true
                attempt = a
                store.save(a)
                syncNow() // in Salesforce the moment the call ends, before any wrap-up
                return callEnded(answered: c.answeredAt != nil)
            }
        }
    }

    /// Every call logs itself and moves on, so auto-dialing never waits on the rep.
    /// The outcome can be changed afterwards under Last call (`amend`).
    private func callEnded(answered: Bool) {
        vmTask?.cancel(); vmTask = nil
        ScreenerListener.shared.end()
        Log.add("call", "call ended: answered=\(answered) heard=\"\(heardText.suffix(80))\" voicemail=\(vmAt != nil) dropped=\(voicemailDropped) screener=\(screened) phoneMenu=\(phoneTree) badNumber=\(badNumber) youSpoke=\(repSpoke)")
        if badNumber { return log(.badNumber) }
        if voicemailDropped || vmAt != nil { return log(.voicemail) }
        if phoneTree { return log(.noAnswer) }
        log(answered ? .connected : .noAnswer)
    }

    // MARK: What answered (Live Coach's rules: words decide, the beep only times the drop)

    private var repSpoke = false
    private var screened = false
    private var phoneTree = false
    private var badNumber = false
    /// When voicemail words were heard.
    private var vmAt: Date?
    private var vmTask: Task<Void, Never>?
    /// Everything the other side has said so far, and when it last changed.
    private var heardText = ""
    private var heardAt = Date.distantPast
    private var beepAt: Date?

    private var onCall: Bool { state == .live || state == .dialing }

    /// The rep is talking (to a person, a gatekeeper or a screener).
    func repSpeaking() {
        guard onCall, !repSpoke else { return }
        repSpoke = true
        attempt?.repSpoke = true
        Log.add("call", "you're talking: from here only words no person says count as voicemail")
    }

    /// New words from the other side. The one place that decides what answered.
    func otherSideSaid(_ text: String) {
        guard onCall else { return }
        heardText = text
        heardAt = Date()
        guard !screened, vmAt == nil, !badNumber, !phoneTree else { return }
        let early = !repSpoke && Date().timeIntervalSince(attempt?.answeredAt ?? attempt?.dialedAt ?? Date()) < 25
        if BadNumber.detects(text) {
            badNumber = true
            Log.add("call", "bad number: \"\(text.suffix(80))\" -> hanging up")
            return hangUp()
        }
        if Screener.detects(text) {
            screened = true
            attempt?.screenerHeard = true
            Log.add("call", "call screener: \"\(text.suffix(80))\" -> waiting for the person")
            message = "Call screener: say your name and reason. The app waits for them."
            return
        }
        if !repSpoke, PhoneTree.detects(text) {
            phoneTree = true
            Log.add("call", "phone menu: \"\(text.suffix(80))\" -> hanging up, next person")
            return hangUp()
        }
        // Once you've spoken it's a person: only words no person says still mean voicemail.
        let isVoicemail = repSpoke ? Voicemail.certain(text) : (Voicemail.detects(text, earlyInCall: early) || Voicemail.longGreeting(text, earlyInCall: early))
        if isVoicemail { voicemailHeard(text) }
    }

    private func voicemailHeard(_ text: String) {
        guard let lead else { return }
        vmAt = Date()
        attempt?.voicemailHeard = true
        let dialsToday = history.dates(lead.id).filter { Calendar.current.isDateInToday($0) }.count
        let action = Rules.onBeep(dialsToday: dialsToday, step: currentStep, settings)
        Log.add("call", "voicemail: \"\(text.suffix(80))\" (dial \(dialsToday) today, callTwice=\(settings.callTwice), drop=\(settings.voicemailDrop)) -> \(action)")
        switch action {
        case .hangUpAndRedial:
            hungUpAtBeep = true
            hangUp()               // call twice: no need to wait for the beep
        case .hangUp:
            hangUp()
        case .dropVoicemail:
            waitThenDrop()
        }
    }

    /// Drop at the right moment, best first: 0.35 s after a beep that followed the greeting (and no
    /// more talking after it); else once the greeting's words stopped (2 s after "...after the tone",
    /// 4 s otherwise). Never before 3 s after the voicemail was recognized, never after 30 s.
    private func waitThenDrop() {
        guard let start = vmAt else { return }
        vmTask?.cancel()
        vmTask = Task { [weak self] in
            var how = "30 s passed"
            while let self, self.onCall, !Task.isCancelled {
                let now = Date(), since = now.timeIntervalSince(start)
                if since >= 30 { break }
                if let b = self.beepAt, b > start.addingTimeInterval(-2), now.timeIntervalSince(b) >= 0.35,
                   self.heardAt <= b.addingTimeInterval(0.5), since >= 1 {
                    how = "beep"; break
                }
                let quiet = now.timeIntervalSince(self.heardAt)
                let endWords = Voicemail.recordingPrompt(self.heardText)
                if since >= 3, (endWords && quiet >= 2) || quiet >= 4 { how = endWords ? "greeting ended (\"after the tone\")" : "greeting went quiet"; break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, self.onCall, !Task.isCancelled else { return }
            Log.add("vm", "dropping now: \(how)")
            self.dropVoicemail()
        }
    }

    /// A pure tone on the other side. Never acted on by itself: it only times a voicemail drop.
    func heardBeep() {
        guard onCall else { return }
        beepAt = Date()
    }

    func hangUp() {
        Task {
            let ok = await phone.hangUp()
            Log.add("call", "hang up clicked: \(ok ? "found Aircall's button" : "button NOT found")")
            if !ok { message = "Couldn't find Aircall's hang-up button. Hang up in the phone." }
        }
    }

    /// Drops today's recorded voicemail (Voicemail 1 on Day 1, Voicemail 2 on Day 3...).
    /// The call is logged as a voicemail when Aircall ends it.
    func dropVoicemail() {
        guard state == .live || state == .dialing else { return }
        guard let name = currentStep?.voicemail?.nonBlankString else {
            message = "No voicemail on this day of the sequence. Just hang up (⌘.)."
            return
        }
        Task {
            let ok = await phone.dropVoicemail(named: name)
            Log.add("vm", "drop \(name): \(ok ? "clicked" : "Aircall's drop button NOT found")")
            if ok {
                voicemailDropped = true
                attempt?.voicemailDropped = true
            } else {
                message = "Couldn't find Aircall's voicemail drop button. Record a drop in Aircall first."
            }
        }
    }

    // MARK: Wrap-up

    /// Records the outcome, syncs to Salesforce in the background, then redials or moves on.
    func log(_ outcome: Outcome, note: String = "", status: String? = nil) {
        guard var a = attempt, let lead else { return }
        a.outcome = outcome
        a.note = note.trimmed
        a.endedAt = a.endedAt ?? Date()
        if let status = status.nonBlank {
            if status != lead.status { a.statusAfter = status } // the rep's pick wins (the picker starts on the step-up)
        } else if let stepped = autoStatus(for: lead) {
            a.statusAfter = stepped                      // the sequence's status for today, once a day
        }
        a.linkedInSent = a.linkedInSent || linkedInSentToday(lead)
        a.needsSync = true
        a.repSpoke = a.repSpoke ?? repSpoke
        attempt = nil
        store.save(a)
        Log.add("pickup", "\(lead.name): outcome=\(outcome) answered=\(a.answeredAt != nil) youSpoke=\(a.repSpoke ?? false) voicemailHeard=\(a.voicemailHeard ?? false) screener=\(a.screenerHeard ?? false) open=\(a.answeredAt.flatMap { s in a.endedAt.map { Int($0.timeIntervalSince(s)) } } ?? 0)s -> \(a.isPickup ? "PICKUP" : "not a pickup")")
        lastLoggedID = a.id
        if outcome.isFinal { history.finish(lead.id) }
        if let s = a.statusAfter { queue[index].status = s }

        let dialsToday = history.dates(lead.id).filter { Calendar.current.isDateInToday($0) }.count
        let redial = Rules.shouldRedial(outcome, dialsToday: dialsToday, settings, hungUpAtBeep: hungUpAtBeep)
        Log.add("redial", "\(lead.name): outcome=\(outcome) dialsToday=\(dialsToday) callTwice=\(settings.callTwice) hungUpAtBeep=\(hungUpAtBeep) paused=\(paused) -> \(redial ? "redial" : "no redial")")
        // Today's text goes once, after the last dial of the day (not before a redial).
        let text = redial || textSentToday(lead) ? nil
            : Rules.text(for: currentStep(for: lead), after: outcome, to: lead, rep: settings.repName)
        let textFrom = settings.textNumberID ?? settings.fromNumberID
        Task { await sync(a, lead: lead, text: text, from: textFrom) }

        if redial {
            // Paused: hold the second call for when the rep resumes, on this same person.
            if holdRedial { pendingRedial = true; return go(.ready) }
            go(.dialing)
            task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.call(isRedial: true)
            }
            return
        }
        advance()
    }

    /// The follow-up text; the attempt then goes to Salesforce again with "text sent" on it.
    private func sync(_ attempt: Attempt, lead: Lead, text: String?, from: Int?) async {
        if let text, let from, let mobile = lead.mobile.nonBlank {
            do {
                try await phone.sendText(text, to: mobile, from: from)
                if var a = store.attempts.first(where: { $0.id == attempt.id }) {
                    a.textSent = true
                    a.needsSync = true
                    store.save(a)
                }
            } catch { message = "Text not sent: \(error.localizedDescription)" }
        }
        syncNow()
    }

    // MARK: Salesforce sync

    /// The last call Salesforce accepted, for the on-screen confirmation.
    private(set) var lastSynced: (name: String, at: Date)?

    private var syncing = false
    private var syncAgain = false

    /// Sends every attempt Salesforce hasn't seen, one at a time (so one call never becomes two
    /// Tasks). Each is re-read from the store, so it always sends the latest version. Anything that
    /// fails stays marked and goes out on the next run (every minute, and at launch).
    func syncNow() {
        guard !syncing else { syncAgain = true; return }
        syncing = true
        Task {
            defer { syncing = false }
            repeat {
                syncAgain = false
                for id in store.unsynced.map(\.id) {
                    guard var a = store.attempts.first(where: { $0.id == id }) else { continue }
                    do {
                        a.salesforceTaskID = try await crm.logCall(a)
                        // Remember the Task right away, so a failed status update can't make a second Task.
                        if var keep = store.attempts.first(where: { $0.id == id }), keep.salesforceTaskID == nil {
                            keep.salesforceTaskID = a.salesforceTaskID
                            store.save(keep)
                        }
                        if let s = a.statusAfter, !a.statusSynced {
                            try await crm.setStatus(leadID: a.leadID, to: s)
                            a.statusSynced = true
                        }
                        // Changed while we were sending? Keep it marked so the change goes out too.
                        let latest = store.attempts.first(where: { $0.id == id })
                        var saved = latest ?? a
                        saved.salesforceTaskID = a.salesforceTaskID
                        saved.statusSynced = a.statusSynced
                        saved.needsSync = latest.map { $0.outcome != a.outcome || $0.note != a.note || $0.textSent != a.textSent || $0.endedAt != a.endedAt || $0.statusAfter != a.statusAfter || $0.voicemailDropped != a.voicemailDropped || $0.linkedInSent != a.linkedInSent } ?? false
                        store.save(saved)
                        lastSynced = (a.leadName, Date())
                    } catch {
                        message = "Saved on this Mac; will retry Salesforce: \(error.localizedDescription)"
                        Log.add("salesforce", "log failed for \(a.leadName): \(error.localizedDescription)")
                    }
                }
            } while syncAgain
        }
    }

    /// At launch: finishes calls the app was closed during, then keeps retrying every minute.
    /// At launch, with Auto LinkedIn Connect on: get macOS's Chrome permission asked up front.
    func checkLinkedInReady() async {
        guard LinkedInBot.isOn else { return }
        if let problem = await LinkedInBot.checkChrome() { linkedInStatus = "LinkedIn: " + problem + "." }
    }

    func startSync() async {
        for var a in store.attempts where a.endedAt == nil && a.salesforceTaskID == nil
            && Date().timeIntervalSince(a.dialedAt) > 600 {
            a.endedAt = a.dialedAt
            a.needsSync = true
            store.save(a)
        }
        while !Task.isCancelled {
            syncNow()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    // MARK: Last call

    private(set) var lastLoggedID: UUID?
    var lastLogged: Attempt? { lastLoggedID.flatMap { id in store.attempts.first { $0.id == id } } }

    /// Changes the last call's outcome or note after the fact (Meeting booked, Not interested...).
    /// Updates the same Salesforce Task.
    func amend(outcome: Outcome? = nil, note: String? = nil) {
        guard var a = lastLogged else { return }
        if let outcome {
            a.outcome = outcome
            if outcome.isFinal { history.finish(a.leadID) }
        }
        if let note { a.note = note.trimmed }
        a.needsSync = true
        store.save(a)
        syncNow()
    }

    // MARK: Moving

    func skip() {
        pendingRedial = false
        guard [.ready, .finished].contains(state) || isCountdown else { return }
        advance(autoDial: false)
    }

    func back() {
        pendingRedial = false
        guard index > 0, [.ready, .finished].contains(state) || isCountdown else { return }
        index -= 1
        go(.ready)
        leadShown()
    }

    /// Stops auto-dial; stays on this person.
    // MARK: Sequence

    /// Which step of the sequence today's call is (0 = Day 1), or nil if they're not due.
    func todayStep(for lead: Lead) -> Int? {
        switch settings.cadence.plan(callDates: history.dates(lead.id)) {
        case .due(let s, _), .calledToday(let s): return s
        default: return nil
        }
    }

    func currentStep(for lead: Lead) -> Step? {
        todayStep(for: lead).flatMap { settings.cadence.steps.indices.contains($0) ? settings.cadence.steps[$0] : nil }
    }

    var currentStep: Step? { lead.flatMap(currentStep(for:)) }

    func plan(for lead: Lead) -> Plan { settings.cadence.plan(callDates: history.dates(lead.id)) }

    /// Today's status for them, set only on their first call of the day (redials never step it again).
    func autoStatus(for lead: Lead) -> String? {
        let callsToday = history.dates(lead.id).filter { Calendar.current.isDateInToday($0) }.count
        guard callsToday <= 1, let step = todayStep(for: lead) else { return nil }
        return settings.cadence.status(forStep: step, current: lead.status, options: statusOptions)
    }

    private var linkedInDone: Set<String> = []

    private func today(_ lead: Lead) -> [Attempt] {
        store.attempts(for: lead.id).filter { Calendar.current.isDateInToday($0.dialedAt) }
    }

    func textSentToday(_ lead: Lead) -> Bool { today(lead).contains(where: \.textSent) }

    func linkedInSentToday(_ lead: Lead) -> Bool {
        linkedInDone.contains(History.key(lead.id)) || today(lead).contains(where: \.linkedInSent)
    }

    /// What the LinkedIn bot is doing, for the screen.
    private(set) var linkedInStatus: String? { didSet { if let l = linkedInStatus { Log.add("linkedin", l) } } }

    /// Day 1: sends the connection request with the sequence's note, in the rep's own Chrome,
    /// while the call rings (like Clarity Live Coach). Skips quietly when it can't.
    /// A person just came on screen: on their LinkedIn day, send the request right away
    /// (once per person per session, so going Back doesn't send twice).
    private func leadShown() {
        guard isLive, let lead, linkedInTried.insert(History.key(lead.id)).inserted else { return }
        connectOnLinkedIn(lead)
    }

    private var linkedInTried: Set<String> = []

    func connectOnLinkedIn(_ lead: Lead) {
        guard LinkedInBot.isOn else { return Log.add("linkedin", "\(lead.name): Auto LinkedIn Connect is off") }
        guard let note = currentStep(for: lead)?.linkedInNote?.nonBlankString else {
            return Log.add("linkedin", "\(lead.name): no LinkedIn step today (sequence step \(todayStep(for: lead).map { String($0 + 1) } ?? "none"))")
        }
        guard !linkedInSentToday(lead) else { return Log.add("linkedin", "\(lead.name): already sent today") }
        let text = LinkedInBot.note(Merge.fill(note, lead: lead, rep: settings.repName))
        Task {
            // The list load can miss the field; ask Salesforce for it directly.
            var raw = lead.linkedIn
            if Self.profileURL(raw) == nil { raw = await Salesforce.linkedIn(of: lead) }
            let profile = Self.profileURL(raw)

            // The automatic sender can't run (permission, limits, weekend...): just open them in Chrome
            // with the note on the clipboard, like before. No permission needed for that.
            var blocker = LinkedInBot.whyNot
            if blocker == nil { blocker = await LinkedInBot.checkChrome() }
            if let why = blocker {
                openForHand(lead, profile: profile, note: text, because: why)
                return
            }
            var url = profile
            if url == nil {
                linkedInStatus = "LinkedIn: searching for \(lead.name) in Chrome…"
                url = await LinkedInBot.findProfile(name: lead.name, company: lead.company)
            }
            guard let url else {
                openForHand(lead, profile: nil, note: text, because: LinkedInBot.chromeProblem ?? "couldn't find their profile automatically")
                return
            }
            linkedInStatus = "LinkedIn: opening \(lead.name)'s profile in Chrome…"
            LinkedInBot.personKey = History.key(lead.id)
            let result = await LinkedInBot.connect(profile: url, note: text, company: lead.company, name: lead.name) { [weak self] s in
                self?.linkedInStatus = s
            }
            switch result {
            case .sent: linkedInStatus = "LinkedIn: request sent to \(lead.name)."; markLinkedInSent(leadID: lead.id)
            case .pending: linkedInStatus = "LinkedIn: already requested."; markLinkedInSent(leadID: lead.id)
            case .alreadyConnected: linkedInStatus = "LinkedIn: already connected."; markLinkedInSent(leadID: lead.id)
            case .skipped(let why): openForHand(lead, profile: url, note: text, because: why)
            case .blocked(let why): linkedInStatus = "LinkedIn paused for 2 hours: \(why)."
            }
        }
    }

    /// Opens their LinkedIn (profile, or a search for them) in Chrome with the note copied, for the
    /// rep to click Connect > Add a note > paste. Used whenever the automatic sender can't finish.
    private func openForHand(_ lead: Lead, profile: URL?, note: String, because why: String) {
        var target = profile
        if target == nil {
            var c = URLComponents(string: "https://www.linkedin.com/search/results/people/")!
            c.queryItems = [URLQueryItem(name: "keywords", value: "\(lead.name) \(lead.company)")]
            target = c.url
        }
        guard let target else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note, forType: .string)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            NSWorkspace.shared.open([target], withApplicationAt: chrome, configuration: config)
        } else {
            NSWorkspace.shared.open(target)
        }
        linkedInStatus = "LinkedIn: opened \(lead.name) in Chrome, note copied. Click Connect > Add a note > ⌘V > Send. (Auto-send didn't run: \(why).)"
        markLinkedInSent(leadID: lead.id)
    }

    static func profileURL(_ raw: String?) -> URL? {
        guard var s = raw?.trimmed, s.lowercased().contains("linkedin.com/in/") else { return nil }
        if s.lowercased().hasPrefix("http://") { s = "https://" + s.dropFirst(7) }
        if !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        return URL(string: s)
    }

    /// The rep sent today's LinkedIn request. Recorded on today's call (and in Salesforce).
    func markLinkedInSent() {
        guard let lead else { return }
        markLinkedInSent(leadID: lead.id)
    }

    func markLinkedInSent(leadID: String) {
        linkedInDone.insert(History.key(leadID))
        if let a = attempt, History.key(a.leadID) == History.key(leadID) {
            attempt?.linkedInSent = true
            return
        }
        guard let lead = queue.first(where: { History.key($0.id) == History.key(leadID) }) else { return }
        if var last = today(lead).last {
            last.linkedInSent = true
            last.needsSync = true
            store.save(last)
            syncNow()
        }
    }

    /// Pause: stops a countdown now, and stops auto-dial after the current call. Resume restarts it.
    /// A call-twice redial that's waiting because the rep paused. Resuming makes it first.
    private(set) var pendingRedial = false
    /// The rep pressed Pause during a call: a second call that comes due waits for Resume.
    private var holdRedial = false

    /// Pause is a real pause: nothing is skipped or dropped. A countdown stops on the same person;
    /// a call in progress finishes; a call-twice redial that was due waits and goes first on resume.
    func togglePause() {
        paused.toggle()
        holdRedial = paused && [.dialing, .live].contains(state)
        if paused {
            if isCountdown { go(.ready) }
            // Paused in the short gap before the second call: keep it for later.
            if state == .dialing, attempt == nil { pendingRedial = true; go(.ready) }
        } else if state == .ready, settings.autoDial {
            resume()
        }
    }

    private func resume() {
        if pendingRedial {
            pendingRedial = false
            call(isRedial: true)
        } else {
            countdown(settings.countdown)
        }
    }

    func pause() { if !paused { togglePause() } }

    /// Start auto-dialing: calls this person now, then each next one after the countdown.
    func startAutoDialing() {
        paused = false
        holdRedial = false
        if pendingRedial, state == .ready {
            pendingRedial = false
            return call(isRedial: true)
        }
        if state == .ready || isCountdown { call() }
    }

    func stopAutoDialing() { pause() }

    private func advance(autoDial: Bool = true) {
        index += 1
        // Re-check as we go: calling hours change during the day.
        while let l = lead, let why = Rules.skip(l, settings, history) {
            skipped.append(SkippedLead(lead: l, reason: why))
            queue.remove(at: index)
        }
        guard lead != nil else { return go(.finished) }
        leadShown()
        guard autoDial, settings.autoDial, !paused else { return go(.ready) }
        countdown(settings.countdown)
    }

    private func countdown(_ seconds: Int) {
        guard seconds > 0 else { go(.ready); return call() }
        go(.countdown(seconds))
        task = Task { [weak self] in
            for left in stride(from: seconds, through: 1, by: -1) {
                // Paused or skipped before this task got to run: don't put the countdown back.
                if Task.isCancelled { return }
                self?.state = .countdown(left)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self?.call()
        }
    }
}
