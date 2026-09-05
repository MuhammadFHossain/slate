import AppKit
import Foundation

/// Quiet confirmation sounds: one when the mic is actually recording, one when
/// the words land, one when they are copied, one when a turn is dropped, and a
/// softer one on an error. Played through the system's shared player
/// (`NSSound`), never an audio engine of our own: an engine held open on
/// Bluetooth headphones slows their profile switch, which is the mic start.
///
/// Four styles, picked in Settings › Sound, plus Off:
///   classic  the system's Pop and Tink, low, as Slate always had
///   soft     short sine tones with a whisper of harmonic
///   marimba  wooden, decaying strikes
///   click    tiny mechanical ticks
@MainActor
enum SoundCue {
    static let enabledKey = "soundCues"
    static let styleKey = "soundStyle"

    enum Cue: String, CaseIterable {
        case start      // the mic is recording
        case placed     // the words landed in the app
        case copied     // the words went to the clipboard
        case cancelled  // the turn was dropped
        case error      // something went wrong
    }

    enum Style: String, CaseIterable {
        case classic, soft, marimba, click, off

        var label: String {
            switch self {
            case .classic: return "Classic"
            case .soft: return "Soft"
            case .marimba: return "Marimba"
            case .click: return "Click"
            case .off: return "Off"
            }
        }
    }

    static var style: Style {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: enabledKey) != nil, !defaults.bool(forKey: enabledKey) { return .off }
        return Style(rawValue: defaults.string(forKey: styleKey) ?? "") ?? .classic
    }

    static var isEnabled: Bool { style != .off }

    /// Pre-render the synthesized styles and pre-load the classic system
    /// sounds, so the first cue costs nothing at the keypress (a first
    /// NSSound(named:) reads and decodes the file, ~150 ms).
    static func warmUp() {
        for style in [Style.soft, .marimba, .click] {
            for cue in Cue.allCases { _ = data(style: style, cue: cue) }
        }
        for cue in Cue.allCases { _ = classicData(cue) }
    }

    static func play(_ cue: Cue) {
        let style = self.style
        guard style != .off else { return }
        // A fresh instance each time: NSSound won't restart one mid-play, and
        // a quick stop-start should sound twice.
        if style == .classic {
            let (_, volume) = classic(cue)
            guard let data = classicData(cue), let sound = NSSound(data: data) else { return }
            sound.volume = volume
            sound.play()
            return
        }
        guard let data = data(style: style, cue: cue), let sound = NSSound(data: data) else { return }
        sound.volume = 1
        sound.play()
    }

    // MARK: - Classic: the system sounds Slate always used

    private static func classic(_ cue: Cue) -> (NSSound.Name, Float) {
        switch cue {
        case .start: return ("Pop", 0.18)
        case .placed: return ("Tink", 0.18)
        case .copied: return ("Tink", 0.14)
        case .cancelled: return ("Pop", 0.10)
        case .error: return ("Basso", 0.10)
        }
    }

    /// The classic sound's file bytes, read once.
    private static func classicData(_ cue: Cue) -> Data? {
        let key = "classic.\(cue.rawValue)"
        if let cached = cache[key] { return cached }
        let (name, _) = classic(cue)
        guard let url = Bundle(identifier: "com.apple.AppKit")?.url(forResource: name, withExtension: "aiff")
                ?? URL(string: "file:///System/Library/Sounds/\(name).aiff"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        cache[key] = data
        return data
    }

    // MARK: - Synthesized styles

    private static var cache: [String: Data] = [:]

    /// WAV bytes for a synthesized cue (nil for classic and off). Shared with
    /// the preview tool so what you audition is what the app plays.
    static func data(style: Style, cue: Cue) -> Data? {
        let key = "\(style.rawValue).\(cue.rawValue)"
        if let cached = cache[key] { return cached }
        let samples: [Float]
        switch style {
        case .soft: samples = Synth.soft(cue)
        case .marimba: samples = Synth.marimba(cue)
        case .click: samples = Synth.click(cue)
        case .classic, .off: return nil
        }
        let wav = Synth.wav(samples)
        cache[key] = wav
        return wav
    }
}

/// The synthesis: pure functions from a cue to 44.1 kHz mono samples.
enum Synth {
    static let sampleRate = 44_100.0

    // MARK: Soft — sine notes under a raised-cosine envelope

    private struct Note { var freq: Double; var duration: Double; var gain: Double; var start: Double }

    static func soft(_ cue: SoundCue.Cue) -> [Float] {
        let notes: [Note]
        switch cue {
        case .start: notes = [Note(freq: 392.00, duration: 0.070, gain: 0.18, start: 0)]
        case .placed: notes = [Note(freq: 392.00, duration: 0.070, gain: 0.26, start: 0),
                               Note(freq: 523.25, duration: 0.120, gain: 0.26, start: 0.055)]
        case .copied: notes = [Note(freq: 466.16, duration: 0.120, gain: 0.24, start: 0)]
        case .cancelled: notes = [Note(freq: 392.00, duration: 0.070, gain: 0.18, start: 0),
                                  Note(freq: 329.63, duration: 0.110, gain: 0.18, start: 0.055)]
        case .error: notes = [Note(freq: 415.30, duration: 0.090, gain: 0.24, start: 0),
                              Note(freq: 311.13, duration: 0.140, gain: 0.24, start: 0.075)]
        }
        let total = (notes.map { $0.start + $0.duration }.max() ?? 0) + 0.02
        var out = [Float](repeating: 0, count: Int(total * sampleRate))
        for note in notes {
            let startFrame = Int(note.start * sampleRate)
            let count = Int(note.duration * sampleRate)
            for n in 0..<count where startFrame + n < out.count {
                let t = Double(n) / sampleRate
                let phase = 2 * Double.pi * note.freq * t
                let p = Double(n) / Double(max(count - 1, 1))
                let envelope = 0.5 - 0.5 * cos(2 * Double.pi * p)
                out[startFrame + n] += Float((sin(phase) + 0.12 * sin(2 * phase)) * envelope * note.gain)
            }
        }
        return out
    }

    // MARK: Marimba — a struck bar: fast attack, exponential decay, the 1:4 partial

    private struct Strike { var freq: Double; var gain: Double; var start: Double }

    static func marimba(_ cue: SoundCue.Cue) -> [Float] {
        let strikes: [Strike]
        switch cue {
        case .start: strikes = [Strike(freq: 523.25, gain: 0.30, start: 0)]
        case .placed: strikes = [Strike(freq: 523.25, gain: 0.30, start: 0), Strike(freq: 783.99, gain: 0.30, start: 0.075)]
        case .copied: strikes = [Strike(freq: 659.25, gain: 0.28, start: 0)]
        case .cancelled: strikes = [Strike(freq: 440.00, gain: 0.24, start: 0), Strike(freq: 349.23, gain: 0.24, start: 0.075)]
        case .error: strikes = [Strike(freq: 392.00, gain: 0.26, start: 0), Strike(freq: 311.13, gain: 0.26, start: 0.10)]
        }
        let length = 0.30
        let total = (strikes.map { $0.start }.max() ?? 0) + length
        var out = [Float](repeating: 0, count: Int(total * sampleRate))
        for strike in strikes {
            let startFrame = Int(strike.start * sampleRate)
            let count = Int(length * sampleRate)
            for n in 0..<count where startFrame + n < out.count {
                let t = Double(n) / sampleRate
                let attack = min(1, t / 0.003)
                let body = sin(2 * Double.pi * strike.freq * t) * exp(-t / 0.09)
                let bar = 0.30 * sin(2 * Double.pi * strike.freq * 4 * t) * exp(-t / 0.035)
                let tick = 0.08 * sin(2 * Double.pi * strike.freq * 10 * t) * exp(-t / 0.02)
                out[startFrame + n] += Float((body + bar + tick) * attack * strike.gain)
            }
        }
        return out
    }

    // MARK: Click — a tiny mechanical tick

    private struct Tick { var freq: Double; var gain: Double; var start: Double; var tau: Double }

    static func click(_ cue: SoundCue.Cue) -> [Float] {
        let ticks: [Tick]
        switch cue {
        case .start: ticks = [Tick(freq: 1400, gain: 0.22, start: 0, tau: 0.004)]
        case .placed: ticks = [Tick(freq: 1400, gain: 0.22, start: 0, tau: 0.004), Tick(freq: 1900, gain: 0.22, start: 0.055, tau: 0.004)]
        case .copied: ticks = [Tick(freq: 1600, gain: 0.20, start: 0, tau: 0.004)]
        case .cancelled: ticks = [Tick(freq: 900, gain: 0.20, start: 0, tau: 0.005)]
        case .error: ticks = [Tick(freq: 700, gain: 0.22, start: 0, tau: 0.006), Tick(freq: 700, gain: 0.22, start: 0.09, tau: 0.006)]
        }
        let length = 0.035
        let total = (ticks.map { $0.start }.max() ?? 0) + length
        var out = [Float](repeating: 0, count: Int(total * sampleRate))
        var seed: UInt32 = 0x9E37_79B9
        for tick in ticks {
            let startFrame = Int(tick.start * sampleRate)
            let count = Int(length * sampleRate)
            for n in 0..<count where startFrame + n < out.count {
                let t = Double(n) / sampleRate
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = (Double(seed >> 8) / Double(1 << 24)) * 2 - 1
                let tone = sin(2 * Double.pi * tick.freq * t) * exp(-t / tick.tau)
                let burst = 0.35 * noise * exp(-t / (tick.tau / 2))
                out[startFrame + n] += Float((tone + burst) * tick.gain)
            }
        }
        return out
    }

    // MARK: WAV — 16-bit PCM mono

    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(byteCount)
        data.reserveCapacity(data.count + Int(byteCount))
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * 32_767).littleEndian
            data.append(Data(bytes: &v, count: 2))
        }
        return data
    }
}
