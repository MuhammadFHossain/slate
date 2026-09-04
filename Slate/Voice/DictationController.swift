import AppKit
import Foundation
import SwiftUI

/// Push-to-talk dictation: hold Right Option, speak, release, and the words
/// land at the cursor in whatever app has focus. Speech never leaves the Mac.
///
/// While you talk, the capture is watched for pauses. Each stretch closed off
/// by a pause is transcribed once and settled as a paragraph, so the live
/// transcript only ever re-runs the part you are still saying, and the final
/// placement has almost nothing left to do. Whatever happens after that, the
/// words are kept: placed, copied, or recovered into History.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        /// Typed into the named app.
        case placed(String)
        /// Nothing was there to type into; the text is on the clipboard.
        case copied
        /// Escape. `kept` says whether there was enough said to keep in History.
        case cancelled(kept: Bool)
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var level: Float = 0
    /// The transcript so far, formatted, paragraphs separated by blank lines.
    /// The last paragraph is the stretch still being spoken.
    @Published var liveText: String = ""

    var isBusy: Bool { phase == .listening || phase == .transcribing }

    private let recorder = AudioRecorder()
    private var panel: FloatingPanel?
    /// The island's last reported size, so a re-show lays out from what the
    /// content actually measures rather than a default slot.
    private var lastIslandSize = NSSize(width: 300, height: 90)
    private var startedAt: Date?
    private var liveTask: Task<Void, Never>?
    /// Bumped by every hide request and every start, so a stale hide from an
    /// earlier "Placed" can never dismiss a dictation that began after it.
    private var hideGeneration = 0
    /// Bumped by every start and every cancel; async work checks it before
    /// touching state so a late result from an old turn is dropped.
    private var turn = 0
    /// Raw transcripts of the paragraphs a pause has closed off, and the
    /// sample index in the capture where the last one ended.
    private var settledRaw: [String] = []
    private var settledEnd = 0
    /// Raw transcript of the stretch still being spoken.
    private var tailRaw = ""
    private var targetApp: String?

    /// The live transcript only ever re-runs the last 45 s of the open
    /// stretch; the final pass transcribes all of it.
    private static let liveWindowSamples = 16_000 * 45

    // MARK: - Turns

    func beginHold() {
        Log.write("beginHold phase=\(phase)")
        guard !isBusy else { return }
        hideGeneration += 1
        turn += 1
        targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
        settledRaw = []
        settledEnd = 0
        tailRaw = ""
        liveText = ""
        level = 0
        do {
            recorder.onLevel = { [weak self] level in
                self?.level = level
            }
            // The mic is armed and hot from a recent hold, so capture starts
            // instant and clip-free, seeded with the pre-roll just before this
            // keypress. The first hold after idle warms the engine here once.
            try recorder.beginCapture()
            startedAt = Date()
            phase = .listening
            showIsland()
            // Hush any playing music so the mic hears you, not the speakers.
            // After the island is up, so media control can never block dictation.
            if Prefs.bool(Prefs.pauseMedia) {
                MediaController.shared.pauseIfPlaying()
            }
            liveTask = Task { [weak self] in
                await self?.runLivePass()
            }
        } catch {
            MediaController.shared.resume()
            phase = .error(error.localizedDescription)
            showIsland()
            scheduleHide(after: 2.5)
        }
    }

    func endHold() {
        guard phase == .listening else { return }
        liveTask?.cancel()
        liveTask = nil
        // Your music comes back the moment you stop talking.
        MediaController.shared.resume()
        // Stop the mic the instant you let go, so the orange in-use dot clears
        // right away. No warm-mic idle window; the next hold re-arms fresh.
        let samples = recorder.endCapture()
        recorder.release()
        // A tap shorter than a third of a second is a mis-press, not speech.
        guard Date().timeIntervalSince(startedAt ?? Date()) > 0.3 else {
            phase = .idle
            hideIsland()
            return
        }
        phase = .transcribing

        let myTurn = turn
        let settled = settledRaw
        let start = min(settledEnd, samples.count)
        let app = targetApp
        let autoParagraphs = Prefs.bool(Prefs.autoParagraphs)
        let spaceAfter = Prefs.bool(Prefs.spaceAfter)

        Task { [weak self] in
            guard let self else { return }
            let finalStarted = Date()
            var paragraphs = settled
            var failure: String?
            let ranges = autoParagraphs
                ? PauseSegmenter.segments(in: samples, from: start)
                : [start..<samples.count]
            for range in ranges where !range.isEmpty {
                do {
                    let text = try await SpeechEngine.shared.transcribe(Array(samples[range]))
                    if !text.isEmpty { paragraphs.append(text) }
                } catch {
                    failure = error.localizedDescription
                    break
                }
            }
            let finalSeconds = Date().timeIntervalSince(finalStarted)
            let text = TextFormatter.compose(paragraphs: paragraphs, spaceAfter: spaceAfter)
            let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            // A new turn began while this one was still working: keep the
            // words, never place them somewhere you no longer are.
            guard self.turn == myTurn, self.phase == .transcribing else {
                if hasText { DictationHistory.shared.add(text, outcome: .recovered, appName: app) }
                return
            }
            if let failure, !hasText {
                self.phase = .error(failure)
                self.scheduleHide(after: 2.5)
                return
            }
            guard hasText else {
                self.phase = .idle
                self.hideIsland()
                return
            }

            let placeStarted = Date()
            let outcome = await TextInserter.insert(text)
            Log.write(String(
                format: "turn: %.1fs audio, %ld settled + %ld final segments, final pass %.2fs, placed in %.2fs, %ld chars",
                Double(samples.count) / 16_000, settled.count, ranges.count,
                finalSeconds, Date().timeIntervalSince(placeStarted), text.count
            ))
            switch outcome {
            case .placed(let appName):
                DictationHistory.shared.add(text, outcome: .placed, appName: appName)
                guard self.turn == myTurn else { return }
                self.phase = .placed(appName)
                self.scheduleHide(after: 1.2)
            case .copied:
                DictationHistory.shared.add(text, outcome: .copied, appName: app)
                guard self.turn == myTurn else { return }
                self.phase = .copied
                self.scheduleHide(after: 3.2)
            }
        }
    }

    /// Escape while listening. The turn is dropped from the cursor, but what
    /// was said is transcribed quietly and kept in History: an Escape meant
    /// for some dialog in another app must never cost you a paragraph.
    func cancel() {
        guard phase == .listening else { return }
        liveTask?.cancel()
        liveTask = nil
        MediaController.shared.resume()
        let samples = recorder.endCapture()
        recorder.release()

        let settled = settledRaw
        let start = min(settledEnd, samples.count)
        let app = targetApp
        turn += 1

        let worthKeeping = !settled.isEmpty || samples.count - start > 16_000
        phase = .cancelled(kept: worthKeeping)
        scheduleHide(after: worthKeeping ? 1.5 : 0.7)
        guard worthKeeping else { return }

        Task {
            var paragraphs = settled
            for range in PauseSegmenter.segments(in: samples, from: start) where !range.isEmpty {
                if let text = try? await SpeechEngine.shared.transcribe(Array(samples[range])),
                   !text.isEmpty {
                    paragraphs.append(text)
                }
            }
            let text = TextFormatter.compose(paragraphs: paragraphs, spaceAfter: false)
            DictationHistory.shared.add(text, outcome: .recovered, appName: app)
        }
    }

    /// Tap-to-start, tap-to-stop: one tap begins listening, the next places it.
    func toggle() {
        switch phase {
        case .listening: endHold()
        case .transcribing: break
        default: beginHold()
        }
    }

    // MARK: - Live transcript

    private func runLivePass() async {
        let myTurn = turn
        try? await SpeechEngine.shared.ensureLoaded()
        let autoParagraphs = Prefs.bool(Prefs.autoParagraphs)

        while !Task.isCancelled, phase == .listening, turn == myTurn {
            let samples = recorder.snapshot()

            if autoParagraphs {
                // Settle every paragraph a pause has closed off: transcribed
                // once, here, and never again.
                for cut in PauseSegmenter.cutPoints(in: samples, from: settledEnd) where cut > settledEnd {
                    let segment = Array(samples[settledEnd..<cut])
                    let text = try? await SpeechEngine.shared.transcribe(segment)
                    guard !Task.isCancelled, phase == .listening, turn == myTurn else { return }
                    // A failed pass leaves the boundary where it was, so the
                    // final pass covers this stretch instead of losing it.
                    guard let text else { break }
                    if !text.isEmpty {
                        settledRaw.append(text)
                    }
                    settledEnd = cut
                    tailRaw = ""
                    publishLive()
                }
            }

            let tail = samples[min(settledEnd, samples.count)...]
            if tail.count > 9600 {  // ~0.6 s of audio
                let window = Array(tail.suffix(Self.liveWindowSamples))
                let text = try? await SpeechEngine.shared.transcribe(window)
                guard !Task.isCancelled, phase == .listening, turn == myTurn else { return }
                if let text, !text.isEmpty, text != tailRaw {
                    tailRaw = text
                    publishLive()
                }
            }

            try? await Task.sleep(nanoseconds: 450_000_000)
        }
    }

    private func publishLive() {
        var paragraphs = settledRaw
        if !tailRaw.isEmpty { paragraphs.append(tailRaw) }
        liveText = TextFormatter.compose(paragraphs: paragraphs, spaceAfter: false, final: false)
    }

    // MARK: - Island window

    private func showIsland() {
        if panel == nil {
            let content = DictationIslandView(onResize: { [weak self] size in
                self?.lastIslandSize = size
                self?.panel?.layoutTopCenter(contentSize: size)
            })
            .environmentObject(self)
            .environmentObject(SpeechStatus.shared)
            panel = FloatingPanel(
                content: AnyView(content),
                size: NSSize(width: 300, height: 90),
                anchored: true
            )
        }
        // Lay out from the last measured size; the island then grows itself
        // as words arrive.
        panel?.layoutTopCenter(contentSize: lastIslandSize)
        panel?.orderFrontRegardless()
    }

    private func hideIsland() {
        panel?.orderOut(nil)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideGeneration += 1
        let generation = hideGeneration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.hideGeneration == generation, !self.isBusy else { return }
            self.phase = .idle
            self.hideIsland()
        }
    }
}
