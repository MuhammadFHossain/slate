import SwiftUI

/// Slate's look. One accent, the icon's emerald, on adaptive glass; all other
/// ink is system so every surface reads right in light and dark mode and over
/// any wallpaper.
enum Brand {
    /// Emerald #00BF63, the signature green: waveform, accents, live dot.
    static let emerald = Color(red: 0 / 255, green: 191 / 255, blue: 99 / 255)
    /// Mint, the lighter end of the accent gradient.
    static let mint = Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)
    /// Lime #C1FF72, the icon's bright green; used sparingly for glow.
    static let lime = Color(red: 193 / 255, green: 255 / 255, blue: 114 / 255)
    /// Warm coral, kept only for the rare error line so it reads apart from green.
    static let coral = Color(red: 240 / 255, green: 89 / 255, blue: 43 / 255)

    /// Body ink and secondary ink, adaptive.
    static let ink = Color.primary
    static let inkSoft = Color.secondary

    /// The accent as a gradient, top to bottom.
    static var accent: LinearGradient {
        LinearGradient(colors: [emerald, mint], startPoint: .top, endPoint: .bottom)
    }

    /// Labels and controls: SF Rounded, the modern, friendly system face.
    static func ui(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Running text (the transcript, history entries): plain SF for legibility.
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}
