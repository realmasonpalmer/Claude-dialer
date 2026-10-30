import AppKit
import AVFoundation
import Combine
import CoreAudio

/// Phase 1 audio proof: capture the rep's mic and Chrome's call audio as two
/// separate streams, show who is talking, and optionally save a short test recording.
@MainActor
final class ProofModel: ObservableObject {
    enum Source: Hashable {
        case chrome
        case process(pid_t)
    }

    @Published var micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var processes: [AudioProcess] = []
    @Published var source: Source = .chrome
    @Published var isCapturing = false
    @Published var repLevel: Float = 0
    @Published var prospectLevel: Float = 0
    @Published var prospectBuffers = 0 // proves the tap delivers audio even when the call is quiet
    @Published var isRecording = false
    @Published var recordingsFolder: URL?
    @Published var error: String?

    private let capture = CaptureEngine()
    private var timer: Timer?

    /// Chrome uses the mic and plays sound at the same time only while a call is live.
    var chromeOnCall: Bool {
        let chrome = processes.filter(\.isChrome)
        return chrome.contains(where: \.isRunningInput) && chrome.contains(where: \.isRunningOutput)
    }

    var talking: String {
        let threshold: Float = 0.35
        if repLevel < threshold && prospectLevel < threshold { return "No one" }
        if repLevel >= threshold && prospectLevel >= threshold { return "Both" }
        return repLevel > prospectLevel ? "You" : "Prospect"
    }

    func onAppear() {
        refreshProcesses()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshProcesses() }
        }
        if !micAllowed {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in self.micAllowed = granted }
            }
        }
    }

    func refreshProcesses() {
        processes = AudioProcess.all()
            .filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
            .sorted { $0.name < $1.name }
    }

    func start() {
        error = nil
        refreshProcesses()
        let targets: [AudioObjectID]
        switch source {
        case .chrome: targets = processes.filter(\.isChrome).map(\.id)
        case .process(let pid): targets = processes.filter { $0.pid == pid }.map(\.id)
        }
        guard !targets.isEmpty else {
            error = source == .chrome
                ? "Chrome isn't using audio yet. Open Aircall in Chrome, then try again."
                : "That app isn't using audio right now."
            return
        }
        do {
            try capture.start(processes: targets) { [weak self] isRep, value in
                Task { @MainActor in
                    guard let self else { return }
                    if isRep {
                        self.repLevel = value
                    } else {
                        self.prospectLevel = value
                        self.prospectBuffers += 1
                    }
                }
            }
            isCapturing = true
        } catch {
            stop()
            self.error = error.localizedDescription
        }
    }

    func stop() {
        capture.stop()
        stopRecording()
        isCapturing = false
        repLevel = 0
        prospectLevel = 0
    }

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

    /// onLevel(isRep, level) is called from audio threads for every converted chunk.
    func start(processes: [AudioObjectID], onLevel: @escaping (Bool, Float) -> Void) throws {
        let micConverter = self.micConverter, tapConverter = self.tapConverter, writers = self.writers
        do {
            try mic.start { buffer in
                guard let speech = micConverter.convert(buffer) else { return }
                writers.write(speech, isRep: true)
                onLevel(true, level(of: speech))
            }
            try tap.start(processes: processes) { buffer in
                guard let speech = tapConverter.convert(buffer) else { return }
                writers.write(speech, isRep: false)
                onLevel(false, level(of: speech))
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
