import AVFoundation
import Foundation

/// Microphone capture producing the 16 kHz mono Float32 samples Parakeet
/// expects, plus a smoothed level stream that drives the waveform UI.
///
/// Device changes (headphones in or out, AirPods connecting) are survived
/// two ways: every start() builds a fresh AVAudioEngine so it binds to the
/// CURRENT default input, and a configuration-change observer rebuilds the
/// capture mid-recording so a device swap while listening keeps the samples
/// flowing instead of going silent or crashing the tap.
final class AudioRecorder {
    private var engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var wantsVoiceProcessing = false
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    // Pre-roll ring. While the mic is "armed" the engine runs and keeps the
    // last second of audio here (discarded unless a capture begins), so a hold
    // that starts on a keypress is seeded with the instant just before it —
    // the fix for dictation clipping the first words while a cold engine was
    // still spinning up. `isArmed` stays true (mic hot) between holds and is
    // released only after an idle stretch, so back-to-back dictation is
    // instant. `capturing` gates whether the live buffer accumulates.
    private var ring: [Float] = []
    private let ringCapacity = 16_000        // 1.0s at 16 kHz
    private var capturing = false
    private(set) var isArmed = false
    private var idleRelease: DispatchWorkItem?

    /// Called on the main thread ~30x/second with a 0…1 level.
    var onLevel: ((Float) -> Void)?

    /// Called off the main thread with each freshly converted chunk of
    /// 16 kHz samples — the live feed the voice-activity endpointer chews on.
    var onSamples: (([Float]) -> Void)?

    private(set) var isRecording = false

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!

    /// `voiceProcessing` turns on Apple's voice-processing unit (echo
    /// cancellation, noise suppression) so the mic doesn't hear the Mac's own
    /// speakers. Required for talk-over-blue interruption.
    func start(voiceProcessing: Bool = false) throws {
        guard !isRecording else { return }
        lock.lock(); samples = []; lock.unlock()
        wantsVoiceProcessing = voiceProcessing
        try startEngine()
        // Under the lock: consume() reads isRecording on the audio render thread.
        lock.lock(); isRecording = true; lock.unlock()
    }

    /// Builds and starts a brand-new engine against the current default
    /// input. An engine created earlier stays bound to the device that
    /// existed then; that stale binding is exactly what "the mic went dead
    /// after plugging in headphones" was.
    private func startEngine() throws {
        stopObservingConfiguration()
        engine = AVAudioEngine()
        let input = engine.inputNode
        if wantsVoiceProcessing {
            try? input.setVoiceProcessingEnabled(true)
        }
        // Query the format AFTER voice processing: enabling it changes the
        // node's effective format, and a tap installed with the wrong
        // sample rate raises an exception instead of an error.
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw BlueError("No microphone input available.")
        }
        converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// The device under the engine changed mid-recording. Rebuild the capture
    /// on the new default input; everything already captured is kept.
    private func handleConfigurationChange() {
        guard isRecording || isArmed else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try startEngine()
        } catch {
            // No usable input right now (device vanished). Stop cleanly; the
            // samples so far are still returned by stop()/endCapture().
            stopObservingConfiguration()
            lock.lock()
            isRecording = false
            isArmed = false
            capturing = false
            lock.unlock()
        }
    }

    private func stopObservingConfiguration() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
    }

    /// Everything captured so far, without stopping — drives live transcripts.
    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// Stops and returns everything captured since start().
    func stop() -> [Float] {
        stopObservingConfiguration()
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        defer { lock.unlock() }
        isRecording = false
        return samples
    }

    // MARK: - Armed dictation capture (warm mic, pre-roll, idle release)

    /// Start the engine and keep the pre-roll ring filling without capturing a
    /// session yet. Idempotent. The first hold pays this warm-up once; every
    /// hold after it — until the idle release — is instant and clip-free.
    func arm(voiceProcessing: Bool = false) throws {
        guard !isArmed, !isRecording else { return }
        wantsVoiceProcessing = voiceProcessing
        lock.lock(); ring = []; samples = []; lock.unlock()
        try startEngine()
        lock.lock(); isArmed = true; lock.unlock()
    }

    /// Begin capturing a dictation turn, arming first if the mic is cold. The
    /// live buffer is seeded with up to `preRoll` seconds already in the ring,
    /// so speech that began a beat before the keypress is kept.
    func beginCapture(preRoll: TimeInterval = 0.35, voiceProcessing: Bool = false) throws {
        idleRelease?.cancel(); idleRelease = nil
        if !isArmed { try arm(voiceProcessing: voiceProcessing) }
        let preRollCount = max(0, Int(preRoll * Self.targetFormat.sampleRate))
        lock.lock()
        samples = preRollCount > 0 ? Array(ring.suffix(preRollCount)) : []
        capturing = true
        lock.unlock()
    }

    /// End the capture and return everything since beginCapture() (pre-roll
    /// included). The mic stays armed and hot; it is released only after
    /// `idleAfter` seconds with no further capture, so a run of dictation never
    /// pays the warm-up twice.
    @discardableResult
    func endCapture(idleAfter: TimeInterval = 90) -> [Float] {
        lock.lock()
        capturing = false
        let out = samples
        samples = []
        lock.unlock()
        scheduleRelease(after: idleAfter)
        return out
    }

    private func scheduleRelease(after seconds: TimeInterval) {
        idleRelease?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.release() }
        idleRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Fully release the microphone: stop the engine and drop the pre-roll.
    /// Fires on the idle timeout, or when another capture path (the voice
    /// assistant) needs the device.
    func release() {
        idleRelease?.cancel(); idleRelease = nil
        guard isArmed else { return }
        stopObservingConfiguration()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // All three flags + the buffers under one lock: consume() reads them on
        // the render thread, and a buffer already in flight must not append to a
        // half-torn state as the engine is torn down.
        lock.lock()
        isArmed = false
        capturing = false
        samples = []
        ring = []
        lock.unlock()
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return
        }
        var fed = false
        converter.convert(to: converted, error: nil) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard let channel = converted.floatChannelData?[0], converted.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))

        lock.lock()
        if isArmed {
            ring.append(contentsOf: chunk)
            if ring.count > ringCapacity {
                ring.removeFirst(ring.count - ringCapacity)
            }
        }
        let listening = isRecording || capturing
        if listening {
            samples.append(contentsOf: chunk)
        }
        lock.unlock()

        onSamples?(chunk)

        // Between holds the mic is only armed and filling the ring; nothing
        // downstream wants the level then, so skip the per-chunk main hop.
        guard listening else { return }

        // RMS -> perceptual-ish level for the waveform.
        var sum: Float = 0
        for sample in chunk { sum += sample * sample }
        let rms = sqrt(sum / Float(max(chunk.count, 1)))
        let level = min(1, rms * 14)
        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(level)
        }
    }
}
