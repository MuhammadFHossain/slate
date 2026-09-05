import AppKit
import AVFoundation
import SwiftUI

@main
struct SlateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Slate", image: "MenuBarIcon") {
            SlateMenu()
                .environmentObject(DictationHistory.shared)
                .environmentObject(SpeechStatus.shared)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        Log.write("launch; accessibility=\(HotkeyManager.hasAccessibility)")
        // Pre-load the sounds and find the Mac's microphone now, so the first
        // hold pays for neither (the device lookup alone is ~150 ms cold).
        SoundCue.warmUp()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AudioRecorder.builtInInputDevice()
        }
        // Push-to-talk needs Accessibility; retry quietly until it's granted so
        // a grant made in System Settings takes effect without a relaunch.
        HotkeyManager.shared.ensureRunning()
        // Ask for the microphone now, not in the middle of your first
        // sentence, when the permission sheet would eat the dictation.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.write("microphone granted=\(granted)")
            }
        }
        // Confirm Slate is on and guide the one grant the talk key needs.
        LaunchGreeter.shared.show(force: false)
        // Load the speech model and pay its first-inference compile now, in
        // the background, so the first hold is as instant as every other.
        Task.detached(priority: .userInitiated) {
            await SpeechEngine.shared.warmUp()
        }
    }
}

/// The menu-bar dropdown: status, the way-to-talk picker, Recent (the last
/// five, click to copy) and History (the whole record) as two separate
/// items, then Settings and the essentials.
struct SlateMenu: View {
    @AppStorage(Prefs.activationMode) private var mode = ActivationMode.hold.rawValue
    @AppStorage(Prefs.spaceAfter) private var spaceAfter = true
    @AppStorage(Prefs.autoParagraphs) private var autoParagraphs = true
    @AppStorage(Prefs.pauseMedia) private var pauseMedia = true
    @AppStorage(Prefs.soundStyle) private var soundStyle = SoundCue.Style.classic.rawValue
    @AppStorage(Prefs.preferBuiltInMic) private var preferBuiltInMic = true
    @AppStorage(Prefs.paragraphAfterText) private var paragraphAfterText = true
    @EnvironmentObject private var history: DictationHistory
    @EnvironmentObject private var speech: SpeechStatus

    private var statusLine: String {
        guard HotkeyManager.hasAccessibility else {
            return "Turn on Accessibility to use the talk key"
        }
        switch speech.state {
        case .cold, .loading:
            return "Getting the speech model ready…"
        case .downloading:
            return "Downloading the speech model (first run only)…"
        case .failed(let message):
            return "Speech model failed: \(message)"
        case .ready:
            return mode == ActivationMode.tap.rawValue
                ? "Ready. Tap Right Option to talk, tap again to place."
                : "Ready. Hold Right Option to talk."
        }
    }

    var body: some View {
        Text(statusLine)

        Divider()

        Picker("How to talk", selection: $mode) {
            Text("Hold to talk, release to place").tag(ActivationMode.hold.rawValue)
            Text("Tap to start, tap to stop").tag(ActivationMode.tap.rawValue)
        }
        .pickerStyle(.inline)

        Divider()

        // Recent and History are two different things: the last five, one
        // click from the clipboard, and the whole record in its own window.
        Menu("Recent") {
            if history.entries.isEmpty {
                Text("Nothing dictated yet")
            } else {
                Text("Click one to copy it")
                Divider()
                ForEach(Array(history.entries.prefix(5))) { entry in
                    Button(entry.preview) {
                        TextInserter.copyToClipboard(entry.text)
                    }
                }
            }
        }
        Button("History…") { HistoryWindowController.shared.show() }
            .keyboardShortcut("h")
        Button("Paste something recent  (⌘ + Right Option)") { QuickPicker.shared.toggle() }

        Divider()

        Menu("Settings") {
            Toggle("Space after each dictation", isOn: $spaceAfter)
            Toggle("New paragraph when you pause", isOn: $autoParagraphs)
            Toggle("New paragraph when the cursor follows text", isOn: $paragraphAfterText)
            Toggle("Pause music while talking", isOn: $pauseMedia)
            Toggle("Use the Mac's microphone (faster than AirPods)", isOn: $preferBuiltInMic)
            Picker("Sound", selection: $soundStyle) {
                ForEach(SoundCue.Style.allCases, id: \.rawValue) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            Divider()
            Toggle("Launch at login", isOn: Binding(
                get: { LoginItem.isEnabled },
                set: { LoginItem.set($0) }
            ))
        }
        Button("Show me how Slate works") { LaunchGreeter.shared.show(force: true) }
        Button("Open Accessibility settings") { AppSupport.openAccessibilitySettings() }

        Divider()

        Button("Quit Slate") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
