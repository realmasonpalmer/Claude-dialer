import Foundation

/// A proven cold call opener. Claude fills in the brackets for the campaign and the prospect.
struct Opener: Identifiable, Equatable {
    let id: String
    let name: String
    let template: String
    /// What to say after their reply, so the follow-up fits this opener.
    let followUp: String
    /// Where the evidence comes from, in plain words.
    let evidence: String

    /// The rep's best openers, best first. New callers start at the top and go down the list;
    /// after a few tries each, the ones that work best on your calls come up more often.
    static let all: [Opener] = [
        Opener(
            id: "peer-name-drop",
            name: "Peer name drop",
            template: "Hey [first name], we work with a few [industry] teams on Claude and AI. It's [rep] from Clarity Consulting. Have you heard our name tossed around?",
            followUp: "If no: \"No worries, that's why I'm calling\" plus a one-line problem their peers have, then a question. If yes: \"Nice, what have you heard?\"",
            evidence: "Your #1 opener. Name-drop openers topped Gong's study of 300M+ cold calls."
        ),
        Opener(
            id: "ask-30-seconds",
            name: "Ask for 30 seconds",
            template: "Hi [first name], this is [rep] at Clarity Consulting. I know you weren't expecting my call. Can I get 30 seconds to tell you why I called?",
            followUp: "Give the reason in one line built on a peer problem, then ask if it's true for them.",
            evidence: "Your #2 opener. Being upfront keeps people listening (Gong)."
        ),
        Opener(
            id: "problem-question",
            name: "Problem question",
            template: "Hey [first name], [rep] with Clarity Consulting. Quick reason for my call: we talk to sales leaders whose reps spend too much time updating notes, creating deliverables and following up with people, all that manual busy work. Is that you guys, or am I off base?",
            followUp: "Dig into their answer with one follow-up question before saying anything about the offer.",
            evidence: "Your #3 opener. Saying why you're calling right away doubled success (2.1x) in Gong's research."
        ),
    ]
}

/// One opener's results on your calls.
struct OpenerScore: Codable {
    var calls = 0     // calls where a person answered
    var kept = 0      // they kept talking after the opener
    var goals = 0     // the campaign goal was reached
    var good = 0      // calls scoring 50+ (see CallScore)
    var points = 0    // total score, for the average

    var average: Int { calls == 0 ? 0 : Int((Double(points) / Double(calls)).rounded()) }

    init() {}

    /// Older saved scores lack some fields; default them to 0.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calls = (try? c.decodeIfPresent(Int.self, forKey: .calls)) ?? 0
        kept = (try? c.decodeIfPresent(Int.self, forKey: .kept)) ?? 0
        goals = (try? c.decodeIfPresent(Int.self, forKey: .goals)) ?? 0
        good = (try? c.decodeIfPresent(Int.self, forKey: .good)) ?? 0
        points = (try? c.decodeIfPresent(Int.self, forKey: .points)) ?? 0
    }
}

/// Picks the opener for each call and keeps score on this Mac.
/// Every opener gets 3 tries first. After that, better openers come up more often
/// (Thompson sampling), but weaker ones still get the occasional try in case luck was involved.
@MainActor
final class OpenerBook: ObservableObject {
    @Published private(set) var scores: [String: OpenerScore] = [:]
    @Published private(set) var index: Int
    @Published var rotate: Bool { didSet { defaults.set(rotate, forKey: PrefKey.rotateOpeners) } }

    /// Tries each opener gets before results start steering the choice.
    static let warmUp = 3

    private let defaults = UserDefaults.standard

    init() {
        index = defaults.integer(forKey: PrefKey.openerIndex) % Opener.all.count
        rotate = defaults.object(forKey: PrefKey.rotateOpeners) as? Bool ?? true
        if let data = defaults.data(forKey: PrefKey.openerScores),
           let saved = try? JSONDecoder().decode([String: OpenerScore].self, from: data) {
            scores = saved
        }
    }

    var current: Opener { Opener.all[index] }

    /// Scores the call for the current opener, then picks the next one.
    func record(score: Int, kept: Bool, goal: Bool) {
        var s = scores[current.id] ?? OpenerScore()
        s.calls += 1
        s.points += score
        if kept { s.kept += 1 }
        if goal { s.goals += 1 }
        if score >= 50 { s.good += 1 }
        scores[current.id] = s
        chooseNext()
        save()
    }

    func reset() {
        scores = [:]
        save()
    }

    private func chooseNext() {
        let all = Opener.all
        func calls(_ i: Int) -> Int { scores[all[i].id]?.calls ?? 0 }
        // Warm-up: the least-tried opener goes next, starting after the current one.
        let order = (1...all.count).map { (index + $0) % all.count }
        if let fresh = order.filter({ calls($0) < Self.warmUp }).min(by: { calls($0) < calls($1) }) {
            index = fresh
            return
        }
        // Thompson sampling: draw a plausible good-call rate for each opener, use the highest draw.
        let draws = order.map { (index: $0, value: draw(all[$0])) } // draw once per opener
        index = draws.max { $0.value < $1.value }?.index ?? index
    }

    private func draw(_ opener: Opener) -> Double {
        let s = scores[opener.id] ?? OpenerScore()
        return Random.beta(Double(s.good + 1), Double(s.calls - s.good + 1))
    }

    private func save() {
        defaults.set(index, forKey: PrefKey.openerIndex)
        if let data = try? JSONEncoder().encode(scores) { defaults.set(data, forKey: PrefKey.openerScores) }
    }
}

/// Small random helpers for Thompson sampling.
enum Random {
    static func beta(_ a: Double, _ b: Double) -> Double {
        let x = gamma(a), y = gamma(b)
        return x / (x + y)
    }

    /// Marsaglia and Tsang's method. Shape must be at least 1, which it always is here.
    static func gamma(_ shape: Double) -> Double {
        let d = shape - 1.0 / 3.0
        let c = 1.0 / (9.0 * d).squareRoot()
        while true {
            var x = 0.0, v = 0.0
            repeat {
                x = normal()
                v = 1 + c * x
            } while v <= 0
            v = v * v * v
            let u = Double.random(in: 0..<1)
            if u < 1 - 0.0331 * x * x * x * x { return d * v }
            if log(u) < 0.5 * x * x + d * (1 - v + log(v)) { return d * v }
        }
    }

    static func normal() -> Double {
        let u1 = Double.random(in: Double.leastNonzeroMagnitude..<1)
        let u2 = Double.random(in: 0..<1)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
