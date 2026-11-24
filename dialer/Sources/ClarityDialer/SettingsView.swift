import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionsTab().tabItem { Label("Connections", systemImage: "link") }
            CallingTab().tabItem { Label("Calling", systemImage: "phone") }
            SequenceTab().tabItem { Label("Sequence", systemImage: "calendar") }
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
    @State private var anthropicKey = Keychain.read(.anthropic) ?? ""
    @State private var claudeStatus = CallReview.hasKey ? "Saved" : "Off"

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
            Section {
                SecureField("Anthropic API key", text: $anthropicKey)
                HStack {
                    Button("Save") { Keychain.save(anthropicKey.trimmed.isEmpty ? nil : anthropicKey.trimmed, for: .anthropic); claudeStatus = anthropicKey.trimmed.isEmpty ? "Off" : "Saved" }
                    Text(claudeStatus).font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Call review (Claude)") } footer: {
                Text("Reads each answered call's Aircall transcript to count real pickups (the lead, not a front desk) and meetings. A meeting counts once it's on a calendar in Salesforce.")
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
            }
            Section("Voicemail") {
                Toggle("Show Drop voicemail (⌘D). Which recording is set per day in Sequence.", isOn: $store.settings.voicemailDrop)
            }
        }
        .formStyle(.grouped)
    }

}

/// The Day 1 / 3 / 5 sequence, one card per day.
private struct SequenceTab: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Text("Each person moves through these days. Only people due today are loaded, most overdue first. One step per day, so calling someone twice in a day never moves them twice.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach($store.settings.cadence.steps) { $step in
                Section {
                    Stepper("Day \(step.day)", value: $step.day, in: 1...60)
                    TextField("Set status to", text: $step.status)
                    optional("Leave voicemail (Aircall drop name)", $step.voicemail, placeholder: "Voicemail 1")
                    optionalEditor("Text if no answer", $step.text)
                    optionalEditor("LinkedIn connection request note", $step.linkedInNote)
                } header: {
                    HStack {
                        Text("Day \(step.day)")
                        Spacer()
                        Button(role: .destructive) { store.settings.cadence.steps.removeAll { $0.id == step.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).disabled(store.settings.cadence.steps.count < 2)
                    }
                }
            }
            Section {
                HStack {
                    Button("Add a day") {
                        let last = store.settings.cadence.steps.last
                        store.settings.cadence.steps.append(Step(day: (last?.day ?? 0) + 2, status: "\(store.settings.cadence.steps.count + 1)th Contact"))
                    }
                    Button("Reset to Day 1 / 3 / 5") { store.settings.cadence = .standard }
                }
                Text("Merge fields: " + Merge.fields.map { "{{\($0)}}" }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func optional(_ title: String, _ value: Binding<String?>, placeholder: String) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? placeholder : nil }))
            if value.wrappedValue != nil {
                TextField("", text: Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0 }))
                    .frame(width: 160)
            }
        }
    }

    @ViewBuilder
    private func optionalEditor(_ title: String, _ value: Binding<String?>) -> some View {
        Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? "" : nil }))
        if value.wrappedValue != nil {
            TextEditor(text: Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0 }))
                .font(.body).frame(height: 60)
        }
    }
}
