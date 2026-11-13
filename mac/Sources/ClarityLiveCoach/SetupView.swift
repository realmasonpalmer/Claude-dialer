import SwiftUI

/// One place for every one-time setup step, in order, with a check mark when it's done.
/// Each "Set up" button opens that step's own screen.
struct SetupView: View {
    /// Redraws when Salesforce or Aircall connects or disconnects.
    @ObservedObject private var connections = Connections.shared
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var coach: CoachModel
    var onAudioCheck: () -> Void
    var onKeys: () -> Void

    @AppStorage(PrefKey.repName) private var repName = ""
    @AppStorage(PrefKey.audioCheckPassed) private var audioCheckPassed = false
    @State private var showAircall = false
    @State private var showSalesforce = false
    @State private var showCalendar = false
    @State private var askName = false
    @State private var askWebhook = false
    @State private var webhookText = Keychain.read(.bugWebhook) ?? ""
    @State private var refresh = 0 // re-checks the steps after a setup screen closes
    @State private var teamKeys: TeamKeysView.Mode?
    @State private var showMore = false

    struct Step: Identifiable {
        let id: String
        let title: String
        let detail: String
        let done: Bool
        let optional: Bool
        let action: () -> Void
    }

    /// Step-by-step instructions for each setup item, in plain words.
    struct Guide {
        let steps: [String]
        let links: [(String, String)]
    }

    static let guides: [String: Guide] = [
        "name": Guide(steps: [
            "Click Set up.",
            "Type your first name the way you say it on calls (for example: Mason).",
            "Click Save. Your first line now says \"this is Mason from Clarity.\"",
        ], links: []),
        "keys": Guide(steps: [
            "Anthropic (Claude writes your lines):",
            "1. Open the Anthropic Console (link below) and sign in with your work email.",
            "2. Click Settings, then API Keys, then Create Key.",
            "3. Name it \"Clarity Live Coach\" and click Add. Copy the key. It starts with sk-ant- and is shown only once.",
            "4. Make sure the account has credits: Settings, then Billing. About $5 to $15 covers a month of calls.",
            "Deepgram (hears the call):",
            "5. Open the Deepgram Console (link below) and sign up. New accounts get free credit.",
            "6. Click API Keys on the left, then Create a New API Key.",
            "7. Name it \"Clarity Live Coach\", keep the role Member, set it to never expire, then Create. Copy the key (shown only once).",
            "In the app:",
            "8. Click Set up here, paste both keys and click Save. They're stored in your Mac's Keychain.",
        ], links: [("Anthropic Console", "https://console.anthropic.com/settings/keys"),
                   ("Deepgram Console", "https://console.deepgram.com")]),
        "audio": Guide(steps: [
            "1. Put on the headphones you call with. Open Aircall (in the coach or the Aircall app).",
            "2. Click Set up. When macOS asks to use the Microphone, click Allow.",
            "3. When macOS asks about System Audio Recording, click Open System Settings and turn on Clarity Live Coach. Then come back.",
            "4. Follow the check on screen: say a sentence, then play a short sound or test call so the app hears the other side.",
            "5. Both meters should move. If one doesn't: System Settings, then Privacy & Security, then Microphone and Screen & System Audio Recording, and make sure Clarity Live Coach is on.",
            "With Bluetooth headphones the coach hears you through the Mac's built-in mic. That's on purpose.",
        ], links: [("Privacy settings", "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")]),
        "chrome": Guide(steps: [
            "1. Open Google Chrome.",
            "2. In the menu bar at the top of the screen, click View, then Developer, then Allow JavaScript from Apple Events. A check mark shows next to it.",
            "3. Open Salesforce in Chrome and go to your call list (a Lead or Contact list view).",
            "4. The first time, macOS asks: \"Clarity Live Coach wants to control Google Chrome.\" Click OK.",
            "5. Missed that box? System Settings, then Privacy & Security, then Automation, then Clarity Live Coach, and turn on Google Chrome.",
        ], links: [("Automation settings", "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")]),
        "salesforce": Guide(steps: [
            "Clarity already has the app in Salesforce. It's called Clarity Power Dialer. You just need its Consumer Key.",
            "1. In Salesforce, click the gear (top right), then Setup.",
            "2. In Quick Find, type External Client App Manager and open it.",
            "3. Click Clarity Power Dialer, then the Settings tab, then OAuth Settings.",
            "4. Make sure the Callback URL is exactly: \(ChromeLogin.redirectURI)",
            "5. Make sure \"Require Proof Key for Code Exchange (PKCE)\" is checked, and both \"Require secret...\" boxes are unchecked.",
            "6. Click Consumer Key and Secret. Salesforce emails you a code. Enter it, then copy the Consumer Key.",
            "7. Click Set up here, paste the Consumer Key and click Sign in to Salesforce.",
            "8. Chrome opens Salesforce. You're already logged in, so just click Allow. Chrome says \"Signed in.\" Close that tab.",
            "No admin access? Ask Oliver or Ian to do steps 1 to 6 and send you the Consumer Key.",
        ], links: [("Salesforce Setup", "https://clarityconsultingllc.my.salesforce.com/lightning/setup/SetupOneHome/home")]),
        "aircall": Guide(steps: [
            "API keys (needs an Aircall admin):",
            "1. Open the Aircall Dashboard (link below) and sign in.",
            "2. Click Integrations & API, then API Keys, then Generate an API key.",
            "3. Copy the API ID and the API Token. The token is shown only once.",
            "In the app:",
            "4. Click Set up, paste the API ID and API Token, and click Connect.",
            "5. Pick the Aircall number you call and text from (Oliver's Portland Aircall Number).",
            "6. Pick yourself under \"Calls are made as,\" so calls ring on your line.",
            "7. Send a test text to your own cell to make sure texting works.",
            "The phone itself:",
            "8. In the Aircall phone panel (right side of the coach), sign in with your Aircall login and set yourself to Available.",
            "Texting through the app needs Aircall's Professional plan. If the test text fails, the message says why.",
        ], links: [("Aircall Dashboard", "https://dashboard.aircall.io")]),
        "bugs": Guide(steps: [
            "Problems (a call that won't start, listening that fails, Claude or Aircall errors) are sent to a private Slack channel with the app's recent log. Phone numbers are hidden except the last 4 digits.",
            "1. In Slack, make a private channel, for example #live-coach-bugs.",
            "2. Open the Slack app directory link below and create an app (From scratch). Name it \"Live Coach Bugs\" and pick the Clarity workspace.",
            "3. Click Incoming Webhooks, turn it On, then Add New Webhook to Workspace. Pick #live-coach-bugs and click Allow.",
            "4. Copy the Webhook URL (starts with https://hooks.slack.com/services/).",
            "5. Click Set up here, paste it and click Save.",
            "6. Test it: click the gear, then Settings, then Get help, then Send a problem report. A message shows in the channel.",
            "Each teammate pastes the same link, so everyone's reports land in one place.",
        ], links: [("Slack app directory", "https://api.slack.com/apps")]),
        "calendar": Guide(steps: [
            "The app offers real open times on the call, from Oliver's booking page.",
            "1. Click Set up.",
            "2. Paste the Calendly link: https://calendly.com/clarity_consulting",
            "3. Click Save. The app reads Oliver's open times and offers two on each call.",
            "Using a Google Calendar instead: in Google Calendar, click the gear, then Settings, pick the calendar on the left, scroll to Integrate calendar, and copy \"Secret address in iCal format.\" Paste that instead.",
        ], links: [("Clarity Calendly", "https://calendly.com/clarity_consulting")]),
    ]

    /// Team keys are in: Claude, Deepgram and Aircall work.
    static var hasTeamKeys: Bool {
        Keychain.read(.deepgram) != nil && Keychain.read(.anthropic) != nil && Aircall.isSetUp
    }

    /// The steps a new rep does: import team keys, audio check, Chrome. Plus Salesforce sign-in
    /// and their Aircall line, only if the keys file couldn't cover them.
    @MainActor static func doneCount(coach: CoachModel) -> (done: Int, total: Int) {
        var required = [
            hasTeamKeys,
            UserDefaults.standard.bool(forKey: PrefKey.audioCheckPassed),
            (coach.callList.state != .needsChromeSetting && !coach.callList.records.isEmpty),
        ]
        if hasTeamKeys && !Salesforce.isConnected { required.append(false) }
        if Aircall.isSetUp && Aircall.userID == nil { required.append(false) }
        else if Prefs.repName.isEmpty { required.append(false) }
        return (required.filter { $0 }.count, required.count)
    }

    /// The main steps, in order.
    private var steps: [Step] {
        _ = refresh
        var list = [
            Step(id: "team", title: "1. Import team keys",
                 detail: Self.hasTeamKeys ? "Claude, Deepgram, Aircall and the booking calendar are set."
                                          : "Your team lead sends a keys file and a passcode. One step sets up everything.",
                 done: Self.hasTeamKeys, optional: false) { teamKeys = .importKeys },
            Step(id: "audio", title: "2. Audio check",
                 detail: "Makes sure the app hears you and the person you call.",
                 done: audioCheckPassed, optional: false) {
                dismiss(); onAudioCheck()
            },
            Step(id: "chrome", title: "3. Chrome setting",
                 detail: "In Chrome's top menu: View, then Developer, then Allow JavaScript from Apple Events. This lets the app read your list. Click \"Show me how\" for pictures.",
                 done: (coach.callList.state != .needsChromeSetting && !coach.callList.records.isEmpty), optional: false) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Google Chrome.app"))
            },
        ]
        // Only when the keys file didn't cover them.
        if Self.hasTeamKeys && !Salesforce.isConnected {
            list.append(Step(id: "salesforce", title: "Sign in to Salesforce",
                             detail: "One click: Chrome opens Salesforce, you click Allow.",
                             done: false, optional: false) { showSalesforce = true })
        }
        if Aircall.isSetUp && Aircall.userID == nil {
            list.append(Step(id: "aircall", title: "Pick yourself in Aircall",
                             detail: "So calls ring on your line. Your first name comes from it too.",
                             done: false, optional: false) { showAircall = true })
        } else if repName.isEmpty {
            list.append(Step(id: "name", title: "Your first name",
                             detail: "So your first line says \"this is [you]\".",
                             done: false, optional: false) { askName = true })
        }
        return list
    }

    /// Everything else: set one thing by hand, or share keys with a new rep.
    private var moreSteps: [Step] {
        _ = refresh
        return [
            Step(id: "name", title: "Your first name",
                 detail: repName.isEmpty ? "So your first line says \"this is [you]\"." : "Your first line says \"this is \(repName)\".",
                 done: !repName.isEmpty, optional: true) { askName = true },
            Step(id: "keys", title: "AI keys (Anthropic + Deepgram)",
                 detail: "Claude writes your lines. Deepgram hears the call.",
                 done: Keychain.read(.deepgram) != nil && Keychain.read(.anthropic) != nil, optional: true) {
                dismiss(); onKeys()
            },
            Step(id: "salesforce", title: "Salesforce",
                 detail: Salesforce.isConnected ? "Signed in. Saves Relationship Status and Lead Status."
                                                : "Your own Salesforce (like Darren's): the guide walks you through it.",
                 done: Salesforce.isConnected, optional: true) { showSalesforce = true },
            Step(id: "aircall", title: "Aircall calling and texting",
                 detail: "Calls from the app and sends follow-up texts.",
                 done: Aircall.canPlaceCalls, optional: true) { showAircall = true },
            Step(id: "calendar", title: "Booking calendar",
                 detail: "The app offers real open times on the call.",
                 done: coach.availability.feedInput != nil, optional: true) { showCalendar = true },
            Step(id: "bugs", title: "Bug reports",
                 detail: BugReporter.isOn ? "On: problems are sent to your Slack bug channel." : "Sends problems to a private Slack channel so they get fixed fast.",
                 done: BugReporter.isOn, optional: true) { askWebhook = true },
            Step(id: "export", title: "Share team keys",
                 detail: "Save every key on this Mac into one locked file for a new rep.",
                 done: false, optional: true) { teamKeys = .exportKeys },
        ]
    }

    private func row(_ step: Step) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(step.done ? Color.green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title).font(.callout.weight(.semibold))
                    Text(step.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(step.id == "export" ? "Export" : step.done ? "Change" : "Set up", action: step.action)
                    .buttonStyle(.bordered)
                    .tint(step.done || step.optional ? nil : Brand.blue)
            }
            if step.id == "chrome" {
                DisclosureGroup("Show me how") {
                    ChromeSettingGuide().padding(.top, 6)
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.top, -4)
            }
            if let guide = Self.guides[step.id] {
                DisclosureGroup("How to set this up") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(guide.steps.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.callout)
                                .fontWeight(line.hasSuffix(":") ? .semibold : .regular)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        ForEach(Array(guide.links.enumerated()), id: \.offset) { _, link in
                            if let url = URL(string: link.1) {
                                Link("Open \(link.0)", destination: url).font(.callout)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.top, -4)
            }
        }
        .padding(10)
        .brandCard(radius: 10)
    }

    var body: some View {
        let list = steps
        let done = list.filter(\.done).count
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Set up").font(.title2.weight(.semibold))
                Text(done == list.count ? "All set. Come back here any time to change something."
                                        : "\(done) of \(list.count) done. Do these once.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(list) { row($0) }
                DisclosureGroup(isExpanded: $showMore) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(moreSteps) { row($0) }
                    }
                    .padding(.top, 8)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Advanced settings").font(.callout.weight(.semibold))
                        Text("Only change these if you know what you're doing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 380, height: 640)
        .sheet(item: $teamKeys, onDismiss: { refresh += 1 }) { mode in
            TeamKeysView(mode: mode).environmentObject(coach)
        }
        .sheet(isPresented: $showAircall, onDismiss: { refresh += 1 }) { AircallSetupView() }
        .sheet(isPresented: $showSalesforce, onDismiss: { refresh += 1 }) {
            SalesforceConnectView(onConnected: { Task { await coach.leads.start() } })
        }
        .sheet(isPresented: $showCalendar, onDismiss: { refresh += 1 }) {
            BookingCalendarView(availability: coach.availability)
        }
        .alert("Slack link for bug reports", isPresented: $askWebhook) {
            TextField("https://hooks.slack.com/services/...", text: $webhookText)
            Button("Save") {
                let link = webhookText.trimmingCharacters(in: .whitespacesAndNewlines)
                if link.isEmpty { Keychain.delete(.bugWebhook) } else { Keychain.save(link, for: .bugWebhook) }
                refresh += 1
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paste the Incoming Webhook link for your private bug channel. Leave it empty to turn reports off.")
        }
        .alert("Your first name", isPresented: $askName) {
            TextField("First name", text: $repName)
            Button("Save") { coach.refreshOpener(); refresh += 1 }
        }
    }
}
