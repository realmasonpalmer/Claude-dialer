import SwiftUI

/// Sends follow-up texts through Aircall's official API, from the rep's Aircall number.
/// Uses Aircall's "Send Message in agent conversation" (native send), so the text also shows in the Aircall app.
/// Needs Aircall's Professional plan and a number registered for texting (US A2P).
enum Aircall {
    struct Number: Identifiable, Hashable {
        let id: Int
        let name: String
        let digits: String
    }

    /// Aircall answered 400/404/422: bad number, line or message (detail says which).
    struct NotFound: Error { let detail: String }

    struct AircallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var isSetUp: Bool {
        Keychain.read(.aircallID) != nil && Keychain.read(.aircallToken) != nil && numberID != nil
    }

    struct User: Identifiable, Hashable {
        let id: Int
        let name: String
        let email: String
    }

    /// The Aircall person calls are placed as (so Salesforce shows "made by" them).
    static var userID: Int? {
        let id = UserDefaults.standard.integer(forKey: "aircallUserID")
        return id == 0 ? nil : id
    }

    static var canPlaceCalls: Bool { isSetUp && userID != nil }

    static func users() async throws -> [User] {
        let json = try await request("/users?per_page=50")
        return ((json["users"] as? [[String: Any]]) ?? []).compactMap { u in
            guard let id = u["id"] as? Int else { return nil }
            return User(id: id, name: (u["name"] as? String) ?? "User", email: (u["email"] as? String) ?? "")
        }
    }

    /// Starts a call from the rep's Aircall desktop app (Aircall Workspace), like clicking the number there.
    /// Aircall API: POST /v1/users/:id/calls { number_id, to }. The app must be open and the rep available.
    static func startCall(to phone: String) async throws {
        guard let userID, let numberID else { throw AircallError(message: "Pick your Aircall user and number in Aircall settings.") }
        guard let to = e164(phone) else { throw AircallError(message: "That phone number doesn't look right.") }
        do {
            _ = try await request("/users/\(userID)/calls", method: "POST", body: ["number_id": numberID, "to": to])
        } catch let failed as NotFound {
            throw AircallError(message: failed.detail.hasPrefix("400")
                ? "Aircall couldn't dial that number, or your Aircall number isn't active."
                : "Aircall said: \(failed.detail)")
        } catch let error as AircallError where error.message.contains("405") {
            throw AircallError(message: "Aircall says you're not available. Open the Aircall app, set yourself Available, and make sure you're not on a call.")
        }
    }

    static var numberID: Int? {
        let id = UserDefaults.standard.integer(forKey: "aircallNumberID")
        return id == 0 ? nil : id
    }

    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let id = Keychain.read(.aircallID), let token = Keychain.read(.aircallToken) else {
            throw AircallError(message: "Add your Aircall API keys first.")
        }
        var req = URLRequest(url: URL(string: "https://api.aircall.io/v1\(path)")!)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("Basic " + Data("\(id):\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if code == 404 || code == 400 || code == 422 {
            throw NotFound(detail: "\(code) " + (String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? ""))
        }
        guard (200..<300).contains(code) else {
            let detail = (json["message"] as? String) ?? (json["error"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            let lower = detail.lowercased()
            let message: String
            if code == 401 { message = "Aircall didn't accept the API keys (401). Check the API ID and token." }
            else if lower.contains("messaging public api is not enabled") { message = "Texting through the API isn't turned on for your Aircall account. It needs the Professional plan; ask your Aircall admin or Customer Success Manager." }
            else if lower.contains("public api sms is not enabled") { message = "API texting isn't turned on for this Aircall number. Ask your Aircall admin to enable it." }
            else if lower.contains("line does not belong") { message = "That number isn't on your Aircall account. Pick it again in Aircall texting." }
            else if lower.contains("limit") { message = "This Aircall number hit its texting limit. Try again later." }
            else if lower.contains("not verified") || lower.contains("not active") { message = "Your Aircall account isn't verified or active for texting yet." }
            else { message = "Aircall error \(code): \(detail.prefix(200))" }
            throw AircallError(message: message)
        }
        return json
    }

    static func numbers() async throws -> [Number] {
        let json: [String: Any]
        do {
            json = try await request("/numbers?per_page=50")
        } catch let notFound as NotFound {
            throw AircallError(message: "Aircall couldn't find your numbers (404 \(notFound.detail)). Check the API ID and token.")
        }
        return ((json["numbers"] as? [[String: Any]]) ?? []).compactMap { n in
            guard let id = n["id"] as? Int else { return nil }
            return Number(id: id, name: (n["name"] as? String) ?? "Number", digits: (n["digits"] as? String) ?? "")
        }
    }

    /// Asks Aircall whether the rep's line is on a call right now (Aircall's own call status, not a guess).
    /// nil when Aircall isn't set up or can't be reached.
    /// - Parameter since: only count calls that started after this time (to spot a *new* call).
    static func lineIsOnCall(since: Date? = nil) async -> Bool? {
        guard Keychain.read(.aircallID) != nil, Keychain.read(.aircallToken) != nil,
              let json = try? await request("/calls?order=desc&per_page=10") else { return nil }
        let calls = (json["calls"] as? [[String: Any]]) ?? []
        let mine = calls.filter { call in
            if let numberID, ((call["number"] as? [String: Any])?["id"] as? Int) != numberID { return false }
            if let since, let started = call["started_at"] as? Double, started < since.timeIntervalSince1970 { return false }
            return true
        }
        // Aircall call status: "initial" (ringing), "answered" (live), "done" (ended).
        return mine.contains { ["initial", "answered"].contains($0["status"] as? String ?? "") }
    }

    /// Sends one text, from the chosen Aircall number to one person.
    static func sendText(to phone: String, body: String) async throws {
        guard let numberID else { throw AircallError(message: "Pick which Aircall number sends texts.") }
        guard let to = e164(phone) else { throw AircallError(message: "That phone number doesn't look right.") }
        // Aircall API reference: "Send Message in agent conversation".
        // POST /v1/numbers/:id/messages/native/send  { to, body }. No setup needed on the number;
        // the text shows in the Aircall app so anyone on the line can continue the conversation.
        do {
            _ = try await request("/numbers/\(numberID)/messages/native/send", method: "POST", body: ["to": to, "body": body])
        } catch let failed as NotFound {
            throw AircallError(message: plainWords(failed.detail))
        }
    }

    /// Aircall's documented errors, in plain words.
    private static func plainWords(_ detail: String) -> String {
        let d = detail.lowercased()
        if d.hasPrefix("404") { return "Aircall can't find that number (404). Pick your number again in Aircall texting." }
        if d.contains("not sms capable") { return "That Aircall number (or their phone) can't receive texts." }
        if d.contains("not covered") || d.contains("carrier line") { return "Aircall can't text that phone number." }
        if d.contains("ivr") { return "That Aircall number is a phone menu line and can't text. Pick another number." }
        if d.contains("not allowed") { return "Aircall blocked texting this person (they may have opted out)." }
        if d.contains("1600") { return "The text is too long." }
        return "Aircall said: \(detail)"
    }

    /// "(555) 555-0123" -> "+15555550123". US and Canada only.
    static func e164(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        if digits.count == 10 { return "+1" + digits }
        if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
        return nil
    }

    /// Finds the lead's Mobile number in the Salesforce page text.
    static func phone(in pageText: String?) -> String? {
        guard let pageText else { return nil }
        let lines = pageText.components(separatedBy: "\n")
        let pattern = #"(\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}"#
        func phoneIn(_ s: String) -> String? {
            s.range(of: pattern, options: .regularExpression).map { String(s[$0]) }
        }
        // Mobile only: texts can't go to an office line, and the Phone field is never used.
        for (i, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces).hasPrefix("Mobile") {
            if let p = phoneIn(line) ?? (i + 1 < lines.count ? phoneIn(lines[i + 1]) : nil) { return p }
        }
        return nil
    }
}

// MARK: - Setup sheet

struct AircallSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiID = Keychain.read(.aircallID) ?? ""
    @State private var token = Keychain.read(.aircallToken) ?? ""
    @State private var numbers: [Aircall.Number] = []
    @State private var selected = Aircall.numberID ?? 0
    @State private var users: [Aircall.User] = []
    @State private var selectedUser = Aircall.userID ?? 0
    @State private var status: String?
    @State private var working = false
    @State private var testPhone = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Aircall").font(.title2.weight(.semibold))
                Text("Places calls from the Aircall desktop app and sends follow-up texts in one click. Texting needs Aircall's Professional plan.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("An Aircall admin makes these in Aircall: Integrations > API Keys > Generate.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("API ID", text: $apiID).textFieldStyle(.roundedBorder)
                SecureField("API token", text: $token).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Connect") { Task { await connect() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(apiID.trimmed.isEmpty || token.trimmed.isEmpty || working)
                    if working { ProgressView().controlSize(.small) }
                }

                if !numbers.isEmpty {
                    Picker("Your Aircall number", selection: $selected) {
                        ForEach(numbers) { n in Text("\(n.name)  \(n.digits)").tag(n.id) }
                    }
                    .onChange(of: selected) { UserDefaults.standard.set(selected, forKey: "aircallNumberID") }
                }
                if !users.isEmpty {
                    Picker("Calls are made as", selection: $selectedUser) {
                        Text("Choose yourself").tag(0)
                        ForEach(users) { u in Text(u.name).tag(u.id) }
                    }
                    .onChange(of: selectedUser) { UserDefaults.standard.set(selectedUser, forKey: "aircallUserID") }
                    Text("Pick yourself, so Salesforce logs calls as made by you.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let status {
                    Text(status).font(.callout)
                        .foregroundStyle(status.hasPrefix("Connected") ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !numbers.isEmpty {
                    Text("Send yourself a test text").font(.callout.weight(.semibold))
                    HStack {
                        TextField("Your cell", text: $testPhone).textFieldStyle(.roundedBorder)
                        Button("Send test") {
                            Task {
                                working = true
                                defer { working = false }
                                do {
                                    try await Aircall.sendText(to: testPhone, body: "Test from Clarity Live Coach.")
                                    status = "Connected. Test text sent. Check your phone."
                                } catch {
                                    status = error.localizedDescription
                                }
                            }
                        }
                        .disabled(testPhone.trimmed.isEmpty || working)
                    }
                }

                Divider()
                Text("After a 2nd-try voicemail, you get a Send text button. Do Not Call leads are skipped. If anyone texts back STOP, don't text them again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 370, height: 520)
        .task { if Aircall.isSetUp || Keychain.read(.aircallID) != nil { await loadNumbers() } }
    }

    private func connect() async {
        Keychain.save(apiID.trimmed, for: .aircallID)
        Keychain.save(token.trimmed, for: .aircallToken)
        await loadNumbers()
    }

    private func loadNumbers() async {
        working = true
        defer { working = false }
        do {
            numbers = try await Aircall.numbers()
            users = (try? await Aircall.users()) ?? []
            if !numbers.contains(where: { $0.id == selected }), let first = numbers.first {
                selected = first.id
                UserDefaults.standard.set(first.id, forKey: "aircallNumberID")
            }
            status = numbers.isEmpty ? "Connected, but no numbers found." : "Connected. Pick the number that sends texts."
        } catch {
            status = error.localizedDescription
        }
    }
}
