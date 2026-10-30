import AVFoundation

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

/// The rep's microphone, via AVAudioEngine (system default input device).
final class MicCapture {
    private let engine = AVAudioEngine()

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw CoreAudioError(status: -1, what: "Open microphone (no input device or no permission)")
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in onBuffer(buffer) }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
