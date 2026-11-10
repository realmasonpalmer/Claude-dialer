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
    /// Converting and sending happen here, never on the audio thread.
    private let work = DispatchQueue(label: "clarity.process-tap-work", qos: .userInitiated)

    /// onBuffer runs on a background queue (one at a time, in order) with a copy of the audio.
    /// The audio thread itself only copies the samples: it's shared with the rep's headset,
    /// so any slow work there makes the call crackle.
    func start(processes: [AudioObjectID], onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        stop()
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.uuid = UUID()
            description.muteBehavior = .unmuted // the rep still hears the call
            description.isPrivate = true
            description.name = "Clarity Caller"

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
                kAudioAggregateDeviceNameKey: "Clarity Caller Tap",
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
            let work = self.work
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { _, inputData, _, _, _ in
                guard let view = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil),
                      view.frameLength > 0,
                      let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: view.frameLength) else { return }
                copy.frameLength = view.frameLength
                let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: view.audioBufferList))
                let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                for i in 0..<min(from.count, to.count) {
                    guard let src = from[i].mData, let dst = to[i].mData else { continue }
                    memcpy(dst, src, Int(min(from[i].mDataByteSize, to[i].mDataByteSize)))
                }
                work.async { onBuffer(copy) }
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
