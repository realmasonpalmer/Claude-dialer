import Foundation

/// One live transcription stream (one side of the call). We open two: you and the prospect.
/// Separate streams mean we always know who said what.
final class DeepgramStream: @unchecked Sendable {
    enum Event {
        case transcript(text: String, isFinal: Bool, speechFinal: Bool)
        case utteranceEnd
        case failed(String)
    }

    // Tuned for speed: 300 ms of silence ends a statement, words stream as they are heard.
    private static let url = URL(string: "wss://api.deepgram.com/v1/listen?" + [
        "model=nova-3", "encoding=linear16", "sample_rate=16000", "channels=1",
        "interim_results=true", "endpointing=300", "utterance_end_ms=1000",
        "vad_events=true", "smart_format=true",
    ].joined(separator: "&"))!

    private let task: URLSessionWebSocketTask
    private let onEvent: (Event) -> Void
    private let lock = NSLock()
    private var lastSend = Date()
    private var keepAlive: DispatchSourceTimer?
    private var closed = false

    init(apiKey: String, onEvent: @escaping (Event) -> Void) {
        var request = URLRequest(url: Self.url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        task = URLSession.shared.webSocketTask(with: request)
        self.onEvent = onEvent
        task.resume()
        receive()

        // Deepgram closes idle streams after ~10 s. Keep it open during silence.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = self.lock.withLockValue { Date().timeIntervalSince(self.lastSend) > 4 }
            if idle { self.task.send(.string(#"{"type":"KeepAlive"}"#)) { _ in } }
        }
        timer.resume()
        keepAlive = timer
    }

    func send(_ pcm16: Data) {
        lock.withLockValue { lastSend = Date() }
        task.send(.data(pcm16)) { _ in }
    }

    func close() {
        let wasClosed = lock.withLockValue { () -> Bool in
            defer { closed = true }
            return closed
        }
        guard !wasClosed else { return }
        keepAlive?.cancel()
        task.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [task] in
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receive()
            case .failure(let error):
                let wasClosed = self.lock.withLockValue { self.closed }
                if !wasClosed { self.onEvent(.failed(error.localizedDescription)) }
            }
        }
    }

    private func handle(_ text: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "Results":
            let channel = json["channel"] as? [String: Any]
            let alternative = (channel?["alternatives"] as? [[String: Any]])?.first
            let transcript = (alternative?["transcript"] as? String) ?? ""
            onEvent(.transcript(
                text: transcript,
                isFinal: (json["is_final"] as? Bool) ?? false,
                speechFinal: (json["speech_final"] as? Bool) ?? false
            ))
        case "UtteranceEnd":
            onEvent(.utteranceEnd)
        default:
            break
        }
    }
}

extension NSLock {
    func withLockValue<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
