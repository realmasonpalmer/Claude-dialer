import AppKit
import SwiftUI
import CoachCore

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
    @AppStorage(PrefKey.autoText) private var autoText = true
    @AppStorage("linkedInBotSend") private var autoLinkedInRequest = true
    @AppStorage(PrefKey.voicemailDropOn) private var dropOn = false
    @AppStorage(Think.defaultsKey) private var thinkOn = true
    @State private var confirmReset = false
    @State private var note: String?

    // Always on, no switch: lines show once fully written, openers rotate, touchpoints show,
    // the Aircall phone is inside the coach, and the coach hears you with the Mac's built-in mic.

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.title2.weight(.semibold))

            section("Coach card") {
                Toggle("Short thoughts on the card (THINK)", isOn: $thinkOn)
                Text("On: during a call the card shows one short thought from your script's backbone, in words you can say. Command-Shift-L shows the full line. Lines word for word from the script always show in full.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            section("Help") {
                Menu("Get help") {
                    Button("Reload the Aircall phone") {
                        AircallPhone.shared.reload()
                        note = "Reloaded the Aircall phone on the right. Sign in again if it asks."
                    }
                    Button("Copy info for support") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(coach.callList.debugReport() + "\n\n" + ActivityLog.recent(), forType: .string)
                        note = "Copied. Paste it to whoever is helping you."
                    }
                }
                .fixedSize()
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
