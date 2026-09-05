import AVFoundation
import FluidAudio
import Foundation

/// Where the speech model is right now, for the menu and the island.
@MainActor
final class SpeechStatus: ObservableObject {
    static let shared = SpeechStatus()

    enum State: Equatable {
        case cold
        case downloading
        case loading
        case ready
        case failed(String)
    }

    @Published var state: State = .cold

    var isReady: Bool { state == .ready }
}

/// On-device speech-to-text: Parakeet Unified (FastConformer) through
/// FluidAudio, running on the Neural Engine. Nothing spoken leaves the Mac.
actor SpeechEngine {
    static let shared = SpeechEngine()

    private var manager: UnifiedAsrManager?
    private var loading: Task<Void, Error>?

    /// Load once, however many callers arrive at the same time. The very
    /// first load on a Mac also downloads the model; the status says so.
    func ensureLoaded() async throws {
        if manager != nil { return }
        if let loading {
            try await loading.value
            return
        }
        let task = Task<Void, Error> {
            let needsDownload = !Self.modelLooksDownloaded()
            await MainActor.run {
                SpeechStatus.shared.state = needsDownload ? .downloading : .loading
            }
            do {
                let asr = UnifiedAsrManager()
                try await asr.loadModels()  // App Support/FluidAudio on first run
                self.manager = asr
                await MainActor.run { SpeechStatus.shared.state = .ready }
            } catch {
                await MainActor.run { SpeechStatus.shared.state = .failed(error.localizedDescription) }
                throw error
            }
        }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    /// Pay the model load and the first-inference compile at launch, in the
    /// background, so the first dictation is as snappy as the tenth. The
    /// first inference on a cold CoreML model is the slow one; a second of
    /// near-silence is enough to get it out of the way.
    func warmUp() async {
        let started = Date()
        do {
            try await ensureLoaded()
            let loaded = Date()
            guard let manager else { return }
            var quiet = [Float](repeating: 0, count: 16_000)
            for index in quiet.indices where index % 97 == 0 {
                quiet[index] = 0.0004
            }
            _ = try await manager.transcribe(quiet)
            Log.write(String(
                format: "speech engine warm: load %.2fs, first inference %.2fs",
                loaded.timeIntervalSince(started), Date().timeIntervalSince(loaded)
            ))
        } catch {
            Log.write("speech warm-up failed: \(error)")
        }
    }

    /// 16 kHz mono Float32 samples in, text out.
    func transcribe(_ samples: [Float]) async throws -> String {
        try await ensureLoaded()
        guard let manager else { throw BlueError("Speech model failed to load.") }
        // Below about a quarter second there is nothing to transcribe.
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

    /// FluidAudio keeps its models under Application Support/FluidAudio/Models.
    /// A folder for the unified model being there is a good enough sign that
    /// the first-run download is done and this load is just a load.
    private static func modelLooksDownloaded() -> Bool {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return false }
        let models = base
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: models.path) else {
            return false
        }
        return names.contains { $0.lowercased().contains("unified") }
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
