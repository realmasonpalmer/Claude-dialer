import Foundation
import Observation

/// The phone side of a call. Live: Aircall's API + the in-app Aircall phone. Tests: a fake.
@MainActor protocol Phone {
    func dial(_ to: String, user: Int, number: Int) async throws
    func latestCall(user: Int, number: Int, since: Date) async throws -> Aircall.Call?
    func sendText(_ body: String, to: String, from number: Int) async throws
    func hangUp() async -> Bool
    func dropVoicemail() async -> Bool
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
    func dropVoicemail() async -> Bool { await AircallPhone.shared.dropVoicemail() }
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
    /// Auto-dial is paused: finish the current call, then stay on the next person.
    private(set) var paused = false

    private var task: Task<Void, Never>?
    private var voicemailDropped = false

    init(store: Store, phone: Phone? = nil, crm: CRM? = nil) {
        self.store = store
        self.phone = phone ?? LivePhone()
        self.crm = crm ?? LiveCRM()
    }

    var lead: Lead? { queue.indices.contains(index) ? queue[index] : nil }
    var remaining: Int { max(0, queue.count - index) }
    var settings: OutboundSettings { store.settings }

    private func go(_ s: CallState) {
        task?.cancel()
        task = nil
        state = s
    }

    // MARK: List

    func load(_ view: Salesforce.ListView) async {
        go(.loading)
        list = view
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
            queue = Rules.order(callable, settings)
            index = 0
            go(queue.isEmpty ? .finished : .ready)
        } catch {
            message = error.localizedDescription
            go(.idle)
        }
    }

    // MARK: Calling

    func call(isRedial: Bool = false) {
        guard let lead, [.ready, .wrapUp].contains(state) || isCountdown || isRedial else { return }
        guard let number = lead.dialNumber else { return advance() }
        guard let user = settings.aircallUserID, let from = settings.fromNumberID else {
            message = "Pick your Aircall user and number in Settings."
            return go(.ready)
        }
        let a = Attempt(
            leadID: lead.id, leadName: lead.name, listID: list?.id ?? "", listName: list?.label ?? "",
            scriptID: store.script?.id, scriptName: store.script?.name ?? "",
            attemptNumber: history.dates(lead.id).count + 1, isRedial: isRedial,
            fromNumber: settings.fromNumberDigits, leadZone: lead.zone, dialedAt: Date(),
            statusBefore: lead.status)
        attempt = a
        voicemailDropped = false
        message = nil
        store.save(a)
        history.add(lead.id, at: a.dialedAt)
        go(.dialing)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await phone.dial(number, user: user, number: from)
            } catch {
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
                    message = "Aircall didn't report this call. Log it by hand."
                    a.endedAt = Date()
                    a.needsSync = true
                    attempt = a
                    store.save(a)
                    syncNow()
                    go(.wrapUp)
                    return
                }
                continue
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

    private func callEnded(answered: Bool) {
        if voicemailDropped { return log(.voicemail) }
        if !answered { return log(.noAnswer) }
        go(.wrapUp)
    }

    func hangUp() {
        Task { if !(await phone.hangUp()) { message = "Couldn't find Aircall's hang-up button. Hang up in the phone." } }
    }

    /// Drops the recorded voicemail. The call is logged as a voicemail when Aircall ends it.
    func dropVoicemail() {
        guard state == .live || state == .dialing else { return }
        Task {
            if await phone.dropVoicemail() {
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
            a.statusAfter = stepped                      // New -> 1st -> 2nd -> 3rd contact, once a day
        }
        a.needsSync = true
        attempt = nil
        store.save(a)
        if outcome.isFinal { history.finish(lead.id) }
        if let s = a.statusAfter { queue[index].status = s }

        let text = Rules.followUpText(after: outcome, to: lead, settings)
        let textFrom = settings.textNumberID ?? settings.fromNumberID
        Task { await sync(a, lead: lead, text: text, from: textFrom) }

        let dialsToday = history.dates(lead.id).filter { Calendar.current.isDateInToday($0) }.count
        if Rules.shouldRedial(outcome, dialsToday: dialsToday, settings) {
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
                        if let s = a.statusAfter, !a.statusSynced {
                            try await crm.setStatus(leadID: a.leadID, to: s)
                            a.statusSynced = true
                        }
                        // Changed while we were sending? Keep it marked so the change goes out too.
                        let latest = store.attempts.first(where: { $0.id == id })
                        var saved = latest ?? a
                        saved.salesforceTaskID = a.salesforceTaskID
                        saved.statusSynced = a.statusSynced
                        saved.needsSync = latest.map { $0.outcome != a.outcome || $0.note != a.note || $0.textSent != a.textSent || $0.endedAt != a.endedAt || $0.statusAfter != a.statusAfter || $0.voicemailDropped != a.voicemailDropped } ?? false
                        store.save(saved)
                    } catch {
                        message = "Saved on this Mac; will retry Salesforce: \(error.localizedDescription)"
                    }
                }
            } while syncAgain
        }
    }

    /// At launch: finishes calls the app was closed during, then keeps retrying every minute.
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

    // MARK: Moving

    func skip() {
        guard [.ready, .finished].contains(state) || isCountdown else { return }
        advance(autoDial: false)
    }

    func back() {
        guard index > 0, [.ready, .finished].contains(state) || isCountdown else { return }
        index -= 1
        go(.ready)
    }

    /// Stops auto-dial; stays on this person.
    /// The status this call would step them to (see Rules.steppedStatus), for the wrap-up picker too.
    func autoStatus(for lead: Lead) -> String? {
        let callsToday = history.dates(lead.id).filter { Calendar.current.isDateInToday($0) }.count
        return Rules.steppedStatus(from: lead.status, callsToday: callsToday, options: statusOptions)
    }

    /// Pause: stops a countdown now, and stops auto-dial after the current call. Resume restarts it.
    func togglePause() {
        paused.toggle()
        if paused {
            if isCountdown { go(.ready) }
        } else if state == .ready, settings.autoDial {
            countdown(settings.countdown)
        }
    }

    func pause() { if !paused { togglePause() } }

    private func advance(autoDial: Bool = true) {
        index += 1
        // Re-check as we go: calling hours change during the day.
        while let l = lead, let why = Rules.skip(l, settings, history) {
            skipped.append(SkippedLead(lead: l, reason: why))
            queue.remove(at: index)
        }
        guard lead != nil else { return go(.finished) }
        guard autoDial, settings.autoDial, !paused else { return go(.ready) }
        countdown(settings.countdown)
    }

    private func countdown(_ seconds: Int) {
        guard seconds > 0 else { go(.ready); return call() }
        go(.countdown(seconds))
        task = Task { [weak self] in
            for left in stride(from: seconds, through: 1, by: -1) {
                self?.state = .countdown(left)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self?.call()
        }
    }
}
