import Foundation
import Observation

/// Reads each picked-up call's Aircall transcript with Claude to decide two things the phone
/// can't: did the lead themself answer (not a front desk or someone else), and was a meeting
/// agreed to a specific time (then the call is marked Meeting booked in Salesforce).
/// Runs in the background every minute; nothing waits on it.
@MainActor
final class CallReview {
    private let store: Store
    private var running = false

    init(store: Store) { self.store = store }

    static var hasKey: Bool { Keychain.read(.anthropic) != nil }

    func run() async {
        while !Task.isCancelled {
            await pass()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    func pass() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let now = Date()
        for a in store.attempts {
            guard let ended = a.endedAt, now.timeIntervalSince(ended) > 90,
                  now.timeIntervalSince(ended) < 3 * 86_400 else { continue }
            if a.reviewedAt == nil, a.answeredAt != nil, a.aircallCallID != nil, Self.hasKey {
                await review(a, ended: ended)
            }
        }
    }

    private func review(_ a: Attempt, ended: Date) async {
        guard let callID = a.aircallCallID else { return }
        let text = try? await Aircall.transcript(callID: callID)
        guard let text else {
            // No transcript 30 minutes after the call: Aircall won't make one (too short, or off).
            if Date().timeIntervalSince(ended) > 1800 { update(a.id) { $0.reviewedAt = Date() } }
            return
        }
        guard let verdict = try? await Self.classify(transcript: text, leadName: a.leadName) else { return }
        let booked = Self.isCertainMeeting(verdict, transcript: text)
        update(a.id) {
            $0.reviewedAt = Date()
            $0.reachedLead = verdict.reachedLead
            $0.meetingAgreed = booked
            $0.meetingTime = verdict.meetingTime.isEmpty ? nil : verdict.meetingTime
            $0.reviewSummary = verdict.summary
            if booked {
                $0.outcome = .meeting
                $0.needsSync = true // the call's Salesforce Task now says Meeting booked
            }
            if !verdict.reachedLead, $0.outcome == .connected { $0.note = ($0.note.isEmpty ? "" : $0.note + "\n") + "Not the lead: " + verdict.summary }
        }
    }

    private func update(_ id: UUID, _ change: (inout Attempt) -> Void) {
        guard var a = store.attempts.first(where: { $0.id == id }) else { return }
        change(&a)
        store.save(a)
    }

    // MARK: Claude

    struct Verdict: Decodable {
        let reachedLead: Bool
        let meetingAgreed: Bool
        /// "certain" only when nothing about the booking is in doubt.
        let meetingCertainty: String
        let meetingTime: String
        /// The lead's own words agreeing, copied exactly from the transcript.
        let leadConfirmationQuote: String
        let summary: String
    }

    /// A meeting counts only when every check passes: the lead themself answered, Claude is
    /// certain, a specific day and time were set, and the lead's agreeing words really are in the
    /// transcript (checked here, so a made-up quote can't count).
    static func isCertainMeeting(_ v: Verdict, transcript: String) -> Bool {
        func norm(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
                .split(separator: " ").joined(separator: " ")
        }
        let quote = norm(v.leadConfirmationQuote)
        let themLines = transcript.split(separator: "\n").filter { $0.hasPrefix("Them:") }.map { norm(String($0)) }
        return v.reachedLead && v.meetingAgreed && v.meetingCertainty == "certain"
            && !v.meetingTime.trimmed.isEmpty
            && quote.count >= 2 && themLines.contains { $0.contains(quote) }
    }

    private static let system = """
    You review transcripts of outbound sales calls. "Rep" is the salesperson; "Them" is whoever answered.
    Decide:
    - reachedLead: true only if the person the rep was calling (the named lead) was on the line and spoke as themself. \
    False for a front desk, receptionist, assistant, operator, voicemail greeting, phone menu, wrong number, or anyone \
    who says they are someone else or whose name clearly does not match the lead. If unsure, false.
    - meetingAgreed: true only if a meeting was actually booked on this call: the lead explicitly agreed to a specific day \
    AND time, and both sides confirmed it (e.g. the rep repeats the time or says they'll send the invite and the lead \
    says yes). "Send me some info", "call me later", "maybe", "let me check my calendar", "next week sometime", \
    or a time only the rep proposed with no clear yes from the lead are all false.
    - meetingCertainty: "certain" only if there is no doubt at all that a meeting was booked; "likely" if it probably \
    was but anything is vague (no exact time, unclear yes, cut-off audio, transcription gaps); "no" otherwise. \
    When in doubt, never say "certain".
    - meetingTime: the agreed day and time in their words, or "" if none.
    - leadConfirmationQuote: the lead's own words agreeing to the meeting, copied exactly from a "Them:" line, or "".
    - summary: one short sentence on what happened.
    """

    static func classify(transcript: String, leadName: String) async throws -> Verdict {
        guard let key = Keychain.read(.anthropic) else { throw URLError(.userAuthenticationRequired) }
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "reachedLead": ["type": "boolean"],
                "meetingAgreed": ["type": "boolean"],
                "meetingCertainty": ["type": "string", "enum": ["certain", "likely", "no"]],
                "meetingTime": ["type": "string"],
                "leadConfirmationQuote": ["type": "string"],
                "summary": ["type": "string"],
            ],
            "required": ["reachedLead", "meetingAgreed", "meetingCertainty", "meetingTime", "leadConfirmationQuote", "summary"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 4000,
            "fallbacks": "default",
            "output_config": ["effort": "high", "format": ["type": "json_schema", "schema": schema]],
            "system": system,
            "messages": [["role": "user", "content": "Lead being called: \(leadName)\n\n<transcript>\n\(transcript)\n</transcript>"]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["stop_reason"] as? String) != "refusal",
              let text = ((json["content"] as? [[String: Any]]) ?? []).first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
        else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Verdict.self, from: Data(text.utf8))
    }
}
