import AppKit
import Foundation
import ServiceManagement

/// Slate's few settings, all in UserDefaults. The keys are plain strings so
/// `@AppStorage` in the menu and the direct reads on the key-tap path agree.
enum Prefs {
    /// How Right Option drives dictation: hold, or tap to start and stop.
    static let activationMode = "activationMode"
    /// Put a space after what was placed, so the next dictation runs on.
    static let spaceAfter = "spaceAfterDictation"
    /// Pause whatever is playing while the mic is open.
    static let pauseMedia = "pauseMediaWhileTalking"
    /// Start a new paragraph when you pause for a beat.
    static let autoParagraphs = "paragraphsOnPauses"
    /// Master switch for the talk key.
    static let dictationEnabled = "dictationEnabled"
    /// Confirmation sounds on or off (kept for older settings).
    static let soundCues = "soundCues"
    /// Which set of sounds: classic, soft, marimba, click, or off.
    static let soundStyle = "soundStyle"
    /// Capture from the Mac's own microphone even when headphones are the
    /// system input: it opens in a tenth of the time Bluetooth takes, never
    /// drops AirPods into call-quality mode, and hears speech better.
    static let preferBuiltInMic = "preferBuiltInMic"
    /// When the cursor follows text on its line, start the words on a new
    /// paragraph instead of running them into it.
    static let paragraphAfterText = "newParagraphAfterText"

    static let defaults: [String: Any] = [
        spaceAfter: true,
        pauseMedia: true,
        autoParagraphs: true,
        dictationEnabled: true,
        soundCues: true,
        soundStyle: "classic",
        preferBuiltInMic: true,
        paragraphAfterText: true,
    ]

    /// Register the defaults once at launch so an unset key reads as its
    /// real default everywhere, not as `false`.
    static func register() {
        UserDefaults.standard.register(defaults: defaults)
    }

    static func bool(_ key: String) -> Bool {
        let store = UserDefaults.standard
        if store.object(forKey: key) == nil, let fallback = defaults[key] as? Bool {
            return fallback
        }
        return store.bool(forKey: key)
    }
}

/// Launch at login through the system's login-items service, so Slate is
/// just there after a restart without any Login Items fiddling.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.write("login item \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }
}
