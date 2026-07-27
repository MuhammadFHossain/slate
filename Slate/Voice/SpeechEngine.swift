import AVFoundation
import FluidAudio
import Foundation

/// On-device speech-to-text: Parakeet Unified 0.6B (FastConformer) through
/// FluidAudio, running on the Neural Engine. Nothing spoken leaves the Mac.
actor SpeechEngine {
    static let shared = SpeechEngine()

    private var manager: UnifiedAsrManager?

    func ensureLoaded() async throws {
        guard manager == nil else { return }
        let asr = UnifiedAsrManager()
        try await asr.loadModels()  // downloads to App Support/FluidAudio on first run
        manager = asr
    }

    /// 16 kHz mono Float32 samples in, text out.
    func transcribe(_ samples: [Float]) async throws -> String {
        try await ensureLoaded()
        guard let manager else { throw BlueError("Speech model failed to load.") }
        // Below ~a quarter second there is nothing to transcribe.
        guard samples.count > 4000 else { return "" }
        // Quiet capture (distant mic, low gain, lid down) still transcribes
        // if we bring it up to a normal level first. Anything below the
        // floor is noise, not speech; leave it alone.
        var audio = samples
        let peak = audio.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 0.002, peak < 0.15 {
            let gain = min(0.6 / peak, 150)
            for index in audio.indices { audio[index] *= gain }
        }
        let text = try await manager.transcribe(audio)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// File-based path used by the --transcribe CLI test.
    func transcribe(url: URL) async throws -> String {
        let samples = try Self.loadSamples16kMono(url: url)
        return try await transcribe(samples)
    }

    static func loadSamples16kMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(file.length)
        ) else { throw BlueError("Could not allocate audio buffer") }
        try file.read(into: inputBuffer)

        let target = AudioRecorder.targetFormat
        if inputFormat == target {
            let channel = inputBuffer.floatChannelData![0]
            return Array(UnsafeBufferPointer(start: channel, count: Int(inputBuffer.frameLength)))
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw BlueError("Unsupported audio format")
        }
        let ratio = target.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw BlueError("Could not allocate conversion buffer")
        }
        var fed = false
        converter.convert(to: output, error: nil) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inputBuffer
        }
        guard let channel = output.floatChannelData?[0] else {
            throw BlueError("Conversion produced no audio")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
