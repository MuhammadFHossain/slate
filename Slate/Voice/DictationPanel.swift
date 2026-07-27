import AppKit
import SwiftUI

// MARK: - Floating window host

/// Borderless, non-activating floating panel: appears over any app without
/// stealing focus (dictation must not deactivate the app being typed into).
final class FloatingPanel: NSPanel {
    init(content: AnyView, size: NSSize, anchored: Bool = false) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = !anchored

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { false }

    /// Hang the island from the top center of the screen, its top edge flush
    /// with the bottom of the menu bar (centered under the notch on notched
    /// Macs) so it reads as part of the top, not a pill floating below it.
    /// Called again on every content size change so the top edge stays put
    /// while the island grows downward.
    func layoutTopCenter(contentSize: CGSize) {
        guard let screen = NSScreen.main else { return }
        let top = screen.visibleFrame.maxY
        let w = max(contentSize.width, 1)
        let h = max(contentSize.height, 1)
        setFrame(
            NSRect(x: (screen.frame.midX - w / 2).rounded(), y: top - h, width: w, height: h),
            display: true
        )
        // Positioning only. Showing and hiding is the caller's job, so a resize
        // while hidden never yanks an empty island back onto the screen.
    }
}

// MARK: - Shared island surface

/// The "hangs from the top" surface: square top corners so it meets the menu
/// bar cleanly, rounded bottom corners so it reads as an island dropping down.
/// No top padding, so the surface sits flush against the menu bar.
struct IslandSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: 20,
            bottomTrailingRadius: 20, topTrailingRadius: 0, style: .continuous
        )
        return content
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                shape
                    .fill(Brand.surface)
                    .overlay(shape.strokeBorder(Brand.emerald.opacity(0.5), lineWidth: 1.5))
                    .shadow(color: Brand.emerald.opacity(0.22), radius: 12, y: 5)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .fixedSize()
    }
}

extension View {
    func islandSurface() -> some View { modifier(IslandSurface()) }
}

// MARK: - Waveform

/// Live waveform: a row of capsules breathing with the mic level.
struct WaveformView: View {
    var level: Float
    var tint: Color = Brand.emerald
    var barCount: Int = 5

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: 4, height: barHeight(index))
            }
        }
        .animation(.easeOut(duration: 0.18), value: level)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let center = Double(barCount - 1) / 2
        let falloff = 1.0 - abs(Double(index) - center) / (center + 1.2)
        let base: CGFloat = 5
        // Hard cap: bars breathe inside their row, never past it.
        return min(22, base + CGFloat(Double(level) * 22 * falloff))
    }
}

// MARK: - Dictation island

/// A small capsule that hangs from the top center of the screen, out of the
/// way. The waveform moves as you speak and the words type out below it; words
/// that Parakeet has just revised carry a lime highlight, so you watch the
/// transcript settle in real time before it lands in the text field.
struct DictationIslandView: View {
    @EnvironmentObject var controller: DictationController
    var onResize: (CGSize) -> Void

    /// The previous partial's words, so the current one can highlight what changed.
    @State private var prevWords: [String] = []

    private var hasText: Bool {
        controller.phase == .listening && !controller.liveText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: hasText ? 8 : 0) {
            HStack(spacing: 10) {
                switch controller.phase {
                case .listening:
                    WaveformView(level: controller.level, tint: Brand.emerald)
                        .frame(width: 44, height: 20)
                        .clipped()
                    if controller.liveText.isEmpty {
                        Text("Listening…")
                            .font(Brand.text(12, weight: .medium))
                            .foregroundStyle(Brand.emerald.opacity(0.9))
                    }
                case .transcribing:
                    ProgressView()
                        .controlSize(.small)
                        .tint(Brand.emerald)
                    Text("Placing your words…")
                        .font(Brand.text(12, weight: .medium))
                        .foregroundStyle(Brand.emerald.opacity(0.9))
                case .error(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Brand.coral)
                    Text(message)
                        .font(Brand.text(12))
                        .foregroundStyle(Brand.deepGreen)
                        .lineLimit(2)
                case .idle:
                    EmptyView()
                }
            }
            if hasText {
                Text(liveAttributed())
                    .font(Brand.text(15))
                    .lineLimit(3)
                    .frame(maxWidth: 360, alignment: .leading)
                    .contentTransition(.interpolate)
                    .animation(.easeOut(duration: 0.22), value: controller.liveText)
            }
        }
        .islandSurface()
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onResize(proxy.size) }
                    .onChange(of: proxy.size) { _, size in onResize(size) }
            }
        )
        .onChange(of: controller.liveText) { oldValue, _ in
            prevWords = oldValue.split(separator: " ").map(String.init)
        }
    }

    /// Deep green for settled words; a lime highlight on everything from the
    /// first word that changed since the last partial, so a correction lights up
    /// and then calms as the next partial confirms it.
    private func liveAttributed() -> AttributedString {
        let words = controller.liveText.split(separator: " ").map(String.init)
        var firstChanged = 0
        while firstChanged < words.count,
              firstChanged < prevWords.count,
              words[firstChanged] == prevWords[firstChanged] {
            firstChanged += 1
        }
        var result = AttributedString()
        for (index, word) in words.enumerated() {
            var piece = AttributedString(word)
            piece.foregroundColor = Brand.deepGreen
            if index >= firstChanged {
                piece.backgroundColor = Brand.lime
            }
            result += piece
            if index < words.count - 1 {
                result += AttributedString(" ")
            }
        }
        return result
    }
}
