import SwiftUI

/// One place for every one-time setup step, in order, with a check mark when it's done.
/// Each "Set up" button opens that step's own screen.
struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var coach: CoachModel
    var onAudioCheck: () -> Void
    var onKeys: () -> Void

    @AppStorage("repName") private var repName = ""
    @AppStorage("audioCheckPassed") private var audioCheckPassed = false
    @State private var showAircall = false
    @State private var showSalesforce = false
    @State private var showCalendar = false
    @State private var askName = false
    @State private var refresh = 0 // re-checks the steps after a setup screen closes

    struct Step: Identifiable {
        let id: String
        let title: String
        let detail: String
        let done: Bool
        let optional: Bool
        let action: () -> Void
    }

    @MainActor static func doneCount(coach: CoachModel) -> (done: Int, total: Int) {
        let required = [
            !(UserDefaults.standard.string(forKey: "repName") ?? "").isEmpty,
            Keychain.read(.deepgram) != nil && Keychain.read(.anthropic) != nil,
            UserDefaults.standard.bool(forKey: "audioCheckPassed"),
            coach.callList.state != .needsChromeSetting,
            Salesforce.isConnected,
            Aircall.canPlaceCalls,
            coach.availability.feedInput != nil,
        ]
        return (required.filter { $0 }.count, required.count)
    }

    private var steps: [Step] {
        _ = refresh
        return [
            Step(id: "name", title: "1. Your first name",
                 detail: repName.isEmpty ? "So openers say \"this is [you]\"." : "Openers say \"this is \(repName)\".",
                 done: !repName.isEmpty, optional: false) { askName = true },
            Step(id: "keys", title: "2. AI keys (Anthropic + Deepgram)",
                 detail: "Claude writes your lines. Deepgram hears the call.",
                 done: Keychain.read(.deepgram) != nil && Keychain.read(.anthropic) != nil, optional: false) {
                dismiss(); onKeys()
            },
            Step(id: "audio", title: "3. Audio check",
                 detail: "Makes sure the app hears you and the person you call.",
                 done: audioCheckPassed, optional: false) {
                dismiss(); onAudioCheck()
            },
            Step(id: "chrome", title: "4. Chrome setting",
                 detail: "In Chrome: View > Developer > Allow JavaScript from Apple Events. Lets the app read your Salesforce list.",
                 done: coach.callList.state != .needsChromeSetting, optional: false) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Google Chrome.app"))
            },
            Step(id: "salesforce", title: "5. Salesforce",
                 detail: Salesforce.isConnected ? "Signed in. Saves Relationship Status and Lead Status." : "Sign in through Chrome. Needed to save statuses.",
                 done: Salesforce.isConnected, optional: false) { showSalesforce = true },
            Step(id: "aircall", title: "6. Aircall calling and texting",
                 detail: "Calls from the app and sends follow-up texts.",
                 done: Aircall.canPlaceCalls, optional: false) { showAircall = true },
            Step(id: "calendar", title: "7. Booking calendar",
                 detail: "The app offers real open times on the call.",
                 done: coach.availability.feedInput != nil, optional: false) { showCalendar = true },
        ]
    }

    var body: some View {
        let list = steps
        let done = list.filter(\.done).count
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Setup").font(.title2.weight(.semibold))
                Text("\(done) of \(list.count) done. Do these once. Come back here any time to change something.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(list) { step in
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
                        Button(step.done ? "Change" : "Set up", action: step.action)
                            .buttonStyle(.bordered)
                            .tint(step.done ? nil : .accentColor)
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 440, height: 620)
        .sheet(isPresented: $showAircall, onDismiss: { refresh += 1 }) { AircallSetupView() }
        .sheet(isPresented: $showSalesforce, onDismiss: { refresh += 1 }) {
            SalesforceConnectView(onConnected: { Task { await coach.leads.start() } })
        }
        .sheet(isPresented: $showCalendar, onDismiss: { refresh += 1 }) {
            BookingCalendarView(availability: coach.availability)
        }
        .alert("Your first name", isPresented: $askName) {
            TextField("First name", text: $repName)
            Button("Save") { coach.refreshOpener(); refresh += 1 }
        }
    }
}
