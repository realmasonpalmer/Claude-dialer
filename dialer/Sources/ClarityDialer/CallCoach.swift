import Foundation
import Observation

/// The Help me button. Sends the whole call so far to Claude Opus and shows one thing to say
/// right now to move the call toward a meeting. Runs only when the rep presses the button.
@Observable @MainActor
final class CallCoach {
    static let shared = CallCoach()

    enum Status: Equatable { case idle, thinking, done, failed(String) }

    private(set) var status: Status = .idle
    /// The words to say (streams in as Claude writes them).
    private(set) var say = ""
    /// One short line on why.
    private(set) var why = ""
    private var task: Task<Void, Never>?

    var isThinking: Bool { status == .thinking }
    var hasCard: Bool { status != .idle }

    /// A new call: clear the last answer.
    func clear() {
        task?.cancel()
        task = nil
        status = .idle
        say = ""
        why = ""
    }

    func help(lead: Lead?, script: String, rep: String, transcript: String) {
        task?.cancel()
        say = ""
        why = ""
        guard let key = Keychain.read(.anthropic) else {
            status = .failed("Add your Anthropic API key in Settings (⌘,) to use Help me.")
            return
        }
        status = .thinking
        let prompt = Self.prompt(lead: lead, script: script, rep: rep, transcript: transcript)
        Log.add("coach", "help pressed: sending \(transcript.count) characters of transcript to Opus")
        let started = Date()
        task = Task { [weak self] in
            do {
                try await Self.stream(prompt: prompt, key: key) { text in self?.show(text) }
                guard let self, !Task.isCancelled else { return }
                if say.isEmpty { status = .failed("The coach came back empty. Press Help me again.") } else { status = .done }
                Log.add("coach", "answer in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            } catch {
                guard let self, !Task.isCancelled else { return }
                Log.add("coach", "failed: \(error.localizedDescription)")
                status = .failed("The coach couldn't answer (\(error.localizedDescription)). Press Help me again.")
            }
        }
    }

    /// Splits Claude's text ("SAY: ... WHY: ...") into the two parts as it streams in.
    private func show(_ text: String) {
        let parts = Self.parse(text)
        say = parts.say
        why = parts.why
    }

    nonisolated static func parse(_ text: String) -> (say: String, why: String) {
        var body = text
        if let r = body.range(of: "SAY:") { body = String(body[r.upperBound...]) }
        var why = ""
        if let r = body.range(of: "WHY:") {
            why = String(body[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            body = String(body[..<r.lowerBound])
        }
        return (body.trimmingCharacters(in: .whitespacesAndNewlines), why)
    }

    // MARK: Prompt

    nonisolated static let system = """
    You are a world-class cold-call coach sitting next to a sales rep during a live phone call. \
    The rep just pressed a Help button because they are stuck: usually an objection, a brush-off, \
    a question they can't answer, or they don't know how to get to the ask. The one goal of every \
    call is to book a short meeting. Your job: read the whole call so far and give the rep the exact \
    words to say next that move the call from where it is right now toward a booked meeting.

    How to coach:
    - Answer what the other person said last. Use their own words back to them when it helps.
    - Objections: don't argue and don't fold. Acknowledge in a few words, get curious or reframe \
    around what they care about, then go back to a meeting ask with a specific time.
    - If they already said yes, lock it in: a specific day and time, and confirm the best email for the invite.
    - If it's a gatekeeper or screener, give the words to get through or get the right person's name.
    - If it's a firm, clear no, give a graceful exit that keeps the door open (a later date, or who else to talk to).
    - Only use facts from the script and the call. Never make up numbers, clients, or claims.

    How to write it:
    - Words the rep says out loud, word for word. Never instructions like "ask about..." or "mention...".
    - Sound like a real person talking: short, plain, warm, confident. No jargon. Easy to read at a glance.
    - One to three short sentences. End with a question.
    - The transcript comes from live speech recognition, so expect wrong words and missing bits. \
    Work out what was really meant.

    Reply in exactly this format and nothing else:
    SAY: <the exact words to say>
    WHY: <one short line, under 12 words, on why this works>
    """

    nonisolated static func prompt(lead: Lead?, script: String, rep: String, transcript: String) -> String {
        var who: [String] = []
        if let lead {
            who.append("Name: \(lead.name)")
            if !lead.title.isEmpty { who.append("Title: \(lead.title)") }
            if !lead.company.isEmpty { who.append("Company: \(lead.company)") }
            let place = [lead.city, lead.state].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            if !place.isEmpty { who.append("Location: \(place)") }
        }
        let call = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        <rep>\(rep.isEmpty ? "the rep" : rep)</rep>

        <person_being_called>
        \(who.isEmpty ? "Unknown" : who.joined(separator: "\n"))
        </person_being_called>

        <call_script>
        \(script.isEmpty ? "(no script loaded)" : script)
        </call_script>

        <call_so_far>
        \(call.isEmpty ? "(nothing transcribed yet: the call just started, or the words didn't come through)" : call)
        </call_so_far>

        The rep needs help right now. What should they say next?
        """
    }

    // MARK: Claude

    /// Streams Claude's answer, calling `onText` with everything written so far.
    /// Tries fast mode first; if that request is refused, sends a plain one.
    static func stream(prompt: String, key: String, onText: @escaping @MainActor (String) -> Void) async throws {
        do {
            try await send(prompt: prompt, key: key, fast: true, onText: onText)
        } catch CoachError.rejected(let code) {
            Log.add("coach", "fast request refused (\(code)): retrying at normal speed")
            try await send(prompt: prompt, key: key, fast: false, onText: onText)
        }
    }

    enum CoachError: LocalizedError {
        case rejected(Int)
        case refused
        var errorDescription: String? {
            switch self {
            case .rejected(let code): return "error \(code)"
            case .refused: return "Claude declined"
            }
        }
    }

    private static func send(prompt: String, key: String, fast: Bool, onText: @escaping @MainActor (String) -> Void) async throws {
        var body: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 8000,
            "stream": true,
            // Low effort keeps the answer coming in a few seconds while the prospect waits.
            "output_config": ["effort": "low"],
            "system": system,
            "messages": [["role": "user", "content": prompt]],
        ]
        if fast {
            body["speed"] = "fast"
            body["fallbacks"] = "default"
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if fast { req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            var detail = ""
            for try await line in bytes.lines { detail += line; if detail.count > 400 { break } }
            Log.add("coach", "HTTP \(code): \(detail.prefix(300))")
            throw CoachError.rejected(code)
        }
        var text = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            switch type {
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any], (delta["type"] as? String) == "text_delta",
                   let piece = delta["text"] as? String {
                    text += piece
                    let snapshot = text
                    onText(snapshot)
                }
            case "message_delta":
                if let d = json["delta"] as? [String: Any], (d["stop_reason"] as? String) == "refusal" { throw CoachError.refused }
            case "error":
                let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "stream error"
                Log.add("coach", "stream error: \(msg)")
                throw CoachError.rejected(0)
            default:
                break
            }
        }
    }
}
