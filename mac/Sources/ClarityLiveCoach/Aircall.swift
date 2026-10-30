import SwiftUI

/// Sends follow-up texts through Aircall's official API, from the rep's Aircall number.
/// Uses Aircall's "native send" (send in agent conversation), so the text also shows in the Aircall app.
/// Needs Aircall's Professional plan and a number registered for texting (US A2P).
enum Aircall {
    struct Number: Identifiable, Hashable {
        let id: Int
        let name: String
        let digits: String
    }

    /// Aircall answered 404: that address or number doesn't exist for this account.
    struct NotFound: Error { let detail: String }

    struct AircallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var isSetUp: Bool {
        Keychain.read(.aircallID) != nil && Keychain.read(.aircallToken) != nil && numberID != nil
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
            // Wrong address or wrong field names for this account: worth trying the next format.
            throw NotFound(detail: "\(code) " + (String(data: data, encoding: .utf8).map { String($0.prefix(160)) } ?? ""))
        }
        guard (200..<300).contains(code) else {
            let detail = (json["message"] as? String) ?? (json["error"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw AircallError(message: code == 401 || code == 403
                ? "Aircall said no (\(code)). Check the API keys, and that your plan includes API texting."
                : "Aircall error \(code): \(detail.prefix(200))")
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

    /// Sends one text, from the chosen Aircall number to one person.
    static func sendText(to phone: String, body: String) async throws {
        guard let numberID else { throw AircallError(message: "Pick which Aircall number sends texts.") }
        guard let to = e164(phone) else { throw AircallError(message: "That phone number doesn't look right.") }
        // "In agent conversation" (native) sends show in the Aircall app and need no setup on the number.
        // Aircall's docs show two shapes (per-number path with to/body, or a shared path with
        // lineId/externalNumber/text, as their WhatsApp version uses). Try each, stop at the first success.
        let attempts: [(path: String, body: [String: Any])] = [
            ("/numbers/\(numberID)/messages/native/send", ["to": to, "body": body]),
            ("/messages/send/sms/native", ["lineId": numberID, "externalNumber": to, "text": body]),
            ("/messages/native/send", ["lineId": numberID, "externalNumber": to, "text": body]),
            ("/numbers/\(numberID)/messages/native/send", ["externalNumber": to, "text": body]),
        ]
        var tried: [String] = []
        for attempt in attempts {
            do {
                _ = try await request(attempt.path, method: "POST", body: attempt.body)
                UserDefaults.standard.set(attempt.path, forKey: "aircallWorkingPath") // for troubleshooting
                return
            } catch let notFound as NotFound {
                tried.append("\(attempt.path): \(notFound.detail)")
            }
        }
        throw AircallError(message: "Aircall couldn't send (number \(numberID)). " + tried.joined(separator: " | "))
    }

    /// "(555) 555-0123" -> "+15555550123". US and Canada only.
    static func e164(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        if digits.count == 10 { return "+1" + digits }
        if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
        return nil
    }

    /// Finds the lead's phone in the Salesforce page text, preferring Mobile.
    static func phone(in pageText: String?) -> String? {
        guard let pageText else { return nil }
        let lines = pageText.components(separatedBy: "\n")
        let pattern = #"(\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}"#
        func phoneIn(_ s: String) -> String? {
            s.range(of: pattern, options: .regularExpression).map { String(s[$0]) }
        }
        for label in ["Mobile", "Phone"] {
            for (i, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces).hasPrefix(label) {
                if let p = phoneIn(line) ?? (i + 1 < lines.count ? phoneIn(lines[i + 1]) : nil) { return p }
            }
        }
        return lines.lazy.compactMap(phoneIn).first
    }
}

// MARK: - Setup sheet

struct AircallSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiID = Keychain.read(.aircallID) ?? ""
    @State private var token = Keychain.read(.aircallToken) ?? ""
    @State private var numbers: [Aircall.Number] = []
    @State private var selected = Aircall.numberID ?? 0
    @State private var status: String?
    @State private var working = false
    @AppStorage("autoSendText") private var autoSend = false
    @State private var testPhone = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Aircall texting").font(.title2.weight(.semibold))
                Text("Sends your follow-up text from your Aircall number in one click. Needs Aircall's Professional plan.")
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
                    Picker("Send texts from", selection: $selected) {
                        ForEach(numbers) { n in Text("\(n.name)  \(n.digits)").tag(n.id) }
                    }
                    .onChange(of: selected) { UserDefaults.standard.set(selected, forKey: "aircallNumberID") }
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
                Toggle("Send the text by itself after a voicemail", isOn: $autoSend)
                Text("Off: you click Send (recommended). On: it sends as soon as the voicemail is detected. Texting rules still apply: skip Do Not Call leads and stop if anyone replies STOP. Not legal advice.")
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
