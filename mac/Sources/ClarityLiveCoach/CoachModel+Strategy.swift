import CoachCore
import Foundation

/// The strategic layer: what the whole call means for the rep's next move. The rules live in
/// CoachCore (CallStrategy) so they can be tested without a call; this file connects them to the live call.
extension CoachModel {
    func strategyTurns() -> [CallStrategy.Turn] {
        turns.map { CallStrategy.Turn(rep: $0.speaker == .rep, text: $0.text) }
    }

    /// After every final piece of transcript: decide what the call means now. The prompt and the line checks read it.
    func refreshStrategy() {
        guard status == .live, !callClosed, !voicemailActive, !screenerActive, !phoneTreeActive else {
            CoachPrompt.strategy = nil
            CoachPrompt.strategyFacts = ""
            return
        }
        let d = CallStrategy.current(strategyTurns())
        CoachPrompt.strategy = d
        CoachPrompt.strategyFacts = d.map { CallStrategy.promptText($0) } ?? ""
        let kind = d?.kind.rawValue ?? ""
        if kind != loggedStrategyKind {
            loggedStrategyKind = kind
            if let d {
                CallTrace.event("strategy.detected", ["kind": d.kind.rawValue, "why": d.reason, "think": d.think, "hard": d.hard])
                ActivityLog.add("Strategy: \(d.reason)")
            }
        }
    }

    /// A hard rule decided the move, so the app writes the card itself and nothing slower may replace it.
    func showStrategyCard(_ d: CallStrategy.Directive) {
        coachTask?.cancel()
        specTimer?.cancel()
        pending = nil
        yesBranch = nil
        yesBranchTask?.cancel()
        thinking = false
        seq += 1
        CoachPrompt.latestProspect = turns.last { $0.speaker == .prospect }?.text ?? ""
        var s = Suggestion(say: d.say, cue: "Coach: \(d.reason)", stage: "", sayComplete: true)
        s.think = d.think
        s.move = d.move
        s.strategy = d.kind.rawValue
        CallTrace.event("strategy.card", ["kind": d.kind.rawValue, "why": d.reason, "think": d.think, "say": d.say])
        show(s, id: seq, kind: .reply)
    }

    /// After the rep speaks: pitching with no reason, pushing past a no, or promising too much.
    /// One card per stretch of rep talk, never over the prospect.
    func strategyCheckAfterRep() {
        guard status == .live, !doNotCall, !callClosed, !voicemailActive, !screenerActive, !phoneTreeActive, !badNumberThisCall else { return }
        guard let d = CoachPrompt.strategy, d.hard, [CallStrategy.Kind.stopPitching, .respectNo, .riskyClaim].contains(d.kind) else { return }
        let prospectTurns = turns.filter { $0.speaker == .prospect }.count
        let key = "\(d.kind.rawValue)#\(prospectTurns)"
        guard key != lastStrategyKey, !signals().prospectSpeaking else { return }
        lastStrategyKey = key
        showStrategyCard(d)
    }
}
