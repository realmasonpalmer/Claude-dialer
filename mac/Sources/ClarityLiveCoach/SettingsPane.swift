import AppKit
import SwiftUI

/// Everything that used to crowd the gear menu, in one pane: how the coach behaves,
/// the call list, tools, and updates.
struct SettingsPane: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var coach: CoachModel
    @ObservedObject var updater: Updater

    @AppStorage("coachSpeed") private var speed = CoachSpeed.balanced.rawValue
    @AppStorage("wholeLine") private var wholeLine = true
    @AppStorage("nextDials") private var nextDials = true
    @AppStorage("showTouchpoints") private var showTouchpoints = true
    @AppStorage("appPhone") private var appPhone = true
    @AppStorage("coachBuiltInMic") private var builtInMic = true
    @State private var showScoreboard = false
    @State private var confirmReset = false
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings and tools").font(.title2.weight(.semibold))

                section("Coach") {
                    Picker("Speed", selection: $speed) {
                        ForEach(CoachSpeed.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Toggle("Show each line only once it's fully written", isOn: $wholeLine)
                    Toggle("Rotate proven openers", isOn: Binding(
                        get: { coach.openers.rotate },
                        set: { coach.openers.rotate = $0; coach.refreshOpener() }
                    ))
                    Toggle("Show touchpoints", isOn: $showTouchpoints)
                }

                section("Calling") {
                    Text("Auto-dial is the checkbox next to Aircall phone, at the bottom of the coach.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Aircall phone inside the coach", isOn: $appPhone)
                    if Salesforce.isConnected {
                        Picker("Call list", selection: Binding(
                            get: { coach.leads.selected?.id ?? "" },
                            set: { id in
                                if let view = coach.leads.views.first(where: { $0.id == id }) {
                                    Task { await coach.leads.open(view) }
                                } else {
                                    coach.leads.close()
                                }
                            }
                        )) {
                            Text("The list open in Chrome").tag("")
                            ForEach(coach.leads.views) { Text($0.title).tag($0.id) }
                        }
                        .disabled(coach.status != .ready)
                    }
                    Text("21-day plan: 2 dials on days 1, 2, 5, 8 and 16. Voicemail on day 1. Texts on days 1, 2 and 16. LinkedIn request on day 1. People come off the list when the plan ends or they pick up.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Reset everyone's call counts...") { confirmReset = true }
                        .confirmationDialog("Reset everyone's call counts?", isPresented: $confirmReset) {
                            Button("Reset", role: .destructive) {
                                DialHistory.resetAll()
                                note = "Call counts reset. Everyone is back on the list."
                            }
                        } message: {
                            Text("People taken off for too many calls or bad numbers come back on your list. This can't be undone.")
                        }
                    Button("Reset who's been called today") {
                        coach.callList.clearCalledToday()
                        coach.leads.clearCalledToday()
                        note = "Everyone on your list can be called again today."
                    }
                }

                section("Audio") {
                    Toggle("Coach hears you with the Mac's built-in mic", isOn: $builtInMic)
                    Text("Best with Bluetooth headphones: Aircall keeps the headset mic to itself, so calls and the hang-up tone don't glitch. Takes effect on the next call.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("During a call") {
                    HStack {
                        Button(coach.status == .paused ? "Resume" : "Pause") { coach.togglePause() }
                            .disabled(coach.status == .ready)
                        Button("Start listening now (new call)") { coach.startByHand(); dismiss() }
                    }
                    HStack {
                        Button("It's a voicemail") { coach.markVoicemail(); dismiss() }
                            .disabled(coach.status != .live)
                        Button("End call") { coach.endCall(); dismiss() }
                            .disabled(coach.status == .ready)
                    }
                }

                section("Tools") {
                    HStack {
                        Button(coach.lab.hasNewSuggestions ? "Script Lab (new)" : "Script Lab") {
                            openWindow(id: "script-lab")
                            NSApplication.shared.activate(ignoringOtherApps: true)
                        }
                        Button("Opener scoreboard") { showScoreboard = true }
                    }
                    HStack {
                        Button("Copy activity log") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ActivityLog.recent(), forType: .string)
                            note = "Copied the last 400 lines. Paste it to whoever is helping you."
                        }
                        Button("Send bug report") {
                            Task { note = await BugReporter.manual() }
                        }
                        Button("Copy help info") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(coach.callList.debugReport(), forType: .string)
                            note = "Copied. Paste it to whoever is helping you."
                        }
                    }
                    if let note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 380, height: 620)
        .sheet(isPresented: $showScoreboard) { ScoreboardView(book: coach.openers) }
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
