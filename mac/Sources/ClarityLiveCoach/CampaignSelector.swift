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
    @State private var writeStart = Date()
    @State private var thought = ""
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
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Label(writing ? ScriptWriter.progress(script, since: writeStart, now: context.date) : "Generate script",
                              systemImage: "sparkles")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(BrandPrimaryButton())
                .disabled(audience.trimmed.isEmpty || writing || Keychain.read(.anthropic) == nil)
                .help("Claude writes a full cold call script for this call segment, built on Clarity's cold call backbone. Takes 2 to 5 minutes.")
                if writing, !thought.isEmpty {
                    Text(ScriptWriter.lastThought(thought))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("4. Script").font(.headline)
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
        writeStart = Date()
        thought = ""
        message = nil
        defer { writing = false }
        do {
            script = ""
            let text = try await ScriptWriter.write(segment: name.trimmed.isEmpty ? (view?.label ?? "") : name.trimmed,
                                                    audience: audience, list: view, onText: { partial in
                Task { @MainActor in if writing { script = partial } }
            }, onThinking: { partial in
                Task { @MainActor in if writing { thought = partial } }
            })
            script = text
            if name.trimmed.isEmpty, let v = view { name = v.label }
        } catch {
            message = "Couldn't write the script: \(error.localizedDescription)"
        }
    }
}

/// Writes a cold call script for one call segment on the `ScriptSkeleton`. The rep's description
/// leads; titles and companies from the Salesforce list are only a backup hint. Used by New Campaign
/// and Edit Campaign.
enum ScriptWriter {
    /// What to put in the "Describe this call segment" box.
    static let describeHint = "e.g. Owners of 5 to 20 person CPA firms in Portland. Swamped Jan to April. Every client call ends with someone typing notes. They want to grow without hiring, and worry about mistakes and burnout. Most started solo and built the firm on referrals."

    /// The Generate button while it runs. Claude thinks through the segment before the first word
    /// (often 1 to 3 minutes), so the seconds show it's still working.
    static func progress(_ script: String, since start: Date, now: Date = Date()) -> String {
        let words = script.split(separator: " ").count
        let s = max(0, Int(now.timeIntervalSince(start)))
        let time = s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
        return words == 0 ? "Thinking through this segment... \(time)" : "Writing... \(words) words · \(time)"
    }

    /// The last line of Claude's thinking summary, short enough for one line under the button.
    static func lastThought(_ thinking: String) -> String {
        let lines = thinking.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*#")) }
            .filter { !$0.isEmpty }
        return String((lines.last ?? "").prefix(140))
    }

    static func write(segment: String, audience: String, list: Salesforce.ListView?,
                      onText: @escaping (String) -> Void,
                      onThinking: ((String) -> Void)? = nil) async throws -> String {
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
        client.totalTimeout = 420 // high effort can think for several minutes first
        client.thinking = ["type": "adaptive", "display": "summarized"] // so the rep sees it working
        let year = Calendar.current.component(.year, from: Date())
        let system = """
        You are a world-class cold call script writer, using the best \(year) cold calling techniques, openers
        and talk tracks. You write for Clarity Consulting, a boutique Salesforce partner and Anthropic Claude
        partner in Portland, Oregon. A live call coach app reads your script during the call: it tracks state,
        walks the pick order, matches what the prospect says to a row's "Sounds like", and shows that row's "Say"
        line word for word. So the script must be complete and follow the skeleton below exactly.

        Every call segment is different. A tax firm, a law firm, a sales team and a manufacturer have different
        pains, words, busy seasons, tools, goals and brush-offs, so the reason, the question, discovery, the
        objections, voicemails, texts and LinkedIn notes are all written fresh for this segment. Never reuse a
        generic pitch. Before writing, think hard about this segment from the rep's description: their top pains
        in their own words, what they want this year, what they're proud of and afraid of, their day and busy
        seasons, what makes them look for help, who else they answer to, the tools they use, and the brush-offs
        they give every cold caller.

        The one thing that's the same for every segment: the ask is a free 45 minute health check with Oliver,
        our managing partner. Pick the kind that fits this segment's problem: a CRM health check (data, pipeline,
        Salesforce or another CRM) or an AI health check (hours lost to manual work, AI use). Use that name
        everywhere the skeleton says [CRM or AI].

        How great cold calls work in \(year):
        - Opener: honest and calm. Say it's a cold call or give the reason right away, then ask for 30 seconds.
          Never "how are you", never "did I catch you at a bad time".
        - Reason: one problem people like them have, in their words, framed as what peers deal with. Not the product.
        - The question: one question that sorts them into 2 to 4 tracks, so discovery fits where they are.
        - Discovery: one short question at a time, branching on their answer. Get the task or problem, who it hits
          and what it costs, in their words. At most 3 questions before playing it back.
        - Play it back in their words and get a yes before asking for the meeting.
        - Objections: a few words of agreement, then one curious question. Never argue. Respect a second firm no.
        - The ask: small, specific, low risk, with two real times.
        - Gatekeepers: sound expected, ask for help, never pitch them.
        - Voicemail under 20 seconds; texts and LinkedIn notes in the same voice, each a new angle.
        - Sound like a sharp, calm peer from their world. Short words, contractions, no jargon, no hype.

        Rules:
        - Follow the skeleton exactly: every section, in order, with the same titles and table columns
          separated by tabs. Copy the sections it says to copy. Replace every note in (parentheses) with real
          content for this segment. Use row IDs in the same style (G1, S1 open, S5 ns 1, Q1, O1, VM1, T1, L1).
        - Every Say line: 25 words at most, ends with a question unless it ends the call, plain spoken English
          a 5th grader could read, no em dashes. Outcome first (time back, more selling, less risk), then the
          problem, then the fix. Technology last.
        - Facts: only the FACTS section. Never invent a number, stat, client name, result, price or offer. If the
          rep's description gives a real proof point, you may use it exactly as written.
        - Use [slots] like [Name], [Firm], [SDR], [Day], [Time], [Number]. Use [Name] for the prospect, never he or she.
        - Return only the script as plain text. No markdown, no notes before or after.

        SKELETON:
        \(ScriptSkeleton.text)
        """
        let user = """
        Write the script for this call segment.
        Call segment: \(segment.isEmpty ? "Not named" : segment)
        The rep's description (this leads): \(audience.trimmed.isEmpty ? "Not given. Use the list below." : audience.trimmed)
        \(sample.isEmpty ? "" : "Titles and companies from the Salesforce list (a hint only; the description wins):\n\(sample)")
        """
        var text = ""
        try await client.stream(system: system, user: user, onText: { partial in
            text = partial
            onText(partial)
        }, onThinking: onThinking)
        return text.trimmed
    }
}
