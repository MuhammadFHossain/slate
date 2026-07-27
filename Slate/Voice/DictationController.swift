import AppKit
import Foundation
import SwiftUI

/// Push-to-talk dictation: hold Right Option, speak, release, and the words
/// land at the cursor in whatever app has focus. Speech never leaves the Mac.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var level: Float = 0
    /// Rolling transcript shown in the island while the key is held.
    @Published var liveText: String = ""

    private let recorder = AudioRecorder()
    private var panel: FloatingPanel?
    private var startedAt: Date?
    private var partialTask: Task<Void, Never>?

    func beginHold() {
        Log.write("beginHold phase=\(phase)")
        guard phase == .idle else { return }
        do {
            recorder.onLevel = { [weak self] level in
                self?.level = level
            }
            // The mic is armed and hot from a recent hold, so capture starts
            // instant and clip-free, seeded with the pre-roll just before this
            // keypress. The first hold after idle warms the engine here once.
            try recorder.beginCapture()
            startedAt = Date()
            liveText = ""
            phase = .listening
            showIsland()
            // Hush any playing music so the mic hears you, not the speakers.
            // After the island is up, so media control can never block dictation.
            MediaController.shared.pauseIfPlaying()
            // Warm the model while the user is still talking, then keep
            // re-transcribing the growing buffer so words appear live
            // (Parakeet runs ~190x realtime, so each pass is a few ms).
            partialTask = Task { [weak self] in
                try? await SpeechEngine.shared.ensureLoaded()
                while let self, !Task.isCancelled, self.phase == .listening {
                    let samples = self.recorder.snapshot()
                    if samples.count > 9600 { // ~0.6s of audio
                        if let text = try? await SpeechEngine.shared.transcribe(samples),
                           !text.isEmpty, self.phase == .listening {
                            self.liveText = text
                        }
                    }
                    try? await Task.sleep(nanoseconds: 550_000_000)
                }
            }
        } catch {
            MediaController.shared.resume()
            phase = .error(error.localizedDescription)
            showIsland()
            scheduleHide(after: 2)
        }
    }

    func endHold() {
        guard phase == .listening else { return }
        partialTask?.cancel()
        // Your music comes back the moment you stop talking.
        MediaController.shared.resume()
        // Stop the mic the instant you let go, so the orange in-use dot clears
        // right away. No warm-mic idle window; the next hold re-arms fresh.
        let samples = recorder.endCapture()
        recorder.release()
        // A tap shorter than a third of a second is a mis-press, not speech.
        guard Date().timeIntervalSince(startedAt ?? Date()) > 0.3 else {
            hideIsland()
            phase = .idle
            return
        }
        phase = .transcribing
        Task {
            do {
                let text = try await SpeechEngine.shared.transcribe(samples)
                if !text.isEmpty {
                    TextInserter.insert(text)
                }
                phase = .idle
                hideIsland()
            } catch {
                phase = .error(error.localizedDescription)
                scheduleHide(after: 2.5)
            }
        }
    }

    func cancel() {
        guard phase != .idle else { return }
        partialTask?.cancel()
        MediaController.shared.resume()
        // Drop this turn and stop the mic immediately.
        recorder.endCapture()
        recorder.release()
        liveText = ""
        phase = .idle
        hideIsland()
    }

    /// Tap-to-start, tap-to-stop: one tap begins listening, the next places it.
    func toggle() {
        switch phase {
        case .idle: beginHold()
        case .listening: endHold()
        case .transcribing, .error: break
        }
    }

    // MARK: - Island window

    private func showIsland() {
        if panel == nil {
            let content = DictationIslandView(onResize: { [weak self] size in
                self?.panel?.layoutTopCenter(contentSize: size)
            })
            .environmentObject(self)
            panel = FloatingPanel(
                content: AnyView(content),
                size: NSSize(width: 260, height: 60),
                anchored: true
            )
        }
        // Reset to a compact top slot; the island grows itself as words arrive.
        panel?.layoutTopCenter(contentSize: NSSize(width: 260, height: 60))
        panel?.orderFrontRegardless()
    }

    private func hideIsland() {
        panel?.orderOut(nil)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.phase = .idle
            self?.hideIsland()
        }
    }
}
