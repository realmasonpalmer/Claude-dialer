import AppKit
import SwiftUI

/// Decides which screen to show: audio check (first run), keys (once), then the coach.
struct RootView: View {
    enum Screen { case check, keys, coach }

    @EnvironmentObject var proof: ProofModel
    @EnvironmentObject var coach: CoachModel
    @AppStorage("audioCheckPassed") private var audioCheckPassed = false
    @State private var screen: Screen?

    var body: some View {
        Group {
            switch screen ?? firstScreen {
            case .check:
                AudioCheckView(onFinish: {
                    audioCheckPassed = true
                    screen = hasKeys ? .coach : .keys
                })
                .onAppear { proof.onAppear() }
            case .keys:
                KeysView(onSave: { screen = .coach })
            case .coach:
                CoachView(
                    onAudioCheck: { proof.testAgain(); screen = .check },
                    onKeys: { screen = .keys }
                )
            }
        }
        .frame(width: 380)
    }

    private var hasKeys: Bool { Keychain.read(.deepgram) != nil && Keychain.read(.anthropic) != nil }
    private var firstScreen: Screen { !audioCheckPassed ? .check : (hasKeys ? .coach : .keys) }
}

// MARK: - Keys

struct KeysView: View {
    var onSave: () -> Void
    @State private var deepgram = Keychain.read(.deepgram) ?? ""
    @State private var anthropic = Keychain.read(.anthropic) ?? ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 6) {
                Text("Connect the coach").font(.title2.weight(.semibold))
                Text("Paste two keys, one time. They're stored safely in your Mac's Keychain.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            keyField(
                title: "Deepgram key",
                hint: "Turns the call into live text.",
                link: "https://console.deepgram.com",
                text: $deepgram
            )
            keyField(
                title: "Anthropic key",
                hint: "Lets Claude write your next line. Starts with sk-ant-",
                link: "https://console.anthropic.com/settings/keys",
                text: $anthropic
            )
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            Button("Save and continue") { save() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(deepgram.trimmed.isEmpty || anthropic.trimmed.isEmpty)
        }
        .padding(24)
    }

    private func keyField(title: String, hint: String, link: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Link("Get a key", destination: URL(string: link)!).font(.callout)
            }
            SecureField("Paste here", text: text)
                .textFieldStyle(.roundedBorder)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        guard anthropic.trimmed.hasPrefix("sk-ant-") else {
            error = "That Anthropic key doesn't look right. It should start with sk-ant-"
            return
        }
        guard Keychain.save(deepgram.trimmed, for: .deepgram), Keychain.save(anthropic.trimmed, for: .anthropic) else {
            error = "Couldn't save to the Keychain. Try again."
            return
        }
        onSave()
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Coach

struct CoachView: View {
    var onAudioCheck: () -> Void
    var onKeys: () -> Void
    @EnvironmentObject var coach: CoachModel
    @EnvironmentObject var campaigns: CampaignStore
    @Environment(\.openWindow) private var openWindow
    @State private var showTranscript = false
    @State private var showScoreboard = false
    @State private var showCalendar = false
    @State private var askName = false
    @AppStorage("repName") private var repName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            card
            if let problem = coach.problem {
                Text(problem).font(.callout).foregroundStyle(.orange)
            }
            if coach.status == .ready {
                readyHelp
            } else {
                controls
            }
            transcript
        }
        .padding(18)
        .onAppear {
            coach.use(campaigns.selected)
            coach.activate(true)
        }
        .onDisappear { coach.activate(false) }
        .onChange(of: campaigns.selected) { coach.use(campaigns.selected) }
        .sheet(isPresented: $showScoreboard) { ScoreboardView(book: coach.openers) }
        .sheet(isPresented: $showCalendar) { BookingCalendarView(availability: coach.availability) }
        .alert("Your first name", isPresented: $askName) {
            TextField("First name", text: $repName)
            Button("Save") { coach.refreshOpener() }
        } message: {
            Text("So openers say \"this is Mason\" instead of [your name].")
        }
        .animation(.easeInOut(duration: 0.2), value: coach.status)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                campaignMenu
                Spacer()
                Menu {
                    Button(coach.lab.hasNewSuggestions ? "Script Lab (new suggestions)" : "Script Lab") {
                        openWindow(id: "script-lab")
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                    Button("Opener scoreboard") { showScoreboard = true }
                    Button("Booking calendar...") { showCalendar = true }
                    Toggle("Rotate proven openers", isOn: Binding(
                        get: { coach.openers.rotate },
                        set: { coach.openers.rotate = $0; coach.refreshOpener() }
                    ))
                    Button(repName.isEmpty ? "Add your name..." : "Your name: \(repName)") { askName = true }
                    Divider()
                    Button("Run audio check", action: onAudioCheck)
                    Button("Change API keys", action: onKeys)
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            statusRow
        }
    }

    /// Pick a campaign, or create and edit one. Locked during a call.
    private var campaignMenu: some View {
        Menu {
            ForEach(campaigns.campaigns) { campaign in
                Button {
                    campaigns.selectedID = campaign.id
                } label: {
                    if campaign.id == campaigns.selected.id {
                        Label(campaign.name, systemImage: "checkmark")
                    } else {
                        Text(campaign.name)
                    }
                }
            }
            Divider()
            Button("Edit this campaign...") { edit(campaigns.selected) }
            Button("New campaign...") { edit(Campaign()) }
        } label: {
            Text(campaigns.selected.name).font(.headline).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(coach.status != .ready)
        .help(coach.status == .ready ? "Choose or edit a campaign" : "Finish the call to switch campaigns")
    }

    private func edit(_ campaign: Campaign) {
        campaigns.editing = campaign
        openWindow(id: "campaign-editor")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.callout.weight(.medium))
            if !coach.suggestion.stage.isEmpty {
                Text(coach.suggestion.stage)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
            }
            Spacer()
            if let calling = coach.calling {
                Text(calling.replacingOccurrences(of: "\"", with: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if coach.kind == .reply, !coach.latestProspect.isEmpty {
                Text("They said: \u{201C}\(coach.latestProspect)\u{201D}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Text(coach.kind == .opener ? "WHEN THEY PICK UP" : "SAY NEXT")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if coach.thinking && coach.status == .live {
                    ProgressView().controlSize(.mini)
                }
            }
            Text(coach.suggestion.say.isEmpty ? "Getting your opener ready..." : coach.suggestion.say)
                .font(.system(size: 24, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(coach.suggestion.say.isEmpty ? .secondary : .primary)
            if !coach.suggestion.cue.isEmpty {
                Text(coach.suggestion.cue)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if coach.kind == .opener, coach.openers.rotate {
                Text(coach.openers.current.evidence)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .animation(.easeOut(duration: 0.15), value: coach.suggestion.say)
    }

    private var readyHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dial from Salesforce. The coach starts by itself when the call connects.")
                .font(.callout)
            Text("Remember to tell them the call is transcribed.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Already on a call? Start listening") { coach.startByHand() }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var controls: some View {
        HStack {
            Button(coach.status == .paused ? "Resume" : "Pause") { coach.togglePause() }
            Button("Next call") { coach.nextCall() }
                .keyboardShortcut("n", modifiers: .command)
            Spacer()
            if let latency = coach.latency {
                Text(String(format: "%.1fs", latency))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Time from when they stopped talking to the first words on screen")
            }
        }
    }

    private var transcript: some View {
        DisclosureGroup("Transcript", isExpanded: $showTranscript) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(coach.turns) { turn in
                            line(turn.speaker, turn.text)
                        }
                        ForEach([Speaker.rep, .prospect], id: \.self) { speaker in
                            if let text = coach.interim[speaker], !text.isEmpty {
                                line(speaker, text).opacity(0.5)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .onChange(of: coach.turns.count) { proxy.scrollTo("end") }
            }
        }
        .font(.callout)
    }

    private func line(_ speaker: Speaker, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(speaker == .rep ? "You" : "Them").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text)
        }
    }

    private var statusText: String {
        switch coach.status {
        case .ready: return "Ready for your call"
        case .live: return "Listening"
        case .paused: return "Paused"
        }
    }

    private var statusColor: Color {
        switch coach.status {
        case .ready: return .secondary
        case .live: return .green
        case .paused: return .orange
        }
    }
}

// MARK: - Opener scoreboard

/// Your own experiment: how each opener does on your calls.
struct ScoreboardView: View {
    @ObservedObject var book: OpenerBook
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Opener scoreboard").font(.title2.weight(.semibold))
            Text("Each opener gets \(OpenerBook.warmUp) tries first. After that, openers with better scores come up more often, and the others still get an occasional try.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Opener").bold()
                    Text("Calls").bold()
                    Text("Avg score").bold()
                    Text("Goal").bold()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(ranked, id: \.opener.id) { row in
                    GridRow {
                        HStack(spacing: 6) {
                            if row.opener.id == leaderID { Text("🏆") }
                            if row.opener.id == book.current.id { Image(systemName: "arrow.right.circle.fill").foregroundStyle(Color.accentColor) }
                            Text(row.opener.name)
                        }
                        Text("\(row.score.calls)").monospacedDigit()
                        Text(row.score.calls == 0 ? "-" : "\(row.score.average)").monospacedDigit()
                        Text(percent(row.score.goals, of: row.score.calls)).monospacedDigit()
                    }
                }
            }

            Text("Score: \(CallScore.explanation) Voicemails and no-answers don't count.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Reset scores", role: .destructive) { book.reset() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 370)
    }

    private var ranked: [(opener: Opener, score: OpenerScore)] {
        Opener.all.map { ($0, book.scores[$0.id] ?? OpenerScore()) }
            .sorted { rate($0.score) > rate($1.score) }
    }

    /// Leader needs at least 5 calls so one lucky call doesn't win.
    private var leaderID: String? {
        ranked.first { $0.score.calls >= 5 }?.opener.id
    }

    private func rate(_ s: OpenerScore) -> Double {
        s.calls == 0 ? -1 : Double(s.points) / Double(s.calls)
    }

    private func percent(_ part: Int, of whole: Int) -> String {
        whole == 0 ? "-" : "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
    }
}
