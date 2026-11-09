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
    @State private var loadingLists = false

    @State private var listSearch = ""

    private var isNew: Bool { !store.campaigns.contains { $0.id == draft.id } }

    /// Lists matching the search box, best match first. No search = all lists in Salesforce's order.
    private var filteredLists: [Salesforce.ListView] {
        let q = listSearch.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return listViews }
        return listViews
            .compactMap { v in FuzzyMatch.score(query: q, in: v.title).map { (v, $0) } }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    private func pickList(_ v: Salesforce.ListView?) {
        draft.listViewID = v?.id ?? ""
        draft.listObject = v?.object ?? ""
        draft.listName = v?.label ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    basics
                    script
                    sections
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 640)
        .onAppear(perform: load)
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
            Text(isNew ? "New campaign" : "Edit campaign").font(.title2.weight(.semibold))
            field("Campaign name", text: $draft.name, placeholder: "e.g. Q4 RevOps outreach")
            field("Goal of these calls", text: $draft.objective,
                  placeholder: "e.g. Book a 30 minute meeting, or transfer to Mason")
            listPicker
        }
    }

    /// Who this campaign calls: a Salesforce list view. Picking the campaign opens this list.
    private var listPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Salesforce list to call").font(.headline)
            if !Salesforce.isConnected {
                Text("Sign in to Salesforce first (gear > Setup > Salesforce), then pick the list here.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if loadingLists && listViews.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                if !draft.listViewID.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(draft.listName).fontWeight(.medium)
                        Spacer()
                        Button("Clear") { pickList(nil) }.buttonStyle(.link)
                    }
                }
                TextField("Search your lists (typos are ok)", text: $listSearch)
                    .textFieldStyle(.roundedBorder)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredLists) { v in
                            Button { pickList(v) } label: {
                                HStack {
                                    Text(v.title)
                                    Spacer()
                                    if v.id == draft.listViewID { Image(systemName: "checkmark") }
                                }
                                .padding(.vertical, 5).padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(v.id == draft.listViewID ? Color.accentColor.opacity(0.15) : .clear)
                        }
                        if filteredLists.isEmpty {
                            Text("No lists match \"\(listSearch)\"")
                                .font(.callout).foregroundStyle(.secondary).padding(8)
                        }
                    }
                }
                .frame(height: 160)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("Picking this campaign opens this list in Chrome and calls everyone on it who's due today.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            guard Salesforce.isConnected, listViews.isEmpty else { return }
            loadingLists = true
            listViews = (try? await Salesforce.listViews()) ?? []
            loadingLists = false
        }
    }

    // MARK: 2. Script

    private var script: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your script").font(.headline)
            Text("Paste your cold call script. Any format works: bullets, paragraphs, a Google Doc copy.")
                .font(.callout).foregroundStyle(.secondary)
            box($draft.pastedScript, height: 200, placeholder: "Paste your script here...")
            HStack(spacing: 10) {
                Button {
                    Task { await organize() }
                } label: {
                    Label("Sort it into sections for me", systemImage: "sparkles")
                }
                .disabled(draft.pastedScript.trimmed.isEmpty || organizing)
                if organizing {
                    ProgressView().controlSize(.small)
                    Text("Claude is reading your script...").font(.callout).foregroundStyle(.secondary)
                }
            }
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
                Text("Optional. Fine-tune what the coach follows.").font(.callout).foregroundStyle(.secondary)
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
                if draft.name.trimmed.isEmpty { draft.name = "Untitled campaign" }
                store.save(draft)
                store.selectedID = draft.id
                dismissWindow(id: "campaign-editor")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
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
            if draft.name == "New campaign" || draft.name.trimmed.isEmpty, let name = result["name"]?.trimmed, !name.isEmpty {
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
        var text = ""
        var client = ClaudeClient(apiKey: apiKey)
        client.effort = "medium"
        try await client.stream(system: system, user: "Script:\n\n\(script)") { text = $0 }

        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let json = try JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else {
            throw ClaudeClient.APIError(message: "Claude's answer wasn't in the expected format. Try again.")
        }
        return json.compactMapValues { $0 as? String }
    }
}

/// Keeps every app window above Salesforce.
@MainActor
func keepWindowsOnTop() {
    DispatchQueue.main.async {
        for window in NSApplication.shared.windows {
            window.level = .floating
            window.collectionBehavior.insert(.canJoinAllSpaces)
        }
    }
}
