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

/// New Campaign: segment name, a Salesforce list, and a script (paste one, or let Claude write it
/// from the people on the list).
struct NewCampaignView: View {
    /// Start using it right away (opened from the coach for the list that's open).
    var useNow = false
    @EnvironmentObject var store: CampaignStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var listID = ""
    @State private var script = ""
    @State private var views: [Salesforce.ListView] = []
    @State private var writing = false
    @State private var message: String?

    private var view: Salesforce.ListView? { views.first { $0.id == listID } }

    /// The list it starts with: the one open now, if no campaign has it yet.
    private var startList: WorkingList? {
        guard let open = store.workingList, store.campaign(for: open) == nil else { return nil }
        return open
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Campaign").font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("1. Segment name").font(.headline)
                TextField("e.g. Tax firm partners", text: $name).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("2. Salesforce list").font(.headline)
                if !Salesforce.isConnected, let list = startList {
                    Text(list.label.isEmpty ? "The list open in Chrome" : list.label).font(.callout)
                } else if !Salesforce.isConnected {
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
                HStack {
                    Text("3. Script").font(.headline)
                    Spacer()
                    Button {
                        Task { await writeScript() }
                    } label: {
                        Label(writing ? "Writing..." : "Write it for me from the list", systemImage: "sparkles")
                    }
                    .disabled(view == nil || writing || Keychain.read(.anthropic) == nil)
                    .help("Claude reads who's on the list and writes a script for that segment")
                }
                TextEditor(text: $script)
                    .font(.callout)
                    .frame(minHeight: 220)
                    .overlay(alignment: .topLeading) {
                        if script.isEmpty {
                            Text("Paste your script, or click \"Write it for me from the list\".")
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
        .frame(width: 560, height: 620)
        .onAppear { keepWindowsOnTop() }
        .task {
            guard Salesforce.isConnected, views.isEmpty else { return }
            views = (try? await Salesforce.listViews()) ?? []
            // Start with the list that's open, so the script is saved with it.
            if listID.isEmpty, let list = startList, let match = views.first(where: { list.matches($0) }) {
                listID = match.id
            }
        }
    }

    private func save() {
        var c = Campaign(name: name.trimmed, objective: "Book a 20 minute meeting", pastedScript: script.trimmed,
                         company: "Clarity Consulting: a boutique Salesforce partner and Anthropic Claude partner.")
        if let v = view {
            c.link(v)
        } else if !Salesforce.isConnected, let list = startList {
            // Not signed in to Salesforce: save it with the list as Chrome shows it.
            c.link(Salesforce.ListView(id: list.view, label: list.label.isEmpty ? "\(list.object) list" : list.label,
                                       object: list.object))
        }
        c.active = store.activeCampaigns.count < CampaignStore.maxActive
        store.save(c)
        if useNow { store.selectedID = c.id }
        dismiss()
    }

    /// Reads who's on the list (titles and companies) and asks Claude for a script for that segment.
    private func writeScript() async {
        guard let v = view, let key = Keychain.read(.anthropic) else { return }
        writing = true
        message = nil
        defer { writing = false }
        let rows = (try? await Salesforce.fullList(object: v.object, key: v.id)) ?? []
        let sample = rows.prefix(60).map { $0.subtitle.isEmpty ? $0.name : $0.subtitle }.joined(separator: "\n")
        var client = ClaudeClient(apiKey: key) // Opus
        client.effort = "medium"
        let system = """
        You write cold call scripts for Clarity Consulting, a boutique Salesforce partner and Anthropic Claude partner.
        What Clarity sells: Claude implementations. Flagship: an AI notetaker plus Claude updating CRM fields after
        every call, so reps stop doing data entry and managers get clean pipeline data. Also Claude and AI health checks,
        and Salesforce implementation, cleanup and automation.
        How Clarity talks: outcome first (time back, more selling time, cleaner data, more revenue), then the problem,
        then the fix. Technology last. Plain English, short lines a rep can say out loud, warm and confident, no jargon,
        no hype, no em dashes. The goal of every call is a 20 minute meeting with Oliver, Clarity's managing partner.
        """
        let user = """
        Write a cold call script for this segment.
        Segment: \(name.isEmpty ? v.label : name)
        Salesforce list: \(v.label) (\(rows.count) people)
        Titles and companies of people on the list:
        \(sample.isEmpty ? "(not available)" : sample)

        Use what the list tells you about their roles and industry. Sections, each short:
        OPENER (one line, honest that it's a cold call), REASON FOR THE CALL (a problem their peers have, ending in a
        question), 3 DISCOVERY QUESTIONS, VALUE (one sentence), OBJECTIONS (5 common ones for this segment with a short
        answer each, including "we're all good": offer a free 20 minute health check), CLOSE (offer two specific times),
        VOICEMAIL (about 20 seconds). Plain text, no markdown tables.
        """
        do {
            var text = ""
            try await client.stream(system: system, user: user) { text = $0 }
            script = text.trimmed
            if name.trimmed.isEmpty { name = v.label }
        } catch {
            message = "Couldn't write the script: \(error.localizedDescription)"
        }
    }
}
