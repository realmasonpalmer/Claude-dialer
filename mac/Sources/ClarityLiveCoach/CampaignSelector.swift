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
            Text("Campaigns").font(.title2.weight(.semibold))
            Text("Up to \(CampaignStore.maxActive) active at a time. Each one has its own Salesforce list and script.")
                .font(.callout).foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach(store.campaigns) { c in
                    row(c).tag(c.id)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 220)

            HStack(spacing: 8) {
                Button("New Campaign") { showNew = true }
                Button("Activate") {
                    guard let id = selection else { return }
                    note = store.setActive(id, true) ? nil : "Up to \(CampaignStore.maxActive) campaigns can be active. Pause one first."
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
                    store.selectedID = c.id // the coach switches script and opens the list
                    dismissWindow(id: "campaign-selector")
                }
                .buttonStyle(.borderedProminent)
                .disabled(picked?.active != true)
                .help("Pick an active campaign to call its list")
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
        .sheet(isPresented: $showNew) { NewCampaignView().environmentObject(store) }
        .task { await refreshSizes() }
        .onAppear { selection = selection ?? store.selectedID }
    }

    private func row(_ c: Campaign) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.callout.weight(.semibold))
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
            guard let rows = try? await Salesforce.fullList(object: c.listObject, key: c.listViewID) else { continue }
            guard var latest = store.campaigns.first(where: { $0.id == c.id }), latest.listSize != rows.count else { continue }
            latest.listSize = rows.count
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
            Text("New Campaign").font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("1. Segment name").font(.headline)
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

            VStack(alignment: .leading, spacing: 4) {
                Text("3. Who is this for?").font(.headline)
                Text("Who you're calling and what they deal with. Claude writes the script for them.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $audience)
                    .font(.callout)
                    .frame(height: 80)
                    .overlay(alignment: .topLeading) {
                        if audience.isEmpty {
                            Text("e.g. Owners of 5 to 20 person CPA firms. Busy in tax season. Lots of client calls, notes typed by hand, often no CRM.")
                                .foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("4. Script").font(.headline)
                    Spacer()
                    Button("Use the backbone") { script = ColdCallBackbone.text }
                        .help("Start from Clarity's cold call backbone as is")
                    Button {
                        Task { await writeScript() }
                    } label: {
                        Label(writing ? "Writing..." : "Write it for me", systemImage: "sparkles")
                    }
                    .disabled((audience.trimmed.isEmpty && view == nil) || writing || Keychain.read(.anthropic) == nil)
                    .help("Claude writes a full script in the backbone format for the people in box 3")
                }
                TextEditor(text: $script)
                    .font(.callout)
                    .frame(minHeight: 220)
                    .overlay(alignment: .topLeading) {
                        if script.isEmpty {
                            Text("Paste your script, or fill in box 3 and click \"Write it for me\". Takes about a minute.")
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

    /// Writes a full script in the cold call backbone format. The rep's "who is this for" leads;
    /// titles and companies from the list are only a backup hint.
    private func writeScript() async {
        guard let key = Keychain.read(.anthropic) else { return }
        writing = true
        message = nil
        defer { writing = false }
        var sample = ""
        if let v = view {
            let rows = (try? await Salesforce.fullList(object: v.object, key: v.id)) ?? []
            sample = rows.prefix(40).map { $0.subtitle.isEmpty ? $0.name : $0.subtitle }.joined(separator: "\n")
        }
        var client = ClaudeClient(apiKey: key) // Opus
        client.effort = "medium"
        client.maxTokens = 24000 // a full backbone script is long
        let system = """
        You write cold call scripts for Clarity Consulting that a live call coach app reads during the call.
        The app follows the script like a decision tree: it tracks state, walks the pick order, matches what the
        prospect says to a row's "Sounds like", and shows that row's "Say" line word for word.

        Below is the backbone. Your script must match it exactly in format and level of detail:
        the same sections in the same order (OUTPUT RULES, BANNED WORDS AND CLAIMS, TRANSCRIPT NOISE, FACTS,
        STATE TO TRACK, PICK ORDER, GLOBAL TRIGGERS, S1 to S8, OBJECTIONS, VOICEMAIL, AFTER THE CALL), the same
        row IDs, the same table columns separated by tabs, and about the same number of rows per section.
        Keep OUTPUT RULES, BANNED WORDS AND CLAIMS, TRANSCRIPT NOISE, STATE TO TRACK and PICK ORDER as written.
        Rewrite the lines for the audience you're given: their words, their world, their likely answers in
        "Sounds like", their objections. Swap rows that don't fit them for rows that do (keep the ID style).

        Rules for every Say line: max 25 words, ends with a question unless it ends the call, plain spoken
        English a 5th grader could read, warm and direct, no jargon, no em dashes. Outcome first (time back,
        more selling), then the problem, then the fix. Technology last.
        Facts: use only the FACTS section. Never invent a number, client name, price, offer or result.
        If the audience isn't a tax or accounting firm, still use the real tax firm proof point, said as it is.
        Use [slots] like [Name], [Firm], [SDR], [Day], [Time], [Number] the way the backbone does.
        Use [Name] for the prospect, never he or she.
        Return only the script as plain text. No markdown, no notes before or after.

        BACKBONE:
        \(ColdCallBackbone.text)
        """
        let user = """
        Write the script for this campaign.
        Segment: \(name.trimmed.isEmpty ? (view?.label ?? "Not named") : name.trimmed)
        Who it's for (from the rep, this leads): \(audience.trimmed.isEmpty ? "Not given. Use the list below." : audience.trimmed)
        \(sample.isEmpty ? "" : "Titles and companies from the Salesforce list (a hint only; the rep's description wins):\n\(sample)")
        """
        do {
            var text = ""
            try await client.stream(system: system, user: user) { text = $0 }
            script = text.trimmed
            if name.trimmed.isEmpty, let v = view { name = v.label }
        } catch {
            message = "Couldn't write the script: \(error.localizedDescription)"
        }
    }
}
