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
        HSplitView {
            VStack(spacing: 0) {
                TopBar(lists: lists, listError: listError, reloadLists: loadLists)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let m = updater.message {
                            Label(m, systemImage: "arrow.down.circle").foregroundStyle(.secondary).font(.callout)
                        }
                        if session.paused {
                            Label("Auto-dial paused. Press ⌘P or Resume to keep going.", systemImage: "pause.circle")
                                .foregroundStyle(.secondary).font(.callout)
                        }
                        if let m = session.message {
                            Label(m, systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange).font(.callout)
                        }
                        content
                    }
                    .padding(20)
                }
                Divider()
                ActionBar()
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(.bar)
            }
            .frame(minWidth: 600)
            AircallPhoneView()
                .frame(minWidth: 340, idealWidth: 360, maxWidth: 420)
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
                Text(session.list?.title ?? "Choose a list").font(.headline)
            }
            .menuStyle(.borderlessButton).fixedSize()

            if session.list != nil, session.state != .loading {
                Text("\(min(session.index + 1, session.queue.count)) of \(session.queue.count)")
                    .foregroundStyle(.secondary).monospacedDigit()
                Button { if let v = session.list { Task { await session.load(v) } } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload list")
            }
            if let listError { Text(listError).font(.caption).foregroundStyle(.orange) }
            Spacer()
            if store.settings.autoDial, session.list != nil {
                Button { session.togglePause() } label: {
                    Label(session.paused ? "Resume auto-dial" : "Pause auto-dial",
                          systemImage: session.paused ? "play.fill" : "pause.fill")
                }
                .keyboardShortcut("p", modifiers: .command)
                .tint(session.paused ? .green : nil)
                .help("⌘P. Pausing lets the current call finish, then stops before the next dial.")
            }
            if updater.updating {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.caption).foregroundStyle(.secondary)
            } else if updater.available {
                Button { updater.update() } label: { Label("Update", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(.borderedProminent).tint(.blue)
                    .help("A new build was pushed. Installs it and reopens the app (1–3 minutes).")
            }
            TodayStrip().onTapGesture { openWindow(id: "metrics") }.help("Open Metrics (⇧⌘M)")
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
}

/// Today's numbers, always visible.
struct TodayStrip: View {
    @Environment(Store.self) private var store
    var body: some View {
        let s = Metrics.summary(store.attempts.filter { Period.today.contains($0.dialedAt) })
        HStack(spacing: 14) {
            stat("\(s.dials)", "dials")
            stat("\(s.connects)", "connects · \(s.connectRate.percent)")
            stat("\(s.meetings)", "meetings")
            stat(s.talkSeconds.duration, "talk")
        }
        .font(.callout)
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

/// Today's step of the sequence: what to do, and what's done.
private struct TodayCard: View {
    @Environment(Store.self) private var store
    @Environment(Session.self) private var session
    let lead: Lead

    var body: some View {
        let steps = store.settings.cadence.steps
        if let i = session.todayStep(for: lead), steps.indices.contains(i) {
            let step = steps[i]
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("DAY \(step.day) · STEP \(i + 1) OF \(steps.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if case .due(_, let late) = session.plan(for: lead), late > 0 {
                            Text("\(late) day\(late == 1 ? "" : "s") overdue").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    item("phone", "Call", done: session.attempt != nil || session.history.dates(lead.id).contains { Calendar.current.isDateInToday($0) })
                    item("arrow.up.right", "Status → \(step.status)", done: lead.status.caseInsensitiveCompare(step.status) == .orderedSame)
                    if let vm = step.voicemail { item("recordingtape", "If no answer: drop \(vm) (⌘D)", done: session.attempt?.voicemailDropped == true) }
                    else { item("recordingtape", "No voicemail today", done: false, muted: true) }
                    if step.text != nil {
                        item("message", lead.mobile.nonBlank == nil ? "Text: no mobile number" : "If no answer: text goes out automatically",
                             done: session.textSentToday(lead), muted: lead.mobile.nonBlank == nil)
                    }
                    if let note = step.linkedInNote { linkedIn(note) }
                }
            }
        }
    }

    private func item(_ icon: String, _ text: String, done: Bool, muted: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : icon)
                .foregroundStyle(done ? Color.green : Color.secondary).frame(width: 18)
            Text(text).foregroundStyle(muted ? .tertiary : .primary).strikethrough(done, color: .secondary)
        }
    }

    private func linkedIn(_ note: String) -> some View {
        let sent = session.linkedInSentToday(lead)
        return HStack(spacing: 8) {
            Image(systemName: sent ? "checkmark.circle.fill" : "person.badge.plus")
                .foregroundStyle(sent ? Color.green : Color.secondary).frame(width: 18)
            Text("LinkedIn request").strikethrough(sent, color: .secondary)
            Spacer()
            Button(sent ? "Open again" : "Copy note & open LinkedIn") {
                let body = Merge.fill(note, lead: lead, rep: store.settings.repName)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(body, forType: .string)
                NSWorkspace.shared.open(profileURL)
                session.markLinkedInSent()
            }
            .help("Copies the note, opens their profile. Click Connect, then Add a note, then paste (⌘V).")
        }
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

private struct ScriptCard: View {
    @Environment(Store.self) private var store
    let lead: Lead
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(store.script?.name.uppercased() ?? "SCRIPT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(LocalizedStringKey(store.script?.render(for: lead, rep: store.settings.repName) ?? "Add a script in Settings."))
                    .font(.system(size: 17)).lineSpacing(5).textSelection(.enabled)
            }
        }
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
    @State private var outcome: Outcome?
    @State private var note = ""
    @State private var status = ""

    var body: some View {
        HStack(spacing: 10) {
            switch session.state {
            case .ready:
                primary("Call", "phone.fill") { session.call() }
                Button("Skip") { session.skip() }.keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Back") { session.back() }.keyboardShortcut(.leftArrow, modifiers: .command).disabled(session.index == 0)
            case .countdown(let n):
                Text("Calling in \(n)…").font(.headline).monospacedDigit()
                primary("Call now", "phone.fill") { session.call() }
                Button("Pause") { session.togglePause() }.keyboardShortcut(.cancelAction)
                Button("Skip") { session.skip() }.keyboardShortcut(.rightArrow, modifiers: .command)
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
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            case .wrapUp:
                wrapUp
            default:
                EmptyView()
            }
            if !isCall { Spacer() }
        }
        .onChange(of: session.state) { _, s in
            if s == .wrapUp, let lead = session.lead {
                outcome = nil
                note = ""
                status = session.autoStatus(for: lead) ?? lead.status
            }
        }
    }

    private var isCall: Bool { session.state == .dialing || session.state == .live }

    private var wrapUp: some View {
        HStack(spacing: 10) {
            ForEach(Outcome.allCases) { o in
                Toggle(o.label, isOn: Binding(get: { outcome == o }, set: { if $0 { outcome = o } }))
                    .toggleStyle(.button)
                    .keyboardShortcut(KeyEquivalent(o.key), modifiers: .command)
                    .help("⌘\(o.key)")
            }
            TextField("Note", text: $note).textFieldStyle(.roundedBorder).frame(minWidth: 120)
                .onSubmit(logIt)
            if !session.statusOptions.isEmpty {
                Picker("Status", selection: $status) {
                    if !session.statusOptions.contains(status) { Text(status.isEmpty ? "-" : status).tag(status) }
                    ForEach(session.statusOptions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 150)
            }
            primary("Log & next", "checkmark") { logIt() }.disabled(outcome == nil)
        }
    }

    private func logIt() {
        guard let outcome else { return }
        session.log(outcome, note: note, status: status)
    }

    private func primary(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).frame(minWidth: 110) }
            .buttonStyle(.borderedProminent).controlSize(.large)
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
