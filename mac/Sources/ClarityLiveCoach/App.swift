import AppKit
import SwiftUI

@main
struct ClarityLiveCoachApp: App {
    @StateObject private var proof = ProofModel()

    var body: some Scene {
        WindowGroup("Clarity Live Coach") {
            AudioCheckView()
                .environmentObject(proof)
                .frame(width: 360)
                .onAppear {
                    proof.onAppear()
                    keepOnTop()
                }
        }
        .windowResizability(.contentSize)
    }

    /// Float above Salesforce so the coach is always visible.
    private func keepOnTop() {
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                window.level = .floating
                window.collectionBehavior.insert(.canJoinAllSpaces)
            }
        }
    }
}

/// One step at a time. Each step says what to do, checks itself, and moves on.
/// Help appears only when a step takes longer than it should.
struct AudioCheckView: View {
    @EnvironmentObject var model: ProofModel
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                ProgressDots(step: model.step)
                    .padding(.top, 4)

                Image(systemName: icon)
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(model.step == .done ? Color.green : Color.accentColor)
                    .symbolEffect(.pulse, isActive: model.step == .call)
                    .frame(height: 52)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                stepContent

                if let notice = model.notice, model.step == .call {
                    Text(notice).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                if showHelp {
                    help
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .animation(.easeInOut(duration: 0.25), value: model.step)
            .animation(.easeInOut(duration: 0.25), value: showHelp)

            Divider()
            advanced
        }
    }

    // MARK: Step copy

    private var icon: String {
        switch model.step {
        case .mic: return "mic.circle"
        case .call: return "phone.arrow.up.right"
        case .you: return "person.wave.2"
        case .prospect: return "person.2.wave.2"
        case .done: return "checkmark.circle.fill"
        }
    }

    private var title: String {
        switch model.step {
        case .mic: return "Let the coach hear you"
        case .call: return "Make a test call"
        case .you: return "Say something"
        case .prospect: return "Now have them talk"
        case .done: return "You're all set"
        }
    }

    private var detail: String {
        switch model.step {
        case .mic: return "The coach needs your microphone to hear your side of the call."
        case .call: return "Call a teammate from Aircall in Salesforce. This screen moves on by itself when the call connects."
        case .you: return "Say \"Testing, one, two, three.\""
        case .prospect: return "Ask your teammate to say a few words."
        case .done: return "The coach can hear you and the prospect, each on their own. You can hang up."
        }
    }

    // MARK: Step content

    @ViewBuilder private var stepContent: some View {
        switch model.step {
        case .mic:
            Button("Allow microphone") { model.allowMic() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .call:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for your call").foregroundStyle(.secondary)
            }
        case .you:
            LevelMeter(label: "You", level: model.repLevel, progress: model.repSpeech)
        case .prospect:
            LevelMeter(label: "Your teammate", level: model.prospectLevel, progress: model.prospectSpeech)
        case .done:
            VStack(spacing: 10) {
                if model.micHearsCall {
                    Text("Tip: your mic also picks up the call. A headset keeps the two voices apart.")
                        .font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                Button("Test again") { model.testAgain() }
                    .controlSize(.large)
            }
        }
    }

    // MARK: Help, shown only when a step is slow

    private var showHelp: Bool {
        switch model.step {
        case .call: return model.secondsOnStep > 20
        case .you, .prospect: return model.secondsOnStep > 10
        default: return false
        }
    }

    @ViewBuilder private var help: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Not working?").font(.headline)
            switch model.step {
            case .call:
                Text("Already on the call? Start listening yourself.")
                Button("I'm on a call. Start listening") { model.startByHand() }
                Text("Using the Aircall desktop app instead of Chrome? Open Advanced below and pick it.")
                    .font(.callout).foregroundStyle(.secondary)
            case .you:
                Text("Check your headset is the input in System Settings > Sound > Input.")
            case .prospect:
                Text("Turn on Clarity Live Coach under \"System Audio Recording Only\", then press Try again.")
                HStack {
                    Button("Open settings") { model.openSettings("Privacy_ScreenCapture") }
                    Button("Try again") { model.retry() }
                }
            default:
                EmptyView()
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Advanced (hidden by default)

    private var advanced: some View {
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Hear the call from", selection: $model.source) {
                    Text("Google Chrome").tag(ProofModel.Source.chrome)
                    ForEach(model.processes.filter { !$0.isChrome && $0.isRunningOutput }) { process in
                        Text(process.name).tag(ProofModel.Source.process(process.pid))
                    }
                }
                .disabled(model.isCapturing)

                HStack {
                    Button(model.isRecording ? "Stop test recording" : "Record a test") { model.toggleRecording() }
                        .disabled(!model.isCapturing)
                    if model.recordingsFolder != nil {
                        Button("Show") { model.showRecordings() }
                        Button("Delete", role: .destructive) { model.deleteRecordings() }
                    }
                }
                Text("Recordings stay on this Mac. Only record calls where everyone agreed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .font(.callout)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

/// Four dots: where you are in the check.
struct ProgressDots: View {
    let step: ProofModel.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach([ProofModel.Step.mic, .call, .you, .prospect], id: \.self) { dot in
                Capsule()
                    .fill(dot.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: dot == step ? 22 : 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }
}

/// A live loudness bar plus a check that fills as we hear enough speech.
struct LevelMeter: View {
    let label: String
    let level: Float
    let progress: Double // seconds of speech heard; 1.0 passes

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.callout.weight(.medium))
                Spacer()
                Text(level > 0.4 ? "Sound coming through" : "Listening")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(8, geo.size.width * CGFloat(level)))
                }
            }
            .frame(height: 12)
            .animation(.linear(duration: 0.08), value: level)
            ProgressView(value: min(progress, 1))
                .tint(.green)
        }
    }
}
