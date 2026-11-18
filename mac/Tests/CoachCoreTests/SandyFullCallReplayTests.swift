import XCTest
@testable import CoachCore

/// The whole Sandy Adkins call (2026-11-18), replayed second by second: real transcript timing,
/// the real Haiku lines and latencies from the log, the queue, and what the screen shows.
/// It drives the same CoachCore rules the app uses (canReplace, QueuedLine, FollowRep, Delivery);
/// the small loop below stands in for the app's offer/promote code. Times are seconds from the dial.
final class SandyFullCallReplayTests: XCTestCase {
    enum Who { case rep, prospect }
    struct Turn { let who: Who; let start: Double; let end: Double; let text: String }

    // From the log (13:31:07.139 = 0). start = when the words began, end = the final transcript.
    let call: [Turn] = [
        Turn(who: .prospect, start: 9.0, end: 9.63, text: "Hello?"),
        Turn(who: .rep, start: 12.2, end: 13.97, text: "Hi, Sandy."),
        Turn(who: .rep, start: 14.8, end: 16.50, text: "This is Mason at Clarity Consulting."),
        Turn(who: .rep, start: 16.9, end: 19.51, text: "I know you weren't expecting my call. Can I give you"),
        Turn(who: .rep, start: 19.6, end: 20.97, text: "can I get thirty seconds just to tell you why I called?"),
        Turn(who: .prospect, start: 22.7, end: 23.72, text: "Sure."),
        Turn(who: .rep, start: 25.0, end: 25.96, text: "Cool."),
        Turn(who: .rep, start: 28.5, end: 29.52, text: "So, essentially,"),
        Turn(who: .rep, start: 30.6, end: 31.73, text: "what we do is"),
        Turn(who: .rep, start: 33.0, end: 36.75, text: "we are... We work with sales and RevOps teams."),
        Turn(who: .rep, start: 38.0, end: 41.54, text: "To, kind of, like, uncover where missed time is."),
        Turn(who: .rep, start: 43.0, end: 45.50, text: "So what, like, CRM are you guys using?"),
        Turn(who: .prospect, start: 49.4, end: 50.49, text: "Are you talking about my employer?"),
        Turn(who: .rep, start: 52.9, end: 53.96, text: "You're the VP of sales. Yeah?"),
        Turn(who: .prospect, start: 55.6, end: 56.06, text: "Correct."),
        Turn(who: .rep, start: 58.0, end: 58.97, text: "Yeah. So"),
        Turn(who: .rep, start: 59.5, end: 62.46, text: "what what, like, system do you guys use to, like, take notes and keep"),
        Turn(who: .rep, start: 64.2, end: 67.71, text: "track of? Like, leads and things like that in your pipelines."),
        Turn(who: .prospect, start: 69.0, end: 73.04, text: "Okay. Well, that's something that we use internally. So it's not something I can discuss"),
    ]
    let callEnds = 76.97
    let opener = "Hi Sandy, this is Mason at Clarity Consulting. I know you weren't expecting my call. Can I get 30 seconds to tell you why I called?"
    // The real Haiku answers and how long each took (the employer one includes its fix).
    let haikuAfter: [String: (line: String, seconds: Double)] = [
        "Sure.": ("Thanks, Sandy. Lots of sales leaders tell us reps lose hours typing call notes. Does that sound familiar for your team?", 1.57),
        "Are you talking about my employer?": ("Sorry, Sandy, I meant your sales team's customer records system. Which tool does your team use?", 2.0),
        "Correct.": ("Thanks, Sandy. Quick reason: sales leaders tell us reps lose hours typing call notes. Does that sound familiar to you?", 0.95),
    ]
    let followLatency = 1.0
    let yesLineLatency = 1.0 // Haiku writing the "yes" line while the rep waits for the answer

    struct Shown { let at: Double; let id: Int; let line: String }
    struct Request { let id: Int; let askedAt: Double; let readyAt: Double; let line: String; let repWords: Int; let repLed: Bool }

    func testWholeCall() {
        var shownLine = opener, shownAt = 0.0, shownID = 0
        var repSaidSinceShown = "", repWordsSinceShown = 0, answeredAfterDelivery = false, superseded = false
        var repWords = 0, repWordsAtLastAsk = 0
        var repTextSinceAsk = ""
        var pending: (req: Request, queuedAt: Double, askedSince: Bool)?
        var inflight: [Request] = []
        var seq = 0
        var shown: [Shown] = [Shown(at: 0, id: 0, line: opener)]
        var events: [String] = []
        var followsWhileTalking = 0
        var yesLine: (question: String, readyAt: Double)?
        var yesUsed: [Double] = []

        func repSpeaking(_ t: Double) -> Bool {
            // The app's rule (RepTurn.stillTalking): words in the air; else the transcriber's end-of-speech
            // call (it fires after 0.3 s of silence) and whether the sentence hangs; windows only as fallback.
            if call.contains(where: { $0.who == .rep && t >= $0.start && t <= $0.end }) { return true }
            guard let i = call.lastIndex(where: { $0.who == .rep && $0.end <= t }) else { return false }
            let last = call[i]
            let nextRep = call[(i + 1)...].first { $0.who == .rep }
            let endpointed = t >= last.end + 0.3 && (nextRep.map { $0.start > last.end + 0.3 } ?? true)
            return RepTurn.stillTalking(wordsInTheAir: false, endpointed: endpointed, lastFinal: last.text,
                                        secondsSinceFinal: t - last.end, inFallbackWindow: t <= last.end + SpeechTimeline.repActiveWindow)
        }
        func prospectSpeaking(_ t: Double) -> Bool {
            call.contains { $0.who == .prospect && t >= $0.start && t <= $0.end + SpeechTimeline.prospectActiveWindow }
        }
        func signals(_ t: Double) -> CoachSignals {
            let delivered = Delivery.delivered(line: shownLine, spoken: repSaidSinceShown)
            return CoachSignals(hasLine: true, prospectSpeaking: prospectSpeaking(t), repSpeaking: repSpeaking(t),
                                secondsSinceShown: t - shownAt, repStarted: repWordsSinceShown > 0, delivered: delivered,
                                prospectAnsweredSince: answeredAfterDelivery, queued: pending != nil, queuedIsForNewTopic: superseded,
                                lineWords: shownLine.split(separator: " ").count, overlapping: false,
                                repOnLine: Delivery.onLine(line: shownLine, spoken: repSaidSinceShown))
        }
        func show(_ r: Request, _ t: Double) {
            // Never while the rep talks: the core check the replay must prove.
            XCTAssertFalse(repSpeaking(t), "line #\(r.id) changed while the rep was speaking at \(t)")
            shown.append(Shown(at: t, id: r.id, line: r.line))
            events.append(String(format: "%6.2f  SHOWN #%d: %@", t, r.id, r.line))
            shownLine = r.line; shownAt = t; shownID = r.id
            repSaidSinceShown = ""; repWordsSinceShown = 0; answeredAfterDelivery = false; superseded = false
            pending = nil
        }
        func ask(_ t: Double, line: String, latency: Double, repLed: Bool) {
            seq += 1
            repWordsAtLastAsk = repWords
            repTextSinceAsk = ""
            inflight = [Request(id: seq, askedAt: t, readyAt: t + latency, line: line, repWords: repWords, repLed: repLed)]
            events.append(String(format: "%6.2f  ask #%d%@", t, seq, repLed ? " (follow the rep)" : ""))
        }

        var t = 0.0
        var nextTurn = 0
        while t <= callEnds {
            // 1. Transcript finals that land now.
            while nextTurn < call.count, call[nextTurn].end <= t {
                let turn = call[nextTurn]; nextTurn += 1
                if turn.who == .rep {
                    let n = turn.text.split(separator: " ").count
                    repWords += n; repWordsSinceShown += n
                    repSaidSinceShown += " " + turn.text
                    repTextSinceAsk += " " + turn.text
                    if pending != nil, turn.text.contains("?") { pending!.askedSince = true }
                    // A yes/no question: the line for "yes" is written now, held, never shown before the answer.
                    yesLine = RepQuestion.closedQuestion(in: turn.text).map { (question: $0, readyAt: t + yesLineLatency) }
                    if let y = yesLine { events.append(String(format: "%6.2f  writing the yes line for: %@", t, y.question)) }
                    let delivered = Delivery.delivered(line: shownLine, spoken: repSaidSinceShown)
                    let prevRep = call.prefix(nextTurn - 1).last { $0.who == .rep }?.text ?? ""
                    if FollowRep.shouldPrepare(repJustSaid: turn.text, recentRepSpeech: prevRep + " " + turn.text, shownLine: shownLine,
                                               shownLineDelivered: delivered, repWordsSinceLastAsk: repWords - repWordsAtLastAsk) {
                        if let p = pending { events.append(String(format: "%6.2f  dropped #%d while rep talks (heuristic)", t, p.req.id)) }
                        pending = nil
                        if repSpeaking(t) { followsWhileTalking += 1 }
                        ask(t, line: "FOLLOW: builds on \"\(turn.text)\"", latency: followLatency, repLed: true)
                    }
                } else {
                    if Delivery.delivered(line: shownLine, spoken: repSaidSinceShown), AnswerEvidence.isAnswer(turn.text) { answeredAfterDelivery = true }
                    let greeting = shownID == 0 && turn.text.split(separator: " ").count <= 4 && repWords == 0
                    let kind = ProspectReply.kind(turn.text)
                    if let y = yesLine, kind == .yes, y.readyAt <= t {
                        yesLine = nil
                        seq += 1
                        repWordsAtLastAsk = repWords
                        let r = Request(id: seq, askedAt: t, readyAt: t, line: "YES LINE after \"\(y.question)\"", repWords: repWords, repLed: false)
                        superseded = true // they answered the rep's question
                        yesUsed.append(t)
                        events.append(String(format: "%6.2f  \"%@\" is a yes: ready line, no wait", t, turn.text))
                        if CoachController.offer(isOpenerOrVoicemail: false, firstLine: false, holdLine: false, signals: signals(t)) == .show { show(r, t) } else { pending = (r, t, false) }
                    } else if !greeting {
                        yesLine = nil
                        let h = haikuAfter[turn.text] ?? (line: "ANSWER: \(turn.text)", seconds: 1.0)
                        ask(t, line: h.line, latency: h.seconds, repLed: false)
                    }
                }
            }
            // 2. Answers that finish now: show if safe, else queue (the app's offer()).
            if let r = inflight.first, r.readyAt <= t {
                inflight = []
                let lastProspect = call.prefix(nextTurn).last { $0.who == .prospect }
                let lastIsProspect = call.prefix(nextTurn).last?.who == .prospect
                let repAsked = call.prefix(nextTurn).dropLast().last { $0.who == .rep }?.text.hasSuffix("?") ?? false
                if r.repLed { superseded = true }
                else if lastIsProspect, let p = lastProspect,
                        repAsked || p.text.split(separator: " ").count >= 3 || p.text.contains("?") { superseded = true }
                if CoachController.offer(isOpenerOrVoicemail: false, firstLine: false, holdLine: false, signals: signals(t)) == .show { show(r, t) }
                else {
                    pending = (r, t, false)
                    events.append(String(format: "%6.2f  queued #%d (rep speaking: %@)", t, r.id, repSpeaking(t) ? "yes" : "no"))
                }
            }
            // 3. Each tick: promote a waiting line if safe, unless it went stale (the app's promotePendingIfReady()).
            if let p = pending {
                // The same decision function the app's promotePendingIfReady() calls (H7).
                switch CoachController.promote(holdLine: false, signals: signals(t), ageSeconds: t - p.queuedAt,
                                               repWordsSinceQueued: repWords - p.req.repWords, repAskedSinceQueued: p.askedSince,
                                               repTextSinceQueued: repTextSinceAsk) {
                case .wait: break
                case .show: show(p.req, t)
                case .drop(let why):
                    events.append(String(format: "%6.2f  dropped #%d at the pause: %@ (%@ rule)", t, p.req.id, why, QueuedLine.ruleKind(why)))
                    pending = nil
                }
            }
            t = (t * 100 + 5).rounded() / 100 // 50 ms ticks
        }
        print("Sandy replay:\n" + events.joined(separator: "\n"))

        // A. "Sure." to "Can I get 30 seconds?": the pitch was written while the rep asked, so it shows at once.
        let afterSure = shown.first { $0.at >= 23.72 }
        XCTAssertNotNil(afterSure)
        if let a = afterSure { XCTAssertLessThan(a.at - 23.72, 0.1, "the line after Sure wasn't ready") }
        // "Correct." to "...Yeah?" (a yes/no question) also used a ready line. Open questions ("What CRM?") didn't.
        XCTAssertEqual(yesUsed.count, 2)
        // B. No stale line: queued lines only show after passing QueuedLine.staleReason (step 3), and the
        // 23 s old pitch never comes back once the rep has pitched in their own words.
        XCTAssertFalse(shown.contains { $0.line.hasPrefix("Thanks, Sandy. Lots of") },
                       "the old pitch showed after the rep had pitched in their own words")
        // C. The coach prepared lines while the rep improvised, not only after they stopped.
        XCTAssertGreaterThan(followsWhileTalking, 0, "no line was prepared while the rep was talking off script")
        // D. When the rep finished with their own question, nothing was pushed over it (they wait for the answer).
        XCTAssertFalse(shown.contains { $0.at > 45.5 && $0.at < 50.49 }, "a line was pushed while the rep waited for an answer")
        // F. Never mid-sentence: the rep paused 1.7 s inside "...take notes and keep / track of?" and
        // the first replay showed a new line right there. Nothing may show between 62.46 and 67.71.
        XCTAssertFalse(shown.contains { $0.at > 62.46 && $0.at < 67.71 }, "a line changed in the middle of the rep's sentence")
        // E. Her question about her employer got its answer on screen within about 2 s.
        let employer = shown.first { $0.line.hasPrefix("Sorry, Sandy") }
        XCTAssertNotNil(employer)
        if let e = employer { XCTAssertLessThan(e.at - 50.49, 2.6) }
    }
}
