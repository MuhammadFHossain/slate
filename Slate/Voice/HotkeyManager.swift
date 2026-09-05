import AppKit
import Foundation

/// How Right Option drives dictation.
enum ActivationMode: String {
    case hold   // hold to talk, release to place the words
    case tap    // tap to start, tap again to place

    /// Read fresh on every keypress, so a change in the menu takes effect at once.
    static var current: ActivationMode {
        ActivationMode(rawValue: UserDefaults.standard.string(forKey: Prefs.activationMode) ?? "") ?? .hold
    }
}

/// Global hotkeys, active anywhere in macOS (needs Accessibility):
///   Right Option            -> push-to-talk dictation (hold, or tap to start and stop)
///   Command + Right Option  -> the quick picker of recent dictations
///   Escape                  -> cancel an in-progress dictation (what was said is
///                              kept in History, so a stray Escape never loses anything)
///   While the picker is up: arrows move, Return pastes, Escape closes.
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// When Right Option last went down, so the controller can log how long
    /// the hop to the main queue took.
    static var lastPressAt: Date?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightOptionDown = false
    /// What the press in flight means, fixed at key-down, so the release is
    /// resolved against its own press.
    private enum PressIntent { case dictate, picker }
    private var pressIntent: PressIntent = .dictate
    private var retryTimer: Timer?

    var isRunning: Bool { eventTap != nil }

    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// True while any modifier key is physically down. The text inserter
    /// waits on this: a ⌘V typed while Option is still held is ⌘⌥V.
    static var physicalModifiersDown: Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        return !flags.intersection(modifiers).isEmpty
    }

    @discardableResult
    static func promptForAccessibility() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

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

    func startIfPossible() {
        Log.write("startIfPossible: armed=\(eventTap != nil) accessibility=\(Self.hasAccessibility)")
        guard eventTap == nil, Self.hasAccessibility else { return }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            // A consumed key (Return with the picker up) must not reach the
            // app underneath; nil drops it.
            let consumed = HotkeyManager.shared.handle(type: type, event: event)
            return consumed ? nil : Unmanaged.passUnretained(event)
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

    /// Returns true when the event was consumed and must not reach the app.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // macOS disables taps that stall; re-enable defensively.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .flagsChanged:
            // Right Option is keycode 61; track its own press and release.
            guard keyCode == 61 else { return false }
            // The generic Option flag is set for either Option key, so a Right
            // Option release while Left Option is held would read as still
            // down. The device-specific bits tell them apart; fall back to the
            // generic flag only when a virtual keyboard sets neither.
            let raw = event.flags.rawValue
            let rightOptionBit: UInt64 = 0x40
            let leftOptionBit: UInt64 = 0x20
            let optionHeld: Bool
            if (raw & (rightOptionBit | leftOptionBit)) != 0 {
                optionHeld = (raw & rightOptionBit) != 0
            } else {
                optionHeld = event.flags.contains(.maskAlternate)
            }
            let mode = ActivationMode.current
            let enabled = Prefs.bool(Prefs.dictationEnabled)
            if optionHeld, !rightOptionDown {
                rightOptionDown = true
                HotkeyManager.lastPressAt = Date()
                // Command with the talk key opens the picker instead: nothing
                // is recorded and the microphone never opens.
                if event.flags.contains(.maskCommand) {
                    pressIntent = .picker
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { QuickPicker.shared.toggle() }
                    }
                    return false
                }
                pressIntent = .dictate
                // Off the tap callback (a stalled tap gets disabled), in order:
                // the main queue is FIFO, so a quick press-release can never
                // run its release before its press.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let controller = DictationController.shared
                        // Disabled only stops new turns; a turn already
                        // running can always be finished.
                        guard enabled || controller.isBusy else { return }
                        switch mode {
                        case .hold: controller.beginHold()
                        case .tap: controller.toggle()
                        }
                    }
                }
            } else if !optionHeld, rightOptionDown {
                rightOptionDown = false
                // A picker press has nothing to place on release.
                guard pressIntent == .dictate else { return false }
                // Hold mode places the words on release; tap mode ignores the
                // release and waits for a second tap to stop.
                if mode == .hold {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { DictationController.shared.endHold() }
                    }
                }
            }

        case .keyDown:
            // With the picker up, its keys are ours: arrows, Return and
            // Escape are consumed here; anything else closes it and passes
            // through to the app, because it belongs to the user.
            if PickerState.isOpen {
                let handled = [126, 125, 36, 76, 53].contains(keyCode)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if handled { QuickPicker.shared.handleKey(keyCode) } else { QuickPicker.shared.close() }
                    }
                }
                return handled
            }
            // Escape cancels an in-progress dictation.
            if keyCode == 53 {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { DictationController.shared.cancel() }
                }
            }

        default:
            break
        }
        return false
    }
}
