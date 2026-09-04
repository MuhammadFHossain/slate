import AppKit
import SwiftUI

// MARK: - System blur

/// The system blur behind Slate's surfaces. `.behindWindow` samples whatever
/// is under the panel, which is what makes the island read as frosted glass
/// over the app you are typing into rather than a painted card.
///
/// Rounded corners come from `maskImage`, not a layer mask: a behind-window
/// backdrop is composited by the window server and ignores CALayer masks, so
/// a plain `clipShape` would leave square blur corners poking out.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized: Bool = false
    var radius: CGFloat = 0
    var roundTop: Bool = true

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.wantsLayer = true
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.isEmphasized = emphasized
        view.maskImage = radius > 0 ? GlassMask.image(radius: radius, roundTop: roundTop) : nil
    }
}

/// A resizable mask image with the chosen corners rounded. Cap insets equal
/// to the radius keep the corners crisp at any size.
enum GlassMask {
    static func image(radius: CGFloat, roundTop: Bool) -> NSImage {
        let r = max(radius, 1)
        let side = r * 2 + 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath()
            let tl: CGFloat = roundTop ? r : 0
            let tr: CGFloat = roundTop ? r : 0
            let bl: CGFloat = r
            let br: CGFloat = r
            path.move(to: NSPoint(x: rect.minX + tl, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX - tr, y: rect.maxY))
            if tr > 0 {
                path.appendArc(
                    withCenter: NSPoint(x: rect.maxX - tr, y: rect.maxY - tr),
                    radius: tr, startAngle: 90, endAngle: 0, clockwise: true
                )
            }
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY + br))
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX - br, y: rect.minY + br),
                radius: br, startAngle: 0, endAngle: 270, clockwise: true
            )
            path.line(to: NSPoint(x: rect.minX + bl, y: rect.minY))
            path.appendArc(
                withCenter: NSPoint(x: rect.minX + bl, y: rect.minY + bl),
                radius: bl, startAngle: 270, endAngle: 180, clockwise: true
            )
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY - tl))
            if tl > 0 {
                path.appendArc(
                    withCenter: NSPoint(x: rect.minX + tl, y: rect.maxY - tl),
                    radius: tl, startAngle: 180, endAngle: 90, clockwise: true
                )
            }
            path.close()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Glass surface

/// A glass card, built the way light actually behaves on a pane: the system
/// blur underneath, thin enough sheen that what is behind still shows
/// through, a light catch near the top-left corner, a specular line just
/// inside the top edge, a touch of shade along the bottom for thickness, an
/// outer edge that is white where the light hits and emerald where it
/// leaves, and a deep diffuse shadow with a green glow. `roundTop` false
/// gives the island its hangs-from-the-menu-bar silhouette.
struct GlassSurface: ViewModifier {
    var radius: CGFloat
    var roundTop: Bool = true
    var material: NSVisualEffectView.Material = .popover

    @Environment(\.colorScheme) private var scheme

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: roundTop ? radius : 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: roundTop ? radius : 0,
            style: .continuous
        )
    }

    private var dark: Bool { scheme == .dark }

    /// White at one opacity in light mode and another in dark.
    private func white(_ light: Double, _ darkValue: Double) -> Color {
        Color.white.opacity(dark ? darkValue : light)
    }

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    VisualEffectView(material: material, radius: radius, roundTop: roundTop)
                    // Sheen: brighter along the top, thin enough that the app
                    // behind the glass still shows through.
                    LinearGradient(
                        colors: [white(0.42, 0.12), white(0.10, 0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                    // The brand green, cast in from the top-leading corner.
                    LinearGradient(
                        colors: [Brand.emerald.opacity(dark ? 0.20 : 0.16), Brand.emerald.opacity(0)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    // A light catch near the top-left, the way a lamp sits on glass.
                    RadialGradient(
                        colors: [white(0.55, 0.18), Color.white.opacity(0)],
                        center: UnitPoint(x: 0.18, y: 0), startRadius: 0, endRadius: 170
                    )
                    // Thickness: the pane darkens a touch toward its bottom edge.
                    LinearGradient(
                        stops: [
                            .init(color: Color.black.opacity(0), location: 0),
                            .init(color: Color.black.opacity(0), location: 0.65),
                            .init(color: Color.black.opacity(dark ? 0.22 : 0.07), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .clipShape(shape)
            )
            .overlay(
                // Outer edge: white where the light hits the top, a whisper of
                // emerald where it leaves the bottom.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            white(1.0, 0.55),
                            white(0.45, 0.14),
                            Brand.emerald.opacity(dark ? 0.45 : 0.35),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .overlay(
                // Specular line just inside the top edge.
                shape.inset(by: 1.5).strokeBorder(
                    LinearGradient(
                        colors: [white(0.70, 0.30), Color.white.opacity(0)],
                        startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.4)
                    ),
                    lineWidth: 1
                )
            )
            .background(
                // Shadow drawn as a blurred shape underneath, since the hosted
                // blur view is not part of SwiftUI's own shadow rasterization.
                shape
                    .fill(Color.black.opacity(dark ? 0.55 : 0.22))
                    .blur(radius: 18)
                    .offset(y: 10)
            )
            .background(
                shape
                    .fill(Brand.emerald.opacity(dark ? 0.26 : 0.20))
                    .blur(radius: 26)
                    .offset(y: 4)
            )
    }
}

extension View {
    /// A free-standing glass card with all corners rounded.
    func glassCard(radius: CGFloat = 18, material: NSVisualEffectView.Material = .popover) -> some View {
        modifier(GlassSurface(radius: radius, roundTop: true, material: material))
    }

    /// The "hangs from the top" island: square top so it meets the menu bar,
    /// rounded bottom so it reads as an island dropping down. No top padding so
    /// the surface sits flush against the menu bar; outer padding leaves room
    /// for the shadow inside the panel's frame.
    func islandSurface() -> some View {
        self
            .padding(.horizontal, 18)
            .padding(.top, 13)
            .padding(.bottom, 14)
            .modifier(GlassSurface(radius: 22, roundTop: false))
            .padding(.horizontal, 28)
            .padding(.bottom, 30)
            .fixedSize()
    }
}

// MARK: - Small shared pieces

/// A soft pulsing dot, the "live" indicator next to the listening label.
struct LiveDot: View {
    var color: Color = Brand.emerald
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(on ? 0.9 : 0.3), radius: on ? 6 : 2)
            .scaleEffect(on ? 1.0 : 0.82)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

/// A capsule keycap for hints like "⌥" or "esc".
struct KeyCap: View {
    var label: String

    var body: some View {
        Text(label)
            .font(Brand.ui(10, weight: .semibold))
            .foregroundStyle(Brand.inkSoft)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Brand.emerald.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Brand.emerald.opacity(0.22), lineWidth: 0.5)
            )
    }
}
