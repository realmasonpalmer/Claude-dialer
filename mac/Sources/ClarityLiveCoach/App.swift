import AppKit
import SwiftUI

@main
struct ClarityLiveCoachApp: App {
    @StateObject private var proof = ProofModel()

    var body: some Scene {
        WindowGroup("Clarity Live Coach") {
            ProofView()
                .environmentObject(proof)
                .frame(width: 380)
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

struct ProofView: View {
    @EnvironmentObject var model: ProofModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Audio check").font(.title2.bold())
            Text("Start a test call in Aircall, then press Start. Talk, and have the other person talk.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                status("Microphone access", ok: model.micAllowed,
                       fix: "Allow in System Settings > Privacy & Security > Microphone")
                status("Call detected in Chrome", ok: model.chromeOnCall,
                       fix: "Chrome is not using the mic and speaker right now")
                if model.isCapturing {
                    status("Call audio arriving", ok: model.prospectBuffers > 0,
                           fix: "No audio from the tap yet. Allow System Audio Recording when asked")
                }
            }

            Picker("Hear the call from", selection: $model.source) {
                Text("Google Chrome (Aircall)").tag(ProofModel.Source.chrome)
                ForEach(model.processes.filter { !$0.isChrome && $0.isRunningOutput }) { process in
                    Text(process.name).tag(ProofModel.Source.process(process.pid))
                }
            }
            .disabled(model.isCapturing)

            meter("You (mic)", model.repLevel)
            meter("Prospect (call audio)", model.prospectLevel)
            HStack {
                Text("Talking now:").foregroundStyle(.secondary)
                Text(model.talking).font(.title3.bold())
            }

            HStack {
                Button(model.isCapturing ? "Stop" : "Start") {
                    model.isCapturing ? model.stop() : model.start()
                }
                .keyboardShortcut(.defaultAction)
                Button(model.isRecording ? "Stop test recording" : "Record test") { model.toggleRecording() }
                    .disabled(!model.isCapturing)
            }

            if model.recordingsFolder != nil {
                HStack {
                    Button("Show recordings") { model.showRecordings() }
                    Button("Delete recordings", role: .destructive) { model.deleteRecordings() }
                }
                Text("Two files: you.wav and prospect.wav. Each should hold only one voice.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            Text("Only record calls where everyone agreed. Test recordings stay on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
    }

    private func status(_ label: String, ok: Bool, fix: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if !ok { Text(fix).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func meter(_ label: String, _ value: Float) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint).frame(width: geo.size.width * CGFloat(value))
                }
            }
            .frame(height: 10)
            .animation(.linear(duration: 0.08), value: value)
        }
    }
}
