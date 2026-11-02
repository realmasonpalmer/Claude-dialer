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
    @State private var showScoreboard = false
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings and tools").font(.title2.weight(.semibold))

                section("Coach") {
                    Picker("Speed", selection: $speed) {
                        ForEach(CoachSpeed.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Toggle("Show each line all at once", isOn: $wholeLine)
                    Toggle("Rotate proven openers", isOn: Binding(
                        get: { coach.openers.rotate },
                        set: { coach.openers.rotate = $0; coach.refreshOpener() }
                    ))
                    Toggle("Show touchpoints", isOn: $showTouchpoints)
                }

                section("Calling") {
                    Toggle("Next calls right away", isOn: $nextDials)
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
                    Button("Reset who's been called today") {
                        coach.callList.clearCalledToday()
                        coach.leads.clearCalledToday()
                        note = "Everyone on your list can be called again today."
                    }
                }

                section("During a call") {
                    HStack {
                        Button(coach.status == .paused ? "Resume" : "Pause") { coach.togglePause() }
                            .disabled(coach.status == .ready)
                        Button("Start listening now (new call)") { coach.startByHand(); dismiss() }
                    }
                }

                section("Tools") {
                    HStack {
                        Button(coach.lab.hasNewSuggestions ? "Script Lab (new)" : "Script Lab") {
                            openWindow(id: "script-lab")
                            NSApplication.shared.activate(ignoringOtherApps: true)
                        }
                        Button("Opener scoreboard") { showScoreboard = true }
                        Button("Copy Next debug info") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(coach.callList.debugReport(), forType: .string)
                            note = "Copied. Paste it to whoever is helping you."
                        }
                    }
                }

                section("Updates") {
                    HStack {
                        Button(updater.updateAvailable ? "Install update" : "Check for updates") {
                            if updater.updateAvailable { updater.update() } else { Task { await updater.check(byHand: true) } }
                        }
                        .disabled(updater.updating)
                        if let message = updater.message {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 440, height: 620)
        .sheet(isPresented: $showScoreboard) { ScoreboardView(book: coach.openers) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.semibold))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
