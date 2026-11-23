import AppKit
import SwiftUI

/// The one screen: who, what to say, and one primary action.
struct DialerView: View {
    @Environment(Store.self) private var store
    @Environment(Updater.self) private var updater
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    @State private var lists: [Salesforce.ListView] = []
    @State private var listError: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TopBar(lists: lists, listError: listError, reloadLists: loadLists)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let m = updater.message {
                            Label(m, systemImage: "arrow.down.circle").foregroundStyle(.secondary).font(.callout)
                        }
                        if let m = session.linkedInStatus {
                            Label(m, systemImage: "person.badge.plus").foregroundStyle(.secondary).font(.callout)
                        }
                        if let m = session.message {
                            Label(m, systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange).font(.callout)
                        }
                        content
                    }
                    .padding(20)
                }
                if session.lastLogged != nil {
                    Divider()
                    LastCallBar()
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Brand.navy)
                }
                Divider()
                ActionBar()
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(Brand.navy)
                Divider()
                OutboundPanel()
                    .background(Brand.navy)
            }
            .frame(minWidth: 560)
            Divider()
            AircallPane(width: 360)
        }
        .task { await loadLists() }
    }

    @ViewBuilder private var content: some View {
        switch session.state {
        case .idle:
            Empty(title: "Pick a list to start", text: "Choose a Salesforce list view at the top. Connect Salesforce and Aircall in Settings (⌘,) first.")
        case .loading:
            ProgressView("Loading list…").frame(maxWidth: .infinity, minHeight: 200)
        case .finished:
            Empty(title: "List done", text: "Nobody left to call right now. \(session.skipped.count) skipped (see below).")
            SkippedList()
        default:
            if let lead = session.lead {
                LeadCard(lead: lead)
                TodayCard(lead: lead)
                ScriptCard(lead: lead)
            }
        }
    }

    private func loadLists() async {
        guard Salesforce.isConnected else { listError = "Connect Salesforce in Settings."; return }
        do { lists = try await Salesforce.listViews(); listError = nil } catch { listError = error.localizedDescription }
        // Pick up where you left off: reopen the last list.
        if session.list == nil, session.state == .idle, let last = Session.lastList {
            await session.load(last)
        }
    }
}

private struct TopBar: View {
    @Environment(Store.self) private var store
    @Environment(Updater.self) private var updater
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    let lists: [Salesforce.ListView]
    let listError: String?
    let reloadLists: () async -> Void

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(lists) { v in Button(v.title) { Task { await session.load(v) } } }
                Divider()
                Button("Refresh lists") { Task { await reloadLists() } }
            } label: {
                Text(session.list?.title ?? "Choose a list").font(.headline).lineLimit(1).truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 280, alignment: .leading)
            .layoutPriority(1)

            if session.list != nil, session.state != .loading {
                Text("\(min(session.index + 1, session.queue.count)) of \(session.queue.count)")
                    .foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
                Button { if let v = session.list { Task { await session.load(v) } } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload list")
            }
            if let listError { Text(listError).font(.caption).foregroundStyle(.orange).lineLimit(1) }
            Spacer(minLength: 8)
            // Narrow window: drop words before anything wraps. Every variant is one line.
            ViewThatFits(in: .horizontal) {
                trailing(labels: true, stats: .full)
                trailing(labels: false, stats: .full)
                trailing(labels: false, stats: .compact)
                trailing(labels: false, stats: .hidden)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
}

extension TopBar {
    /// Pause, Update and today's numbers, at one of several widths.
    @ViewBuilder
    func trailing(labels: Bool, stats: TodayStrip.Style) -> some View {
        HStack(spacing: 10) {
            if updater.updating {
                ProgressView().controlSize(.small)
                if labels { Text("Updating…").font(.caption).foregroundStyle(.secondary) }
            } else if updater.available {
                Button { updater.update() } label: {
                    if labels { Label("Update", systemImage: "arrow.down.circle.fill") } else { Image(systemName: "arrow.down.circle.fill") }
                }
                .buttonStyle(BrandPrimaryButton())
                .help("A new build is ready. Installs it and reopens the app (1–3 minutes).")
            }
            if stats != .hidden {
                TodayStrip(style: stats).onTapGesture { openWindow(id: "metrics") }.help("Today. Click for Metrics (⇧⌘M)")
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Today's numbers, always visible.
struct TodayStrip: View {
    enum Style { case full, compact, hidden }
    @Environment(Store.self) private var store
    var style: Style = .full

    var body: some View {
        let s = Metrics.summary(store.attempts.filter { Period.today.contains($0.dialedAt) })
        HStack(spacing: style == .full ? 14 : 10) {
            if style == .full {
                stat("\(s.dials)", "dials")
                stat("\(s.connects)", "connects · \(s.connectRate.percent)")
                stat("\(s.meetings)", "meetings")
                stat(s.talkSeconds.duration, "talk")
            } else {
                stat("\(s.dials)", "dials")
                stat("\(s.connects)", "conn")
                stat("\(s.meetings)", "mtg")
            }
        }
        .font(.callout)
        .lineLimit(1)
        .fixedSize()
    }

    private func stat(_ v: String, _ l: String) -> some View {
        HStack(spacing: 4) { Text(v).bold().monospacedDigit(); Text(l).foregroundStyle(.secondary) }
    }
}

private struct LeadCard: View {
    @Environment(Store.self) private var store
    @Environment(Session.self) private var session
    let lead: Lead

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(lead.name).font(.system(size: 26, weight: .semibold))
                    Spacer()
                    if let url = Salesforce.recordURL(lead.id) {
                        Link(destination: url) { Label("Salesforce", systemImage: "arrow.up.right.square") }
                    }
                }
                Text([lead.title, lead.company].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.title3).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    if let n = lead.dialNumber {
                        Label(n + (lead.mobile.nonBlank != nil ? "  mobile" : ""), systemImage: "phone").monospacedDigit()
                    }
                    if let z = lead.zone { Label("\(z.timeString(at: Date())) \(z.label)", systemImage: "clock") }
                    if !lead.status.isEmpty { Label(lead.status, systemImage: "tag") }
                }
                .font(.callout).foregroundStyle(.secondary)
                Text(lastTouch).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// "Last contacted 2 days ago (Voicemail)"
    private var lastTouch: String {
        let today = Calendar.current.startOfDay(for: Date())
        let before = session.history.dates(lead.id).filter { $0 < today }.sorted()
        guard let last = before.last else { return "Never contacted" }
        let outcome = store.attempts(for: lead.id).last(where: { $0.isLogged && $0.dialedAt < today })?.outcome?.label
        return "Last contacted \(last.formatted(.relative(presentation: .named)))" + (outcome.map { " (\($0))" } ?? "")
    }
}

/// Where this person is in the sequence: done (green), current (blue), upcoming (grey).
private struct TodayCard: View {
    @Environment(Store.self) private var store
    @Environment(Session.self) private var session
    let lead: Lead

    private static let done = Color(red: 0.30, green: 0.62, blue: 0.42)

    var body: some View {
        let steps = store.settings.cadence.steps
        if let current = session.todayStep(for: lead), steps.indices.contains(current) {
            let overdue: Int = { if case .due(_, let d) = session.plan(for: lead) { return d } else { return 0 } }()
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("OUTREACH SEQUENCE").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if overdue > 0 {
                            Text("\(overdue) day\(overdue == 1 ? "" : "s") overdue").font(.caption).foregroundStyle(Brand.stop)
                        }
                    }
                    track(steps, current: current)
                }
            }
        }
    }

    private func track(_ steps: [Step], current: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                VStack(spacing: 6) {
                    node(i, current: current)
                    Text("Day \(step.day)").font(.callout.weight(i == current ? .bold : .regular))
                        .foregroundStyle(i == current ? .primary : .secondary)
                    Text(i < current ? "Done" : i == current ? "Current" : "Upcoming")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize()
                if i < steps.count - 1 {
                    Rectangle().fill(i < current ? Self.done : Color.secondary.opacity(0.3))
                        .frame(height: 3).frame(maxWidth: .infinity)
                        .padding(.top, 13)
                }
            }
        }
    }

    private func node(_ i: Int, current: Int) -> some View {
        ZStack {
            if i < current {
                Circle().fill(Self.done)
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            } else if i == current {
                Circle().fill(Brand.blue)
                Text("\(i + 1)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            } else {
                Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 2)
                Text("\(i + 1)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var profileURL: URL {
        if let raw = lead.linkedIn?.trimmed, raw.lowercased().contains("linkedin.com") {
            let s = raw.hasPrefix("http") ? raw : "https://" + raw
            if let u = URL(string: s) { return u }
        }
        var c = URLComponents(string: "https://www.linkedin.com/search/results/people/")!
        c.queryItems = [URLQueryItem(name: "keywords", value: "\(lead.name) \(lead.company)")]
        return c.url!
    }
}

/// The script. Click it to edit; Save shares it with everyone using it.
private struct ScriptCard: View {
    @Environment(Store.self) private var store
    @Environment(ScriptSync.self) private var sync
    let lead: Lead
    @State private var editing = false
    @State private var name = ""
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Card(script: true) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if editing { editor } else { reading }
            }
        }
        .onChange(of: store.script?.id) { _, _ in editing = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(store.scripts) { s in
                    Button(s.name) { store.selectedScriptID = s.id }
                }
                Divider()
                Button("New script") {
                    var s = Script(name: "New script", body: "")
                    s.updatedAt = Date()
                    store.scripts.append(s)
                    store.selectedScriptID = s.id
                    startEditing()
                }
            } label: {
                Text(store.script?.name.uppercased() ?? "SCRIPT").font(.caption.weight(.semibold))
            }
            .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
            if store.script?.needsPublish == true {
                Label("Not shared yet", systemImage: "icloud.slash").font(.caption).foregroundStyle(.orange)
                    .help(sync.status)
            } else if store.script?.sharedDocID != nil {
                Label("Shared with team", systemImage: "person.2").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if !editing {
                Button { startEditing() } label: { Label("Edit", systemImage: "pencil") }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
    }

    private var reading: some View {
        Text(LocalizedStringKey(store.script?.render(for: lead, rep: store.settings.repName) ?? "Click to add a script."))
            .font(.system(size: 17)).lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { startEditing() }
            .help("Click to edit")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Script name", text: $name).textFieldStyle(.roundedBorder).font(.headline)
            TextEditor(text: $draft)
                .font(.system(size: 16)).lineSpacing(4)
                .frame(minHeight: 320)
                .focused($focused)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Text("Merge fields: " + Merge.fields.map { "{{\($0)}}" }.joined(separator: " ") + " · **bold** works")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                Button("Save & share") { save() }
                    .buttonStyle(BrandPrimaryButton())
                    .keyboardShortcut("s", modifiers: .command)
                    .help("⌘S. Saves and updates this script for everyone who uses it.")
            }
        }
    }

    private func startEditing() {
        guard let s = store.script else { return }
        name = s.name
        draft = s.body
        editing = true
        focused = true
    }

    private func save() {
        if let id = store.script?.id { sync.save(id, name: name, body: draft) }
        editing = false
    }
}

private struct SkippedList: View {
    @Environment(Session.self) private var session
    var body: some View {
        let groups = Dictionary(grouping: session.skipped, by: \.reason.label).sorted { $0.value.count > $1.value.count }
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("SKIPPED").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(groups, id: \.key) { g in
                    HStack { Text(g.key); Spacer(); Text("\(g.value.count)").monospacedDigit().foregroundStyle(.secondary) }
                }
                if groups.isEmpty { Text("None").foregroundStyle(.secondary) }
            }
        }
    }
}

private struct Empty: View {
    let title: String, text: String
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.title2.weight(.semibold))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

/// The bottom bar. Changes with the call state; ⏎ is always the next sensible step.
private struct ActionBar: View {
    @Environment(Store.self) private var store
    @Environment(Session.self) private var session

    var body: some View {
        HStack(spacing: 10) {
            switch session.state {
            case .ready:
                if store.settings.autoDial {
                    primary("Start auto-dialing", "play.fill") { session.startAutoDialing() }
                        .help("Calls this person now, then each next one after a \(store.settings.countdown)s countdown. ⌘P stops.")
                } else {
                    primary("Call", "phone.fill") { session.call() }
                }
                Button("Next") { session.skip() }.keyboardShortcut(.rightArrow, modifiers: .command).buttonStyle(BrandQuietButton())
                Button("Back") { session.back() }.keyboardShortcut(.leftArrow, modifiers: .command).disabled(session.index == 0).buttonStyle(BrandQuietButton())
            case .countdown(let n):
                Text("Calling in \(n)…").font(.headline).monospacedDigit()
                primary("Call now", "phone.fill") { session.call() }
                Button("Next") { session.skip() }.keyboardShortcut(.rightArrow, modifiers: .command).buttonStyle(BrandQuietButton())
            case .dialing, .live:
                CallClock(since: session.attempt?.answeredAt ?? session.attempt?.dialedAt, live: session.state == .live)
                Spacer()
                if store.settings.voicemailDrop, let vm = session.currentStep?.voicemail {
                    Button { session.dropVoicemail() } label: {
                        Label(session.attempt?.voicemailDropped == true ? "\(vm) dropped" : "Drop \(vm)", systemImage: "recordingtape")
                    }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(session.attempt?.voicemailDropped == true)
                }
                Button(role: .destructive) { session.hangUp() } label: { Label("Hang up", systemImage: "phone.down.fill") }
                    .keyboardShortcut(".", modifiers: .command)
                    .buttonStyle(BrandPrimaryButton(color: Brand.stop)).controlSize(.large)
            default:
                EmptyView()
            }
            if store.settings.autoDial, !session.paused, session.state != .ready {
                Button { session.stopAutoDialing() } label: { Label("Stop auto-dialing", systemImage: "stop.fill") }
                    .buttonStyle(BrandQuietButton())
                    .keyboardShortcut("p", modifiers: .command)
                    .help("⌘P. The current call finishes, then it stays on the next person.")
            }
            if !isCall { Spacer() }
        }
    }

    private var isCall: Bool { session.state == .dialing || session.state == .live }

    private func primary(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).frame(minWidth: 110) }
            .buttonStyle(BrandPrimaryButton()).controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }
}

private struct CallClock: View {
    let since: Date?
    let live: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let secs = Int(ctx.date.timeIntervalSince(since ?? ctx.date))
            HStack(spacing: 8) {
                Circle().fill(live ? .green : .orange).frame(width: 9, height: 9)
                Text(live ? "Live" : "Ringing").font(.headline)
                Text(String(format: "%d:%02d", secs / 60, secs % 60)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}


/// Icon and title with a small gap (the default label spacing is wide for chips).
private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.imageScale(.small); configuration.title }
    }
}

/// The last call, logged automatically. Change its outcome or add a note without stopping.
private struct LastCallBar: View {
    @Environment(Session.self) private var session
    @State private var note = ""

    var body: some View {
        if let a = session.lastLogged {
            HStack(spacing: 10) {
                Text("Last call").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(a.leadName).font(.callout).lineLimit(1)
                Menu {
                    ForEach(Outcome.allCases) { o in
                        Button(o.label) { session.amend(outcome: o) }
                    }
                } label: {
                    Text(a.outcome?.label ?? "-").font(.callout.weight(.medium))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Change the outcome (updates Salesforce)")
                TextField("Add a note", text: $note)
                    .textFieldStyle(.roundedBorder).font(.callout)
                    .onSubmit { session.amend(note: note) }
                if a.statusAfter != nil {
                    Label(a.statusAfter!, systemImage: "arrow.up.right").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .onChange(of: session.lastLoggedID) { _, _ in note = "" }
            .onAppear { note = a.note }
        }
    }
}
