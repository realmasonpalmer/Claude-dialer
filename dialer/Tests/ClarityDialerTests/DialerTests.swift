import XCTest
@testable import ClarityDialer

func lead(_ id: String = "00Q000000000001", mobile: String? = "(503) 555-0142", phone: String? = nil,
          state: String? = "OR", status: String = "New", dnc: Bool = false) -> Lead {
    Lead(id: id, object: .lead, name: "Dana Whitfield", firstName: "Dana", company: "Northwind", title: "CFO",
         phone: phone, mobile: mobile, city: "Portland", state: state, status: status, doNotCall: dnc)
}

/// Noon Pacific on a fixed day, so calling-hours checks are stable.
let noonPacific = ISO8601DateFormatter().date(from: "2026-11-23T20:00:00Z")!

final class RulesTests: XCTestCase {
    let s = OutboundSettings()
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!; return c }

    func testCallableByDefault() {
        XCTAssertNil(Rules.skip(lead(), s, History(), now: noonPacific, calendar: cal))
    }

    func testDoNotCallAndNoNumber() {
        XCTAssertEqual(Rules.skip(lead(dnc: true), s, History(), now: noonPacific), .doNotCall)
        XCTAssertEqual(Rules.skip(lead(mobile: nil), s, History(), now: noonPacific), .noNumber)
    }

    func testMobileOnly() {
        var m = s; m.mobileOnly = true
        XCTAssertEqual(Rules.skip(lead(mobile: nil, phone: "503-555-0100"), m, History(), now: noonPacific, calendar: cal), .noMobile)
    }

    func testForeignNumber() {
        XCTAssertEqual(Rules.skip(lead(mobile: "+44 20 7946 0958"), s, History(), now: noonPacific), .notNorthAmerican)
    }

    func testCallingHoursUseTheirZone() {
        // 20:00Z = 3pm Eastern, noon Pacific. Ending at 2pm: NY is out, Oregon is in.
        var h = s; h.endHour = 14
        XCTAssertNil(Rules.skip(lead(state: "OR"), h, History(), now: noonPacific, calendar: cal))
        if case .outsideHours = Rules.skip(lead(mobile: "212-555-0100", state: "NY"), h, History(), now: noonPacific, calendar: cal) {} else { XCTFail() }
    }

    func testCalledTodayIsSkipped() {
        var hist = History(); hist.add("00Q000000000001", at: noonPacific.addingTimeInterval(-3600))
        XCTAssertEqual(Rules.skip(lead(), s, hist, now: noonPacific, calendar: cal), .calledToday)
    }

    func testFinalOutcomeFinishes() {
        var a = Attempt(leadID: "00Q000000000001AAA", leadName: "", listID: "", listName: "", scriptName: "",
                        attemptNumber: 1, isRedial: false, fromNumber: "", dialedAt: noonPacific - 200_000, statusBefore: "")
        a.outcome = .meeting
        XCTAssertEqual(Rules.skip(lead(), s, History(attempts: [a]), now: noonPacific, calendar: cal), .finished)
    }

    func testHistoryDedupesSalesforceAndLocal() {
        let a = Attempt(leadID: "00Q000000000001", leadName: "", listID: "", listName: "", scriptName: "",
                        attemptNumber: 1, isRedial: false, fromNumber: "", dialedAt: noonPacific, statusBefore: "")
        let h = History(salesforce: ["00Q000000000001": [noonPacific.addingTimeInterval(30)]], attempts: [a])
        XCTAssertEqual(h.dates("00Q000000000001XYZ").count, 1)
        var redial = History(attempts: [a])
        redial.add("00Q000000000001", at: noonPacific.addingTimeInterval(5))
        XCTAssertEqual(redial.dates("00Q000000000001").count, 2, "a redial is a second call")
    }

    func testRedial() {
        var t = s; t.callTwice = true
        XCTAssertTrue(Rules.shouldRedial(.noAnswer, dialsToday: 1, t))
        XCTAssertFalse(Rules.shouldRedial(.noAnswer, dialsToday: 2, t))
        XCTAssertFalse(Rules.shouldRedial(.voicemail, dialsToday: 1, t))
        XCTAssertFalse(Rules.shouldRedial(.noAnswer, dialsToday: 1, s))
    }

    func testSettingsDecodeWithMissingKeys() throws {
        let s = try JSONDecoder().decode(OutboundSettings.self, from: Data(#"{"callTwice": true}"#.utf8))
        XCTAssertTrue(s.callTwice)
        XCTAssertEqual(s.cadence, .standard)
    }

    // MARK: Sequence (Day 1 / 3 / 5)

    let day: TimeInterval = 86_400
    var seq: Cadence { .standard }

    func testPlanWalksDay1Day3Day5() {
        XCTAssertEqual(seq.plan(callDates: [], now: noonPacific, calendar: cal), .due(step: 0, overdueDays: 0))
        XCTAssertEqual(seq.plan(callDates: [noonPacific - day], now: noonPacific, calendar: cal), .notYet(step: 1, inDays: 1))
        XCTAssertEqual(seq.plan(callDates: [noonPacific - 2 * day], now: noonPacific, calendar: cal), .due(step: 1, overdueDays: 0))
        XCTAssertEqual(seq.plan(callDates: [noonPacific - 4 * day], now: noonPacific, calendar: cal), .due(step: 1, overdueDays: 2))
        XCTAssertEqual(seq.plan(callDates: [noonPacific - 4 * day, noonPacific - 2 * day], now: noonPacific, calendar: cal), .due(step: 2, overdueDays: 0))
        XCTAssertEqual(seq.plan(callDates: [noonPacific - 5 * day, noonPacific - 3 * day, noonPacific - day], now: noonPacific, calendar: cal), .done)
        XCTAssertEqual(seq.plan(callDates: [noonPacific - 3600], now: noonPacific, calendar: cal), .calledToday(step: 0))
    }

    func testTwoCallsSameDayCountAsOneStep() {
        let calls = [noonPacific - 2 * day, noonPacific - 2 * day + 600]  // called twice on Day 1
        XCTAssertEqual(seq.plan(callDates: calls, now: noonPacific, calendar: cal), .due(step: 1, overdueDays: 0))
    }

    func testLateStepPushesTheNextOne() {
        // Day 3 call happened 2 days late: Day 5 is still 2 days after it, not overdue.
        let calls = [noonPacific - 5 * day, noonPacific - day]
        XCTAssertEqual(seq.plan(callDates: calls, now: noonPacific, calendar: cal), .notYet(step: 2, inDays: 1))
    }

    func testNotLoadedUntilDue() {
        var hist = History(); hist.add("00Q000000000001", at: noonPacific - day)
        XCTAssertEqual(Rules.skip(lead(), s, hist, now: noonPacific, calendar: cal), .notDue(days: 1))
        hist = History()
        for d in [5.0, 3, 1] { hist.add("00Q000000000001", at: noonPacific - d * day) }
        XCTAssertEqual(Rules.skip(lead(), s, hist, now: noonPacific, calendar: cal), .finished)
    }

    func testOverdueFirstThenFollowUpsThenNew() {
        let new = lead("N"), due = lead("D"), late = lead("L")
        var hist = History()
        hist.add("D", at: noonPacific - 2 * day)   // Day 3 due today
        hist.add("L", at: noonPacific - 5 * day)   // Day 3, 3 days overdue
        XCTAssertEqual(Rules.order([new, due, late], s, hist, now: noonPacific, calendar: cal).map(\.id), ["L", "D", "N"])
    }

    func testEastToWestWithinTheSameTier() {
        let ny = lead("1", mobile: "212-555-0100", state: "NY"), ca = lead("2", state: "CA"), tx = lead("3", mobile: "214-555-0100", state: "TX")
        XCTAssertEqual(Rules.order([ca, ny, tx], s, History(), now: noonPacific, calendar: cal).map(\.id), ["1", "3", "2"])
        var off = s; off.eastToWest = false
        XCTAssertEqual(Rules.order([ca, ny, tx], off, History(), now: noonPacific, calendar: cal).map(\.id), ["2", "1", "3"])
    }

    func testStatusForEachStep() {
        let opts = ["New", "1st Contact", "2nd Contact", "3rd Contact", "Qualified"]
        XCTAssertEqual(seq.status(forStep: 0, current: "New", options: opts), "1st Contact")
        XCTAssertEqual(seq.status(forStep: 0, current: "", options: opts), "1st Contact")
        XCTAssertEqual(seq.status(forStep: 1, current: "1st contact", options: opts), "2nd Contact")
        XCTAssertEqual(seq.status(forStep: 2, current: "2nd Contact", options: opts), "3rd Contact")
        XCTAssertNil(seq.status(forStep: 1, current: "2nd Contact", options: opts), "never backwards")
        XCTAssertNil(seq.status(forStep: 0, current: "Qualified", options: opts), "off the ladder: leave it")
        XCTAssertNil(seq.status(forStep: 0, current: "New", options: ["New", "Contacted"]), "org lacks the value")
    }

    func testTextsAndVoicemailsPerDay() {
        let steps = seq.steps
        XCTAssertEqual(steps.map(\.day), [1, 3, 5])
        XCTAssertEqual(steps.map(\.voicemail), ["Voicemail 1", "Voicemail 2", nil])
        XCTAssertNotNil(steps[0].linkedInNote)
        XCTAssertNil(steps[2].text, "Day 5: call only")
        var t = s; t.repName = "Mason"
        XCTAssertNotNil(Rules.text(for: steps[1], after: .noAnswer, to: lead(), rep: "Mason"))
        XCTAssertNil(Rules.text(for: steps[1], after: .connected, to: lead(), rep: "Mason"), "no text after a real conversation")
        XCTAssertNil(Rules.text(for: steps[2], after: .noAnswer, to: lead(), rep: "Mason"))
        XCTAssertNil(Rules.text(for: steps[0], after: .voicemail, to: lead(mobile: nil, phone: "503-555-0100"), rep: "Mason"))
        _ = t
    }

    func testZone() {
        XCTAssertEqual(CallZone.of(state: "Oregon", phones: []), .pacific)
        XCTAssertEqual(CallZone.of(state: nil, phones: ["(850) 555-0100"]), .central)
        XCTAssertNil(CallZone.of(state: nil, phones: ["+44 20 7946 0958"]))
    }
}

final class MetricsTests: XCTestCase {
    func attempt(_ o: Outcome, at t: TimeInterval, talk: TimeInterval = 0, lead: String = "A", redial: Bool = false) -> Attempt {
        var a = Attempt(leadID: lead, leadName: lead, listID: "L", listName: "List", scriptName: "S",
                        attemptNumber: 1, isRedial: redial, fromNumber: "+1503", dialedAt: noonPacific + t, statusBefore: "")
        a.outcome = o
        a.answeredAt = noonPacific + t + 10
        a.endedAt = noonPacific + t + 10 + talk
        return a
    }

    func testSummary() {
        let s = Metrics.summary([
            attempt(.noAnswer, at: 0),
            attempt(.voicemail, at: 60, talk: 40),           // voicemail talk doesn't count
            attempt(.connected, at: 120, talk: 20, lead: "B"),
            attempt(.meeting, at: 240, talk: 300, lead: "C"),
        ])
        XCTAssertEqual(s.dials, 4)
        XCTAssertEqual(s.uniqueLeads, 3)
        XCTAssertEqual(s.connects, 2)
        XCTAssertEqual(s.conversations, 1)
        XCTAssertEqual(s.meetings, 1)
        XCTAssertEqual(s.talkSeconds, 320)
        XCTAssertEqual(s.connectRate, 0.5)
        XCTAssertEqual(s.dialsPerMeeting, 4)
    }

    func testUnloggedAttemptsDontCount() {
        var a = attempt(.connected, at: 0); a.outcome = nil
        XCTAssertEqual(Metrics.summary([a]).dials, 0)
    }

    func testActiveTimeExcludesBreaks() {
        let s = Metrics.summary([attempt(.noAnswer, at: 0), attempt(.noAnswer, at: 60), attempt(.noAnswer, at: 7200)])
        // 60s + 10 min cap + last call (min 30s)
        XCTAssertEqual(s.activeSeconds, 60 + 600 + 30)
    }

    func testBreakdown() {
        let rows = Metrics.rows([attempt(.noAnswer, at: 0), attempt(.meeting, at: 60, redial: true)], by: .redial)
        XCTAssertEqual(rows.map(\.label), ["First dial", "Redial"])
        XCTAssertEqual(rows[1].summary.meetings, 1)
    }

    func testCSV() {
        let csv = Metrics.csv([attempt(.meeting, at: 0)])
        XCTAssertEqual(csv.split(separator: "\n").count, 2)
        XCTAssertTrue(csv.contains("Meeting booked"))
    }
}

// MARK: - Session with fake services

@MainActor
final class FakePhone: Phone {
    var dialed: [String] = []
    var texts: [String] = []
    /// What Aircall reports for each dial, in order.
    var answers: [Bool] = []
    var dropWorks = true

    func dial(_ to: String, user: Int, number: Int) async throws { dialed.append(to) }
    func latestCall(user: Int, number: Int, since: Date) async throws -> Aircall.Call? {
        let answered = answers.isEmpty ? false : answers[min(dialed.count, answers.count) - 1]
        return Aircall.Call(id: dialed.count, status: "done", startedAt: since,
                            answeredAt: answered ? since.addingTimeInterval(1) : nil, endedAt: since.addingTimeInterval(20))
    }
    func sendText(_ body: String, to: String, from number: Int) async throws { texts.append(body) }
    func hangUp() async -> Bool { true }
    var droppedNames: [String] = []
    func dropVoicemail(named: String) async -> Bool { droppedNames.append(named); return dropWorks }
}

@MainActor
final class FakeCRM: CRM {
    var people: [Lead] = []
    var logged: [Attempt] = []
    var statusSet: [String] = []
    func leads(of view: Salesforce.ListView) async throws -> [Lead] { people }
    func callHistory(_ ids: [String]) async throws -> [String: [Date]] { [:] }
    func statuses(_ object: SFObject) async -> [String] { ["New", "1st Contact", "2nd Contact", "3rd Contact", "Contacted"] }
    var created = 0
    var failNext = false
    func logCall(_ a: Attempt) async throws -> String {
        if failNext { failNext = false; throw Salesforce.SFError(message: "offline") }
        logged.append(a)
        if let id = a.salesforceTaskID { return id }
        created += 1
        return "00T\(created)"
    }
    func setStatus(leadID: String, to value: String) async throws { statusSet.append(value) }
}

@MainActor
final class SessionTests: XCTestCase {
    var phone: FakePhone!
    var crm: FakeCRM!
    var store: Store!
    var session: Session!

    override func setUp() async throws {
        phone = FakePhone()
        crm = FakeCRM()
        // No state filter: calling hours depend on the real clock here.
        crm.people = [lead("00Q000000000001", state: nil), lead("00Q000000000002", state: nil)]
        store = Store(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.settings.aircallUserID = 1
        store.settings.fromNumberID = 2
        store.settings.autoDial = false
        store.settings.startHour = 0
        store.settings.endHour = 24
        session = Session(store: store, phone: phone, crm: crm)
        session.pollInterval = .milliseconds(5)
        await session.load(Salesforce.ListView(id: "LV", label: "List", object: .lead))
    }

    func wait(until done: @escaping () -> Bool) async {
        var tries = 0
        while !done(), tries < 400 {
            tries += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testUnansweredCallLogsNoAnswerAndMovesOn() async {
        XCTAssertEqual(session.state, .ready)
        session.call()
        await wait { [self] in session.index == 1 }
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(store.attempts.first?.outcome, .noAnswer)
        await wait { [self] in !crm.logged.isEmpty }
        XCTAssertEqual(crm.logged.first?.outcome, .noAnswer)
    }

    func testAnsweredCallWaitsForWrapUp() async {
        phone.answers = [true]
        session.call()
        await wait { [self] in session.state == .wrapUp }
        XCTAssertEqual(session.state, .wrapUp)
        session.log(.meeting, note: "Thu 2pm", status: "Contacted")
        XCTAssertEqual(session.index, 1)
        await wait { [self] in !crm.statusSet.isEmpty }
        XCTAssertEqual(crm.statusSet, ["Contacted"])
        XCTAssertEqual(store.attempts.first?.note, "Thu 2pm")
        XCTAssertTrue(session.history.isFinished("00Q000000000001"))
    }

    func testEveryCallIsLoggedWhenItEndsThenUpdated() async {
        phone.answers = [true]
        session.call()
        await wait { [self] in session.state == .wrapUp }
        // In Salesforce before the rep picks an outcome.
        await wait { [self] in store.attempts.first?.salesforceTaskID != nil }
        XCTAssertEqual(crm.created, 1)
        XCTAssertNil(crm.logged.first?.outcome)
        session.log(.connected, note: "Call back Monday")
        await wait { [self] in crm.logged.last?.outcome == .connected }
        XCTAssertEqual(crm.created, 1, "one call = one Task, updated in place")
        XCTAssertEqual(crm.logged.last?.note, "Call back Monday")
        XCTAssertEqual(store.unsynced.count, 0)
    }

    func testFailedSyncIsRetried() async {
        crm.failNext = true
        session.call()
        await wait { [self] in session.index == 1 }
        try? await Task.sleep(for: .milliseconds(100))
        session.syncNow()
        await wait { [self] in store.unsynced.isEmpty }
        XCTAssertEqual(store.unsynced.count, 0)
        XCTAssertEqual(crm.created, 1)
        XCTAssertEqual(crm.logged.last?.outcome, .noAnswer)
    }

    func testUnansweredCallStepsStatusOnce() async {
        session.call()
        await wait { [self] in session.index == 1 }
        await wait { [self] in !crm.statusSet.isEmpty }
        XCTAssertEqual(crm.statusSet, ["1st Contact"])
        XCTAssertEqual(session.queue[0].status, "1st Contact")
    }

    func testRedialSameDayDoesNotStepAgain() async {
        store.settings.callTwice = true
        session.call()
        await wait { [self] in session.index == 1 }
        await wait { [self] in store.unsynced.isEmpty && !crm.statusSet.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(phone.dialed.count, 2)
        XCTAssertEqual(crm.statusSet, ["1st Contact"], "two calls today, one step")
        XCTAssertEqual(store.attempts.compactMap(\.statusAfter), ["1st Contact"])
    }

    func testRepStatusPickWins() async {
        phone.answers = [true]
        session.call()
        await wait { [self] in session.state == .wrapUp }
        XCTAssertEqual(session.autoStatus(for: session.lead!), "1st Contact")
        session.log(.connected, status: "New") // rep keeps it at New on purpose
        await wait { [self] in store.unsynced.isEmpty }
        XCTAssertNil(store.attempts.first?.statusAfter)
        XCTAssertTrue(crm.statusSet.isEmpty)
    }

    func testPauseMidCallStopsAfterIt() async {
        store.settings.autoDial = true
        store.settings.countdown = 1
        phone.answers = [true]
        session.call()
        await wait { [self] in session.state == .wrapUp }
        session.togglePause()
        session.log(.connected)
        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(session.index, 1)
        XCTAssertEqual(phone.dialed.count, 1, "paused: no auto-dial")
        session.togglePause() // resume -> countdown -> dial
        await wait { [self] in phone.dialed.count == 2 }
        XCTAssertEqual(phone.dialed.count, 2)
    }

    func testRedialSendsOneTextAfterTheLastDial() async {
        store.settings.callTwice = true
        session.call()
        await wait { [self] in session.index == 1 }
        await wait { [self] in !phone.texts.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(phone.dialed.count, 2)
        XCTAssertEqual(phone.texts.count, 1)
    }

    func testDay5HasNoVoicemail() async {
        // Called on Day 1 and Day 3 already.
        let id = "00Q000000000001"
        for d in [4.0, 2] {
            var a = Attempt(leadID: id, leadName: "", listID: "", listName: "", scriptName: "", attemptNumber: 1,
                            isRedial: false, fromNumber: "", dialedAt: Date() - d * 86_400, statusBefore: "")
            a.outcome = .noAnswer
            store.save(a)
        }
        await session.load(Salesforce.ListView(id: "LV", label: "List", object: .lead))
        XCTAssertEqual(session.lead?.id, id)
        XCTAssertEqual(session.currentStep?.day, 5)
        XCTAssertNil(session.currentStep?.voicemail)
        phone.answers = [true]
        session.call()
        await wait { [self] in session.state == .dialing || session.state == .live }
        session.dropVoicemail()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(phone.droppedNames.isEmpty)
    }

    func testCallTwiceRedialsOnce() async {
        store.settings.callTwice = true
        session.call()
        await wait { [self] in session.index == 1 }
        XCTAssertEqual(phone.dialed.count, 2)
        XCTAssertEqual(store.attempts.map(\.isRedial), [false, true])
        XCTAssertEqual(store.attempts.map(\.attemptNumber), [1, 2])
    }

    func testVoicemailDropLogsVoicemailAndTexts() async {
        phone.answers = [true]
        session.pollInterval = .milliseconds(80)
        session.call()
        await wait { [self] in session.state == .dialing && !phone.dialed.isEmpty }
        session.dropVoicemail()
        await wait { [self] in session.index == 1 }
        XCTAssertEqual(store.attempts.first?.outcome, .voicemail)
        await wait { [self] in !phone.texts.isEmpty }
        XCTAssertEqual(phone.texts.count, 1)
        await wait { [self] in store.attempts.first?.textSent == true }
        XCTAssertTrue(store.attempts.first?.textSent == true)
        XCTAssertEqual(phone.droppedNames, ["Voicemail 1"], "Day 1 drops Voicemail 1")
        XCTAssertTrue(phone.texts.first?.contains("Claude or other AI tools") == true, "Day 1 sends Text 1")
    }

    func testAutoDialCountsDownThenCalls() async {
        store.settings.autoDial = true
        store.settings.countdown = 1
        session.call()
        await wait { [self] in phone.dialed.count == 2 }
        XCTAssertEqual(phone.dialed.count, 2)
    }

    func testPauseStopsCountdown() async {
        store.settings.autoDial = true
        store.settings.countdown = 3
        session.call()
        await wait { [self] in if case .countdown = session.state { return true } else { return false } }
        session.pause()
        try? await Task.sleep(for: .seconds(1))
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(phone.dialed.count, 1)
    }

    func testAttemptsSurviveRelaunch() async {
        session.call()
        await wait { [self] in session.index == 1 }
        await wait { [self] in store.unsynced.isEmpty && store.attempts.first?.salesforceTaskID != nil }
        let again = Store(folder: store.folderURL)
        XCTAssertEqual(again.attempts.count, 1)
        XCTAssertEqual(again.attempts.first?.outcome, .noAnswer)
        XCTAssertNotNil(again.attempts.first?.salesforceTaskID)
    }
}
