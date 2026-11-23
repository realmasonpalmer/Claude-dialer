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

    func testCadence() {
        let day: TimeInterval = 86_400
        var hist = History(); hist.add("00Q000000000001", at: noonPacific - day)  // called yesterday
        XCTAssertEqual(Rules.skip(lead(), s, hist, now: noonPacific, calendar: cal), .notDue(days: 1)) // 2nd call is day 2
        hist = History(); hist.add("00Q000000000001", at: noonPacific - 2 * day)
        XCTAssertNil(Rules.skip(lead(), s, hist, now: noonPacific, calendar: cal))
        hist = History()
        for d in [20.0, 18, 15, 11, 6] { hist.add("00Q000000000001", at: noonPacific - d * day) }
        XCTAssertEqual(Rules.skip(lead(), s, hist, now: noonPacific, calendar: cal), .finished)
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
    }

    func testEastToWest() {
        let ny = lead("1", mobile: "212-555-0100", state: "NY"), ca = lead("2", state: "CA"), tx = lead("3", mobile: "214-555-0100", state: "TX")
        XCTAssertEqual(Rules.order([ca, ny, tx], s).map(\.id), ["1", "3", "2"])
        var off = s; off.eastToWest = false
        XCTAssertEqual(Rules.order([ca, ny, tx], off).map(\.id), ["2", "1", "3"])
    }

    func testRedial() {
        var t = s; t.callTwice = true
        XCTAssertTrue(Rules.shouldRedial(.noAnswer, dialsToday: 1, t))
        XCTAssertFalse(Rules.shouldRedial(.noAnswer, dialsToday: 2, t))
        XCTAssertFalse(Rules.shouldRedial(.voicemail, dialsToday: 1, t))
        XCTAssertFalse(Rules.shouldRedial(.noAnswer, dialsToday: 1, s))
    }

    func testFollowUpText() {
        var t = s; t.textAfterVoicemail = true; t.repName = "Mason"
        XCTAssertEqual(Rules.followUpText(after: .voicemail, to: lead(), t),
                       "Hi Dana, it's Mason. Just tried you by phone. Is there a better time to connect?")
        XCTAssertNil(Rules.followUpText(after: .noAnswer, to: lead(), t))
        XCTAssertNil(Rules.followUpText(after: .voicemail, to: lead(mobile: nil, phone: "503-555-0100"), t))
    }

    func testSettingsDecodeWithMissingKeys() throws {
        let s = try JSONDecoder().decode(OutboundSettings.self, from: Data(#"{"callTwice": true}"#.utf8))
        XCTAssertTrue(s.callTwice)
        XCTAssertEqual(s.cadenceDays, [0, 2, 5, 9, 14])
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
    func dropVoicemail() async -> Bool { dropWorks }
}

@MainActor
final class FakeCRM: CRM {
    var people: [Lead] = []
    var logged: [Attempt] = []
    var statusSet: [String] = []
    func leads(of view: Salesforce.ListView) async throws -> [Lead] { people }
    func callHistory(_ ids: [String]) async throws -> [String: [Date]] { [:] }
    func statuses(_ object: SFObject) async -> [String] { ["New", "Contacted"] }
    func logCall(_ a: Attempt) async throws -> String { logged.append(a); return "00T\(logged.count)" }
    func setStatus(_ lead: Lead, to value: String) async throws { statusSet.append(value) }
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

    func wait(until done: () -> Bool) async {
        for _ in 0..<400 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testUnansweredCallLogsNoAnswerAndMovesOn() async {
        XCTAssertEqual(session.state, .ready)
        session.call()
        await wait { session.index == 1 }
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(store.attempts.first?.outcome, .noAnswer)
        await wait { !crm.logged.isEmpty }
        XCTAssertEqual(crm.logged.first?.outcome, .noAnswer)
    }

    func testAnsweredCallWaitsForWrapUp() async {
        phone.answers = [true]
        session.call()
        await wait { session.state == .wrapUp }
        XCTAssertEqual(session.state, .wrapUp)
        session.log(.meeting, note: "Thu 2pm", status: "Contacted")
        XCTAssertEqual(session.index, 1)
        await wait { !crm.statusSet.isEmpty }
        XCTAssertEqual(crm.statusSet, ["Contacted"])
        XCTAssertEqual(store.attempts.first?.note, "Thu 2pm")
        XCTAssertTrue(session.history.isFinished("00Q000000000001"))
    }

    func testCallTwiceRedialsOnce() async {
        store.settings.callTwice = true
        session.call()
        await wait { session.index == 1 }
        XCTAssertEqual(phone.dialed.count, 2)
        XCTAssertEqual(store.attempts.map(\.isRedial), [false, true])
        XCTAssertEqual(store.attempts.map(\.attemptNumber), [1, 2])
    }

    func testVoicemailDropLogsVoicemailAndTexts() async {
        store.settings.textAfterVoicemail = true
        phone.answers = [true]
        session.pollInterval = .milliseconds(80)
        session.call()
        await wait { session.state == .dialing && !phone.dialed.isEmpty }
        session.dropVoicemail()
        await wait { session.index == 1 }
        XCTAssertEqual(store.attempts.first?.outcome, .voicemail)
        await wait { !phone.texts.isEmpty }
        XCTAssertEqual(phone.texts.count, 1)
        await wait { store.attempts.first?.textSent == true }
        XCTAssertTrue(store.attempts.first?.textSent == true)
    }

    func testAutoDialCountsDownThenCalls() async {
        store.settings.autoDial = true
        store.settings.countdown = 1
        session.call()
        await wait { phone.dialed.count == 2 }
        XCTAssertEqual(phone.dialed.count, 2)
    }

    func testPauseStopsCountdown() async {
        store.settings.autoDial = true
        store.settings.countdown = 3
        session.call()
        await wait { if case .countdown = session.state { return true } else { return false } }
        session.pause()
        try? await Task.sleep(for: .seconds(1))
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(phone.dialed.count, 1)
    }

    func testAttemptsSurviveRelaunch() async {
        session.call()
        await wait { session.index == 1 }
        await wait { store.attempts.first?.salesforceTaskID != nil }
        let again = Store(folder: store.folderURL)
        XCTAssertEqual(again.attempts.count, 1)
        XCTAssertEqual(again.attempts.first?.outcome, .noAnswer)
        XCTAssertNotNil(again.attempts.first?.salesforceTaskID)
    }
}
