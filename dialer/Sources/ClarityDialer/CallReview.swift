import Foundation
import Observation

/// Reads each picked-up call's Aircall transcript with Claude to decide two things the phone
/// can't: did the lead themself answer (not a front desk or someone else), and was a meeting
/// agreed. A meeting only counts once a calendar event for that person exists in Salesforce.
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
            } else if a.meetingAgreed == true || a.outcome == .meeting, a.meetingOnCalendar != true, Salesforce.isConnected {
                await checkCalendar(a.id)
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
        update(a.id) {
            $0.reviewedAt = Date()
            $0.reachedLead = verdict.reachedLead
            $0.meetingAgreed = verdict.meetingAgreed
            $0.meetingTime = verdict.meetingTime.isEmpty ? nil : verdict.meetingTime
            $0.reviewSummary = verdict.summary
            if !verdict.reachedLead, $0.outcome == .connected { $0.note = ($0.note.isEmpty ? "" : $0.note + "\n") + "Not the lead: " + verdict.summary }
        }
        if verdict.meetingAgreed { await checkCalendar(a.id) }
    }

    private func checkCalendar(_ id: UUID) async {
        guard let a = store.attempts.first(where: { $0.id == id }),
              let found = try? await Salesforce.hasCalendarEvent(for: a.leadID, since: a.dialedAt) else { return }
        guard found else { update(id) { $0.meetingOnCalendar = false }; return }
        update(id) {
            $0.meetingOnCalendar = true
            $0.outcome = .meeting
            $0.needsSync = true // the call's Salesforce Task now says Meeting booked
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
        let meetingTime: String
        let summary: String
    }

    private static let system = """
    You review transcripts of outbound sales calls. "Rep" is the salesperson; "Them" is whoever answered.
    Decide:
    - reachedLead: true only if the person the rep was calling (the named lead) was on the line and spoke as themself. \
    False for a front desk, receptionist, assistant, operator, voicemail greeting, phone menu, wrong number, or anyone \
    who says they are someone else or whose name clearly does not match the lead. If unsure, false.
    - meetingAgreed: true only if the lead clearly agreed to a specific next meeting or call (a day or time, or accepting \
    a calendar invite). "Send me some info", "call me later" or "maybe" is false.
    - meetingTime: the agreed day/time in their words, or "" if none.
    - summary: one short sentence on what happened.
    """

    static func classify(transcript: String, leadName: String) async throws -> Verdict {
        guard let key = Keychain.read(.anthropic) else { throw URLError(.userAuthenticationRequired) }
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "reachedLead": ["type": "boolean"],
                "meetingAgreed": ["type": "boolean"],
                "meetingTime": ["type": "string"],
                "summary": ["type": "string"],
            ],
            "required": ["reachedLead", "meetingAgreed", "meetingTime", "summary"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 4000,
            "fallbacks": "default",
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
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
