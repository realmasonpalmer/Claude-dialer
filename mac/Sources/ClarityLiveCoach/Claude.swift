import Foundation

/// Streams one coaching answer from the Claude API. Raw HTTPS: there is no official Swift SDK.
struct ClaudeClient {
    let apiKey: String
    var model = "claude-opus-5-5"
    var effort = "low" // fastest setting that keeps Opus-level quality

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Calls onText with all the text so far, each time more arrives. Cancel the surrounding Task to stop early.
    func stream(system: String, user: String, onText: @escaping (String) -> Void) async throws {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 1500,
            "stream": true,
            "output_config": ["effort": effort],
            // The rules and campaign never change during a call, so they are cached.
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": user]],
        ]
        if model.hasPrefix("claude-opus") || model.hasPrefix("claude-fable") {
            // If a safety check declines, the API retries on a fallback model in the same call.
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "No response from Claude") }
        guard http.statusCode == 200 else {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw APIError(message: "Claude error \(http.statusCode): \(text.prefix(300))")
        }

        var full = ""
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
            } else if type == "error" {
                let error = json["error"] as? [String: Any]
                throw APIError(message: (error?["message"] as? String) ?? "Claude stream error")
            }
        }
    }
}
