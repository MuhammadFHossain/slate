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

/// On launch, Slate shows a glass card so you can see it is on, and guides
/// the Accessibility grant the talk key needs. Once granted, the card
/// confirms and fades.
@MainActor
final class LaunchGreeter: ObservableObject {
    static let shared = LaunchGreeter()

    enum Step: Equatable {
        case needsAccessibility
        case ready
    }

    @Published var step: Step = .ready
    @Published var headline = ""
    @Published var detail = ""

    private var panel: FloatingPanel?
    /// The card's last reported size. A re-show with unchanged text reports
    /// no new size, so the panel must be laid out from this, not a default.
    private var lastSize = NSSize(width: 380, height: 110)
    private var pollTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    func show(force: Bool) {
        if HotkeyManager.hasAccessibility {
            // Already set up; don't nag with a card on every launch. The menu's
            // "Show me how Slate works" re-opens this on demand.
            guard force else { return }
            step = .ready
            headline = "Slate is on"
            detail = ActivationMode.current == .tap
                ? "Tap Right Option, talk, then tap it again. Your words land where the cursor is."
                : "Hold Right Option, talk, then let go. Your words land where the cursor is."
            present()
            scheduleDismiss(after: 6)
        } else {
            step = .needsAccessibility
            headline = "One thing before the talk key works"
            detail = "Turn on Slate under Privacy & Security › Accessibility. Then hold Right Option and talk."
            present()
            HotkeyManager.promptForAccessibility()
            AppSupport.openAccessibilitySettings()
            startPolling()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        panel?.orderOut(nil)
    }

    private func present() {
        dismissTask?.cancel()
        if panel == nil {
            let view = WelcomeView(onResize: { [weak self] size in
                self?.lastSize = size
                self?.panel?.layoutTopCenter(contentSize: size)
            })
            .environmentObject(self)
            panel = FloatingPanel(
                content: AnyView(view),
                size: NSSize(width: 380, height: 110),
                anchored: true
            )
        }
        panel?.layoutTopCenter(contentSize: lastSize)
        panel?.orderFrontRegardless()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard HotkeyManager.hasAccessibility else { continue }
                self.step = .ready
                self.headline = "You're all set"
                self.detail = "Hold Right Option, talk, then let go."
                self.scheduleDismiss(after: 5)
                return
            }
        }
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var greeter: LaunchGreeter
    var onResize: (CGSize) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Brand.accent)
                    .frame(width: 38, height: 38)
                    .shadow(color: Brand.emerald.opacity(0.45), radius: 8, y: 3)
                Image(systemName: greeter.step == .ready ? "waveform" : "hand.raised.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(greeter.headline)
                    .font(Brand.ui(14, weight: .bold))
                    .foregroundStyle(Brand.ink)
                Text(greeter.detail)
                    .font(Brand.ui(12, weight: .regular))
                    .foregroundStyle(Brand.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                if greeter.step == .needsAccessibility {
                    Button("Open Accessibility settings") {
                        AppSupport.openAccessibilitySettings()
                    }
                    .buttonStyle(PillButtonStyle(tone: .accent))
                    .padding(.top, 6)
                }
            }
            .frame(width: 290, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassCard(radius: 20)
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 30)
        .fixedSize()
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onResize(proxy.size) }
                    .onChange(of: proxy.size) { _, size in onResize(size) }
            }
        )
    }
}
