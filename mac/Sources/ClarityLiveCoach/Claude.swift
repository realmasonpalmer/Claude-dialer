import Foundation

/// Streams one coaching answer from the Claude API. Raw HTTPS: there is no official Swift SDK.
struct ClaudeClient {
    let apiKey: String
    var model = "claude-opus-5-5"
    var effort = "low" // fastest setting that keeps Opus-level quality
    /// Room for the answer (and thinking). Long scripts need much more than a live line.
    var maxTokens = 1500
    /// Give up if nothing arrives for this long (a stuck answer never hangs the app).
    var idleTimeout: TimeInterval = 20
    /// Give up if the whole answer takes longer than this.
    var totalTimeout: TimeInterval = 90
    /// Optional thinking setting. nil = the model's default (Opus 5.5 always thinks).
    var thinking: [String: String]?

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Calls onText with all the text so far, each time more arrives. Cancel the surrounding Task to stop early.
    /// onThinking gets the thinking summary so far, when `thinking` asks for display "summarized".
    func stream(system: String, user: String, onText: @escaping (String) -> Void,
                onThinking: ((String) -> Void)? = nil) async throws {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "output_config": ["effort": effort],
            // The rules and campaign never change during a call, so they are cached.
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": user]],
        ]
        if let thinking { body["thinking"] = thinking }
        if model.hasPrefix("claude-opus") || model.hasPrefix("claude-fable") {
            // If a safety check declines, the API retries on a fallback model in the same call.
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = idleTimeout
        config.timeoutIntervalForResource = totalTimeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "No response from Claude") }
        guard http.statusCode == 200 else {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw APIError(message: "Claude error \(http.statusCode): \(text.prefix(300))")
        }

        var full = ""
        var thought = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: "),
                  let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            if type == "content_block_delta",
               let delta = json["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                full += text
                onText(full)
            } else if type == "content_block_delta", let onThinking,
                      let delta = json["delta"] as? [String: Any],
                      delta["type"] as? String == "thinking_delta",
                      let text = delta["thinking"] as? String {
                thought += text
                onThinking(thought)
            } else if type == "error" {
                let error = json["error"] as? [String: Any]
                throw APIError(message: (error?["message"] as? String) ?? "Claude stream error")
            }
        }
    }
}

extension ClaudeClient {
    /// The JSON object in Claude's answer (from the first "{" to the last "}"), or nil.
    static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }

    /// Streams the whole answer and returns its JSON object. Throws if it isn't JSON.
    func json(system: String, user: String) async throws -> [String: Any] {
        var text = ""
        try await stream(system: system, user: user) { text = $0 }
        guard let json = Self.jsonObject(in: text) else {
            throw APIError(message: "Claude's answer wasn't in the expected format. Try again.")
        }
        return json
    }
}

/// How the live coach trades polish for speed. Pick in the gear menu.
enum CoachSpeed: String, CaseIterable, Identifiable {
    case best, balanced, fastest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .best: return "Best lines (a bit slower)"
        case .balanced: return "Fast (best for most people)"
        case .fastest: return "Fastest"
        }
    }

    static var current: CoachSpeed {
        CoachSpeed(rawValue: UserDefaults.standard.string(forKey: PrefKey.coachSpeed) ?? "") ?? .balanced
    }

    func client(apiKey: String) -> ClaudeClient {
        var c = ClaudeClient(apiKey: apiKey)
        c.effort = "low"
        c.idleTimeout = 10 // a live line that stalls is useless; the rep keeps the last one
        c.totalTimeout = 30
        switch self {
        case .best:
            c.model = "claude-opus-5-5" // always thinks; low effort keeps it short
        case .balanced:
            c.model = "claude-sonnet-5-5"
            c.thinking = ["type": "between_tools"] // Sonnet 5.5's way to turn thinking off
        case .fastest:
            c.model = "claude-haiku-5-5"
            c.thinking = ["type": "disabled"]
        }
        return c
    }
}
