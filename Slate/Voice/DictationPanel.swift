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

    /// The notch on a notched Mac, in screen coordinates: the gap between the
    /// two top auxiliary areas, as tall as the top safe-area inset. Nil on
    /// screens without one.
    static func notchRect(on screen: NSScreen) -> NSRect? {
        let inset = screen.safeAreaInsets.top
        guard inset > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX
        else { return nil }
        return NSRect(
            x: left.maxX, y: screen.frame.maxY - inset,
            width: right.minX - left.maxX, height: inset
        )
    }

    /// Hang content from the top center of the screen, centered on the notch
    /// where there is one. With `fromScreenTop` the frame starts at the very
    /// top of the screen, over the notch and the menu bar beside it, so a
    /// notch-shaped island grows out of the real notch; otherwise the top
    /// edge sits flush with the bottom of the menu bar (or of the notch, if
    /// the menu bar is hidden). Called again on every content size change so
    /// the top edge stays put while the content grows downward.
    func layoutTopCenter(contentSize: CGSize, fromScreenTop: Bool = false) {
        guard let screen = NSScreen.main else { return }
        let notch = Self.notchRect(on: screen)
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let top = fromScreenTop && notch != nil
            ? screen.frame.maxY
            : screen.frame.maxY - max(screen.safeAreaInsets.top, menuBarHeight)
        let centerX = notch?.midX ?? screen.frame.midX
        let w = max(contentSize.width, 1)
        let h = max(contentSize.height, 1)
        setFrame(
            NSRect(x: (centerX - w / 2).rounded(), y: top - h, width: w, height: h),
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

/// The notch, grown: a deep black shape that comes out of the notch itself
/// on a notched Mac (flaring into the menu bar at the top corners, never
/// narrower than the notch), and hangs from the menu bar elsewhere. The waveform moves as you speak and the words settle in
/// below it, paragraph by paragraph: the newest words arrive dim, a word
/// Parakeet corrects flashes mint, and everything settles to white as the
/// next pass confirms it, so you watch the transcript fix itself before it
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

    /// Ink on the dark glass.
    private let ink = Color.white
    private let inkSoft = Color.white.opacity(0.62)

    /// The body carries 18 pt of padding on each side; the content is held
    /// at least this wide so the body is never narrower than the notch.
    private var contentMinWidth: CGFloat {
        max(0, controller.notch.width - 36)
    }

    var body: some View {
        let notch = controller.notch
        VStack(alignment: .leading, spacing: 0) {
            // Over the physical notch; nothing is drawn there.
            Color.clear.frame(height: notch.height)
            VStack(alignment: .leading, spacing: 0) {
                header
                if hasText {
                    transcript
                        .padding(.top, 9)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, notch.isPresent ? 8 : 13)
            .padding(.bottom, 14)
        }
        .frame(minWidth: contentMinWidth + 36, alignment: .leading)
        .islandSurface(
            fillet: notch.isPresent ? 10 : 0,
            bottomRadius: 22,
            capHeight: notch.height
        )
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
                        .foregroundStyle(ink)
                }
                hint

            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
                Text("Placing your words")
                    .font(Brand.ui(12, weight: .semibold))
                    .foregroundStyle(ink)

            case .placed(let app):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Brand.emerald)
                Text("Placed in \(app)")
                    .font(Brand.ui(12, weight: .semibold))
                    .foregroundStyle(ink)

            case .copied:
                KeyCap(label: "⌘V")
                Text("Copied. Paste anywhere.")
                    .font(Brand.ui(12, weight: .semibold))
                    .foregroundStyle(ink)

            case .cancelled(let kept):
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(inkSoft)
                Text(kept ? "Cancelled. Kept in History." : "Cancelled")
                    .font(Brand.ui(12, weight: .semibold))
                    .foregroundStyle(ink)

            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Brand.coral)
                Text(message)
                    .font(Brand.ui(12, weight: .medium))
                    .foregroundStyle(ink)
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
        .foregroundStyle(inkSoft)
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
                        .foregroundStyle(ink)
                }
            }
        }
        .font(Brand.body(15))
        .frame(width: 400, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.18), value: controller.liveText)
    }

    /// Three inks tell you what just happened: full white for words that
    /// have held steady since the last partial, mint for words Parakeet just
    /// changed its mind about (they replaced words that were already on
    /// screen), dim for words it only just heard. Everything settles to
    /// white as the next partial confirms it.
    private func fadedTail(_ paragraph: String) -> AttributedString {
        let words = Self.words(of: paragraph)
        var settled = 0
        while settled < words.count, settled < previousWords.count, words[settled] == previousWords[settled] {
            settled += 1
        }
        var result = AttributedString()
        for (index, word) in words.enumerated() {
            var piece = AttributedString(word)
            if index < settled {
                piece.foregroundColor = ink
            } else if index < previousWords.count {
                piece.foregroundColor = Brand.mint
            } else {
                piece.foregroundColor = ink.opacity(0.45)
            }
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
