import AppKit
import CryptoKit
import Foundation
import Network

/// Salesforce over its REST API: sign in (OAuth + PKCE), list views, people, call history,
/// statuses, and logging each call as a Task. Needs an External Client App whose callback is
/// http://localhost:53682/callback (the same one the old app uses).
enum Salesforce {
    static let apiVersion = "v62.0"

    struct ListView: Identifiable, Hashable, Codable {
        let id: String
        let label: String
        let object: SFObject
        var title: String { "\(label) · \(object.rawValue)s" }
    }

    struct SFError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var isConnected: Bool { Keychain.read(.sfRefresh) != nil && Keychain.read(.sfInstance) != nil }

    static var loginHost: String {
        get { UserDefaults.standard.string(forKey: "sfLoginHost") ?? "login.salesforce.com" }
        set { UserDefaults.standard.set(newValue, forKey: "sfLoginHost") }
    }

    // MARK: Sign in

    @MainActor
    static func signIn(clientID: String) async throws {
        let verifier = randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var authorize = URLComponents(string: "https://\(loginHost)/services/oauth2/authorize")!
        authorize.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: LoopbackLogin.redirectURI),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "scope", value: "api refresh_token"),
        ]
        let callback = try await LoopbackLogin.run(url: authorize.url!)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            let why = items.first(where: { $0.name == "error_description" })?.value
            throw SFError(message: why.map { "Salesforce said: \($0)" } ?? "Salesforce didn't finish the sign-in.")
        }
        let tokens = try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "client_id": clientID,
            "redirect_uri": LoopbackLogin.redirectURI, "code_verifier": verifier,
        ])
        Keychain.save(clientID, for: .sfClientID)
        save(tokens)
    }

    static func signOut() {
        for k in [Keychain.Key.sfAccess, .sfRefresh, .sfInstance] { Keychain.save(nil, for: k) }
    }

    private static func save(_ tokens: [String: Any]) {
        if let v = tokens["access_token"] as? String { Keychain.save(v, for: .sfAccess) }
        if let v = tokens["refresh_token"] as? String { Keychain.save(v, for: .sfRefresh) }
        if let v = tokens["instance_url"] as? String { Keychain.save(v, for: .sfInstance) }
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://\(loginHost)/services/oauth2/token")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SFError(message: "Salesforce sign-in failed: \((json["error_description"] as? String) ?? "unknown error")")
        }
        return json
    }

    private static func refresh() async throws {
        guard let token = Keychain.read(.sfRefresh), let clientID = Keychain.read(.sfClientID) else {
            throw SFError(message: "Connect Salesforce in Settings.")
        }
        save(try await tokenRequest(["grant_type": "refresh_token", "refresh_token": token, "client_id": clientID]))
    }

    // MARK: REST

    /// One request; refreshes the sign-in once on 401.
    @discardableResult
    static func call(_ method: String, _ path: String, body: [String: Any]? = nil, retry: Bool = true) async throws -> Any? {
        guard let instance = Keychain.read(.sfInstance) else { throw SFError(message: "Connect Salesforce in Settings.") }
        if Keychain.read(.sfAccess) == nil { try await refresh() }
        var req = URLRequest(url: URL(string: instance + path)!)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("Bearer \(Keychain.read(.sfAccess) ?? "")", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retry {
            try await refresh()
            return try await call(method, path, body: body, retry: false)
        }
        let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(code) else {
            let message = ((json as? [[String: Any]])?.first?["message"] as? String) ?? "error \(code)"
            throw SFError(message: "Salesforce: \(message)")
        }
        return json
    }

    static func query(_ soql: String) async throws -> [[String: Any]] {
        let q = soql.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var out: [[String: Any]] = []
        var path: String? = "/services/data/\(apiVersion)/query?q=\(q)"
        while let p = path {
            let json = try await call("GET", p) as? [String: Any]
            out += (json?["records"] as? [[String: Any]]) ?? []
            path = json?["nextRecordsUrl"] as? String
        }
        return out
    }

    private static func safeIDs(_ ids: some Sequence<String>) -> String {
        ids.filter { $0.allSatisfy { $0.isLetter || $0.isNumber } }.map { "'\($0)'" }.joined(separator: ",")
    }

    // MARK: Lists and people

    static func listViews() async throws -> [ListView] {
        try await query("SELECT Id, Name, SobjectType FROM ListView WHERE SobjectType IN ('Lead','Contact') ORDER BY SobjectType DESC, Name")
            .compactMap { r in
                guard let id = r["Id"] as? String, let name = r["Name"] as? String,
                      let o = (r["SobjectType"] as? String).flatMap(SFObject.init) else { return nil }
                return ListView(id: id, label: name, object: o)
            }
    }

    /// Everyone on a list view (up to 2,000), in the list's order, with the fields the dialer needs.
    static func leads(of view: ListView) async throws -> [Lead] {
        let json = try await call("GET", "/services/data/\(apiVersion)/sobjects/\(view.object.rawValue)/listviews/\(view.id)/results?limit=2000") as? [String: Any]
        let ids: [String] = ((json?["records"] as? [[String: Any]]) ?? []).compactMap { record in
            ((record["columns"] as? [[String: Any]]) ?? []).first { ($0["fieldNameOrPath"] as? String) == "Id" }?["value"] as? String
        }
        let statusField = try await self.statusField(view.object)
        let fields = view.object == .lead
            ? "Id, Name, FirstName, Company, Title, Phone, MobilePhone, City, State, DoNotCall"
            : "Id, Name, FirstName, Account.Name, Title, Phone, MobilePhone, MailingCity, MailingState, DoNotCall"
        var byID: [String: Lead] = [:]
        for start in stride(from: 0, to: ids.count, by: 200) {
            let batch = safeIDs(ids[start..<min(start + 200, ids.count)])
            guard !batch.isEmpty else { continue }
            let extra = statusField.map { ", \($0)" } ?? ""
            for r in try await query("SELECT \(fields)\(extra) FROM \(view.object.rawValue) WHERE Id IN (\(batch))") {
                guard let id = r["Id"] as? String else { continue }
                let company = (r["Company"] as? String) ?? ((r["Account"] as? [String: Any])?["Name"] as? String) ?? ""
                byID[History.key(id)] = Lead(
                    id: id, object: view.object,
                    name: (r["Name"] as? String) ?? company,
                    firstName: (r["FirstName"] as? String) ?? "",
                    company: company,
                    title: (r["Title"] as? String) ?? "",
                    phone: r["Phone"] as? String,
                    mobile: r["MobilePhone"] as? String,
                    city: (r["City"] as? String) ?? (r["MailingCity"] as? String),
                    state: (r["State"] as? String) ?? (r["MailingState"] as? String),
                    status: statusField.flatMap { r[$0] as? String } ?? "",
                    doNotCall: (r["DoNotCall"] as? Bool) ?? false)
            }
        }
        return ids.compactMap { byID[History.key($0)] }
    }

    /// Dates of past call Tasks for these people (last 90 days), so cadence follows the rep across Macs.
    static func callHistory(_ ids: [String]) async throws -> [String: [Date]] {
        var out: [String: [Date]] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for start in stride(from: 0, to: ids.count, by: 200) {
            let batch = safeIDs(ids[start..<min(start + 200, ids.count)])
            guard !batch.isEmpty else { continue }
            for r in try await query("SELECT WhoId, CreatedDate FROM Task WHERE TaskSubtype = 'Call' AND WhoId IN (\(batch)) AND CreatedDate = LAST_N_DAYS:90") {
                guard let who = r["WhoId"] as? String, let raw = r["CreatedDate"] as? String else { continue }
                let fixed = raw.replacingOccurrences(of: "+0000", with: "Z")
                if let d = iso.date(from: fixed) ?? ISO8601DateFormatter().date(from: fixed) {
                    out[History.key(who), default: []].append(d)
                }
            }
        }
        return out
    }

    // MARK: Status

    private static var statusCache: [SFObject: (field: String?, values: [String])] = [:]

    /// Lead: Status. Contact: Relationship_Status__c when the org has it.
    static func statusField(_ object: SFObject) async throws -> String? {
        try await statusInfo(object).field
    }

    static func statuses(_ object: SFObject) async -> [String] {
        (try? await statusInfo(object).values) ?? []
    }

    private static func statusInfo(_ object: SFObject) async throws -> (field: String?, values: [String]) {
        if let c = statusCache[object] { return c }
        let describe = try await call("GET", "/services/data/\(apiVersion)/sobjects/\(object.rawValue)/describe") as? [String: Any]
        let fields = (describe?["fields"] as? [[String: Any]]) ?? []
        let wanted = object == .lead ? "Status" : "Relationship_Status__c"
        let f = fields.first { ($0["name"] as? String) == wanted }
        let values = ((f?["picklistValues"] as? [[String: Any]]) ?? [])
            .filter { ($0["active"] as? Bool) != false }.compactMap { $0["value"] as? String }
        let info = (f == nil ? nil : wanted, values)
        statusCache[object] = info
        return info
    }

    static func setStatus(_ lead: Lead, to value: String) async throws {
        guard let field = try await statusField(lead.object) else { return }
        var body: [String: Any] = [field: value]
        // Orgs often require a Rating once a Lead moves past New, and a reason when Unqualified.
        if lead.object == .lead, value != "New" {
            let current = try? await query("SELECT Rating, Unqualified_Reason__c FROM Lead WHERE Id = '\(lead.id)'").first
            if current != nil, ((current?["Rating"] as? String) ?? "").isEmpty {
                body["Rating"] = value == "Qualified" ? "Hot" : ["Interested", "AE Engaged"].contains(value) ? "Warm" : "Cold"
            }
            if current != nil, value == "Unqualified", ((current?["Unqualified_Reason__c"] as? String) ?? "").isEmpty {
                body["Unqualified_Reason__c"] = "Non-Responsive"
            }
        }
        try await call("PATCH", "/services/data/\(apiVersion)/sobjects/\(lead.object.rawValue)/\(lead.id)", body: body)
    }

    static func setDoNotCall(_ lead: Lead) async throws {
        try await call("PATCH", "/services/data/\(apiVersion)/sobjects/\(lead.object.rawValue)/\(lead.id)", body: ["DoNotCall": true])
    }

    // MARK: Logging

    /// Creates the call Task for an attempt. Returns the Task Id.
    static func logCall(_ a: Attempt) async throws -> String {
        let outcome = a.outcome?.label ?? "Call"
        var description = a.note
        if a.voicemailDropped { description += (description.isEmpty ? "" : "\n") + "Voicemail dropped." }
        if a.textSent { description += (description.isEmpty ? "" : "\n") + "Follow-up text sent." }
        let day = ISO8601DateFormatter.string(from: a.dialedAt, timeZone: .current, formatOptions: [.withFullDate])
        let body: [String: Any] = [
            "WhoId": a.leadID,
            "Subject": "Call: \(outcome)",
            "Status": "Completed",
            "TaskSubtype": "Call",
            "CallType": "Outbound",
            "CallDisposition": outcome,
            "CallDurationInSeconds": max(0, Int((a.endedAt ?? a.dialedAt).timeIntervalSince(a.answeredAt ?? a.dialedAt))),
            "ActivityDate": day,
            "Description": String(description.prefix(30_000)),
        ]
        let json = try await call("POST", "/services/data/\(apiVersion)/sobjects/Task", body: body) as? [String: Any]
        guard let id = json?["id"] as? String else { throw SFError(message: "Salesforce didn't return the Task.") }
        return id
    }

    static func recordURL(_ id: String) -> URL? {
        Keychain.read(.sfInstance).flatMap { URL(string: "\($0)/\(id)") }
    }

    private static func randomURLSafe(_ length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Opens the sign-in page in the default browser and waits on http://localhost:53682 for the callback.
@MainActor
final class LoopbackLogin {
    nonisolated static let port: UInt16 = 53682
    nonisolated static var redirectURI: String { "http://localhost:\(port)/callback" }

    private static var current: LoopbackLogin?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?

    static func run(url: URL) async throws -> URL {
        current?.finish(.failure(Salesforce.SFError(message: "Sign-in was restarted.")))
        let login = LoopbackLogin()
        current = login
        return try await withCheckedThrowingContinuation { c in
            login.continuation = c
            do { try login.listen() } catch {
                login.finish(.failure(Salesforce.SFError(message: "Port \(port) is busy. Quit the other Clarity app and try again.")))
                return
            }
            NSWorkspace.shared.open(url)
            Task { @MainActor [weak login] in
                try? await Task.sleep(for: .seconds(300))
                login?.finish(.failure(Salesforce.SFError(message: "Sign-in timed out.")))
            }
        }
    }

    private func listen() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
        l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.handle(c) } }
        l.start(queue: .main)
        listener = l
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let isCallback = path.hasPrefix("/callback")
            let page = isCallback && !path.contains("error=")
                ? "Signed in. Close this tab and go back to Clarity Dialer."
                : "Sign-in didn't finish. Go back to Clarity Dialer and try again."
            let html = "<html><body style='font-family:-apple-system;font-size:20px;padding:40px'>\(page)</body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard isCallback else { return }
            Task { @MainActor in
                self?.finish(URL(string: "http://localhost:\(LoopbackLogin.port)\(path)").map { .success($0) }
                    ?? .failure(Salesforce.SFError(message: "Salesforce didn't finish the sign-in.")))
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        listener?.cancel()
        listener = nil
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }
}
