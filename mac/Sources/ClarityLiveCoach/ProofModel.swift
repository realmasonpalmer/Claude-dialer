import AppKit
import AVFoundation
import Combine
import CoreAudio

/// Phase 1 audio check, as a guided walk-through. Each step checks itself and
/// moves on automatically: mic allowed, call connected, rep heard, prospect heard.
@MainActor
final class ProofModel: ObservableObject {
    enum Source: Hashable {
        case chrome
        case process(pid_t)
    }

    enum Step: Int, CaseIterable {
        case mic, call, you, prospect, done
    }

    /// Louder than this counts as someone talking (about -36 dB).
    private let speechLevel: Float = 0.4
    /// Seconds of speech needed to pass a step.
    private let speechNeeded = 1.0

    @Published private(set) var step: Step = .mic
    @Published private(set) var stepStartedAt = Date()
    @Published private(set) var now = Date()
    @Published private(set) var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var processes: [AudioProcess] = []
    @Published var source: Source = .chrome
    @Published private(set) var isCapturing = false
    @Published private(set) var repLevel: Float = 0
    @Published private(set) var prospectLevel: Float = 0
    @Published private(set) var repSpeech = 0.0
    @Published private(set) var prospectSpeech = 0.0
    @Published private(set) var bothSpeech = 0.0
    @Published private(set) var notice: String?
    @Published private(set) var isRecording = false
    @Published private(set) var recordingsFolder: URL?
    @Published var error: String?

    private let capture = CaptureEngine()
    private var timer: Timer?
    private var startedByHand = false
    private var quietTicks = 0

    var secondsOnStep: TimeInterval { now.timeIntervalSince(stepStartedAt) }

    /// Chrome uses the mic and plays sound at the same time only while a call is live.
    var chromeOnCall: Bool { AudioProcess.chromeOnCall(in: processes) }

    /// True when the rep's mic also hears the prospect (speakers instead of a headset).
    var micHearsCall: Bool { prospectSpeech > 0 && bothSpeech / prospectSpeech > 0.4 }

    func onAppear() {
        refreshProcesses()
        guard timer == nil else { advance(); return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if micStatus == .notDetermined { allowMic() }
        advance()
    }

    func allowMic() {
        if micStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in
                    self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                    self.advance()
                }
            }
        } else {
            openSettings("Privacy_Microphone")
        }
    }

    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func tick() {
        now = Date()
        refreshProcesses()
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        // Start listening by itself the moment the Aircall call connects.
        if step == .call, !isCapturing, source == .chrome, chromeOnCall {
            startCapture()
        }
        // Call ended before the check finished: go back and wait for a new one.
        if isCapturing, !startedByHand, step != .done {
            quietTicks = chromeOnCall ? 0 : quietTicks + 1
            if quietTicks >= 6 {
                stopCapture()
                notice = "The call ended. Start another test call to finish."
                go(.call)
            }
        }
        advance()
    }

    private func refreshProcesses() {
        processes = AudioProcess.all()
            .filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
            .sorted { $0.name < $1.name }
    }

    private func advance() {
        switch step {
        case .mic where micStatus == .authorized: go(.call)
        case .call where isCapturing: go(.you)
        case .you where repSpeech >= speechNeeded: go(.prospect)
        case .prospect where prospectSpeech >= speechNeeded:
            go(.done)
            stopCapture()
        default: break
        }
    }

    private func go(_ next: Step) {
        guard next != step else { return }
        if next == .you { repSpeech = 0; notice = nil }
        if next == .prospect { prospectSpeech = 0; bothSpeech = 0 }
        step = next
        stepStartedAt = Date()
        now = stepStartedAt
    }

    /// Manual fallback when the call isn't detected automatically.
    func startByHand() {
        startedByHand = true
        startCapture()
        advance()
    }

    /// Restarts listening, e.g. after turning on System Audio Recording.
    func retry() {
        stopCapture()
        startCapture()
        stepStartedAt = Date()
    }

    func testAgain() {
        stopCapture()
        startedByHand = false
        notice = nil
        go(micStatus == .authorized ? .call : .mic)
    }

    private func startCapture() {
        error = nil
        refreshProcesses()
        let targets: [AudioObjectID]
        switch source {
        case .chrome: targets = processes.filter(\.isChrome).map(\.id)
        case .process(let pid): targets = processes.filter { $0.pid == pid }.map(\.id)
        }
        guard !targets.isEmpty else {
            error = source == .chrome
                ? "Chrome isn't playing any sound yet. Start the Aircall call first."
                : "That app isn't playing any sound right now."
            return
        }
        do {
            try capture.start(processes: targets) { [weak self] isRep, speech in
                let value = level(of: speech)
                let seconds = Double(speech.frameLength) / speechFormat.sampleRate
                Task { @MainActor in self?.heard(isRep: isRep, level: value, seconds: seconds) }
            }
            isCapturing = true
            quietTicks = 0
        } catch {
            stopCapture()
            self.error = error.localizedDescription
        }
    }

    private func stopCapture() {
        capture.stop()
        stopRecording()
        isCapturing = false
        repLevel = 0
        prospectLevel = 0
    }

    private func heard(isRep: Bool, level: Float, seconds: Double) {
        guard isCapturing else { return }
        let talking = level >= speechLevel
        if isRep {
            repLevel = level
            if talking, step == .you { repSpeech += seconds }
        } else {
            prospectLevel = level
            if talking, step == .prospect {
                prospectSpeech += seconds
                if repLevel >= speechLevel { bothSpeech += seconds }
            }
        }
        advance()
    }

    // MARK: Optional test recording (Advanced)

    func toggleRecording() {
        if isRecording { stopRecording(); return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClarityLiveCoach-proof", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try capture.writers.open(rep: folder.appendingPathComponent("you.wav"), prospect: folder.appendingPathComponent("prospect.wav"))
            recordingsFolder = folder
            isRecording = true
        } catch {
            self.error = "Could not start test recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        capture.writers.close()
        isRecording = false
    }

    func showRecordings() {
        guard let folder = recordingsFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    func deleteRecordings() {
        stopRecording()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClarityLiveCoach-proof")
        try? FileManager.default.removeItem(at: root)
        recordingsFolder = nil
    }
}

/// Owns the two audio streams. Not tied to the main thread: audio arrives on real-time threads.
final class CaptureEngine {
    private let mic = MicCapture()
    private let tap = ProcessTap()
    private let micConverter = SpeechConverter()
    private let tapConverter = SpeechConverter()
    let writers = WriterBox()

    /// onChunk(isRep, speech) is called from audio threads with each 16 kHz mono chunk.
    /// The buffer is safe to keep: it is a fresh conversion output.
    func start(processes: [AudioObjectID], onChunk: @escaping (Bool, AVAudioPCMBuffer) -> Void) throws {
        let micConverter = self.micConverter, tapConverter = self.tapConverter, writers = self.writers
        do {
            try mic.start { buffer in
                guard let speech = micConverter.convert(buffer) else { return }
                writers.write(speech, isRep: true)
                onChunk(true, speech)
            }
            try tap.start(processes: processes) { buffer in
                guard let speech = tapConverter.convert(buffer) else { return }
                writers.write(speech, isRep: false)
                onChunk(false, speech)
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        mic.stop()
        tap.stop()
    }
}

/// Thread-safe holder for the two test-recording files.
final class WriterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rep: WavWriter?
    private var prospect: WavWriter?

    func open(rep repURL: URL, prospect prospectURL: URL) throws {
        let r = try WavWriter(url: repURL)
        let p = try WavWriter(url: prospectURL)
        lock.lock(); defer { lock.unlock() }
        rep = r
        prospect = p
    }

    func write(_ buffer: AVAudioPCMBuffer, isRep: Bool) {
        lock.lock(); defer { lock.unlock() }
        (isRep ? rep : prospect)?.write(buffer)
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        rep = nil
        prospect = nil
    }
}
