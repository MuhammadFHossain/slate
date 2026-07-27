import Foundation

/// Pauses whatever is playing while you dictate, so the mic hears you and not
/// your music, then brings it back when you let go. Talks to the system media
/// controls the same keys on your keyboard use; if they are unavailable it just
/// does nothing.
final class MediaController {
    static let shared = MediaController()

    private typealias SendCommandFn = @convention(c) (Int32, CFDictionary?) -> Bool
    private typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void

    private let sendCommand: SendCommandFn?
    private let isPlaying: IsPlayingFn?

    /// True while a dictation turn wants playback held. Guards the async
    /// is-playing callback so a turn that ended first never pauses after the fact.
    private var active = false
    /// True only if we actually paused something, so we resume only that.
    private var didPause = false

    private init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        let handle = dlopen(path, RTLD_LAZY)
        func bind<T>(_ symbol: String, as type: T.Type) -> T? {
            guard let handle, let sym = dlsym(handle, symbol) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }
        sendCommand = bind("MRMediaRemoteSendCommand", as: SendCommandFn.self)
        isPlaying = bind("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: IsPlayingFn.self)
    }

    private enum Command: Int32 { case play = 0, pause = 1 }

    /// If media is playing right now, pause it and remember to resume later.
    func pauseIfPlaying() {
        guard let isPlaying, let sendCommand else { return }
        active = true
        isPlaying(DispatchQueue.main) { [weak self] playing in
            guard let self, self.active, playing, !self.didPause else { return }
            self.didPause = true
            _ = sendCommand(Command.pause.rawValue, nil)
        }
    }

    /// Resume only what we paused, and cancel any pending pause.
    func resume() {
        active = false
        guard didPause, let sendCommand else { return }
        didPause = false
        _ = sendCommand(Command.play.rawValue, nil)
    }
}
