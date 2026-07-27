import AppKit
import Foundation

/// How Right Option drives dictation.
enum ActivationMode: String {
    case hold   // hold to talk, release to place the words
    case tap    // tap to start, tap again to stop
}

/// Global hotkeys, active anywhere in macOS (needs Accessibility):
///   hold Right Option  -> push-to-talk dictation (Wisprflow-style)
///   Escape             -> cancel an in-progress dictation
final class HotkeyManager {
    static let shared = HotkeyManager()

    static let dictationEnabledKey = "dictationEnabled"
    static let activationModeKey = "activationMode"

    /// Read fresh on every keypress, so a change in the menu takes effect at once.
    private var mode: ActivationMode {
        ActivationMode(rawValue: UserDefaults.standard.string(forKey: Self.activationModeKey) ?? "")
            ?? .hold
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightOptionDown = false
    private var retryTimer: Timer?

    var isRunning: Bool { eventTap != nil }

    /// Starts the tap now if Accessibility is granted, and otherwise keeps
    /// retrying every few seconds so a grant made in System Settings takes
    /// effect without relaunching the app.
    func ensureRunning() {
        startIfPossible()
        guard eventTap == nil, retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.startIfPossible()
            if self.eventTap != nil {
                self.retryTimer?.invalidate()
                self.retryTimer = nil
            }
        }
    }

    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func promptForAccessibility() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func startIfPossible() {
        Log.write("startIfPossible: armed=\(eventTap != nil) accessibility=\(Self.hasAccessibility)")
        guard eventTap == nil, Self.hasAccessibility else { return }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            HotkeyManager.shared.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        // An active (default) tap that passes events through unchanged: active
        // taps are authorized by Accessibility alone, while listen-only taps
        // additionally want Input Monitoring on modern macOS.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: nil
        ) else {
            Log.write("tapCreate returned nil (Input Monitoring / permission?)")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("TAP ARMED")
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables taps that stall; re-enable defensively.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let defaults = UserDefaults.standard

        switch type {
        case .flagsChanged:
            // Right Option is keycode 61; track its own press/release.
            guard keyCode == 61,
                  defaults.object(forKey: Self.dictationEnabledKey) == nil
                    || defaults.bool(forKey: Self.dictationEnabledKey)
            else { return }
            let optionHeld = event.flags.contains(.maskAlternate)
            let mode = self.mode
            if optionHeld, !rightOptionDown {
                rightOptionDown = true
                DispatchQueue.main.async {
                    switch mode {
                    case .hold: DictationController.shared.beginHold()
                    case .tap: DictationController.shared.toggle()
                    }
                }
            } else if !optionHeld, rightOptionDown {
                rightOptionDown = false
                // Hold mode places the words on release; tap mode ignores the
                // release and waits for a second tap to stop.
                if mode == .hold {
                    DispatchQueue.main.async { DictationController.shared.endHold() }
                }
            }

        case .keyDown:
            // Escape cancels an in-progress dictation.
            if keyCode == 53 {
                DispatchQueue.main.async { DictationController.shared.cancel() }
            }

        default:
            break
        }
    }
}

/// Types transcribed text into the frontmost app: preserves the pasteboard,
/// pastes with a synthetic Cmd-V, then restores what was there. (Page 2 makes
/// this clipboard-safe across all types and adds the keystroke fallback.)
enum TextInserter {
    static func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(9)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pasteboard.clearContents()
            if let saved {
                pasteboard.setString(saved, forType: .string)
            }
        }
    }
}
