import AppKit
import SwiftUI

@main
struct SlateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Slate", image: "MenuBarIcon") {
            SlateMenu()
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The pill's glass and white overlays are a light design; keep the app
        // in aqua so it reads like paper even under system dark mode.
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        Log.write("launch; accessibility=\(HotkeyManager.hasAccessibility)")
        // Push-to-talk needs Accessibility; retry quietly until it's granted so
        // a grant made in System Settings takes effect without a relaunch.
        HotkeyManager.shared.ensureRunning()
        // Confirm Slate is on and guide the one grant the talk key needs.
        LaunchGreeter.shared.show(force: false)
    }
}

/// The menu-bar dropdown: status, the way-to-talk picker, and the essentials.
struct SlateMenu: View {
    @AppStorage(HotkeyManager.activationModeKey) private var mode = ActivationMode.hold.rawValue

    var body: some View {
        Text(HotkeyManager.hasAccessibility
             ? "Ready. Use Right Option to talk."
             : "Turn on Accessibility to use the talk key.")

        Divider()

        Picker("How to talk", selection: $mode) {
            Text("Hold to talk, release to place").tag(ActivationMode.hold.rawValue)
            Text("Tap to start, tap to stop").tag(ActivationMode.tap.rawValue)
        }
        .pickerStyle(.inline)

        Divider()

        Button("Show me how Slate works") { LaunchGreeter.shared.show(force: true) }
        Button("Open Accessibility settings") { AppSupport.openAccessibilitySettings() }

        Divider()

        Button("Quit Slate") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
