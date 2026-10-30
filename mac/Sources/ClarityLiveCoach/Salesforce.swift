import AuthenticationServices
import CryptoKit
import SwiftUI

/// Signs in to Salesforce once (OAuth with PKCE, in a normal Salesforce login window) and reads
/// list views and lead/contact details with Salesforce's standard REST API. Read-only.
/// Needs an External Client App in Salesforce (setup steps in the Connect Salesforce sheet).
enum Salesforce {
    static let callbackScheme = "claritylivecoach"
    static let redirectURI = "claritylivecoach://oauth/callback"
    static let apiVersion = "v66.0"

    struct SFError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var isConnected: Bool { Keychain.read(.sfRefresh) != nil && Keychain.read(.sfInstance) != nil }

    static var loginHost: String {
        get { UserDefaults.standard.string(forKey: "sfLoginHost") ?? "clarityconsultingllc.my.salesforce.com" }
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
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "scope", value: "api refresh_token"),
        ]
        let callback = try await WebLogin.run(url: authorize.url!, scheme: callbackScheme)
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw SFError(message: "Salesforce didn't finish the sign-in. Try again.")
        }
        let tokens = try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "client_id": clientID,
            "redirect_uri": redirectURI, "code_verifier": verifier,
        ])
        Keychain.save(clientID, for: .sfClientID)
        save(tokens)
    }

    static func signOut() {
        for key in [Keychain.Key.sfAccess, .sfRefresh, .sfInstance] { Keychain.delete(key) }
    }

    private static func save(_ tokens: [String: Any]) {
        if let access = tokens["access_token"] as? String { Keychain.save(access, for: .sfAccess) }
        if let refresh = tokens["refresh_token"] as? String { Keychain.save(refresh, for: .sfRefresh) }
        if let instance = tokens["instance_url"] as? String { Keychain.save(instance, for: .sfInstance) }
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://\(loginHost)/services/oauth2/token")!)
        req.httpMethod = "POST"
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
        guard let refresh = Keychain.read(.sfRefresh), let clientID = Keychain.read(.sfClientID) else {
            throw SFError(message: "Connect Salesforce first (gear menu).")
        }
        save(try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]))
    }

    // MARK: REST

    /// GET against the Salesforce REST API. Refreshes the sign-in once if it expired.
    static func get(_ path: String, retry: Bool = true) async throws -> Any {
        guard let instance = Keychain.read(.sfInstance) else { throw SFError(message: "Connect Salesforce first (gear menu).") }
        if Keychain.read(.sfAccess) == nil { try await refresh() }
        var req = URLRequest(url: URL(string: instance + path)!)
        req.setValue("Bearer \(Keychain.read(.sfAccess) ?? "")", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retry {
            try await refresh()
            return try await get(path, retry: false)
        }
        let json = try? JSONSerialization.jsonObject(with: data)
        guard code == 200, let json else {
            let message = ((json as? [[String: Any]])?.first?["message"] as? String) ?? "error \(code)"
            throw SFError(message: "Salesforce: \(message)")
        }
        return json
    }

    static func query(_ soql: String) async throws -> [[String: Any]] {
        let q = soql.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let json = try await get("/services/data/\(apiVersion)/query?q=\(q)") as? [String: Any]
        return (json?["records"] as? [[String: Any]]) ?? []
    }

    // MARK: Lists and records

    struct ListView: Identifiable, Hashable {
        let id: String
        let label: String
        let object: String // "Lead" or "Contact"
        var title: String { "\(label) (\(object)s)" }
    }

    struct Row: Identifiable, Hashable, Codable {
        let id: String
        let name: String
        let subtitle: String
    }

    static func listViews() async throws -> [ListView] {
        var views: [ListView] = []
        for object in ["Lead", "Contact"] {
            let json = try await get("/services/data/\(apiVersion)/sobjects/\(object)/listviews") as? [String: Any]
            for v in (json?["listviews"] as? [[String: Any]]) ?? [] {
                if let id = v["id"] as? String, let label = v["label"] as? String {
                    views.append(ListView(id: id, label: label, object: object))
                }
            }
        }
        return views
    }

    /// The rows of a list view, in the list view's own order.
    static func rows(of view: ListView) async throws -> [Row] {
        let json = try await get("/services/data/\(apiVersion)/sobjects/\(view.object)/listviews/\(view.id)/results?limit=2000") as? [String: Any]
        return ((json?["records"] as? [[String: Any]]) ?? []).compactMap { record in
            var values: [String: String] = [:]
            for column in (record["columns"] as? [[String: Any]]) ?? [] {
                if let field = column["fieldNameOrPath"] as? String, let value = column["value"] as? String {
                    values[field] = value
                }
            }
            guard let id = values["Id"], let name = values["Name"] ?? values["FirstName"].map({ "\($0) \(values["LastName"] ?? "")" }) else {
                return nil
            }
            let subtitle = [values["Title"], values["Company"] ?? values["Account.Name"]].compactMap { $0 }.joined(separator: " · ")
            return Row(id: id, name: name, subtitle: subtitle)
        }
    }

    struct Details: Equatable {
        let id: String
        let object: String
        let name: String
        let firstName: String?
        let company: String?
        let title: String?
        let phone: String?
        let mobile: String?
        let state: String?
        let status: String?
        let doNotCall: Bool
        let linkedIn: URL?
        let notes: String?
        let recent: [String]

        var callNumber: String? { mobile ?? phone }
        /// Plain text for the coach, like the Salesforce page text it used to read.
        var promptText: String {
            var lines = ["Name: \(name)"]
            if let title { lines.append("Title: \(title)") }
            if let company { lines.append("Company: \(company)") }
            if let state { lines.append("State: \(state)") }
            if let status { lines.append("Lead status: \(status)") }
            if let notes, !notes.isEmpty { lines.append("Notes: \(notes.prefix(800))") }
            if !recent.isEmpty { lines.append("Recent activity:\n" + recent.joined(separator: "\n")) }
            return lines.joined(separator: "\n")
        }
    }

    static func details(id: String, object: String) async throws -> Details {
        guard id.allSatisfy({ $0.isLetter || $0.isNumber }), ["Lead", "Contact"].contains(object) else {
            throw SFError(message: "Unexpected record.")
        }
        let base = object == "Lead"
            ? "Id, Name, FirstName, Company, Title, Phone, MobilePhone, State, Status, DoNotCall, Description"
            : "Id, Name, FirstName, Account.Name, Title, Phone, MobilePhone, MailingState, DoNotCall, Description"
        let linkedIn = object == "Lead" ? "Linkedin__c" : "LinkedIn__c"
        // The LinkedIn field is custom; if this org doesn't have it, ask again without it.
        var records = (try? await query("SELECT \(base), \(linkedIn) FROM \(object) WHERE Id = '\(id)'")) ?? []
        if records.isEmpty { records = try await query("SELECT \(base) FROM \(object) WHERE Id = '\(id)'") }
        guard let r = records.first else { throw SFError(message: "Couldn't load that record.") }

        let tasks = (try? await query(
            "SELECT Subject, ActivityDate, CallDisposition FROM Task WHERE WhoId = '\(id)' ORDER BY CreatedDate DESC LIMIT 5"
        )) ?? []
        let recent = tasks.map { t in
            [t["ActivityDate"] as? String, t["Subject"] as? String, t["CallDisposition"] as? String]
                .compactMap { $0 }.joined(separator: " · ")
        }
        var link = (r[linkedIn] as? String)
        if let l = link, l.hasPrefix("http://") { link = "https://" + l.dropFirst(7) }
        return Details(
            id: id, object: object,
            name: (r["Name"] as? String) ?? "",
            firstName: r["FirstName"] as? String,
            company: (r["Company"] as? String) ?? ((r["Account"] as? [String: Any])?["Name"] as? String),
            title: r["Title"] as? String,
            phone: r["Phone"] as? String,
            mobile: r["MobilePhone"] as? String,
            state: (r["State"] as? String) ?? (r["MailingState"] as? String),
            status: r["Status"] as? String,
            doNotCall: (r["DoNotCall"] as? Bool) ?? false,
            linkedIn: link.flatMap(URL.init(string:)),
            notes: r["Description"] as? String,
            recent: recent
        )
    }

    /// Opens the record in the browser, for when the rep wants the full page.
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

/// Shows Salesforce's own login page and waits for it to hand back to the app.
@MainActor
final class WebLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static var current: WebLogin?
    private var session: ASWebAuthenticationSession?

    static func run(url: URL, scheme: String) async throws -> URL {
        let login = WebLogin()
        current = login
        defer { current = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: error ?? Salesforce.SFError(message: "Sign-in was cancelled.")) }
            }
            session.presentationContextProvider = login
            session.prefersEphemeralWebBrowserSession = false
            login.session = session
            session.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor() }
    }
}

// MARK: - Connect sheet

struct SalesforceConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host = Salesforce.loginHost
    @State private var clientID = Keychain.read(.sfClientID) ?? ""
    @State private var status: String?
    @State private var working = false
    @State private var showSteps = !Salesforce.isConnected
    var onConnected: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect Salesforce").font(.title2.weight(.semibold))
                Text("Your list views and lead details show right in the coach. Read-only: the app never changes Salesforce.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup("One-time setup in Salesforce (admin, 5 minutes)", isExpanded: $showSteps) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Setup > External Client App Manager > New External Client App.")
                        Text("2. Name: Clarity Live Coach. Contact email: yours.")
                        Text("3. Check Enable OAuth. Callback URL: \(Salesforce.redirectURI)")
                        Text("4. Scopes: \"Manage user data via APIs (api)\" and \"Perform requests at any time (refresh_token, offline_access)\".")
                        Text("5. Check \"Require Proof Key for Code Exchange (PKCE)\". Uncheck \"Require secret for Web Server Flow\".")
                        Text("6. Create. Then open it > Settings > OAuth Settings > Consumer Key and Secret. Copy the Consumer Key here.")
                    }
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                }
                .font(.callout)

                TextField("Salesforce address", text: $host).textFieldStyle(.roundedBorder)
                SecureField("Consumer Key", text: $clientID).textFieldStyle(.roundedBorder)
                HStack {
                    Button(Salesforce.isConnected ? "Sign in again" : "Sign in to Salesforce") {
                        Task { await signIn() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(clientID.trimmed.isEmpty || host.trimmed.isEmpty || working)
                    if working { ProgressView().controlSize(.small) }
                    if Salesforce.isConnected {
                        Button("Disconnect") { Salesforce.signOut(); status = "Disconnected." }
                    }
                }
                if let status {
                    Text(status).font(.callout)
                        .foregroundStyle(status.hasPrefix("Connected") ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 370, height: 520)
    }

    private func signIn() async {
        working = true
        defer { working = false }
        Salesforce.loginHost = host.trimmed
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        do {
            try await Salesforce.signIn(clientID: clientID.trimmed)
            status = "Connected. Pick a list at the top of the coach."
            onConnected()
        } catch {
            status = error.localizedDescription
        }
    }
}
