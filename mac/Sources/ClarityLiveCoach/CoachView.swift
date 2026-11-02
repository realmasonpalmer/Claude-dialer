import AppKit
import SwiftUI

/// Decides which screen to show: audio check (first run), keys (once), then the coach.
struct RootView: View {
    enum Screen { case check, keys, coach }

    @EnvironmentObject var proof: ProofModel
    @EnvironmentObject var coach: CoachModel
    @AppStorage("audioCheckPassed") private var audioCheckPassed = false
    @AppStorage("appPhone") private var appPhone = true
    @ObservedObject private var phone = AircallPhone.shared
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
        // Wider, not taller, when the Aircall phone is open on the right.
        .frame(width: showPhone ? 380 + AircallPhoneSide.width : 380)
        // Never taller than the screen, counting the title bar.
        .frame(maxHeight: (NSScreen.main?.visibleFrame.height ?? 900) - 72)
    }

    private var showPhone: Bool { appPhone && phone.shown && (screen ?? firstScreen) == .coach }

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
            if let guide = SetupView.guides["keys"] {
                DisclosureGroup("Step by step: how to get both keys") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(guide.steps.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.callout)
                                    .fontWeight(line.hasSuffix(":") ? .semibold : .regular)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                }
                .font(.callout)
            }
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

/// The live coach. Built to be glanced at: the line to say is the hero,
/// status and stage are readable without reading a sentence, and navigation never moves.
struct CoachView: View {
    var onAudioCheck: () -> Void
    var onKeys: () -> Void
    @EnvironmentObject var coach: CoachModel
    @EnvironmentObject var campaigns: CampaignStore
    @Environment(\.openWindow) private var openWindow
    @State private var showTranscript = false
    @State private var showScoreboard = false
    @State private var showCalendar = false
    @State private var showHelp = false
    @State private var showAircall = false
    @State private var showSalesforce = false
    @State private var showSetup = false
    @State private var showSettings = false
    @StateObject private var updater = Updater()
    @State private var askName = false
    @AppStorage("repName") private var repName = ""
    @AppStorage("showTouchpoints") private var showTouchpoints = true
    @AppStorage("coachSpeed") private var speed = CoachSpeed.balanced.rawValue
    @AppStorage("wholeLine") private var wholeLine = true
    @AppStorage("nextDials") private var nextDials = true
    @AppStorage("appPhone") private var appPhone = true

    // One visual system: blue = actions, green = listening, amber = real warnings.
    private let margin: CGFloat = 16
    private let gap: CGFloat = 12
    private let listening = Color.green
    private let warning = Color.orange

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Exactly the screen's height (minus the title bar): the middle scrolls, nothing gets cut off.
            coachColumn.frame(width: 380, height: (NSScreen.main?.visibleFrame.height ?? 900) - 72)
            // The Aircall phone sits to the right. Hidden = 1 point wide, but still running.
            if appPhone { AircallPhoneSide() }
        }
    }

    private var coachColumn: some View {
        VStack(alignment: .leading, spacing: gap) {
            topBar
            // The middle scrolls if it's ever taller than the screen; the top bar and the buttons stay put.
            ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: gap) {
            // The Chrome list is the default. This header only shows if a Salesforce list was picked in the gear menu.
            if Salesforce.isConnected && coach.leads.selected != nil { leadHeader }
            StageBar(steps: CoachModel.journey, current: coach.journeyStep, active: coach.status != .ready)
            scriptCard
            belowCard
            if coach.statusRecordID != nil {
                RelationshipCard(coach: coach)
            }
            if coach.followUp != nil {
                FollowUpCard(
                    followUp: $coach.followUp,
                    canSend: Aircall.isSetUp,
                    onSend: { coach.sendFollowUpText() },
                    onLinkedIn: { coach.openLinkedIn() },
                    onLinkedInMessage: { coach.openLinkedIn(message: true) },
                    onSetupAircall: { showAircall = true }
                )
            }
            if showTouchpoints && coach.status == .ready {
                TouchpointsCard(touchpoints: coach.touchpoints)
            }
            warnings
            }
            }
            .scrollBounceBehavior(.basedOnSize)
            Spacer(minLength: 0)
            if appPhone { AircallPhonePanel() }
            if let message = coach.callMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        coach.callMessage = nil
                    } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            if let left = coach.autoNextIn { autoNextBar(left) }
            if coach.waitingForText && coach.autoNextIn == nil {
                HStack(spacing: 8) {
                    Text(coach.autoDial ? "Send the text. Then the next person loads and the call starts." : "Send the text. Then the next person loads.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Skip text") { coach.startNextSequence() }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            navigation
        }
        .padding(.horizontal, margin)
        .padding(.vertical, gap)
        .background(
            // Command-J: a different line right now (no visible button needed).
            Button("") { coach.newLine() }
                .keyboardShortcut("j", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        )
        .onAppear {
            coach.use(campaigns.selected)
            coach.activate(true)
        }
        .task {
            // Look for a new version now and every 2 minutes, so the Update button shows up on its own.
            while !Task.isCancelled {
                await updater.check()
                try? await Task.sleep(for: .seconds(120))
            }
        }
        .onDisappear { coach.activate(false) }
        // Also check whenever the rep switches back to the app.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await updater.check() }
        }
        .onChange(of: campaigns.selected) { coach.use(campaigns.selected) }
        .sheet(isPresented: $showScoreboard) { ScoreboardView(book: coach.openers) }
        .sheet(isPresented: $showCalendar) { BookingCalendarView(availability: coach.availability) }
        .sheet(isPresented: $showHelp) { HelpView() }
        .sheet(isPresented: $showSetup) {
            SetupView(onAudioCheck: onAudioCheck, onKeys: onKeys).environmentObject(coach)
        }
        .sheet(isPresented: $showSettings) { SettingsPane(updater: updater).environmentObject(coach) }
        .sheet(isPresented: $showAircall) { AircallSetupView() }
        .sheet(isPresented: $showSalesforce) {
            SalesforceConnectView(onConnected: { Task { await coach.leads.start() } })
        }
        .alert("Your first name", isPresented: $askName) {
            TextField("First name", text: $repName)
            Button("Save") { coach.refreshOpener() }
        } message: {
            Text("So openers say \"this is Mason\" instead of [your name].")
        }
        .animation(.easeInOut(duration: 0.2), value: coach.status)
    }

    // MARK: Top: campaign, status, settings

    private var topBar: some View {
        HStack(spacing: 8) {
            // No status pill, Voicemail or End call buttons here: the app handles those by itself.
            // (Command-E still ends a call; both are also in Settings and tools.)
            Spacer()
            Button("") { coach.endCall() }
                .keyboardShortcut("e", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
                .allowsHitTesting(false)
            // Updates live only here. It checks by itself every 10 minutes.
            if updater.updating {
                Button("Updating...") {}
                    .controlSize(.small)
                    .disabled(true)
                    .help("Keep working. The app closes and reopens by itself in about 2 minutes.")
            } else if updater.updateAvailable && coach.status == .ready {
                Button("Update") { updater.update() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("A new version is ready. Click to install it (about 2 minutes, no Terminal).")
            }
            campaignMenu
            settingsMenu
        }
    }

    private var pillState: String {
        switch coach.status {
        case .ready: return "Ready"
        case .paused: return "Paused"
        case .live:
            if coach.kind == .voicemail { return "Voicemail" }
            return coach.prospectSpeaking ? "Prospect speaking" : "Listening"
        }
    }

    private var pillColor: Color {
        switch coach.status {
        case .ready: return .secondary
        case .paused: return warning
        case .live: return coach.kind == .voicemail ? warning : listening
        }
    }

    /// "Setup (5 of 7 done)" until everything is set up.
    private var setupLabel: String {
        let c = SetupView.doneCount(coach: coach)
        return c.done == c.total ? "Setup and integrations..." : "Setup (\(c.done) of \(c.total) done)..."
    }

    /// Three items only. Everything else lives in the Setup and Settings panes.
    private var settingsMenu: some View {
        Menu {
            Button(setupLabel) { showSetup = true }
            Button("Settings and tools...") { showSettings = true }
            Button("How to use") { showHelp = true }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
            Text(campaigns.selected.name).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(coach.status != .ready)
        .help(coach.status == .ready ? "Choose or edit a campaign" : "Finish the call to switch campaigns")
    }

    private func edit(_ campaign: Campaign) {
        campaigns.editing = campaign
        openWindow(id: "campaign-editor")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    // MARK: Who's up (Salesforce list)

    private var leadHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(coach.leads.views) { view in
                        Button(view.title) { Task { await coach.leads.open(view) } }
                    }
                    Divider()
                    Button("Reload list") { Task { await coach.leads.reload() } }
                } label: {
                    Text(coach.leads.selected?.label ?? "Pick a list").font(.caption.weight(.semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(coach.status != .ready)
                if coach.leads.loading { ProgressView().controlSize(.mini) }
                Spacer()
                if coach.leads.isActive {
                    Text("\(coach.leads.index + 1) of \(coach.leads.rows.count) · \(coach.leads.leftToCall) left")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let d = coach.leads.details {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(d.name).font(.headline).lineLimit(1)
                    Text([d.title, d.company].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if let url = Salesforce.recordURL(d.id) {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            .help("Open in Salesforce")
                    }
                }
                if d.doNotCall {
                    warningText("Do Not Call is checked in Salesforce. Skip this one.")
                } else if let last = d.recent.first {
                    Text("Last: \(last)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if let error = coach.leads.error {
                warningText(error)
            } else if coach.leads.selected == nil && !coach.leads.loading {
                Text("Pick a Salesforce list above to start calling.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: The hero: what to say

    private var scriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(cardLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(coach.kind == .voicemail || coach.kind == .screener ? warning : .secondary)
                Spacer()
                if coach.thinking && coach.status == .live {
                    ProgressView().controlSize(.mini)
                }
                if coach.historyIndex != nil {
                    Button("Latest") { coach.showLatest() }
                        .buttonStyle(.link).font(.caption2)
                }
            }
            Text(coach.suggestion.say.isEmpty ? "Getting your line ready..." : coach.suggestion.say)
                .font(.system(size: 26, weight: .semibold))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(coach.suggestion.say.isEmpty ? .secondary : .primary)
                .opacity(coach.historyIndex == nil ? 1 : 0.6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .animation(.easeOut(duration: 0.15), value: coach.suggestion.say)
    }

    private var cardLabel: String {
        if coach.historyIndex != nil { return "EARLIER LINE" }
        switch coach.kind {
        case .opener: return "WHEN THEY PICK UP"
        case .screener: return "CALL SCREENER"
        case .voicemail: return "VOICEMAIL · WAIT FOR THE BEEP"
        case .reply: return "SAY THIS"
        }
    }

    // MARK: Right under the card: tip, meeting times, transcript

    private var belowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !coach.suggestion.cue.isEmpty {
                Text(coach.suggestion.cue)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if coach.suggestion.stage == "Closing", !coach.nextOffer.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "calendar").foregroundStyle(.secondary)
                    Text(coach.nextOffer.map { coach.availability.label($0) }.joined(separator: "  ·  "))
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("Other times") { coach.skipOfferedTimes() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            transcript
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showTranscript.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showTranscript ? "chevron.down" : "chevron.right").font(.caption2)
                    Text("Transcript").font(.caption)
                    if !showTranscript, let last = coach.turns.last(where: { $0.speaker == .prospect }) {
                        Text("· \(last.text)").font(.caption).lineLimit(1).foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if showTranscript {
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
                    .frame(maxHeight: 140)
                    .onChange(of: coach.turns.count) { proxy.scrollTo("end") }
                }
            }
        }
    }

    private func line(_ speaker: Speaker, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(speaker == .rep ? "You" : "Them").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
    }

    // MARK: Real warnings only, never cut off

    @ViewBuilder private var warnings: some View {
        if let message = updater.message, !updater.updating, message.hasPrefix("The update") || message.hasPrefix("Couldn't") {
            Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let problem = coach.problem {
            warningText(problem)
        }
        if coach.callList.state == .needsChromeSetting {
            warningText("Chrome needs one setting for Next: View > Developer > Allow JavaScript from Apple Events.")
        }
        if let message = coach.callList.message {
            warningText(message)
        }
    }

    private func warningText(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(warning)
    }

    /// After a 2nd-try voicemail: "Calling Jane in 4", with a button to stay.
    private func autoNextBar(_ left: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
            Text("Calling \(coach.autoNextName ?? coach.nextLeadName ?? "next person") in \(left)")
                .font(.callout.weight(.semibold))
            Spacer(minLength: 0)
            Button("Wait") { coach.cancelAutoNext() }
                .controlSize(.large)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Navigation: always here, always the same two buttons

    @ViewBuilder private var navigation: some View {
        if coach.status == .ready && coach.leads.isActive {
            leadNavigation
        } else {
            stepNavigation
        }
    }

    /// Between calls with the Salesforce list: Back, a big Call button, Next.
    private var leadNavigation: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = coach.dialError {
                warningText(error)
            }
            HStack(spacing: 8) {
                Button {
                    coach.previousLead()
                } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28)
                }
                .disabled(!coach.leads.canGoBack)
                .help("Previous lead")

                let first = coach.leads.details.map { $0.firstName ?? $0.name } ?? ""
                let nextName = coach.leads.nextRow?.name
                if coach.shouldOfferRedial {
                    // 1st try, no answer: call right back.
                    bigButton("Redial \(first)", icon: "arrow.clockwise") { coach.redial() }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(!canCall)
                    smallButton(nextName.map { "Call \($0)" } ?? "No one left") { coach.nextLead() }
                        .keyboardShortcut("n", modifiers: .command)
                        .disabled(nextName == nil || coach.dialing)
                } else if coach.currentAttempts == 0 {
                    // Haven't called them yet.
                    bigButton(coach.dialing ? "Calling..." : callTitle, icon: "phone.fill") { coach.dial() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canCall)
                    smallButton(nextName.map { "Call \($0)" } ?? "No one left") { coach.nextLead() }
                        .keyboardShortcut("n", modifiers: .command)
                        .disabled(nextName == nil || coach.dialing)
                } else {
                    // Two tries done (or they answered): on to the next person.
                    bigButton(nextName.map { "Call \($0)" } ?? "No one left", icon: "phone.arrow.right") { coach.nextLead() }
                        .keyboardShortcut("n", modifiers: .command)
                        .disabled(nextName == nil || coach.dialing)
                    smallButton("Redial") { coach.redial() }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(!canCall)
                }
            }
            .controlSize(.large)
        }
    }

    private func bigButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).lineLimit(1).frame(maxWidth: 120)
        }
        .controlSize(.large)
    }

    private var canCall: Bool {
        guard let d = coach.leads.details, !d.doNotCall, d.callNumber != nil, !coach.dialing else { return false }
        return Aircall.canPlaceCalls
    }

    private var callTitle: String {
        guard let d = coach.leads.details else { return "Loading..." }
        if d.doNotCall { return "Do Not Call" }
        if !Aircall.canPlaceCalls { return "Set up Aircall calling first" }
        return d.callNumber != nil ? "Call \(d.name)" : "No mobile number"
    }

    /// During a call (or without the Salesforce list): Back and Next as before.
    private var stepNavigation: some View {
        HStack(spacing: 8) {
            Button {
                coach.status == .ready ? coach.previousLead() : coach.back()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: 28)
            }
            .disabled(!backEnabled)
            .help(coach.status == .ready ? "Previous lead" : "Show the line before this one")

            if coach.status == .ready && coach.calling != nil && coach.currentAttemptKey == nil {
                // A lead is open in Salesforce and not called yet: call their Mobile right from here.
                bigButton(coach.gettingReady ?? (coach.dialing ? "Calling..." : "Call \(currentName)"), icon: "phone.fill") {
                    coach.callOpenLead()
                }
                .disabled(coach.dialing)
                smallButton(nextTitle) { coach.nextLead() }
                    .disabled(!nextEnabled || coach.dialing)
            } else if coach.status == .ready && coach.shouldOfferRedial {
                // 1st try, no answer: call right back.
                bigButton("Redial \(currentName)", icon: "arrow.clockwise") { coach.redial() }
                    .keyboardShortcut("r", modifiers: .command)
                smallButton(nextTitle) { coach.nextLead() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!nextEnabled)
            } else {
                bigButton(nextTitle, icon: coach.status == .ready ? (nextDials ? "phone.arrow.right" : "arrow.right") : "arrow.right") {
                    coach.status == .ready ? coach.nextLead() : coach.advanceStep()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!nextEnabled)
                if coach.status == .ready && coach.currentAttemptKey != nil {
                    smallButton("Redial") { coach.redial() }
                        .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        .controlSize(.large)
    }

    /// The person on screen now, from the Salesforce tab (e.g. Lead "Burcin Sonmezer").
    private var currentName: String {
        guard let calling = coach.calling, let open = calling.firstIndex(of: "\""), let close = calling.lastIndex(of: "\""),
              open < close else { return "them" }
        return String(calling[calling.index(after: open)..<close])
    }

    private var backEnabled: Bool {
        coach.status == .ready ? !coach.callList.records.isEmpty : coach.canGoBack
    }

    private var nextEnabled: Bool {
        if coach.status != .ready { return true }
        if case .ready = coach.callList.state { return true }
        return false
    }

    /// The preview on the Next button: the next step during a call, the next lead between calls.
    private var nextTitle: String {
        if coach.status != .ready {
            return coach.nextStepName.map { "\($0) question" } ?? "New line"
        }
        switch coach.callList.state {
        case .ready(let name, _, _): return nextDials ? "Call \(name)" : "Next: \(name)"
        case .needsList: return "Open a lead list in Salesforce"
        case .needsChromeSetting: return "Needs a Chrome setting"
        case .endOfList: return "Everyone here is called"
        }
    }
}

/// Big, colored status you can read without reading.
struct StatusPill: View {
    let status: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(status).font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color == .secondary ? Color.primary : color)
    }
}

/// Opener -> Discovery -> Value -> Close, with the current step highlighted.
struct StageBar: View {
    let steps: [String]
    let current: Int
    let active: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(steps.indices, id: \.self) { i in
                Text(steps[i])
                    .font(.caption.weight(i == current ? .semibold : .regular))
                    .foregroundStyle(i == current && active ? Color.primary : (i < current ? Color.secondary : Color.secondary.opacity(0.5)))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(i == current && active ? Color.secondary.opacity(0.2) : .clear, in: Capsule())
                if i < steps.count - 1 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Onboarding and how-to, out of the way of the live screen.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("How to use").font(.title2.weight(.semibold))
                section("Calling from the app (recommended)", [
                    "Gear > Setup: do each step once (keys, audio, Chrome, Salesforce, Aircall, calendar).",
                    "Gear > Settings and tools: speed, toggles, call list, Script Lab, updates.",
                    "Aircall phone (bottom of the coach): click Show, sign in once, set yourself Available, click Hide.",
                    "The big Call button dials their Mobile through Aircall. The call rings in the coach.",
                    "Call [next name] loads the next lead and dials right away. Turn it off in Gear > Settings and tools.",
                    "Calls log to Salesforce through Aircall, made by you, like always.",
                ])
                section("Calling", [
                    "Or click a phone number in Salesforce. The coach starts on its own when the call connects.",
                    "Read the big line. Say it in your own words.",
                    "Tell them the call is transcribed. Some states require it.",
                ])
                section("Next and Back", [
                    "Between calls: Next opens the next lead on your list. Back opens the one before.",
                    "During a call: Next gives you the line for the next step. Back shows the line before.",
                    "To set up your list: open your lead list in Salesforce (split view or table view). The app learns it by itself.",
                ])
                section("One Chrome setting", [
                    "In Chrome's top menu: View > Developer > Allow JavaScript from Apple Events.",
                    "It lets the coach read the open lead and click Next for you.",
                ])
                section("Double dial", [
                    "1st try, no answer or voicemail: hang up and click Redial.",
                    "2nd try, voicemail: leave the message on screen.",
                    "After a voicemail: click Send text, then Open profile + copy note.",
                    "When the call ends, the app calls the next person in 5 seconds. Click Wait to stay.",
                ])
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 370, height: 480)
    }

    private func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ForEach(lines, id: \.self) { line in
                Text("• \(line)").font(.callout).fixedSize(horizontal: false, vertical: true)
            }
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

// MARK: - Voicemail follow-ups

/// After a voicemail: send the text in one click (Aircall) and open LinkedIn with the note copied.
/// Stays after the call until both are done or it's closed.
struct FollowUpCard: View {
    @Binding var followUp: FollowUp?
    var canSend: Bool
    var onSend: () -> Void
    var onLinkedIn: () -> Void
    var onLinkedInMessage: () -> Void
    var onSetupAircall: () -> Void

    var body: some View {
        if let f = followUp {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Follow up\(f.prospect.map { " with \($0)" } ?? "")").font(.headline)
                    Spacer()
                    Button {
                        followUp = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Close")
                }

                // LinkedIn
                row(done: f.linkedinDone, title: "LinkedIn note", message: f.linkedin) {
                    if f.linkedinDone {
                        Button("Open again") { onLinkedIn() }.buttonStyle(.link)
                    } else {
                        Button(f.linkedinURL == nil ? "Search LinkedIn + copy note" : "Open profile + copy note") { onLinkedIn() }
                            .keyboardShortcut("l", modifiers: .command)
                            .buttonStyle(.borderedProminent)
                            .disabled(f.linkedin.isEmpty)
                    }
                }
                if f.linkedinDone {
                    Text("On their profile: click Connect, then Add a note. Right-click the box, click Paste, then Send.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // LinkedIn message (already connected)
                row(done: f.linkedinMessageDone, title: "LinkedIn message (already connected)", message: f.linkedinMessage) {
                    if f.linkedinMessageDone {
                        Button("Copy again") { onLinkedInMessage() }.buttonStyle(.link)
                    } else {
                        Button("Copy message") { onLinkedInMessage() }
                            .buttonStyle(.borderedProminent)
                            .disabled(f.linkedinMessage.isEmpty)
                    }
                }
                if f.linkedinMessageDone {
                    Text("Copied. On their profile: click Message, paste (Command-V), then Send.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // Text
                row(done: f.textDone, title: "Text", message: f.text) {
                    if f.textDone {
                        Label("Sent", systemImage: "checkmark").foregroundStyle(.green)
                    } else if canSend {
                        HStack(spacing: 6) {
                            TextField("Their phone", text: phoneBinding)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 130)
                            Button("Send text") { onSend() }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut("t", modifiers: .command)
                                .disabled(f.text.isEmpty || f.phone.isEmpty || f.textStatus == "Sending...")
                        }
                    } else {
                        HStack(spacing: 12) {
                            Button("Copy") { copy(f.text); followUp?.textDone = true }
                            Button("Send from Aircall in one click...") { onSetupAircall() }
                                .buttonStyle(.link)
                        }
                    }
                }
                if let status = f.textStatus, status != "Sent" {
                    Text(status).font(.caption)
                        .foregroundStyle(status == "Sending..." ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: f.allDone) {
                if f.allDone {
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        if followUp?.allDone == true { followUp = nil }
                    }
                }
            }
        }
    }

    private func row<Actions: View>(done: Bool, title: String, message: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(message.isEmpty ? "Writing..." : message)
                    .font(.callout)
                    .foregroundStyle(message.isEmpty || done ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                actions().font(.caption)
            }
        }
    }

    private var phoneBinding: Binding<String> {
        Binding(get: { followUp?.phone ?? "" }, set: { followUp?.phone = $0 })
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}


// MARK: - Relationship Status / Lead Status

/// Contact: every Relationship Status. Lead: every Lead Status. Round radio buttons, two columns, Save.
/// Saves to Salesforce. "Not Quality Prospect", "Negative" and "Unqualified" take them off the list.
struct RelationshipCard: View {
    @ObservedObject var coach: CoachModel
    @State private var picked: String?
    @State private var pickedFor: String?

    private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]

    /// "Calls: 2 of 4" (or "Calls: 3 · picked up" once someone answered).
    private func callsLabel(_ id: String) -> String {
        _ = coach.touchpoints.events.count // redraw after each call
        let p = DialHistory.person(id)
        if p.pickups > 0 { return "Calls: \(p.dials.count) · picked up" }
        return DialHistory.maxDials > 0 ? "Calls: \(p.dials.count) of \(DialHistory.maxDials)" : "Calls: \(p.dials.count)"
    }

    var body: some View {
        let object = coach.statusObject ?? "Contact"
        let current = picked ?? coach.recordStatus
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(object == "Lead" ? "Lead Status" : "Relationship Status").font(.callout.weight(.semibold))
                Spacer()
                if let id = coach.statusRecordID {
                    Text(callsLabel(id)).font(.caption).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(Salesforce.statuses(object), id: \.self) { value in
                    Button {
                        picked = value
                        pickedFor = coach.statusRecordID
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: current == value ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(current == value ? Color.accentColor : .secondary)
                            Text(value).font(.callout).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                Button(coach.savingStatus ? "Saving..." : "Save") {
                    if let picked { coach.saveStatus(picked) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(picked == nil || picked == coach.recordStatus || coach.savingStatus)
                if let message = coach.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: coach.statusRecordID) {
            // New person on screen: start fresh.
            if pickedFor != coach.statusRecordID { picked = nil; pickedFor = nil }
        }
    }
}
