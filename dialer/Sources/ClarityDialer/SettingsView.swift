import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionsTab().tabItem { Label("Connections", systemImage: "link") }
            CallingTab().tabItem { Label("Calling", systemImage: "phone") }
            ScriptTab().tabItem { Label("Script", systemImage: "text.alignleft") }
        }
        .frame(width: 620, height: 520)
    }
}

private struct ConnectionsTab: View {
    @Environment(Store.self) private var store
    @State private var host = Salesforce.loginHost
    @State private var clientID = Keychain.read(.sfClientID) ?? ""
    @State private var sfStatus = Salesforce.isConnected ? "Connected" : "Not connected"
    @State private var apiID = Keychain.read(.aircallID) ?? ""
    @State private var token = Keychain.read(.aircallToken) ?? ""
    @State private var numbers: [Aircall.Number] = []
    @State private var users: [Aircall.User] = []
    @State private var acStatus = ""

    var body: some View {
        @Bindable var store = store
        Form {
            Section("You") {
                TextField("Your first name (for {{Rep}})", text: $store.settings.repName)
            }
            Section {
                TextField("Login host", text: $host, prompt: Text("yourcompany.my.salesforce.com"))
                TextField("Consumer key", text: $clientID)
                HStack {
                    Button(Salesforce.isConnected ? "Sign in again" : "Sign in") {
                        Task {
                            Salesforce.loginHost = host.trimmed
                            do { try await Salesforce.signIn(clientID: clientID.trimmed); sfStatus = "Connected" }
                            catch { sfStatus = error.localizedDescription }
                        }
                    }
                    .disabled(clientID.trimmed.isEmpty || host.trimmed.isEmpty)
                    if Salesforce.isConnected { Button("Sign out") { Salesforce.signOut(); sfStatus = "Not connected" } }
                    Text(sfStatus).font(.caption).foregroundStyle(sfStatus == "Connected" ? .green : .secondary)
                }
            } header: { Text("Salesforce") } footer: {
                Text("External Client App with callback http://localhost:53682/callback, scopes api + refresh_token, PKCE, no secret required.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                SecureField("API ID", text: $apiID)
                SecureField("API token", text: $token)
                HStack {
                    Button("Connect") {
                        Keychain.save(apiID.trimmed, for: .aircallID)
                        Keychain.save(token.trimmed, for: .aircallToken)
                        Task { await loadAircall() }
                    }
                    .disabled(apiID.trimmed.isEmpty || token.trimmed.isEmpty)
                    Text(acStatus).font(.caption).foregroundStyle(.secondary)
                }
                if !users.isEmpty {
                    Picker("Calls are made as", selection: $store.settings.aircallUserID) {
                        Text("Choose yourself").tag(Int?.none)
                        ForEach(users) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                }
                if !numbers.isEmpty {
                    Picker("Calls go out from", selection: $store.settings.fromNumberID) {
                        Text("Choose a number").tag(Int?.none)
                        ForEach(numbers) { Text("\($0.name)  \($0.digits)").tag(Int?.some($0.id)) }
                    }
                    .onChange(of: store.settings.fromNumberID) { _, id in
                        store.settings.fromNumberDigits = numbers.first { $0.id == id }?.digits ?? ""
                    }
                    Picker("Texts go out from", selection: $store.settings.textNumberID) {
                        Text("Same as calls").tag(Int?.none)
                        ForEach(numbers) { Text("\($0.name)  \($0.digits)").tag(Int?.some($0.id)) }
                    }
                }
            } header: { Text("Aircall") } footer: {
                Text("Aircall > Integrations > API Keys. Sign in to the Aircall phone on the right of the dialer once; calls ring there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { if Aircall.hasKeys { await loadAircall() } }
    }

    private func loadAircall() async {
        do {
            numbers = try await Aircall.numbers()
            users = try await Aircall.users()
            acStatus = "Connected"
        } catch { acStatus = error.localizedDescription }
    }
}

private struct CallingTab: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Dialing") {
                Toggle("Auto-dial the next person", isOn: $store.settings.autoDial)
                Stepper("Countdown: \(store.settings.countdown)s", value: $store.settings.countdown, in: 0...15)
                    .disabled(!store.settings.autoDial)
                Toggle("Call twice (redial once if no answer)", isOn: $store.settings.callTwice)
                Stepper("Max dials per person per day: \(store.settings.maxAttemptsPerDay)", value: $store.settings.maxAttemptsPerDay, in: 1...5)
            }
            Section("Who gets called") {
                Toggle("Mobile numbers only", isOn: $store.settings.mobileOnly)
                Toggle("East to West (call earlier time zones first)", isOn: $store.settings.eastToWest)
                HStack {
                    Stepper("From \(hour(store.settings.startHour))", value: $store.settings.startHour, in: 0...23)
                    Stepper("to \(hour(store.settings.endHour))", value: $store.settings.endHour, in: 1...24)
                    Text("their local time").foregroundStyle(.secondary)
                }
                TextField("Cadence (days after first call)", text: Binding(
                    get: { store.settings.cadenceDays.map(String.init).joined(separator: ", ") },
                    set: { store.settings.cadenceDays = $0.split(separator: ",").compactMap { Int($0.trimmed) }.sorted() }))
                Text("e.g. 0, 2, 5, 9, 14 = five call days. After the last one they stop coming up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Voicemail & text") {
                Toggle("Show Drop voicemail (⌘D) — uses your Aircall recorded drop", isOn: $store.settings.voicemailDrop)
                Toggle("Text their mobile after a voicemail", isOn: $store.settings.textAfterVoicemail)
                TextEditor(text: $store.settings.textTemplate)
                    .font(.body).frame(height: 70)
                    .disabled(!store.settings.textAfterVoicemail)
                Text("Merge fields: " + Merge.fields.map { "{{\($0)}}" }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func hour(_ h: Int) -> String { "\(h % 12 == 0 ? 12 : h % 12)\(h < 12 || h == 24 ? "am" : "pm")" }
}

private struct ScriptTab: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        HSplitView {
            List(selection: $store.selectedScriptID) {
                ForEach(store.scripts) { s in Text(s.name).tag(Optional(s.id)) }
            }
            .frame(minWidth: 150, maxWidth: 190)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { let s = Script(name: "New script", body: ""); store.scripts.append(s); store.selectedScriptID = s.id } label: { Image(systemName: "plus") }
                    Button {
                        store.scripts.removeAll { $0.id == store.selectedScriptID }
                        store.selectedScriptID = store.scripts.first?.id
                    } label: { Image(systemName: "minus") }
                    .disabled(store.scripts.count < 2)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(8)
            }
            if let i = store.scripts.firstIndex(where: { $0.id == (store.selectedScriptID ?? store.scripts.first?.id) }) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name", text: $store.scripts[i].name).font(.headline)
                    TextEditor(text: $store.scripts[i].body).font(.system(size: 14))
                    Text("Paste your script. Merge fields: " + Merge.fields.map { "{{\($0)}}" }.joined(separator: " ") + ". **Bold** works.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
    }
}
