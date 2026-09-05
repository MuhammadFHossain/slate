import AVFoundation
import CoreAudio
import Foundation

/// Microphone capture producing the 16 kHz mono Float32 samples Parakeet
/// expects, plus a smoothed level stream that drives the waveform UI.
///
/// Two capture paths. With "Use the Mac's microphone" on (the default) and a
/// built-in mic present, a HAL input unit is opened directly on that device,
/// configured before it is initialized, so the system's default input (often
/// Bluetooth headphones) is never touched: no call-profile switch, no
/// half-second wake, music stays music. Otherwise an AVAudioEngine binds to
/// the CURRENT default input, and a configuration-change observer rebuilds
/// the capture mid-recording so a device swap while listening keeps the
/// samples flowing instead of going silent or crashing the tap.
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

    /// The input device the capture engine is actually bound to right now,
    /// for the log lines that time the mic start and record a rebuild. Read
    /// from the engine, not the system default, so a stale binding would show.
    var boundInputName: String {
        if halUnit != nil, let pinned = pinnedDevice { return Self.deviceName(pinned) }
        let id = engine.inputNode.auAudioUnit.deviceID
        return id == 0 ? "none" : Self.deviceName(id)
    }

    /// The built-in microphone, if this Mac has one with input streams.
    /// Cached: the lookup asks every audio device (virtual ones can be slow
    /// to answer) and only changes when the device list does.
    static func builtInInputDevice() -> AudioDeviceID? {
        builtInLock.lock()
        defer { builtInLock.unlock() }
        if !builtInListening {
            builtInListening = true
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                builtInLock.lock()
                builtInCache = nil
                builtInLock.unlock()
            }
        }
        if let cached = builtInCache { return cached.device }
        let found = findBuiltInInputDevice()
        builtInCache = (device: found, at: Date())
        return found
    }

    private static let builtInLock = NSLock()
    private static var builtInListening = false
    private static var builtInCache: (device: AudioDeviceID?, at: Date)?

    private static func findBuiltInInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return nil }
        for id in ids where hasInput(id) {
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
               transport == kAudioDeviceTransportTypeBuiltIn {
                return id
            }
        }
        return nil
    }

    /// The name of the system's current default input.
    static func defaultInputName() -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let got = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard got == noErr, device != 0 else { return "none" }
        return deviceName(device)
    }

    static func deviceName(_ device: AudioDeviceID) -> String {
        // AVAudioEngine binds its input to CoreAudio's private "default device"
        // aggregate; name the real device inside it, not the wrapper.
        if let inner = mainSubDevice(of: device), inner != device {
            return deviceName(inner)
        }
        return rawDeviceName(device)
    }

    /// For an aggregate device, the id of its active sub-device (the real
    /// hardware inside CoreAudio's default-device wrapper); nil otherwise.
    /// The active list, not the "main" sub-device: main is the clock master,
    /// which can stay on the old device after the input moves.
    private static func mainSubDevice(of device: AudioDeviceID) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ids) == noErr else { return nil }
        // Prefer a member that actually has input streams.
        for id in ids where id != 0 && id != device && hasInput(id) { return id }
        return ids.first { $0 != 0 && $0 != device }
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func rawDeviceName(_ device: AudioDeviceID) -> String {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, $0)
        }
        return status == noErr ? (name as String) : "unknown"
    }

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

    /// Opens the capture. The Mac's own microphone through a HAL unit when
    /// preferred and present; otherwise a brand-new engine against the
    /// current default input (an engine created earlier stays bound to the
    /// device that existed then; that stale binding is exactly what "the mic
    /// went dead after plugging in headphones" was).
    private func startEngine() throws {
        stopObservingConfiguration()
        pinnedDevice = nil
        let tLookup = Date()
        if Prefs.bool(Prefs.preferBuiltInMic), let builtIn = Self.builtInInputDevice() {
            let t0 = Date()
            do {
                try startHAL(on: builtIn)
                Log.write(String(
                    format: "mic unit on %@ in %.0fms (lookup %.0fms)",
                    Self.deviceName(builtIn), Date().timeIntervalSince(t0) * 1000,
                    t0.timeIntervalSince(tLookup) * 1000
                ))
                return
            } catch {
                Log.write("built-in mic unit failed (\(error)); using the system input")
            }
        }
        let t0 = Date()
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
        Log.write(String(
            format: "engine on %@ in %.0fms", boundInputName, Date().timeIntervalSince(t0) * 1000
        ))

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    // MARK: - The Mac's microphone through a HAL input unit

    private var halUnit: AudioUnit?
    private var halFormat: AVAudioFormat?
    private var deviceListBlock: AudioObjectPropertyListenerBlock?

    /// An input-only HAL unit on `device`, its device chosen before it is
    /// initialized so nothing else is ever opened. Float32, the device's own
    /// rate and channel count (the unit does not resample); consume() does.
    private func startHAL(on device: AudioDeviceID) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw BlueError("No audio input unit available.")
        }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "create")
        guard let unit = created else { throw BlueError("No audio input unit available.") }
        var started = false
        defer { if !started { AudioComponentInstanceDispose(unit) } }

        var on: UInt32 = 1
        var off: UInt32 = 0
        let four = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, four), "enable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, four), "disable output")
        var chosen = device
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &chosen, UInt32(MemoryLayout<AudioDeviceID>.size)
        ), "select device")

        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &size), "read format")
        guard deviceFormat.mSampleRate > 0,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: deviceFormat.mSampleRate,
                channels: max(1, deviceFormat.mChannelsPerFrame), interleaved: false
              )
        else { throw BlueError("No microphone input available.") }
        var wanted = format.streamDescription.pointee
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &wanted, size), "set format")

        var callback = AURenderCallbackStruct(
            inputProc: recorderInputProc,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ), "set callback")
        try check(AudioUnitInitialize(unit), "initialize")

        halFormat = format
        converter = AVAudioConverter(from: format, to: Self.targetFormat)
        halUnit = unit
        do {
            try check(AudioOutputUnitStart(unit), "start")
        } catch {
            halUnit = nil
            halFormat = nil
            AudioUnitUninitialize(unit)
            throw error
        }
        started = true
        pinnedDevice = device
        observeDeviceList()
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw BlueError("Microphone \(step) failed (\(status)).") }
    }

    /// Render-thread entry: pull the frames the device just captured into a
    /// buffer in the unit's format and hand them to consume().
    fileprivate func renderInput(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timestamp: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32,
        _ frames: UInt32
    ) -> OSStatus {
        guard let unit = halUnit, let format = halFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }
        consume(buffer)
        return noErr
    }

    /// Stop whichever capture is running. Stopping the HAL unit waits for the
    /// cycle in flight, so no callback runs after this returns.
    private func stopCapture() {
        stopObservingConfiguration()
        if let unit = halUnit {
            AudioOutputUnitStop(unit)
            halUnit = nil
            halFormat = nil
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            stopObservingDeviceList()
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// While pinned to the built-in mic, the only change that matters is that
    /// device going away (a closed laptop on an external display): then the
    /// capture rebuilds on whatever input is left.
    private func observeDeviceList() {
        guard deviceListBlock == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceListChange()
        }
        deviceListBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    private func stopObservingDeviceList() {
        guard let block = deviceListBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        deviceListBlock = nil
    }

    private func handleDeviceListChange() {
        guard halUnit != nil, isRecording || isArmed else { return }
        guard Self.builtInInputDevice() != pinnedDevice else { return }
        stopCapture()
        do {
            try startEngine()
            Log.write("built-in mic gone: capture rebuilt on \(boundInputName)")
        } catch {
            lock.lock()
            isRecording = false
            isArmed = false
            capturing = false
            lock.unlock()
        }
    }

    /// The device under the engine changed mid-recording. Rebuild the capture
    /// on the new default input; everything already captured is kept.
    private var configWork: DispatchWorkItem?
    /// The built-in microphone, when capture is pinned to it.
    private var pinnedDevice: AudioDeviceID?

    private func handleConfigurationChange() {
        guard isRecording || isArmed else { return }
        // Headphones connecting or disconnecting arrive as a burst of
        // changes; act once, after the burst.
        configWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyConfigurationChange() }
        configWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func applyConfigurationChange() {
        guard isRecording || isArmed else { return }
        stopCapture()
        do {
            try startEngine()
            Log.write("input changed: capture rebuilt on \(boundInputName)")
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
        configWork?.cancel()
        configWork = nil
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
        stopCapture()
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
        stopCapture()
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

/// The HAL unit's input callback: a C function, so it lives outside the class.
private let recorderInputProc: AURenderCallback = { refCon, flags, timestamp, bus, frames, _ in
    Unmanaged<AudioRecorder>.fromOpaque(refCon).takeUnretainedValue()
        .renderInput(flags, timestamp, bus, frames)
}
