import AppKit
import SwiftUI

/// Edit a campaign: name, goal, paste a script, let Claude sort it into sections, fine-tune.
struct CampaignEditorView: View {
    @EnvironmentObject var store: CampaignStore
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var draft = Campaign()
    @State private var organizing = false
    @State private var message: String?
    @State private var showSections = false
    /// Salesforce list views to pick this campaign's audience from.
    @State private var listViews: [Salesforce.ListView] = []
    @State private var listError: String?
    @State private var loadingLists = false
    @State private var writing = false
    /// The script being written, so Stop can cancel it.
    @State private var writeTask: Task<Void, Never>?
    @State private var filling = false
    @State private var writeStart = Date()
    @State private var thought = ""

    private var isNew: Bool { !store.campaigns.contains { $0.id == draft.id } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    basics
                    script
                    // No "Sections" boxes and no "Tidy up" button: the My script card on the coach
                    // already shows the script as one page, by section.
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 640)
        .onAppear(perform: load)
        .onDisappear { writeTask?.cancel() } // closing the window stops the writing
        .onChange(of: store.editing?.id) { load() }
    }

    private func load() {
        draft = store.editing ?? Campaign()
        message = nil
        showSections = !draft.opening.isEmpty || !draft.objections.isEmpty
        keepWindowsOnTop()
    }

    // MARK: 1. Basics

    private var basics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New call list" : "Edit call list").font(.title2.weight(.semibold))
            field("Name", text: $draft.name, placeholder: "e.g. Tax firm owners")
            field("Goal of these calls", text: $draft.objective,
                  placeholder: "e.g. Book a 30 minute meeting, or transfer to Mason")
            listPicker
        }
    }

    /// Who this campaign calls: a Salesforce list view. Picking the campaign opens this list.
    private var listPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Who to call (a Salesforce list)").font(.headline)
            if !Salesforce.isConnected {
                Text("Sign in to Salesforce first: click the gear, then Set up. Then pick the list here.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if loadingLists && listViews.isEmpty {
                ProgressView().controlSize(.small)
            } else if let listError, listViews.isEmpty {
                HStack(spacing: 8) {
                    Text(listError).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button("Try again") { Task { await loadLists() } }
                }
            } else {
                Picker("", selection: Binding(
                    get: { draft.listViewID },
                    set: { id in
                        if let v = listViews.first(where: { $0.id == id }) {
                            draft.listViewID = v.id; draft.listObject = v.object; draft.listName = v.label
                        } else {
                            draft.listViewID = ""; draft.listObject = ""; draft.listName = ""
                        }
                    }
                )) {
                    Text("None (use the list open in Chrome)").tag("")
                    ForEach(listViews) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                Text("When you pick this call list, these people open in Chrome. The app calls everyone who is due today.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { if listViews.isEmpty { await loadLists() } }
    }

    private func loadLists() async {
        guard Salesforce.isConnected else { return }
        loadingLists = true
        defer { loadingLists = false }
        do {
            listViews = try await Salesforce.listViews()
            listError = listViews.isEmpty ? "No Lead or Contact lists found in Salesforce." : nil
        } catch {
            listError = "Couldn't load your Salesforce lists: \(error.localizedDescription)"
        }
    }

    // MARK: 2. Script

    private var script: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Who are these people?").font(.headline)
                Spacer()
                if filling { ProgressView().controlSize(.small) }
                Button("Fill from Salesforce") { Task { await fillFromSalesforce() } }
                    .disabled(draft.listViewID.isEmpty || filling || writing)
                    .help("Reads the titles, levels, industries, company sizes and states of the people on this call list's Salesforce list.")
            }
            Text("This fills in by itself when you pick a list. Add what keeps them up at night and what they want, then click Generate script.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            box($draft.persona, height: 110, placeholder: ScriptWriter.describeHint)
                // A list picked and the box still empty: describe the list's people right away.
                .onChange(of: draft.listViewID) { _, _ in Task { await fillFromSalesforce(auto: true) } }
            HStack(spacing: 8) {
                Button {
                    writeTask = Task { await write() }
                } label: {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Label(writing ? ScriptWriter.progress(draft.pastedScript, since: writeStart, now: context.date) : "Generate script",
                              systemImage: "sparkles")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(BrandPrimaryButton())
                .disabled(writing || draft.persona.trimmed.isEmpty)
                .help("Claude writes the whole script for these people. Takes about 1 to 2 minutes. It replaces the script below.")
                if writing {
                    Button("Stop") { writeTask?.cancel() }
                        .controlSize(.large)
                        .help("Stop writing. Your script goes back to how it was.")
                }
            }
            if writing, !thought.isEmpty {
                Text(ScriptWriter.lastThought(thought))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("Your script").font(.headline)
            Text("Claude writes this for you. You can also paste your own, in any format.")
                .font(.callout).foregroundStyle(.secondary)
            box($draft.pastedScript, height: 200, placeholder: "Paste your script here...")
                .disabled(writing)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 3. Sections

    private var sections: some View {
        DisclosureGroup(isExpanded: $showSections) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Campaign.sections.indices, id: \.self) { index in
                    let section = Campaign.sections[index]
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title).font(.callout.weight(.semibold))
                        Text(section.hint).font(.caption).foregroundStyle(.secondary)
                        box(binding(section.key), height: 70, placeholder: "")
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sections").font(.headline)
                Text("You can skip this. Change any part of the script here.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if !isNew && store.campaigns.count > 1 {
                Button("Delete", role: .destructive) {
                    store.delete(draft)
                    dismissWindow(id: "campaign-editor")
                }
            }
            Spacer()
            Button("Cancel") { dismissWindow(id: "campaign-editor") }
                .keyboardShortcut(.cancelAction)
            Button("Save and use") {
                if draft.name.trimmed.isEmpty { draft.name = "Untitled call list" }
                store.save(draft)
                store.selectedID = draft.id
                dismissWindow(id: "campaign-editor")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: Claude writes the script

    /// Describes the people on this call list's Salesforce list. `auto`: only when the box is empty.
    private func fillFromSalesforce(auto: Bool = false) async {
        guard !draft.listViewID.isEmpty else {
            if !auto { message = "Pick a Salesforce list first." }
            return
        }
        if auto, !draft.persona.trimmed.isEmpty { return }
        filling = true
        defer { filling = false }
        do {
            let text = try await ListProfile.describe(object: draft.listObject, viewID: draft.listViewID)
            draft.persona = draft.persona.trimmed.isEmpty ? text : draft.persona.trimmed + "\n\n" + text
            // A list was just picked and there's no script yet: write it right away. Stop is right there.
            if auto, draft.pastedScript.trimmed.isEmpty, !writing, Keychain.read(.anthropic) != nil {
                message = "Filled from Salesforce. Writing the script now. Click Stop to change something first."
                writeTask = Task { await write() }
            } else {
                message = "Filled from Salesforce. Add what keeps them up at night, then click Generate script."
            }
        } catch {
            message = "Couldn't read the list: \(error.localizedDescription)"
        }
    }

    private func write() async {
        writing = true
        writeStart = Date()
        thought = ""
        message = nil
        defer { writing = false }
        let list = listViews.first { $0.id == draft.listViewID }
        let before = draft.pastedScript
        do {
            draft.pastedScript = ""
            draft.pastedScript = try await ScriptWriter.write(segment: draft.name.trimmed, audience: draft.persona,
                                                              list: list, onText: { partial in
                Task { @MainActor in if writing { draft.pastedScript = partial } }
            }, onThinking: { partial in
                Task { @MainActor in if writing { thought = partial } }
            })
            message = "Done. Read it over, then click Save and use."
        } catch {
            if Task.isCancelled {
                writing = false // late updates from Claude are dropped
                draft.pastedScript = before
                message = "Stopped. Your script is back the way it was."
            } else {
                message = "Couldn't write the script: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Claude sorts the script

    private func organize() async {
        guard let key = Keychain.read(.anthropic) else {
            message = "Add your Anthropic key first (gear menu > Setup > AI keys)."
            return
        }
        organizing = true
        message = nil
        defer { organizing = false }
        do {
            let result = try await CampaignOrganizer.organize(script: draft.pastedScript, apiKey: key)
            var filled = 0
            for section in Campaign.sections {
                if let value = result[section.json]?.trimmed, !value.isEmpty {
                    draft[keyPath: section.key] = value
                    filled += 1
                }
            }
            if draft.objective.trimmed.isEmpty, let goal = result["objective"]?.trimmed { draft.objective = goal }
            if ["New call list", "New call segment", "New segment", "New campaign"].contains(draft.name) || draft.name.trimmed.isEmpty, let name = result["name"]?.trimmed, !name.isEmpty {
                draft.name = name
            }
            showSections = true
            message = "Done. Filled \(filled) sections. Read them over, change anything, then Save."
        } catch {
            message = "Couldn't sort the script: \(error.localizedDescription)"
        }
    }

    // MARK: Small pieces

    private func binding(_ key: WritableKeyPath<Campaign, String>) -> Binding<String> {
        Binding(get: { draft[keyPath: key] }, set: { draft[keyPath: key] = $0 })
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.semibold))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func box(_ text: Binding<String>, height: CGFloat, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
            if text.wrappedValue.isEmpty && !placeholder.isEmpty {
                Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: height)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }
}

/// One Claude call that splits a pasted script into the campaign sections.
enum CampaignOrganizer {
    static func organize(script: String, apiKey: String) async throws -> [String: String] {
        let keys = ["name", "objective"] + Campaign.sections.map { $0.json }
        let system = """
        You turn a sales rep's cold calling script into organized sections for a live call coach.
        Use the script's own words where you can. Keep each section short and practical.
        Leave a section as an empty string if the script doesn't cover it. Never invent facts, prices or results.
        "objective" is the goal of the call in one sentence. "name" is a short campaign name.
        "objections" lists each objection with its approved answer, one per line.
        Return only a JSON object with exactly these string keys: \(keys.joined(separator: ", ")).
        """
        var client = ClaudeClient(apiKey: apiKey)
        client.effort = "medium"
        client.totalTimeout = 180
        return try await client.json(system: system, user: "Script:\n\n\(script)").compactMapValues { $0 as? String }
    }
}

/// Keeps every app window above Salesforce.
@MainActor
func keepWindowsOnTop() {
    DispatchQueue.main.async {
        for window in NSApplication.shared.windows {
            window.level = .floating
            // Navy title bar that blends into the navy window.
            window.titlebarAppearsTransparent = true
            window.backgroundColor = Brand.navyNS
            window.collectionBehavior.insert(.canJoinAllSpaces)
        }
    }
}
