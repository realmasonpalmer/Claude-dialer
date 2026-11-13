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
    @State private var confirmReset = false
    @State private var note: String?

    // Always on, no switch: lines show once fully written, openers rotate, touchpoints show,
    // the Aircall phone is inside the coach, and the coach hears you with the Mac's built-in mic.

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.title2.weight(.semibold))

            section("Calling") {
                Toggle("Call the next person for me", isOn: $autoDial)
                Text("On: after you send the text, the next person loads and the app calls them after a short countdown.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Call each person twice", isOn: $doubleTap)
                Text("On: if they don't pick up, the app calls them one more time right away.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
