import AppKit
import SwiftUI

/// Small helpers for the one setting Slate depends on.
enum AppSupport {
    /// Open System Settings straight to Privacy and Security, Accessibility.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// On launch, Slate shows a small card so you can see it is on, and guides the
/// Accessibility grant the talk key needs. Once granted, the card confirms and
/// fades. This is the seed of the fuller onboarding (a later page).
final class LaunchGreeter: ObservableObject {
    static let shared = LaunchGreeter()

    @Published var message = ""
    @Published var granted = false

    private var panel: FloatingPanel?
    private var pollTimer: Timer?
    private var dismissWork: DispatchWorkItem?

    func show(force: Bool) {
        granted = HotkeyManager.hasAccessibility
        if granted {
            // Already set up; don't nag with a bubble on every launch. The menu's
            // "Show me how Slate works" re-opens this on demand.
            guard force else { return }
            message = "Slate is on. Hold Right Option, talk, then let go."
            present()
            scheduleDismiss(after: 5)
        } else {
            message = "Slate is on. Turn Slate on under Accessibility so the talk key works, then hold Right Option."
            present()
            HotkeyManager.promptForAccessibility()
            AppSupport.openAccessibilitySettings()
            startPolling()
        }
    }

    private func present() {
        dismissWork?.cancel()
        if panel == nil {
            let view = WelcomeView(onResize: { [weak self] size in
                self?.panel?.layoutTopCenter(contentSize: size)
            })
            .environmentObject(self)
            panel = FloatingPanel(
                content: AnyView(view),
                size: NSSize(width: 320, height: 80),
                anchored: true
            )
        }
        panel?.layoutTopCenter(contentSize: NSSize(width: 320, height: 80))
        panel?.orderFrontRegardless()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard HotkeyManager.hasAccessibility else { return }
            self.granted = true
            self.message = "You're all set. Hold Right Option, talk, then let go."
            self.pollTimer?.invalidate()
            self.pollTimer = nil
            self.scheduleDismiss(after: 5)
        }
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

struct WelcomeView: View {
    @EnvironmentObject var greeter: LaunchGreeter
    var onResize: (CGSize) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: greeter.granted ? "checkmark.circle.fill" : "waveform")
                .font(.system(size: 20))
                .foregroundStyle(Brand.emerald)
            Text(greeter.message)
                .font(Brand.text(13, weight: .medium))
                .foregroundStyle(Brand.deepGreen)
                .frame(maxWidth: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .islandSurface()
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onResize(proxy.size) }
                    .onChange(of: proxy.size) { _, size in onResize(size) }
            }
        )
    }
}
