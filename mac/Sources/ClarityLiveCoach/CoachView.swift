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
                // The Aircall phone sits on the right here too, so the test call comes from it.
                HStack(alignment: .top, spacing: 0) {
                    AudioCheckView(onFinish: {
                        audioCheckPassed = true
                        screen = hasKeys ? .coach : .keys
                    }, onCancel: audioCheckPassed && hasKeys ? { screen = .coach } : nil)
                    .frame(width: 380)
                    .onAppear { proof.onAppear() }
                    if appPhone { AircallPhoneSide() }
                }
            case .keys:
                KeysView(onSave: { screen = .coach }, onCancel: hasKeys ? { screen = .coach } : nil)
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

    private var showPhone: Bool {
        let current = screen ?? firstScreen
        return appPhone && phone.shown && (current == .coach || current == .check)
    }

    private var hasKeys: Bool { Keychain.read(.deepgram) != nil && Keychain.read(.anthropic) != nil }
    private var firstScreen: Screen { !audioCheckPassed ? .check : (hasKeys ? .coach : .keys) }
}

// MARK: - Keys

struct KeysView: View {
    var onSave: () -> Void
    /// Set when the keys are already saved: a way back without changing them.
    var onCancel: (() -> Void)? = nil
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
            if let onCancel {
                Button("Cancel") { onCancel() }
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
    @State private var showHelp = false
    @State private var showAircall = false
    @State private var showSetup = false
    @State private var showSettings = false
    @StateObject private var updater = Updater()
    @AppStorage("repName") private var repName = ""
    @AppStorage("showTouchpoints") private var showTouchpoints = true
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
            // The Chrome list is the default. This header only shows if a Salesforce list was picked in Settings and tools.
            if Salesforce.isConnected && coach.leads.selected != nil { leadHeader }
            if coach.status != .ready {
                StageBar(steps: CoachModel.journey, current: coach.journeyStep, active: true)
            }
            scriptCard
            belowCard
            if coach.statusRecordID != nil { // stays up during calls too, with the LinkedIn and text cards
                RelationshipCard(coach: coach)
                    .id(coach.statusRecordID) // a fresh card per person: nothing picked carries over
            }
            if coach.followUp != nil {
                FollowUpCard(
                    followUp: $coach.followUp,
                    isLastPerson: coach.followUp?.key != nil && coach.followUp?.key != coach.statusRecordID,
                    steps: coach.todaySteps(for: coach.followUp?.key),
                    canSend: Aircall.isSetUp,
                    onSend: { coach.sendFollowUpText() },
                    onLinkedIn: { coach.openLinkedIn() },
                    onLinkedInMessage: { coach.openLinkedIn(message: true) },
                    onSetupAircall: { showAircall = true }
                )
            }
            if coach.status == .ready {
                DailyGoalCard(touchpoints: coach.touchpoints, activeCampaigns: campaigns.activeCampaigns)
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
            bottomBanner
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
        .onChange(of: campaigns.selected) { old, new in
            coach.use(new)
            // A different campaign, or its list changed in the editor: open that list in Chrome.
            if old.id != new.id || old.listViewID != new.listViewID { openList(of: new) }
            if old.id != new.id { coach.listDone = false }
        }
        .sheet(isPresented: $showHelp) { HelpView() }
        .sheet(isPresented: $showSetup) {
            SetupView(onAudioCheck: onAudioCheck, onKeys: onKeys).environmentObject(coach)
        }
        .sheet(isPresented: $showSettings) { SettingsPane(updater: updater).environmentObject(coach) }
        .sheet(isPresented: $showAircall) { AircallSetupView() }
        .animation(.easeInOut(duration: 0.2), value: coach.status)
    }

    // MARK: Top: campaign, status, settings

    private var topBar: some View {
        HStack(spacing: 8) {
            // No status, Voicemail or End call buttons here (the app handles those by itself).
            // Command-E still ends a call; Settings and tools has both buttons.
            Spacer()
            Button("") { coach.endCall() }
                .keyboardShortcut("e", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
                .allowsHitTesting(false)
            // Updates live only here. It checks by itself every 2 minutes and when the app is opened.
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
            Button("Campaigns...") {
                openWindow(id: "campaign-selector")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Divider()
            // Only the active campaigns (up to 3): pick one to call its list.
            if campaigns.activeCampaigns.isEmpty {
                Text("No active campaigns. Open Campaigns... to activate up to 3.")
            }
            ForEach(campaigns.activeCampaigns) { campaign in
                Button {
                    switchTo(campaign)
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
        } label: {
            Text(campaigns.selected.name).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(coach.status != .ready)
        .help(coach.status == .ready ? "Choose or edit a campaign" : "Finish the call to switch campaigns")
    }

    /// Switches campaign (its script) and opens its Salesforce list in Chrome, so the app works that list.
    private func switchTo(_ campaign: Campaign) {
        campaigns.selectedID = campaign.id // its list opens via onChange below
        coach.listDone = false
    }

    private func openList(of campaign: Campaign) {
        guard !campaign.listViewID.isEmpty, !campaign.listObject.isEmpty else { return }
        let origin = SalesforceChrome.url().flatMap { URL(string: $0) }.flatMap { u in u.host.map { "https://\($0)" } }
            ?? Keychain.read(.sfInstance) ?? ""
        guard !origin.isEmpty else { return }
        _ = SalesforceChrome.open("\(origin)/lightning/o/\(campaign.listObject)/list?filterName=\(campaign.listViewID)")
        ActivityLog.add("Campaign: \(campaign.name), list \(campaign.listName)")
    }

    /// The campaign after this one that has a list (the next list to work today).
    private var nextCampaign: Campaign? {
        let all = campaigns.campaigns
        guard let i = all.firstIndex(where: { $0.id == campaigns.selected.id }) else { return nil }
        let after = all[(i + 1)...] + all[..<i]
        return after.first { $0.active && !$0.listViewID.isEmpty }
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
            Text(coach.suggestion.say.isEmpty
                 ? (Keychain.read(.anthropic) == nil ? "Add your Anthropic key: gear > Setup > AI keys." : "Getting your line ready...")
                 : coach.suggestion.say)
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
        if coach.status != .ready {
            // During a call: no stage buttons, just a way out if the app ever misses the hang-up.
            Button(role: .destructive) {
                coach.endCall()
            } label: {
                Label("End call", systemImage: "phone.down.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .help("The call is over but the app didn't notice? Click here. (Command-E)")
        } else if coach.leads.isActive {
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
        return d.callNumber != nil ? "Call \(d.name)" : "No phone number"
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
        switch coach.callList.state {
        case .ready, .endOfList: return true // at the end, Next loads more people from the list
        default: return false
        }
    }

    /// One message above the buttons at a time, the most important first:
    /// a call problem, the countdown, "send the text", then why Next can't move on.
    @ViewBuilder private var bottomBanner: some View {
        if coach.listDone && coach.status == .ready {
            let calledHere = coach.callList.records.filter { coach.callList.calledToday.contains($0.id) }.count
            VStack(alignment: .leading, spacing: 8) {
                Text("\(campaigns.selected.name) list done for today").font(.callout.weight(.semibold))
                Text("\(calledHere) people called on this list today.").font(.caption).foregroundStyle(.secondary)
                if let next = nextCampaign {
                    Button("Start next list: \(next.name)") { switchTo(next) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("Pick another campaign at the top, or link a list to one (campaign menu).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        } else if let message = coach.callMessage {
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
        } else if let left = coach.autoNextIn {
            autoNextBar(left)
        } else if let detail = coach.gettingReadyDetail {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(detail).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        } else if coach.waitingForText {
            HStack(spacing: 8) {
                Text(coach.autoDial ? "Send the text. Then the next person loads and the call starts." : "Send the text. Then the next person loads.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Skip text") { coach.startNextSequence() }
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        } else if let hint = nextHint, !coach.leads.isActive {
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Why Next can't move on, shown as a line above the buttons (never squeezed into a button).
    private var nextHint: String? {
        guard coach.status == .ready else { return nil }
        switch coach.callList.state {
        case .needsList: return "Open your lead list in Salesforce (in Chrome) so Next knows who's next."
        case .needsChromeSetting: return "Chrome needs one setting: View > Developer > Allow JavaScript from Apple Events."
        case .endOfList: return "Everyone the app can see has been called. Next loads more from your list."
        case .ready: return nil
        }
    }

    /// The preview on the Next button: the next step during a call, the next lead between calls.
    private var nextTitle: String {
        if coach.status != .ready {
            return coach.nextStepName.map { "\($0) question" } ?? "New line"
        }
        switch coach.callList.state {
        case .ready(let name, _, _): return nextDials ? "Call \(name)" : "Next: \(name)"
        case .needsList, .needsChromeSetting, .endOfList: return "Next"
        }
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
                section("Getting set up", [
                    "Gear > Setup: do each step once (name, keys, audio, Chrome, Salesforce, Aircall, calendar).",
                    "Aircall phone (bottom of the coach): click Show, sign in once, set yourself Available, click Hide.",
                    "Open your lead list in Salesforce in Chrome. The app learns it by itself.",
                ])
                section("Calling", [
                    "Click the big Call button. The app checks that the opener, voicemail and follow-ups are for that person, then calls their Mobile (or Phone, if there's no Mobile).",
                    "Read the big line. Say it in your own words.",
                    "Tell them the call is transcribed. Some states require it.",
                ])
                section("After each call", [
                    "1st try, no answer: the app calls them again in 3 seconds (Auto-dial on). Click Wait to stop it.",
                    "Voicemail: leave the message on screen.",
                    "Then, top to bottom: update their status, send the LinkedIn note or message, then send the text.",
                    "Sending the text loads the next person. Once their info checks out, it calls them in 3 seconds.",
                    "Bad numbers and calls that don't connect are skipped by themselves.",
                ])
                section("Next and Back", [
                    "Between calls: Next opens the next person. Back opens the one before.",
                    "During a call: Next gives you the line for the next step. Back shows the line before.",
                    "Auto-dial (checkbox next to Aircall phone): off means Next and the text only load the next person.",
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
    /// The card is for someone other than the person on screen now.
    var isLastPerson = false
    /// Today's steps for this person (from the 21-day plan).
    var steps: [(title: String, done: Bool)] = []
    /// Show the LinkedIn message instead of the connection note.
    @State private var useMessage = false
    var canSend: Bool
    var onSend: () -> Void
    var onLinkedIn: () -> Void
    var onLinkedInMessage: () -> Void
    var onSetupAircall: () -> Void

    var body: some View {
        if let f = followUp {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text((isLastPerson ? "Last call: " : "Today for ") + (f.prospect ?? "them")).font(.headline)
                    Spacer()
                    Button {
                        followUp = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Close")
                }

                // Today's plan for this person, checked off as it happens.
                if !steps.isEmpty {
                    Text(steps.map { ($0.done ? "✓ " : "○ ") + $0.title }.joined(separator: "   "))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(steps.allSatisfy(\.done) ? Color.green : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // LinkedIn: one row, only on the plan's LinkedIn days. The note (not connected yet)
                // or the message (already connected; the plan's choice on the last call day).
                if !f.linkedInDue && !f.linkedinDone && !f.linkedinMessageDone {
                    EmptyView()
                } else if useMessage || f.linkedInMessageFirst || f.linkedinMessageDone {
                    row(done: f.linkedinMessageDone, title: "LinkedIn message", message: f.linkedinMessage) {
                        if f.linkedinMessageDone {
                            Button("Copy again") { onLinkedInMessage() }.buttonStyle(.link)
                        } else {
                            Button("Copy message") { onLinkedInMessage() }
                                .buttonStyle(.bordered)
                                .disabled(f.linkedinMessage.isEmpty)
                        }
                    }
                    if f.linkedinMessageDone {
                        Text("Copied. On their profile: click Message, paste (Command-V), then Send.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !f.linkedinDone && !f.linkedInMessageFirst {
                        Button("Not connected yet? Use a connection note") { useMessage = false }
                            .buttonStyle(.link).font(.caption)
                    }
                } else {
                    row(done: f.linkedinDone, title: "LinkedIn note", message: f.linkedin) {
                        if f.linkedinDone {
                            Button("Open again") { onLinkedIn() }.buttonStyle(.link)
                        } else {
                            Button(f.linkedinURL == nil ? "Search LinkedIn + copy note" : "Open profile + copy note") { onLinkedIn() }
                                .keyboardShortcut("l", modifiers: .command)
                                .buttonStyle(.bordered)
                                .disabled(f.linkedin.isEmpty)
                        }
                    }
                    if f.linkedinDone {
                        Text("On their profile: click Connect, then Add a note. Right-click the box, click Paste, then Send.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Already connected? Use a message") { useMessage = true }
                            .buttonStyle(.link).font(.caption)
                    }
                }

                // Text: only on the plan's text day (the 2nd call day), never to Washington numbers.
                if f.textDue || f.textDone {
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
                }
                if let status = f.textStatus, status != "Sent" {
                    Text(status).font(.caption)
                        .foregroundStyle(status == "Sending..." ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !f.textDue && !f.textDone && !f.linkedInDue {
                    Text("Nothing to send today. Texts go out on days 1, 2 and 16; the LinkedIn request on day 1.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: f.allDone) {
                // Close only after something was actually sent (a day with nothing due keeps the card up).
                if f.allDone, f.textDone || f.linkedinDone || f.linkedinMessageDone {
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
        _ = p
        return Cadence.label(for: id)
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
                            Text(value).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let picked, Salesforce.removedStatuses.contains(picked), picked != coach.recordStatus {
                Text("Saving this takes them off your list.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button(coach.savingStatus ? "Saving..." : "Save") {
                    if let picked { coach.saveStatus(picked) }
                }
                .buttonStyle(.bordered)
                .disabled(picked == nil || picked == coach.recordStatus || coach.savingStatus || !Salesforce.isConnected)
                if !Salesforce.isConnected {
                    Text("Sign in to Salesforce to save: gear > Setup > Salesforce.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let message = coach.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
