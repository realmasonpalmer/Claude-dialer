import AVFoundation
import AudioToolbox
import CoreAudio

/// The format speech-to-text services want: 16 kHz, mono, 16-bit.
let speechFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

/// Converts any incoming buffer (48 kHz stereo float, Bluetooth 16 kHz...) to speechFormat.
final class SpeechConverter {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: speechFormat)
            converter?.downmix = true
            inputFormat = buffer.format
        }
        guard let converter, buffer.frameLength > 0 else { return nil }
        let ratio = speechFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: capacity) else { return nil }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Loudness from 0 (silent) to 1 (very loud), for meters and "who is talking".
func level(of buffer: AVAudioPCMBuffer) -> Float {
    guard let samples = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return 0 }
    var sum: Float = 0
    for i in 0..<Int(buffer.frameLength) {
        let s = Float(samples[i]) / Float(Int16.max)
        sum += s * s
    }
    let rms = (sum / Float(buffer.frameLength)).squareRoot()
    let db = 20 * log10(max(rms, 0.000_01))
    return min(max((db + 60) / 60, 0), 1) // -60 dB..0 dB -> 0..1
}

/// The rep's microphone, read straight from the mic with Core Audio. Input only, on purpose:
/// it never opens a speaker. (AVAudioEngine, used before, also opened an output device and
/// could build a hidden mic + speaker combo, which pulled call sound to the wrong speakers.)
/// Where sound plays is left 100% to the Mac's Sound settings.
final class MicCapture {
    private var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "clarity.mic", qos: .userInteractive)
    /// Converting and sending happen here, never on the audio thread.
    private let work = DispatchQueue(label: "clarity.mic-work", qos: .userInitiated)

    /// - Parameter device: a specific microphone (like the Mac's built-in one); nil = the Mac's chosen input.
    func start(device: AudioDeviceID? = nil, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        stop()
        let id = try device ?? readProperty(AudioObjectID(kAudioObjectSystemObject),
                                            kAudioHardwarePropertyDefaultInputDevice, AudioDeviceID(kAudioObjectUnknown))
        guard id != kAudioObjectUnknown else {
            throw CoreAudioError(status: -1, what: "Open microphone (no input device)")
        }
        guard let stream = try inputStreams(of: id).first else {
            throw CoreAudioError(status: -1, what: "Open microphone (no input on this device)")
        }
        let asbd = try readProperty(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32
        guard asbd.mSampleRate > 0, asbd.mBytesPerFrame > 0, asbd.mChannelsPerFrame > 0, isFloat,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: 1, interleaved: false) else {
            throw CoreAudioError(status: -1, what: "Read microphone format (\(asbd.mChannelsPerFrame) ch, \(asbd.mBitsPerChannel) bit, \(Int(asbd.mSampleRate)) Hz)")
        }
        let bytesPerFrame = asbd.mBytesPerFrame
        // Interleaved: channels side by side, step over them. Not interleaved: one channel per buffer.
        let channels = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : Int(asbd.mChannelsPerFrame)
        let work = self.work
        var proc: AudioDeviceIOProcID?
        // Only reads inputData. Never writes outputData, so no speaker is ever used.
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, id, queue) { _, inputData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard list.count > 0, let src = list[0].mData else { return } // the first input stream
            let frames = AVAudioFrameCount(list[0].mDataByteSize / bytesPerFrame)
            guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let dst = copy.floatChannelData?[0] else { return }
            copy.frameLength = frames
            // Interleaved floats: keep the first channel.
            let samples = src.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(frames) { dst[i] = samples[i * channels] }
            work.async { onBuffer(copy) }
        }, "Open microphone")
        deviceID = id
        procID = proc
        do {
            try check(AudioDeviceStart(id, proc), "Start microphone")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if deviceID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        deviceID = AudioDeviceID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private func inputStreams(of device: AudioDeviceID) throws -> [AudioStreamID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size), "Find microphone streams")
        var list = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard !list.isEmpty else { return [] }
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &list), "Read microphone streams")
        return list
    }
}

/// Writes one speechFormat WAV file. Used only by the audio proof.
final class WavWriter {
    private let file: AVAudioFile
    let url: URL

    init(url: URL) throws {
        self.url = url
        file = try AVAudioFile(forWriting: url, settings: speechFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        try? file.write(from: buffer)
    }
}
