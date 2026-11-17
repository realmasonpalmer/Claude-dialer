import AppKit
import SwiftUI

/// Settings and tools: the coach's speed, plus tools for checking results and getting help.
struct SettingsPane: View {
    /// Redraws when Salesforce or Aircall connects or disconnects.
    @ObservedObject private var connections = Connections.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var coach: CoachModel
    @ObservedObject var updater: Updater

    @AppStorage(PrefKey.coachSpeed) private var speed = CoachSpeed.balanced.rawValue
    @AppStorage(PrefKey.nextDials) private var autoDial = true
    @AppStorage(PrefKey.doubleTap) private var doubleTap = true
    @AppStorage(PrefKey.autoLinkedIn) private var autoLinkedIn = false
    @AppStorage(PrefKey.autoText) private var autoText = true
    private func runLinkedInTest(really: Bool) {
        guard let url = URL(string: testProfile.trimmingCharacters(in: .whitespaces)), url.host?.contains("linkedin.com") == true else {
            testResult = "That doesn't look like a LinkedIn profile link."
            return
        }
        testing = true
        testResult = nil
        Task { @MainActor in
            LinkedInBot.testRun = !really
            let r = await LinkedInBot.connect(profile: url, note: LinkedInBot.note("", first: Screener.firstName(coach.followUp?.prospect) ?? "there"),
                                              company: testCompany.isEmpty ? nil : testCompany) { testResult = $0 }
            LinkedInBot.testRun = false
            testing = false
            switch r {
            case .sent: testResult = "SENT. The connection request went out with the note."
            case .alreadyConnected: testResult = "Already connected. Try someone you're not connected to."
            case .pending: testResult = "Request already pending. Try someone else."
            case .skipped(let why): testResult = why
            case .blocked(let why): testResult = "Stopped: \(why)"
            }
            ActivityLog.add("LinkedIn bot \(really ? "real send" : "test"): \(testResult ?? "")")
        }
    }

    @State private var audioRecording = false
    @State private var testProfile = ""
    @State private var testCompany = ""
    @State private var testing = false
    @State private var confirmSend = false
    @State private var testResult: String?
    @AppStorage(PrefKey.voicemailDropOn) private var dropOn = false
    @State private var confirmReset = false
    @State private var note: String?

    // Always on, no switch: lines show once fully written, openers rotate, touchpoints show,
    // the Aircall phone is inside the coach, and the coach hears you with the Mac's built-in mic.

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.title2.weight(.semibold))

            section("Calling") {
                Toggle("Send texts by itself", isOn: $autoText)
                Text("On: the text goes out in the background while the next person loads.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Drop my recorded voicemail by itself", isOn: $dropOn)
                Text("Set it up first: gear, then Voicemail drop.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            section("Audio problems") {
                Text("Records 60 seconds of everything your Mac plays (what you hear), plus the call audio the app gets, and a report of your audio devices and their speeds. Start it, then make a call. Saved in Documents, Clarity Audio Debug. Nothing is sent anywhere.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(audioRecording ? "Recording..." : "Record audio for debugging (60 s)") {
                        audioRecording = true
                        Task { @MainActor in
                            let dir = await AudioDebug.shared.record()
                            audioRecording = false
                            if let dir { NSWorkspace.shared.open(dir) }
                        }
                    }
                    .disabled(audioRecording)
                }
            }
            section("Test the LinkedIn bot") {
                Text("Uses the person on screen now (their LinkedIn from Salesforce), or paste any profile. It does everything except Send, then cancels. Nothing goes out.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("https://www.linkedin.com/in/...", text: $testProfile)
                HStack {
                    Button(testing ? "Testing..." : "Test it") { runLinkedInTest(really: false) }
                    .disabled(testing || LinkedInBot.running)
                    .onAppear {
                        let d = coach.leads.details
                        if testProfile.isEmpty, let url = coach.followUp?.linkedinURL ?? d?.linkedIn { testProfile = url.absoluteString }
                        if testCompany.isEmpty { testCompany = d?.company ?? coach.recordCompany ?? "" }
                    }
                    Button("Send for real") { confirmSend = true }
                        .disabled(testing || LinkedInBot.running)
                        .help("Sends one real connection request with the note.")
                        .confirmationDialog("Send a real LinkedIn connection request to this person?", isPresented: $confirmSend) {
                            Button("Send it") { runLinkedInTest(really: true) }
                            Button("Cancel", role: .cancel) {}
                        }
                    if let testResult { Text(testResult).font(.caption).fixedSize(horizontal: false, vertical: true) }
                }
            }

            section("Coach") {
                Picker("How fast lines show up", selection: $speed) {
                    ForEach(CoachSpeed.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }

            section("Tools") {
                // Script Lab holds the call results, script suggestions and the opener scoreboard.
                Button(coach.lab.hasNewSuggestions ? "What's working (new ideas)" : "What's working") {
                    openWindow(id: "script-lab")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                HStack {
                    Menu("Get help") {
                        Button("Reload the Aircall phone") {
                            AircallPhone.shared.reload()
                            note = "Reloaded the Aircall phone on the right. Sign in again if it asks."
                        }
                        Button("Send a problem report") {
                            Task { note = await BugReporter.manual() }
                        }
                        Button("Copy info for support") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(coach.callList.debugReport() + "\n\n" + ActivityLog.recent(), forType: .string)
                            note = "Copied. Paste it to whoever is helping you."
                        }
                    }
                    .fixedSize()
                    Menu("Start over") {
                        Button("Let me call today's people again") {
                            coach.callList.clearCalledToday()
                            coach.leads.clearCalledToday()
                            note = "Everyone on your list can be called again today."
                        }
                        Button("Erase everyone's call counts...") { confirmReset = true }
                    }
                    .fixedSize()
                }
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .confirmationDialog("Erase everyone's call counts?", isPresented: $confirmReset) {
            Button("Erase", role: .destructive) {
                DialHistory.resetAll()
                note = "Call counts erased. Everyone is back on the list."
            }
        } message: {
            Text("People who were taken off for too many calls or bad numbers come back on your list. You can't undo this.")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.semibold))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard(radius: 10)
    }
}
