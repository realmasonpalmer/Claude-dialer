import AVFoundation
import CoreAudio

/// Captures the sound one or more apps are playing (for us: Chrome running Aircall),
/// using Core Audio process taps (macOS 14.4+). Works with any output device,
/// including Bluetooth and USB headsets, because it taps the app before the device.
final class ProcessTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "clarity.process-tap", qos: .userInteractive)

    /// onBuffer runs on a real-time audio queue. The buffer is only valid during the call: copy or convert it there.
    func start(processes: [AudioObjectID], onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        stop()
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.uuid = UUID()
            description.muteBehavior = .unmuted // the rep still hears the call
            description.isPrivate = true
            description.name = "Clarity Live Coach"

            var tap = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateProcessTap(description, &tap), "Create process tap")
            tapID = tap

            var streamDescription = try readProperty(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw CoreAudioError(status: -1, what: "Read tap format")
            }

            // A private aggregate device lets us read the tap like a microphone.
            let outputUID = try defaultOutputDeviceUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Clarity Live Coach Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            var device = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "Create aggregate device")
            aggregateID = device

            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { _, inputData, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else { return }
                onBuffer(buffer)
            }, "Create IO proc")
            procID = proc

            try check(AudioDeviceStart(aggregateID, procID), "Start tap")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}
