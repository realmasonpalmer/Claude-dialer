import AppKit
import SwiftUI

/// Decides which screen to show: audio check (first run), keys (once), then the coach.
struct RootView: View {
    /// keys = upload the team keys file. manualKeys = type keys by hand (hidden, team lead only).
    enum Screen { case check, keys, manualKeys, coach }

    @EnvironmentObject var proof: ProofModel
    @EnvironmentObject var coach: CoachModel
    @AppStorage(PrefKey.audioCheckPassed) private var audioCheckPassed = false
    /// Skipped on a first run: don't show the audio check again at every launch (Set up still lists it).
    @AppStorage(PrefKey.audioCheckSkipped) private var audioCheckSkipped = false
    private let appPhone = true // always: the Aircall phone is inside the coach
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
                    }, onCancel: audioCheckPassed && hasKeys ? { screen = .coach } : nil,
                       // Never trap a new rep here: they can finish it later from Set up.
                       onSkip: { audioCheckSkipped = true; proof.testAgain(); screen = .coach })
                    .frame(minWidth: 380, maxWidth: .infinity)
                    .onAppear { proof.onAppear() }
                    if appPhone { AircallPhoneSide() }
                }
            case .keys:
                // Reps never type keys: they upload the keys file their team lead sends.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    TeamKeysView(mode: .importKeys, firstRun: true, onClose: { screen = .coach })
                    Spacer(minLength: 0)
                }
            case .manualKeys:
                KeysView(onSave: { screen = .coach }, onCancel: { screen = .coach })
            case .coach:
                CoachView(
                    onAudioCheck: { proof.testAgain(); screen = .check },
                    onKeys: { screen = .manualKeys }
                )
            }
        }
        // The window opens at the coach's size (taller than wide, with the Aircall phone on the right
        // when it's showing) and can be dragged or zoomed bigger. It never gets smaller than this width.
        .frame(minWidth: minWindowWidth, idealWidth: minWindowWidth, maxWidth: .infinity,
               minHeight: 440, idealHeight: (NSScreen.main?.visibleFrame.height ?? 900) - 72, maxHeight: .infinity)
        // Show or hide the phone: the window grows or shrinks by the phone's width.
        .onChange(of: showPhone) { _, shown in
            let change = AircallPhoneSide.width - 1
            DispatchQueue.main.async {
                guard let window = NSApp.windows.first(where: { $0.title == "Clarity Live Coach" && $0.isVisible }) else { return }
                var frame = window.frame
                frame.size.width = max(381, frame.size.width + (shown ? change : -change))
                if let screen = window.screen?.visibleFrame, frame.maxX > screen.maxX {
                    frame.origin.x = max(screen.minX, screen.maxX - frame.width) // keep it on the screen
                }
                window.setFrame(frame, display: true, animate: true)
            }
        }
        .brandWindow()
    }

    /// The least width the coach needs: the column, plus the Aircall phone when it's showing.
    private var minWindowWidth: CGFloat { 380 + (showPhone ? AircallPhoneSide.width : 1) }

    private var showPhone: Bool {
        let current = screen ?? firstScreen
        return appPhone && phone.shown && (current == .coach || current == .check)
    }

    private var hasKeys: Bool { Keychain.read(.deepgram) != nil && Keychain.read(.anthropic) != nil }
    private var firstScreen: Screen { !audioCheckPassed && !audioCheckSkipped ? .check : (hasKeys || audioCheckSkipped ? .coach : .keys) }
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
                .foregroundStyle(Brand.blue)
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
    /// Redraws when Salesforce or Aircall connects or disconnects.
    @ObservedObject private var connections = Connections.shared
    @State private var showHelp = false
    @State private var showAircall = false
    @State private var showSetup = false
    @State private var showSettings = false
    /// The first-run tour: 0 = welcome card, 1...n = steps, nil = hidden.
    @State private var tourStep: Int?
    @AppStorage(PrefKey.tourSeen) private var tourSeen = false
    @StateObject private var updater = Updater()
    @AppStorage(PrefKey.repName) private var repName = ""
    private let showTouchpoints = true // always on
    @AppStorage(PrefKey.nextDials) private var nextDials = true
    @State private var listViewCache: [Salesforce.ListView] = []
    private let appPhone = true // always: the Aircall phone is inside the coach

    // One visual system: blue = actions, green = listening, amber = real warnings.
    private let margin: CGFloat = 16
    private let gap: CGFloat = 12
    private let listening = Color.green
    private let warning = Color.orange

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // As wide and tall as the window: the middle scrolls, nothing gets cut off.
            coachColumn.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                .overlayPreferenceValue(TourSpotKey.self) { spots in
                    TourOverlay(step: $tourStep, spots: spots) { tourSeen = true }
                }
            // The Aircall phone sits to the right. Hidden = 1 point wide, but still running.
            if appPhone { AircallPhoneSide() }
        }
        .frame(maxHeight: .infinity)
    }

    private var coachColumn: some View {
        VStack(alignment: .leading, spacing: gap) {
            topBar
            nowBar
            // The middle scrolls if it's ever taller than the screen; the top bar and the buttons stay put.
            ScrollViewReader { scroller in
            ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: gap) {
            // The Chrome list is the default. This header only shows if a Salesforce list was picked in Settings and tools.
            if Salesforce.isConnected && coach.leads.selected != nil { leadHeader }
            if coach.status != .ready {
                StageBar(steps: CoachModel.journey, current: coach.journeyStep, active: true)
            }
            scriptCard.tourScrollSpot(.line)
            ScriptOutlineCard(coach: coach).tourScrollSpot(.script)
            belowCard
            if coach.statusRecordID != nil { // stays up during calls too, with the LinkedIn and text cards
                RelationshipCard(coach: coach)
                    .id(coach.statusRecordID) // a fresh card per person: nothing picked carries over
                    .tourScrollSpot(.status)
            }
            if inTour && coach.followUp == nil {
                // The tour points here before any voicemail: show a sample card so the spot isn't empty.
                FollowUpCard(followUp: .constant(Optional(TourSample.followUp)), steps: TourSample.steps, canSend: true,
                             onSend: {}, onLinkedIn: {}, onLinkedInMessage: {}, onSetupAircall: {})
                    .allowsHitTesting(false)
                    .tourScrollSpot(.followUp)
            } else if coach.followUp != nil {
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
                .tourScrollSpot(.followUp)
            }
            if coach.status == .ready {
                DailyGoalCard(touchpoints: coach.touchpoints, activeCampaigns: campaigns.activeCampaigns)
                    .tourScrollSpot(.goal)
            }
            if showTouchpoints && coach.status == .ready {
                TouchpointsCard(touchpoints: coach.touchpoints).tourScrollSpot(.numbers)
            }
            warnings
            }
            }
            .scrollBounceBehavior(.basedOnSize)
            // The tour: bring the part it's pointing at into view.
            .onChange(of: tourStep) { _, step in
                guard let step, step >= 1, step <= Tour.steps.count else { return }
                withAnimation { scroller.scrollTo(Tour.steps[step - 1].spot.rawValue, anchor: .center) }
            }
            }
            Spacer(minLength: 0)
            if appPhone { AircallPhonePanel().tourSpot(.phone) }
            bottomBanner
            navigation.tourSpot(.call)
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
            if !tourSeen, coach.status == .ready { tourStep = 0 } // first open: the welcome card
            campaigns.ensureSelectedActive()
            coach.use(campaigns.selected)
            coach.activate(true)
            syncScriptToList()
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
        // The list open in Chrome decides the script: land on a campaign's list and its script follows.
        .onChange(of: coach.callList.listKey) { _, _ in syncScriptToList() }
        .onChange(of: coach.status) { _, status in
            syncScriptToList()
            if status != .ready { tourStep = nil } // never during a call
        }
        .onChange(of: campaigns.campaigns) { _, _ in campaigns.ensureSelectedActive(); syncScriptToList() }
        .sheet(isPresented: $showHelp) { HelpView() }
        .sheet(isPresented: $showSetup) {
            SetupView(onAudioCheck: onAudioCheck, onKeys: onKeys).environmentObject(coach)
        }
        .sheet(isPresented: $showSettings) { SettingsPane(updater: updater).environmentObject(coach) }
        .sheet(isPresented: $showAircall) { AircallSetupView() }
        .animation(.easeInOut(duration: 0.2), value: coach.status)
    }

    // MARK: What's happening now

    /// One plain line that always says what's happening and what to do next.
    private var nowLine: (text: String, color: Color) {
        switch coach.phase {
        case .live:
            switch coach.kind {
            case .voicemail: return ("Voicemail. Wait for the beep, then read the message.", warning)
            case .screener: return ("A robot answered. Say the line below.", warning)
            default: return ("On a call. Read the big line out loud.", listening)
            }
        case .paused: return ("Paused. The app is not listening.", warning)
        case .dialing: return ("Calling. Get ready to talk.", Brand.blue)
        case .countdown: return ("Calling the next person soon. Click Wait to stop.", Brand.blue)
        case .gettingReady: return ("Getting the next person ready.", Brand.blue)
        case .waitingForText: return ("Send the text below. Then the next person loads.", Brand.blue)
        case .idle: break
        }
        if listRanOut { return ("Nobody left to call on this list right now.", Brand.blue) }
        if !coach.leads.isActive && coach.callList.records.isEmpty {
            let setup = SetupView.doneCount(coach: coach)
            return setup.done < setup.total
                ? ("Start here: click the gear, then Set up.", warning)
                : ("Open your list in Salesforce, in Chrome.", warning)
        }
        if coach.shouldOfferRedial { return ("No answer. Click Redial to try one more time.", Brand.blue) }
        return ("Ready. Click Call.", listening)
    }

    private var nowBar: some View {
        let now = nowLine
        let plan = coach.status == .ready ? (coach.leads.isActive ? coach.leads.summary : coach.callList.summary) : nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(now.color).frame(width: 7, height: 7)
                Text(now.text).font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let plan {
                Text(plan).font(.caption2).foregroundStyle(.secondary)
                    .padding(.leading, 13)
                    .help("Late = behind on the 5 day plan. Resting = waiting for their next call day.")
            }
        }
    }

    // MARK: Top: campaign, status, settings

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            // One row for the three menus when they fit. If the window is narrow they wrap to two rows,
            // so nothing is ever pushed off the edge.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    campaignMenu.tourSpot(.segment)
                    Spacer(minLength: 0)
                    timeZoneMenu.tourSpot(.zone)
                    settingsMenu.tourSpot(.gear)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        campaignMenu.tourSpot(.segment)
                        Spacer(minLength: 0)
                        settingsMenu.tourSpot(.gear)
                    }
                    timeZoneMenu.tourSpot(.zone)
                }
            }
            // Updates get their own row, so the button always has room. It checks by itself every
            // 2 minutes and when the app is opened.
            updateBar
        }
        // No status, Voicemail or End call buttons here (the app handles those by itself).
        // Command-E still ends a call; Settings has both buttons.
        .background(
            Button("") { coach.endCall() }
                .keyboardShortcut("e", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }

    /// A long call list name shortened with "..." so the menu is never wider than the bar.
    private static func short(_ name: String, max: Int = 26) -> String {
        name.count > max ? String(name.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" : name
    }

    /// The walkthrough is on its "Stay up to date" step: show a sample bar if there's no real update.
    private var tourShowsUpdate: Bool {
        guard let step = tourStep, step >= 1, step <= Tour.steps.count else { return false }
        return Tour.steps[step - 1].spot == .update
    }

    @ViewBuilder private var updateBar: some View {
        if updater.updating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Updating. The app restarts by itself in about 2 minutes. Keep working.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Brand.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        } else if (updater.updateAvailable && coach.status == .ready) || tourShowsUpdate {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Brand.blue)
                Text("A new version is ready.").font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Button("Update now") { updater.update() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(!updater.updateAvailable)
                    .help("Installs the new version. Takes about 2 minutes. No Terminal.")
            }
            .padding(8)
            .background(Brand.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .tourSpot(.update)
        }
    }

    /// Only call people in one time zone. "All time zones" turns it off.
    private var timeZoneMenu: some View {
        let picked = TimeZoneFilter.selected
        return Menu {
            Button {
                coach.setTimeZoneFilter(nil)
            } label: {
                if picked == nil { Label("All time zones", systemImage: "checkmark") } else { Text("All time zones") }
            }
            // Only matters with all time zones: east to west, so nobody gets called before 9 there.
            Button {
                coach.setEastCoastFirst(!TimeZoneFilter.eastCoastFirst)
            } label: {
                if TimeZoneFilter.eastCoastFirst { Label("Start in the East, go West", systemImage: "checkmark") }
                else { Text("Start in the East, go West") }
            }
            .disabled(picked != nil)
            Divider()
            ForEach(CallZone.allCases) { zone in
                Button {
                    coach.setTimeZoneFilter(zone)
                } label: {
                    let title = "\(zone.label) · \(zone.timeNow) there now"
                    if picked == zone { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            Label(picked.map { "\($0.label) time" } ?? (TimeZoneFilter.eastCoastFirst ? "East first" : "All time zones"),
                  systemImage: "globe.americas.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(coach.status != .ready)
        .help(picked == nil
              ? "Where to call: pick one time zone, or start in the East and go West"
              : "Only calling people in \(picked?.label ?? "") time. People with no state or US number in Salesforce stay on the list.")
    }

    /// "Setup (5 of 7 done)" until everything is set up.
    private var setupLabel: String {
        let c = SetupView.doneCount(coach: coach)
        return c.done == c.total ? "Set up..." : "Set up (\(c.done) of \(c.total) done)..."
    }

    /// Three items only. Everything else lives in the Setup and Settings panes.
    private var settingsMenu: some View {
        Menu {
            Button(setupLabel) { showSetup = true }
            Button("Settings...") { showSettings = true }
            Button("Help") { showHelp = true }
            Button("Show me around") { tourStep = 0 }
                .disabled(coach.status != .ready)
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Pick a campaign, or create and edit one. Locked during a call.
    private var campaignMenu: some View {
        Menu {
            Button("All call lists...") {
                openWindow(id: "campaign-selector")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Divider()
            // Only the active campaigns (up to 3): pick one to call its list.
            if campaigns.activeCampaigns.isEmpty {
                Text("No call lists are turned on. Click All call lists... to turn one on.")
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
            Button("Edit this call list...") { edit(campaigns.selected) }
        } label: {
            Label(Self.short(campaigns.selected.name), systemImage: "person.2.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .disabled(coach.status != .ready)
        .help(coach.status == .ready ? "Who to call: pick a call list (people to call, plus what to say)" : "Finish the call to switch call lists")
    }

    /// Picks the active campaign whose Salesforce list is the one open in Chrome (between calls only).
    /// Chrome's address can hold the list's Id or its API name, so both are matched.
    private func syncScriptToList() {
        guard coach.status == .ready, let key = coach.callList.listKey?.view, !key.isEmpty else { return }
        Task {
            if listViewCache.isEmpty { listViewCache = (try? await Salesforce.listViews()) ?? [] }
            let openID = listViewCache.first { $0.id.prefix(15) == key.prefix(15) || $0.developerName == key }?.id ?? key
            guard coach.status == .ready,
                  let match = campaigns.campaigns.first(where: { $0.active && !$0.listViewID.isEmpty && $0.listViewID.prefix(15) == openID.prefix(15) }),
                  match.id != campaigns.selectedID else { return }
            ActivityLog.add("Campaign: the open list matches \(match.name), switching script")
            campaigns.selectedID = match.id
        }
    }

    /// Switches campaign (its script) and opens its Salesforce list in Chrome, so the app works that list.
    private func switchTo(_ campaign: Campaign) {
        campaigns.selectedID = campaign.id // its list opens via onChange below
        coach.listDone = false
    }

    private func openList(of campaign: Campaign) {
        guard !campaign.listViewID.isEmpty, !campaign.listObject.isEmpty else { return }
        // Already on that list in Chrome (the script just followed it): don't reload it.
        if let open = coach.callList.listKey?.view,
           open.prefix(15) == campaign.listViewID.prefix(15)
            || listViewCache.contains(where: { $0.developerName == open && $0.id.prefix(15) == campaign.listViewID.prefix(15) }) { return }
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
                    Button("Get new people from Salesforce") { Task { await coach.leads.reload() } }
                    Button("Use my Chrome list") { coach.leads.close() }
                } label: {
                    Text(coach.leads.selected?.label ?? "Pick a list").font(.caption.weight(.semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(coach.status != .ready)
                if coach.leads.loading { ProgressView().controlSize(.mini) }
                Spacer()
                if coach.leads.isActive {
                    Text("\(min(coach.leads.index + 1, coach.leads.rows.count)) of \(coach.leads.rows.count) · \(coach.leads.leftToCall) to call today")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let d = coach.leads.details {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(d.name).font(.headline).lineLimit(1)
                    Text([d.title, d.company, TimeZoneFilter.zone(of: d.id).map { "\($0.label) time" }]
                        .compactMap { $0 }.joined(separator: " · "))
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
                Text("Step 1: click \"Pick a list\" above and choose who to call.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: The hero: what to say

    private var scriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let d = coach.leads.details {
                let who = Salesforce.isPlaceholderName(d.name) ? (d.company ?? d.name) : d.name
                Label("Calling \(who)", systemImage: "phone.fill")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Brand.blue.opacity(0.25), in: Capsule())
            }
            HStack(spacing: 6) {
                Text(cardLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(coach.kind == .voicemail || coach.kind == .screener ? warning : Brand.teal)
                // Which script row (or which opener) this line is, so the rep learns what works.
                if let tag = coach.suggestion.rowTag {
                    tagChip(tag)
                } else if coach.kind == .opener, let name = coach.openerName {
                    tagChip(name)
                }
                Spacer()
                if coach.thinking && coach.status == .live {
                    ProgressView().controlSize(.mini)
                }
                if coach.historyIndex != nil {
                    Button("Latest") { coach.showLatest() }
                        .buttonStyle(.link).font(.caption2)
                } else if coach.status == .live {
                    Button("Different line ⌘J") { coach.newLine() }
                        .buttonStyle(.link).font(.caption2)
                        .help("Don't like this line? Get a new one right now.")
                }
            }
            Text(inTour && coach.status == .ready ? TourSample.line
                 : coach.suggestion.say.isEmpty
                 ? (Keychain.read(.anthropic) == nil ? "Almost there. Click the gear, then Set up, and upload your keys file." : "Getting your line ready...")
                 : coach.suggestion.say)
                .font(lineFont)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(lineIsSoft ? Color.secondary : Color.primary)
                .opacity(coach.historyIndex == nil ? 1 : 0.6)
            if let n = coach.meetingThisWeek, coach.status == .live {
                Text("Meeting \(n) this week")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.green)
                    .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.scriptCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .leading) {
            // Thin teal accent: the brand, without a bright panel behind the words.
            Rectangle().fill(Brand.teal).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.edge, lineWidth: 0.5))
        .overlay(MeetingGlow(trigger: coach.meetingMoments))
        .animation(.easeOut(duration: 0.15), value: coach.suggestion.say)
    }

    /// The line on the card: big and bold, or a little softer for a nudge.
    private var lineFont: Font {
        coach.suggestion.nudge ? Font.system(size: 22, weight: .medium) : Font.system(size: 26, weight: .semibold)
    }

    private var lineIsSoft: Bool { coach.suggestion.say.isEmpty || coach.suggestion.nudge }

    private func tagChip(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }

    /// The walkthrough is showing: sample info stands in where no list is loaded yet.
    private var inTour: Bool { tourStep != nil }

    private var cardLabel: String {
        if inTour && coach.status == .ready { return "WHEN THEY PICK UP" }
        if coach.historyIndex != nil { return "EARLIER LINE" }
        if coach.suggestion.nudge { return "IF IT GOES QUIET" }
        switch coach.kind {
        case .opener: return "WHEN THEY PICK UP"
        case .screener: return "A ROBOT ANSWERED · SAY THIS"
        case .voicemail: return "VOICEMAIL · WAIT FOR THE BEEP"
        case .reply: return "SAY THIS"
        }
    }

    // MARK: Right under the card: tip, meeting times, transcript

    private var belowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Phone tree: one click sends the keys Opus picked into the call.
            if coach.status == .live, coach.suggestion.stage == "Phone tree", !coach.suggestion.keys.isEmpty {
                HStack(spacing: 8) {
                    Button("Press \(coach.suggestion.keys)") { coach.pressKeys(coach.suggestion.keys) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    if let m = coach.keysMessage {
                        Text(m).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !coach.suggestion.cueText.isEmpty {
                Text(coach.suggestion.cueText)
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
            TranscriptSection(transcript: coach.transcript, open: $showTranscript)
        }
    }

    // MARK: Real warnings only, never cut off

    /// One warning at a time, the most important first. Nothing here while the bar above the
    /// buttons already shows a warning (the Chrome setting is shown there too, so not repeated).
    @ViewBuilder private var warnings: some View {
        if coach.callMessage == nil || (listRanOut) {
            if let problem = coach.problem {
                warningText(problem)
            } else if let message = coach.callList.message {
                warningText(message)
            } else if coach.callList.state == .needsChromeSetting, coach.status != .ready {
                VStack(alignment: .leading, spacing: 4) {
                    warningText("Chrome needs one setting. At the top of your screen: click View, then Developer, then Allow JavaScript from Apple Events.")
                    Button("Show me with pictures") { showSetup = true }
                        .buttonStyle(.link).font(.caption)
                }
            } else if let message = updater.message, !updater.updating,
                      message.hasPrefix("The update") || message.hasPrefix("Couldn't") {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
        .brandCard(radius: 10)
    }

    // MARK: Navigation: always here, always the same two buttons

    @ViewBuilder private var navigation: some View {
        if coach.status != .ready {
            // During a call: no stage buttons, just a way out if the app ever misses the hang-up.
            HStack(spacing: 8) {
                Button(role: .destructive) {
                    coach.endCall()
                } label: {
                    Label("End call", systemImage: "phone.down.fill").frame(maxWidth: .infinity)
                }
                .help("Is the call over, but the app is still listening? Click here. (Command-E)")
                if coach.status == .live {
                    Button("Voicemail") { coach.markVoicemail() }
                        .help("Is it a voicemail, and the app missed it? Click here to see your message.")
                }
            }
            .controlSize(.large)
        } else if inTour {
            // Walkthrough: a sample person, since no list is loaded yet.
            HStack(spacing: 8) {
                bigButton("Call \(TourSample.name)", icon: "phone.fill") {}
                smallButton("Call \(TourSample.next)") {}
            }
            .controlSize(.large)
            .allowsHitTesting(false)
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
                    Image(systemName: "chevron.left").frame(width: 16, height: 20)
                }
                .buttonStyle(BrandQuietButton())
                .disabled(!coach.leads.canGoBack)
                .help("Go back to the person before")

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
            .padding(.vertical, 2)
        }
        .buttonStyle(BrandPrimaryButton())
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout).lineLimit(1).frame(maxWidth: 120)
                .padding(.vertical, 2)
        }
        .buttonStyle(BrandQuietButton())
    }

    private var canCall: Bool {
        guard let d = coach.leads.details, !d.doNotCall, d.callNumber != nil, !coach.dialing else { return false }
        return Aircall.canPlaceCalls
    }

    private var callTitle: String {
        guard let d = coach.leads.details else { return "Loading..." }
        if d.doNotCall { return "Do Not Call" }
        if !Aircall.canPlaceCalls { return "Set up Aircall first (gear)" }
        return d.callNumber != nil ? "Call \(d.name)" : "No phone number"
    }

    /// During a call (or without the Salesforce list): Back and Next as before.
    private var stepNavigation: some View {
        HStack(spacing: 8) {
            Button {
                coach.status == .ready ? coach.previousLead() : coach.back()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 16, height: 20)
            }
            .buttonStyle(BrandQuietButton())
            .disabled(!backEnabled)
            .help(coach.status == .ready ? "Go back to the person before" : "Show the line before this one")

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
        guard let name = Screener.fullName(coach.calling) else { return "them" }
        // "Unknown Unknown" is a placeholder: show the company from the open page instead.
        if Salesforce.isPlaceholderName(name), let company = coach.recordCompany, !company.isEmpty { return company }
        return name
    }

    /// Nobody left to call today on this list (or a Salesforce list opened with nobody due).
    private var listRanOut: Bool {
        guard coach.status == .ready else { return false }
        // From the real list, not from a flag: people loaded, and none of them can be called right now.
        if coach.leads.isActive {
            return coach.leads.current == nil && !coach.leads.loading && !coach.leads.rows.isEmpty
        }
        return coach.callList.state == .endOfList
    }

    /// A Salesforce list that loaded with nobody on it who can be called (no phone, Do Not Call, taken off).
    private var listIsEmpty: Bool {
        coach.status == .ready && coach.leads.isActive && coach.leads.selected != nil
            && coach.leads.rows.isEmpty && !coach.leads.loading
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
        if listRanOut {
            let why = CalledToday.breakdown(coach.leads.isActive ? coach.leads.rows.map(\.id) : coach.callList.records.map(\.id))
            VStack(alignment: .leading, spacing: 8) {
                Text(why.calledToday > 0 ? "Nobody left to call right now on \(campaigns.selected.name). Nice work."
                                         : "Nobody is due to call right now on \(campaigns.selected.name).")
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(why.total) people on this list:")
                    if why.calledToday > 0 { Text("• \(why.calledToday) called today") }
                    if why.comeBackLater > 0 { Text("• \(why.comeBackLater) come back on another day (we call each person on day 1, 2, 5, 8 and 16)") }
                    if why.takenOff > 0 { Text("• \(why.takenOff) were taken off (no answer after a few tries, a bad number, or not interested)") }
                    if why.planDone > 0 { Text("• \(why.planDone) finished the 5 day plan, or already picked up") }
                }
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let zone = TimeZoneFilter.selected {
                    let held = coach.leads.isActive ? coach.leads.heldByTimeZone : coach.callList.heldByTimeZone
                    Text("You're only calling \(zone.label) time. \(held) more people are waiting in other time zones.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if held > 0 {
                        Button("Call all time zones") { coach.setTimeZoneFilter(nil) }
                    }
                }
                Text("Want to keep going? Add people to this list in Salesforce, or start your next list.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let next = nextCampaign {
                    Button("Start next list: \(next.name)") { switchTo(next) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("Pick another call list at the top.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        } else if listIsEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No one on \(coach.leads.selected?.label ?? "this list") can be called.")
                    .font(.callout.weight(.semibold))
                Text("Everyone is missing a phone number, is marked Do Not Call, or was taken off the list. Check the list in Salesforce, or pick another one.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
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
            .brandCard(radius: 10)
        } else if let hint = nextHint, !coach.leads.isActive {
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Why Next can't move on, shown as a line above the buttons (never squeezed into a button).
    private var nextHint: String? {
        guard coach.status == .ready else { return nil }
        switch coach.callList.state {
        case .needsList: return "Open your list in Salesforce, in Chrome. Then the app knows who to call next."
        case .needsChromeSetting: return "Chrome needs one setting. At the top of your screen: click View, then Developer, then Allow JavaScript from Apple Events."
        case .endOfList: return "You called everyone the app can see. Click Next to load more people."
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
                Text("Help").font(.title2.weight(.semibold))
                Text("New here? Click the gear, then \"Show me around\". It points at every button.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                section("1. Get ready (one time)", [
                    "Click the gear, then Set up. Do each step. Each one turns green when it's done.",
                    "Aircall phone (on the right): sign in one time and set yourself to Available. If it ever freezes: gear, then Settings, then Get help, then Reload the Aircall phone.",
                    "Open your list in Salesforce, in Chrome. The app reads it by itself.",
                ])
                section("2. Pick who to call", [
                    "At the top, click the call list name. A call list is people to call, plus what to say.",
                    "Next to it, pick a time zone. Or pick \"Start in the East, go West\".",
                ])
                section("3. Make a call", [
                    "Click the big Call button. The app calls their Mobile. If there's no Mobile, it calls their Phone.",
                    "Read the big line out loud. It changes each time they talk.",
                    "Tell them the call is being written down. Some states require it.",
                    "The app knows when the call ends. If it misses, click End call.",
                ])
                section("4. After the call", [
                    "No answer the first time: the app calls them one more time. Click Wait to stop it.",
                    "Voicemail: read the message on the screen after the beep.",
                    "Then go top to bottom: say how it went, send the LinkedIn note, then send the text.",
                    "Sending the text loads the next person. Then the app calls them after a short countdown.",
                    "Bad numbers are skipped for you.",
                ])
                section("5. The plan for each person", [
                    "We call each person on 5 days: day 1, 2, 5, 8 and 16. Two calls each day.",
                    "They get a voicemail on day 1. Texts go out on days 1, 2 and 16.",
                    "If they pick up, the plan stops for them.",
                ])
                section("6. Settings", [
                    "Gear, then Settings: turn \"Call the next person for me\" and \"Call each person twice\" on or off.",
                    "Gear, then Settings, then What's working: see which lines work best.",
                    "Something broken? Gear, then Settings, then Get help, then Send a problem report.",
                ])
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 370, height: 560)
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
/// Shown as a section of Script Lab.
struct ScoreboardView: View {
    @ObservedObject var book: OpenerBook
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which first line works best").font(.headline)
            Text("Each first line gets \(OpenerBook.warmUp) tries. After that, the app uses the best ones more often.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("First line").bold()
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
                            if row.opener.id == book.current.id { Image(systemName: "arrow.right.circle.fill").foregroundStyle(Brand.blue) }
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

            Button("Erase these scores", role: .destructive) { confirmReset = true }
                .confirmationDialog("Erase every first line's score?", isPresented: $confirmReset) {
                    Button("Reset", role: .destructive) { book.reset() }
                }
        }
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

                // LinkedIn, only on the plan's LinkedIn days. First touch (connect day): both the
                // connection note and the message, so neither waits on whether they're connected.
                // The plan's last call day: just the message.
                if f.linkedInDue || f.linkedinDone || f.linkedinMessageDone {
                    if !f.linkedInMessageFirst || f.linkedinDone {
                        row(done: f.linkedinDone, title: "LinkedIn connection note", message: f.linkedin) {
                            if f.linkedinDone {
                                Button("Open again") { onLinkedIn() }.buttonStyle(.link)
                            } else {
                                Button(f.linkedinURL == nil ? "Search LinkedIn + copy note" : "Open profile + copy note") { onLinkedIn() }
                                    .keyboardShortcut("l", modifiers: .command)
                                    .buttonStyle(.bordered)
                                    .disabled(f.linkedin.isEmpty)
                            }
                        }
                        if f.linkedinDone && !f.linkedinMessageDone {
                            Text("On their profile: click Connect, then Add a note. Right-click the box, click Paste, then Send.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
                    }
                }

                // Text: only on the plan's text day (the 2nd call day), never to Washington numbers.
                if f.textDue || f.textDone {
                row(done: f.textDone, title: "Text", message: f.text,
                    editable: !f.textDone && !f.text.isEmpty ? textBinding : nil) {
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
                                .disabled(f.text.isEmpty || f.phone.isEmpty || f.sending)
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
                if let status = f.textStatus {
                    Text(status).font(.caption)
                        .foregroundStyle(f.sending ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !f.textDue && !f.textDone && !f.linkedInDue {
                    Text("Nothing to send today. Texts go out on days 1, 2 and 16. The LinkedIn note goes out on day 1.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .brandCard(radius: 12)
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

    private func row<Actions: View>(done: Bool, title: String, message: String, editable: Binding<String>? = nil,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let editable {
                    // Click and type to change it before it goes out.
                    TextField("Text message", text: editable, axis: .vertical)
                        .font(.callout)
                        .textFieldStyle(.plain)
                        .lineLimit(2...10)
                        .padding(6)
                        .brandCard(radius: 6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
                        .help("Click to edit the text before you send it")
                } else {
                    Text(message.isEmpty ? "Writing..." : message)
                        .font(.callout)
                        .foregroundStyle(message.isEmpty || done ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions().font(.caption)
            }
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { followUp?.text ?? "" }, set: { new in
            guard followUp?.text != new else { return }
            followUp?.text = new
            followUp?.textEdited = true
        })
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
    @ObservedObject private var connections = Connections.shared
    @State private var picked: String?
    @State private var pickedFor: String?
    /// Lead + Unqualified: Salesforce requires a reason.
    @State private var reason: String?
    /// Folded: one line with the status and the call count. Opens on click.
    @AppStorage(PrefKey.statusCardOpen) private var open = true

    private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]

    /// "Calls: 2 of 4" (or "Calls: 3 · picked up" once someone answered).
    private func callsLabel(_ id: String) -> String {
        _ = coach.touchpoints.events.count // redraw after each call
        let p = DialHistory.person(id)
        if Cadence.pickedUp(id) { return "Calls: \(p.dials.count) · picked up" }
        _ = p
        return Cadence.label(for: id)
    }

    var body: some View {
        let object = coach.statusObject ?? "Contact"
        let current = picked ?? coach.recordStatus
        VStack(alignment: .leading, spacing: 8) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
                    Text("How did it go?").font(.callout.weight(.semibold))
                        .help(object == "Lead" ? "Saves to Lead Status in Salesforce" : "Saves to Relationship Status in Salesforce")
                    if !open, let current {
                        Text(current).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let id = coach.statusRecordID {
                        Text(callsLabel(id)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(Salesforce.statuses(object), id: \.self) { value in
                    Button {
                        picked = value
                        pickedFor = coach.statusRecordID
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: current == value ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(current == value ? Brand.blue : .secondary)
                            Text(value).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if object == "Lead", picked == "Unqualified", picked != coach.recordStatus {
                Picker("Reason", selection: $reason) {
                    Text("Pick a reason").tag(String?.none)
                    ForEach(Salesforce.unqualifiedReasons, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .font(.callout)
            }
            if let picked, Salesforce.removedStatuses.contains(picked), picked != coach.recordStatus {
                Text("Save this and we stop calling them.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button(coach.savingStatus ? "Saving..." : "Save") {
                    if let picked { coach.saveStatus(picked, unqualifiedReason: picked == "Unqualified" ? reason : nil) }
                }
                .buttonStyle(.bordered)
                .disabled(picked == nil || picked == coach.recordStatus || coach.savingStatus || !Salesforce.isConnected
                          || (object == "Lead" && picked == "Unqualified" && reason == nil))
                if !Salesforce.isConnected {
                    Text("To save, sign in to Salesforce: click the gear, then Set up.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let message = coach.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard(radius: 10)
        .onChange(of: coach.statusRecordID) {
            // New person on screen: start fresh.
            if pickedFor != coach.statusRecordID { picked = nil; pickedFor = nil; reason = nil }
        }
    }
}

/// The transcript under the script card. Watches only the transcript, so words streaming in
/// don't redraw the rest of the screen.
struct TranscriptSection: View {
    @ObservedObject var transcript: LiveTranscript
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
                    Text("Transcript").font(.caption)
                    if !open, let last = transcript.turns.last(where: { $0.speaker == .prospect }) {
                        Text("· \(last.text)").font(.caption).lineLimit(1).foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if open {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(transcript.turns) { turn in
                                line(turn.speaker, turn.text)
                            }
                            ForEach([Speaker.rep, .prospect], id: \.self) { speaker in
                                if let text = transcript.interim[speaker], !text.isEmpty {
                                    line(speaker, text).opacity(0.5)
                                }
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    .onChange(of: transcript.turns.count) { proxy.scrollTo("end") }
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
}

/// One soft green glow around the card when a meeting is booked. Fades in, holds, fades out.
struct MeetingGlow: View {
    let trigger: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.green, lineWidth: 2)
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { content, glow in
                content.opacity(glow).shadow(color: Color.green.opacity(glow * 0.5), radius: 8 * glow)
            } keyframes: { _ in
                CubicKeyframe(1.0, duration: 0.35)
                CubicKeyframe(1.0, duration: 0.8)
                CubicKeyframe(0.0, duration: 1.4)
            }
            .allowsHitTesting(false)
    }
}
