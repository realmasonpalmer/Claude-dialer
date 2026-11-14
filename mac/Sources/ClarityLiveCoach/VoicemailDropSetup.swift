import SwiftUI

/// Guides the rep through recording their first voicemail drop in Aircall (Settings > Call settings >
/// Voicemail drop), gives them a script to read, checks the app can find the drop button, and turns
/// on the automatic drop. Opens from Set up, the gear menu, and the one-time nudge.
struct VoicemailDropSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PrefKey.voicemailDropOn) private var on = false
    @State private var kind = 0
    @State private var copied = false
    @State private var checking = false
    @State private var checkResult: String?
    @State private var checkOK = false

    private var rep: String { Prefs.repName.isEmpty ? "[your name]" : Prefs.repName }

    /// About 15 seconds read out loud. No name for them: the same message plays for everyone.
    private var script: String {
        kind == 0
            ? "Hi, this is \(rep) with Clarity Consulting. We help teams that live on client calls get hours back every week. After every call, AI fills in the CRM for them. I'm sending you a quick text with my number. Talk soon."
            : "Hi, this is \(rep) with Clarity Consulting. We helped a tax firm of ten get back about 2,000 hours a year by ending call note typing. I'm sending you a quick text with my number. Talk soon."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Voicemail drop").font(.title2.weight(.semibold))
                Text("Record one message once. On a voicemail day, the app drops it for you after the beep. You skip about 20 seconds of talking on every voicemail.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                step(1, "Open Aircall's call settings") {
                    Button("Take me there") { AircallPhone.shared.openCallSettings() }
                    Text("Or click the gear at the bottom of the Aircall phone, then Call settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Already recorded one? Skip to step 4.").font(.caption).foregroundStyle(.secondary)
                }
                step(2, "Add your message") {
                    Text("Under Voicemail drop, click Add a message. Then click Record a message, or Upload a file if you already have a recording.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                step(3, "Read this script (about 15 seconds)") {
                    Picker("", selection: $kind) {
                        Text("General").tag(0)
                        Text("Tax firms").tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(script)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Brand.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button(copied ? "Copied" : "Copy script") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(script, forType: .string)
                            copied = true
                        }
                        Spacer()
                    }
                    Text("Don't say their name: the same message plays for everyone. Save it, then make it the Default one. The Default is the one the app drops.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                step(4, "Check the app can find the button") {
                    Text("Make a call to your own cell phone from the Aircall phone. While it's ringing, click this.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(checking ? "Looking..." : "Check the button") {
                            checking = true
                            Task {
                                let r = await AircallPhone.shared.dropVoicemail(dryRun: true)
                                checkOK = r.clicked
                                checkResult = r.clicked ? "Found it. The app can drop your message."
                                                        : "Couldn't find it. Is a call on? If it is, tell Mason: the app wrote the button names in the activity log."
                                checking = false
                            }
                        }
                        .disabled(checking)
                        if checkResult != nil { Image(systemName: checkOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(checkOK ? Color.green : Color.orange) }
                    }
                    if let checkResult { Text(checkResult).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                step(5, "Turn it on") {
                    Toggle("I recorded it. Drop it by itself on voicemail days.", isOn: $on)
                        .toggleStyle(.checkbox)
                    Text(on ? "On. After the greeting and the beep, the app clicks the drop button, then moves on."
                            : "Off. You'll read your voicemail yourself.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 400, height: 640)
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Circle().fill(Brand.blue))
                Text(title).font(.callout.weight(.semibold))
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard(radius: 10)
    }
}
