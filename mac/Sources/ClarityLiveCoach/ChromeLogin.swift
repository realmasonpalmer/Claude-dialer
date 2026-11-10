import AppKit
import Network

/// Signs in to Salesforce in Google Chrome, where the rep is already logged in.
/// Opens Salesforce's sign-in page in Chrome, then waits on this Mac (http://localhost:53682)
/// for Salesforce to send Chrome back with the sign-in code. Nothing leaves the Mac.
@MainActor
final class ChromeLogin {
    nonisolated static let port: UInt16 = 53682
    nonisolated static var redirectURI: String { "http://localhost:\(port)/callback" }

    private static var current: ChromeLogin?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?

    /// Opens the address in Chrome and returns the callback address Salesforce sends back.
    static func run(url: URL) async throws -> URL {
        current?.finish(.failure(Salesforce.SFError(message: "Sign-in was restarted.")))
        let login = ChromeLogin()
        current = login
        defer { if current === login { current = nil } }
        return try await withCheckedThrowingContinuation { continuation in
            login.continuation = continuation
            do {
                try login.listen()
            } catch {
                login.finish(.failure(Salesforce.SFError(message: "Couldn't start the sign-in on this Mac (port \(port) busy?). Quit and reopen the app, then try again.")))
                return
            }
            login.openInChrome(url)
            // Give up after 5 minutes.
            Task { @MainActor [weak login] in
                try? await Task.sleep(for: .seconds(300))
                login?.finish(.failure(Salesforce.SFError(message: "Sign-in timed out. Click Sign in again.")))
            }
        }
    }

    private func openInChrome(_ url: URL) {
        let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
        if let chrome {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: config)
        } else {
            NSWorkspace.shared.open(url) // no Chrome: the default browser
        }
    }

    private func listen() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback // only this Mac can reach it
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.handle(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // First line: "GET /callback?code=... HTTP/1.1"
            let path = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let isCallback = path.hasPrefix("/callback")
            let failed = path.contains("error=")
            let page = isCallback && !failed
                ? "Signed in. You can close this tab and go back to Clarity Caller."
                : "Sign-in didn't finish. Go back to Clarity Caller and try again."
            let html = "<html><body style='font-family:-apple-system;font-size:20px;padding:40px'>\(page)</body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard isCallback else { return } // e.g. a favicon request
            Task { @MainActor in
                guard let self else { return }
                if let url = URL(string: "http://localhost:\(Self.port)\(path)") {
                    self.finish(.success(url))
                } else {
                    self.finish(.failure(Salesforce.SFError(message: "Salesforce didn't finish the sign-in. Try again.")))
                }
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        listener?.cancel()
        listener = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
