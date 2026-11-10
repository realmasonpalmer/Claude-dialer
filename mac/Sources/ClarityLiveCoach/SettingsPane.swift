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
    @State private var showScoreboard = false
    @State private var confirmReset = false
    @State private var note: String?

    // Always on, no switch: lines show once fully written, openers rotate, touchpoints show,
    // the Aircall phone is inside the coach, and the coach hears you with the Mac's built-in mic.

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings and tools").font(.title2.weight(.semibold))

            section("Coach") {
                Picker("Speed", selection: $speed) {
                    ForEach(CoachSpeed.allCases) { Text($0.label).tag($0.rawValue) }
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
                    Menu("Get help") {
                        Button("Send bug report") {
                            Task { note = await BugReporter.manual() }
                        }
                        Button("Copy activity log") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ActivityLog.recent(), forType: .string)
                            note = "Copied the last 400 lines. Paste it to whoever is helping you."
                        }
                        Button("Copy help info") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(coach.callList.debugReport(), forType: .string)
                            note = "Copied. Paste it to whoever is helping you."
                        }
                    }
                    .fixedSize()
                    Menu("Reset") {
                        Button("Who's been called today") {
                            coach.callList.clearCalledToday()
                            coach.leads.clearCalledToday()
                            note = "Everyone on your list can be called again today."
                        }
                        Button("Everyone's call counts...") { confirmReset = true }
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
        .confirmationDialog("Reset everyone's call counts?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                DialHistory.resetAll()
                note = "Call counts reset. Everyone is back on the list."
            }
        } message: {
            Text("People taken off for too many calls or bad numbers come back on your list. This can't be undone.")
        }
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
