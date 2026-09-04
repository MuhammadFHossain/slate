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

// MARK: - Waveform

/// Live waveform: a row of capsules breathing with the mic level, each with
/// its own reach so the row moves like a voice rather than a meter.
struct WaveformView: View {
    var level: Float
    var barCount: Int = 7

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(Brand.accent)
                    .frame(width: 3.5, height: barHeight(index))
                    .shadow(color: Brand.emerald.opacity(0.35), radius: 3)
            }
        }
        .frame(width: 44, height: 22)
        .animation(.easeOut(duration: 0.16), value: level)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center) / max(center, 1)
        let falloff = 1.0 - distance * 0.55
        let reach = 0.85 + 0.15 * sin(Double(index) * 1.7)
        let base: CGFloat = 4
        // Hard cap: bars breathe inside their row, never past it.
        return min(22, base + CGFloat(Double(level) * 19 * falloff * reach))
    }
}

// MARK: - Dictation island

/// A glass capsule that hangs from the top center of the screen, out of the
/// way. The waveform moves as you speak and the words settle in below it,
/// paragraph by paragraph: the newest words arrive light and darken as
/// Parakeet confirms them, so you watch the transcript settle before it
/// lands in the text field.
struct DictationIslandView: View {
    @EnvironmentObject private var controller: DictationController
    @EnvironmentObject private var speech: SpeechStatus
    var onResize: (CGSize) -> Void

    /// The previous open paragraph's words, so the current one can show
    /// which of its words are new.
    @State private var previousWords: [String] = []

    private var hasText: Bool {
        controller.phase == .listening && !controller.liveText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if hasText {
                transcript
                    .padding(.top, 9)
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
            previousWords = Self.words(of: Self.visibleParagraphs(oldValue).last ?? "")
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            switch controller.phase {
            case .listening:
                WaveformView(level: controller.level)
                if !hasText {
                    LiveDot()
                    Text(speech.isReady ? "Listening" : "Getting the speech model ready")
                        .font(Brand.ui(12, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                }
                hint

            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                Text("Placing your words")
                    .font(Brand.ui(12, weight: .semibold))
                    .foregroundStyle(Brand.ink)

            case .placed(let app):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Brand.emerald)
                Text("Placed in \(app)")
                    .font(Brand.ui(12, weight: .semibold))
                    .foregroundStyle(Brand.ink)

            case .copied:
                Image(systemName: "doc.on.clipboard.fill")
                    .foregroundStyle(Brand.emerald)
                Text("Nothing to type into. Copied, so press ⌘V to paste.")
                    .font(Brand.ui(12, weight: .semibold))
                    .foregroundStyle(Brand.ink)

            case .cancelled(let kept):
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Brand.inkSoft)
                Text(kept ? "Cancelled. Kept in History." : "Cancelled")
                    .font(Brand.ui(12, weight: .semibold))
                    .foregroundStyle(Brand.ink)

            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Brand.coral)
                Text(message)
                    .font(Brand.ui(12, weight: .medium))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(2)
                    .frame(maxWidth: 360, alignment: .leading)

            case .idle:
                EmptyView()
            }
        }
    }

    private var hint: some View {
        HStack(spacing: 5) {
            if ActivationMode.current == .tap {
                KeyCap(label: "⌥")
                Text("to place")
            } else {
                Text("release to place")
            }
            KeyCap(label: "esc")
        }
        .font(Brand.ui(10, weight: .medium))
        .foregroundStyle(Brand.inkSoft)
        .padding(.leading, 4)
    }

    // MARK: Transcript

    private var transcript: some View {
        let paragraphs = Self.visibleParagraphs(controller.liveText)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                if index == paragraphs.count - 1 {
                    Text(fadedTail(paragraph))
                } else {
                    Text(paragraph)
                        .foregroundStyle(Brand.ink)
                }
            }
        }
        .font(Brand.body(15))
        .frame(width: 400, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.18), value: controller.liveText)
    }

    /// Full ink for the words that have held steady since the last partial,
    /// lighter ink for the words Parakeet has just added or revised; they
    /// darken as the next partial confirms them.
    private func fadedTail(_ paragraph: String) -> AttributedString {
        let words = Self.words(of: paragraph)
        var settled = 0
        while settled < words.count, settled < previousWords.count, words[settled] == previousWords[settled] {
            settled += 1
        }
        var result = AttributedString()
        for (index, word) in words.enumerated() {
            var piece = AttributedString(word)
            piece.foregroundColor = index < settled ? Brand.ink : Brand.ink.opacity(0.45)
            result += piece
            if index < words.count - 1 {
                result += AttributedString(" ")
            }
        }
        return result
    }

    /// The last two paragraphs, each trimmed from the front so the newest
    /// words are always the ones on screen.
    private static func visibleParagraphs(_ text: String) -> [String] {
        let all = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        return all.suffix(2).map { paragraph in
            guard paragraph.count > 220 else { return paragraph }
            let cut = paragraph.suffix(220).drop(while: { !$0.isWhitespace })
            return "…" + cut.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Split on spaces only, so a line break inside a paragraph stays put.
    private static func words(of text: String) -> [String] {
        text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }
}
