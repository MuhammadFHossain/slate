import SwiftUI

/// Slate's look, taken from the app icon: two greens and a serif face. Bright
/// and clear on purpose. The app forces aqua (see SlateApp) so these read the
/// same over any wallpaper.
enum Brand {
    /// Emerald #00BF63 — the signature green: the waveform, accents, borders.
    static let emerald = Color(red: 0 / 255, green: 191 / 255, blue: 99 / 255)
    /// Lime #C1FF72 — the bright, cheerful light green.
    static let lime = Color(red: 193 / 255, green: 255 / 255, blue: 114 / 255)
    /// Deep green ink, dark enough to read clearly on the bright pill.
    static let deepGreen = Color(red: 8 / 255, green: 54 / 255, blue: 32 / 255)
    /// The pill surface: a bright near-white with a faint lime warmth.
    static let surface = Color(red: 244 / 255, green: 253 / 255, blue: 236 / 255)
    /// Warm coral, kept only for the rare error line so it reads apart from green.
    static let coral = Color(red: 240 / 255, green: 89 / 255, blue: 43 / 255)

    /// A serif face (New York on macOS): bright, clear, with a little warmth.
    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}
