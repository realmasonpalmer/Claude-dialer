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

    /// Five openers with the best published evidence (Gong Labs call studies).
    /// "Did I catch you at a bad time?" is deliberately absent: it tested worst.
    static let all: [Opener] = [
        Opener(
            id: "heard-name",
            name: "Heard the name",
            template: "Hey [first name], this is [rep] from [company]. Have you heard our name tossed around?",
            followUp: "If no: \"No worries, that's why I'm calling\" plus a one-line problem their peers have, then a question. If yes: \"Nice, what have you heard?\"",
            evidence: "Top opener in Gong's study of 300M+ cold calls (about 11% success)."
        ),
        Opener(
            id: "permission",
            name: "Permission",
            template: "Hi [first name], this is [rep] from [company]. I know I'm calling out of the blue. Mind if I take 30 seconds to tell you why, and you tell me if it's worth talking?",
            followUp: "Give the reason in one line built on a peer problem, then ask if it's true for them.",
            evidence: "Nearly tied for first in Gong's 300M-call study. Being upfront keeps people listening."
        ),
        Opener(
            id: "how-been",
            name: "How have you been",
            template: "Hey [first name], it's [rep] with [company]. How have you been?",
            followUp: "After their answer, be honest: \"Truth is, we haven't spoken before. This is a cold call. Can I tell you why I called?\"",
            evidence: "6.6x the average success rate in Gong's study of 90,000 cold calls."
        ),
        Opener(
            id: "reason-first",
            name: "Reason first",
            template: "Hi [first name], [rep] from [company]. The reason I'm calling is [a problem their peers have]. Is that on your radar?",
            followUp: "Dig into their answer with one follow-up question before saying anything about the offer.",
            evidence: "Saying why you're calling right away doubled success (2.1x) in Gong's research."
        ),
        Opener(
            id: "hang-up",
            name: "Wildcard: hang up or 30 seconds",
            template: "Hi [first name], [rep] from [company]. I'll be honest, this is a cold call. Want to hang up now, or give me 30 seconds?",
            followUp: "They usually laugh and say go ahead. Give the reason in one line, then ask a question.",
            evidence: "A fun pattern interrupt. The data is thinner, so your own calls will settle it."
        ),
    ]
}

/// Rotates openers call by call and keeps score on this Mac, so you run your own experiment.
struct OpenerScore: Codable {
    var calls = 0     // calls where a person answered
    var kept = 0      // they kept talking after the opener
    var goals = 0     // the campaign goal was reached
}

@MainActor
final class OpenerBook: ObservableObject {
    @Published private(set) var scores: [String: OpenerScore] = [:]
    @Published private(set) var index: Int
    @Published var rotate: Bool { didSet { defaults.set(rotate, forKey: "rotateOpeners") } }

    private let defaults = UserDefaults.standard

    init() {
        index = defaults.integer(forKey: "openerIndex") % Opener.all.count
        rotate = defaults.object(forKey: "rotateOpeners") as? Bool ?? true
        if let data = defaults.data(forKey: "openerScores"),
           let saved = try? JSONDecoder().decode([String: OpenerScore].self, from: data) {
            scores = saved
        }
    }

    var current: Opener { Opener.all[index] }

    /// Record a connected call for the current opener, then move to the next one.
    func record(kept: Bool, goal: Bool) {
        var score = scores[current.id] ?? OpenerScore()
        score.calls += 1
        if kept { score.kept += 1 }
        if goal { score.goals += 1 }
        scores[current.id] = score
        index = (index + 1) % Opener.all.count
        save()
    }

    func reset() {
        scores = [:]
        save()
    }

    private func save() {
        defaults.set(index, forKey: "openerIndex")
        if let data = try? JSONEncoder().encode(scores) { defaults.set(data, forKey: "openerScores") }
    }
}
