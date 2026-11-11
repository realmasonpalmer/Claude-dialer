import SwiftUI

/// One screen for all campaigns. Each row: segment name, list size, Active or Paused.
/// Up to 3 can be active. Click an active campaign and Start calling to work its list.
struct CampaignSelectorView: View {
    @EnvironmentObject var store: CampaignStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var selection: UUID?
    @State private var showNew = false
    @State private var note: String?

    private var picked: Campaign? { store.campaigns.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Call Segments").font(.title2.weight(.semibold))
            Text("Up to \(CampaignStore.maxActive) active at a time. Each one has its own Salesforce list and script.")
                .font(.callout).foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach(store.campaigns) { c in
                    row(c).tag(c.id)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 220)
            // Double-click a campaign to start calling it (a paused one is activated first).
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first {
                    Button("Start calling") { start(id) }
                    Button("Edit") {
                        store.editing = store.campaigns.first { $0.id == id }
                        openWindow(id: "campaign-editor")
                    }
                }
            } primaryAction: { ids in
                if let id = ids.first { start(id) }
            }

            HStack(spacing: 8) {
                Button("New Call Segment") { showNew = true }
                Button("Activate") {
                    guard let id = selection else { return }
                    note = store.setActive(id, true) ? nil : "Up to \(CampaignStore.maxActive) call segments can be active. Pause one first."
                }
                .disabled(picked == nil || picked?.active == true)
                Button("Pause") {
                    guard let id = selection else { return }
                    store.setActive(id, false)
                    note = nil
                }
                .disabled(picked?.active != true)
                Spacer()
                Button("Edit") {
                    guard let c = picked else { return }
                    store.editing = c
                    openWindow(id: "campaign-editor")
                }
                .disabled(picked == nil)
                Button("Start calling") {
                    guard let c = picked else { return }
                    start(c.id)
                }
                .buttonStyle(.borderedProminent)
                .disabled(picked?.active != true)
                .help("Pick an active call segment to call its list (or double-click it)")
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.orange)
            } else {
                Text("Tip: double-click a call segment to start calling it.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
        .sheet(isPresented: $showNew) { NewCampaignView().environmentObject(store) }
        .task { await refreshSizes() }
        .onAppear { selection = selection ?? store.selectedID }
    }

    /// Calls this campaign's list: activates it if it's paused (when there's room), then switches to it.
    private func start(_ id: UUID) {
        guard let c = store.campaigns.first(where: { $0.id == id }) else { return }
        if !c.active, !store.setActive(id, true) {
            note = "Up to \(CampaignStore.maxActive) call segments can be active. Pause one first."
            return
        }
        note = nil
        store.selectedID = id // the coach switches script and opens the list
        dismissWindow(id: "campaign-selector")
    }

    private func row(_ c: Campaign) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.callout.weight(.semibold))
                // Who it's for, so campaigns are easy to tell apart.
                if !c.persona.trimmed.isEmpty {
                    Text(c.persona.trimmed).font(.caption).lineLimit(1)
                }
                Text(c.listName.isEmpty ? "No Salesforce list yet" : c.listName)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(c.listViewID.isEmpty ? "–" : "\(c.listSize) people")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            Text(c.active ? "Active" : "Paused")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background((c.active ? Color.green : Color.secondary).opacity(0.18), in: Capsule())
                .foregroundStyle(c.active ? Color.green : Color.secondary)
        }
        .padding(.vertical, 4)
    }

    /// Counts the people on each campaign's Salesforce list.
    private func refreshSizes() async {
        guard Salesforce.isConnected else { return }
        for c in store.campaigns where !c.listViewID.isEmpty {
            guard let size = try? await Salesforce.count(object: c.listObject, key: c.listViewID) else { continue }
            guard var latest = store.campaigns.first(where: { $0.id == c.id }), latest.listSize != size else { continue }
            latest.listSize = size
            store.save(latest)
        }
    }
}

/// New Campaign: segment name, a Salesforce list, who it's for, and a script (paste one, or let
/// Claude write it in the cold call backbone format from who the rep says it's for).
struct NewCampaignView: View {
    @EnvironmentObject var store: CampaignStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var listID = ""
    @State private var audience = ""
    @State private var script = ""
    @State private var views: [Salesforce.ListView] = []
    @State private var writing = false
    @State private var message: String?

    private var view: Salesforce.ListView? { views.first { $0.id == listID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Call Segment").font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("1. Call Segment name").font(.headline)
                TextField("e.g. Tax firm partners", text: $name).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("2. Salesforce list").font(.headline)
                if !Salesforce.isConnected {
                    Text("Sign in to Salesforce first (gear > Setup > Salesforce).").font(.callout).foregroundStyle(.secondary)
                } else if views.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    Picker("", selection: $listID) {
                        Text("Pick a list...").tag("")
                        ForEach(views) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("3. Describe this call segment").font(.headline)
                Text("Who they are, what keeps them up at night, what they want, and their story. The more real, the better the script.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $audience)
                    .font(.callout)
                    .frame(height: 110)
                    .overlay(alignment: .topLeading) {
                        if audience.isEmpty {
                            Text(ScriptWriter.describeHint)
                                .foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                Button {
                    Task { await writeScript() }
                } label: {
                    Label(writing ? "Generating... \(script.split(separator: " ").count) words" : "Generate script",
                          systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(BrandPrimaryButton())
                .disabled(audience.trimmed.isEmpty || writing || Keychain.read(.anthropic) == nil)
                .help("Claude writes a full cold call script for this call segment. Takes about a minute.")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("4. Script").font(.headline)
                    Spacer()
                    Button("Use the backbone") { script = ColdCallBackbone.text }
                        .help("Start from Clarity's cold call backbone as is")
                        .disabled(writing)
                }
                TextEditor(text: $script)
                    .font(.callout)
                    .frame(minHeight: 200)
                    .disabled(writing) // it's filling in as Claude writes
                    .overlay(alignment: .topLeading) {
                        if script.isEmpty {
                            Text("Your script shows up here. Or paste your own.")
                                .foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmed.isEmpty || script.trimmed.isEmpty || writing)
            }
        }
        .padding(20)
        .frame(width: 640, height: 760)
        .task {
            guard Salesforce.isConnected, views.isEmpty else { return }
            views = (try? await Salesforce.listViews()) ?? []
        }
    }

    private func save() {
        var c = Campaign(name: name.trimmed, objective: "Book a free AI health check with Oliver, our managing partner.",
                         pastedScript: script.trimmed,
                         company: "Clarity Consulting. Anthropic partner. Salesforce partner.")
        c.persona = audience.trimmed
        if let v = view { c.listObject = v.object; c.listViewID = v.id; c.listName = v.label }
        c.active = store.activeCampaigns.count < CampaignStore.maxActive
        store.save(c)
        dismiss()
    }

    /// Writes a full script in the backbone format, shown as it's written.
    private func writeScript() async {
        writing = true
        message = nil
        defer { writing = false }
        do {
            script = ""
            let text = try await ScriptWriter.write(segment: name.trimmed.isEmpty ? (view?.label ?? "") : name.trimmed,
                                                    audience: audience, list: view) { partial in
                Task { @MainActor in if writing { script = partial } }
            }
            script = text
            if name.trimmed.isEmpty, let v = view { name = v.label }
        } catch {
            message = "Couldn't write the script: \(error.localizedDescription)"
        }
    }
}

/// Writes a cold call script in the backbone format (`ColdCallBackbone`). The rep's "who is this for"
/// leads; titles and companies from the Salesforce list are only a backup hint. Used by New Campaign
/// and Edit Campaign.
enum ScriptWriter {
    /// What to put in the "Describe this call segment" box.
    static let describeHint = "e.g. Owners of 5 to 20 person CPA firms in Portland. Swamped Jan to April. Every client call ends with someone typing notes. They want to grow without hiring, and worry about mistakes and burnout. Most started solo and built the firm on referrals."

    static func write(segment: String, audience: String, list: Salesforce.ListView?,
                      onText: @escaping (String) -> Void) async throws -> String {
        guard let key = Keychain.read(.anthropic) else {
            throw ClaudeClient.APIError(message: "Add your Anthropic key first (gear menu > Setup > AI keys).")
        }
        var sample = ""
        if let v = list {
            let rows = (try? await Salesforce.fullList(object: v.object, key: v.id)) ?? []
            sample = rows.prefix(40).map { $0.subtitle.isEmpty ? $0.name : $0.subtitle }.joined(separator: "\n")
        }
        var client = ClaudeClient(apiKey: key) // Opus
        client.effort = "high" // the best script, not the fastest
        client.maxTokens = 32000 // a full backbone script is long
        client.idleTimeout = 60
        client.totalTimeout = 300
        let system = """
        You are the best cold call script writer working today. You write for Clarity Consulting, a boutique
        Salesforce partner and Anthropic Claude partner. A live call coach app reads your script during the call:
        it tracks state, walks the pick order, matches what the prospect says to a row's "Sounds like", and shows
        that row's "Say" line word for word. So the script must be complete and in the backbone's exact format.

        Before writing, think hard about this call segment, from what the rep wrote: their top pains (in their own
        words), what they want this year, what they're proud of and afraid of, their day, their busy seasons,
        what triggers them to look for help, who else they answer to, and the brush-offs they use on every
        cold caller. Every line of the script comes from that picture. A generic line is a failed line.

        How great cold calls work now (use all of it):
        - Opener: honest and calm. Say it's a cold call or give the reason right away, then ask for 30 seconds.
          Never "how are you", never "did I catch you at a bad time".
        - Reason: one problem people like them have, in their words, framed as what peers deal with. Not the
          product. End with a question: is that true for them?
        - Discovery: one short question at a time, branching on their answer. Get the problem, who it hits and
          what it costs them, in their words. Don't over-discover: ask for the meeting once a problem is named.
        - Objections: plan for the 12 to 15 brush-offs this segment really uses. Each answer: a few words of
          agreement, then one curious question. Never argue. Respect a second firm no.
        - The ask: small, specific, low risk. Two real times. A free health check with Oliver, our managing partner.
        - Gatekeepers: sound expected, ask for help, never pitch them.
        - Voicemail under 20 seconds, texts and LinkedIn notes in the same voice, each one a new angle.
        - Sound like a sharp, friendly person from their world. Short words, contractions, no jargon, no hype.

        Format: match the backbone below exactly: the same sections in the same order (OUTPUT RULES, BANNED
        WORDS AND CLAIMS, TRANSCRIPT NOISE, FACTS, STATE TO TRACK, PICK ORDER, GLOBAL TRIGGERS, S1 to S8,
        OBJECTIONS, VOICEMAIL, AFTER THE CALL), the same row ID style, table columns separated by tabs, and at
        least as many rows per section. Keep OUTPUT RULES, BANNED WORDS AND CLAIMS, STATE TO TRACK and PICK ORDER
        as written. Add words this segment uses to TRANSCRIPT NOISE if speech-to-text could mishear them.

        Rules for every Say line: 25 words at most, ends with a question unless it ends the call, plain spoken
        English a 5th grader could read, no em dashes. Outcome first (time back, more selling, less risk), then
        the problem, then the fix. Technology last.
        Facts: only the FACTS section. Never invent a number, client name, result, price or offer. The real proof
        point is a tax firm of ten that got back about 2,000 hours a year; say it as it is.
        Use [slots] like [Name], [Firm], [SDR], [Day], [Time], [Number] the way the backbone does.
        Use [Name] for the prospect, never he or she.
        Return only the script as plain text. No markdown, no notes before or after.

        BACKBONE:
        \(ColdCallBackbone.text)
        """
        let user = """
        Write the script for this call segment.
        Call segment: \(segment.isEmpty ? "Not named" : segment)
        The rep's description (this leads): \(audience.trimmed.isEmpty ? "Not given. Use the list below." : audience.trimmed)
        \(sample.isEmpty ? "" : "Titles and companies from the Salesforce list (a hint only; the description wins):\n\(sample)")
        """
        var text = ""
        try await client.stream(system: system, user: user) { partial in
            text = partial
            onText(partial)
        }
        return text.trimmed
    }
}
