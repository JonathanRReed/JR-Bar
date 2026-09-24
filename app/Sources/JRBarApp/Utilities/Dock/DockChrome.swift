import AppKit
import SwiftUI

/// What the Dock's floating surfaces share — the preview panel, its
/// cards and the ⌥⇥ switcher: continuous corners, a hairline rim that
/// reads on glass in either appearance, quiet plates, and the traffic
/// lights' three colours kept for the moment a verb is under the hand.
enum DockChrome {
    /// A still's corner at thumbnail size.
    static let stillRadius: CGFloat = 8
    /// The rim a still or artwork wears so it never bleeds into glass.
    static let hairline = Color.primary.opacity(0.12)
    /// The pointer's plate under a card, a chip or a row.
    static let plateHover = Color.primary.opacity(0.08)
    /// Quit, close.
    static let stop = Color(red: 1.0, green: 0.37, blue: 0.34)
    /// Minimize, hide.
    static let caution = Color(red: 1.0, green: 0.74, blue: 0.18)
    /// New window, full screen.
    static let go = Color(red: 0.16, green: 0.79, blue: 0.35)
}

/// A hairline between the panel's sections.
struct DockPanelRule: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 2)
    }
}

/// A window's still as every Dock surface draws it: fitted, its own
/// corners rounded (not the letterbox's), a hairline rim and a soft
/// lift off the glass. A waiting agent's ring sits just outside the
/// still's own edge, concentric with it, and glows a little.
struct DockStill: View {
    let image: NSImage
    var radius: CGFloat = DockChrome.stillRadius
    var ring: Color? = nil
    var ringWidth: CGFloat = 2

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .clipShape(shape)
            .overlay(shape.strokeBorder(DockChrome.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.24), radius: 5, y: 2)
            .overlay {
                if let ring {
                    RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                        .strokeBorder(ring, lineWidth: ringWidth)
                        .padding(-3)
                        .shadow(color: ring.opacity(0.55), radius: 5)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The face of a window with no still — no Screen Recording, a capture
/// that failed, a card past the compact limit: the app's own icon on a
/// soft plate, and "Minimized" when that is why.
struct DockStillPlaceholder: View {
    let icon: NSImage?
    var minimized = false
    var ring: Color? = nil
    var radius: CGFloat = DockChrome.stillRadius

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(Color.primary.opacity(0.06))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .overlay {
                VStack(spacing: 6) {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 40, height: 40)
                            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                            .opacity(minimized ? 0.7 : 1)
                    }
                    if minimized {
                        Text("Minimized")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if let ring {
                    RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                        .strokeBorder(ring, lineWidth: 2)
                        .padding(-3)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The minimized mark on a still's corner — the Dock's own
/// "tucked away" arrows on a dark disc that reads on any window.
struct DockMinimizedMark: View {
    var body: some View {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .accessibilityLabel("Minimized")
    }
}

/// The Dock tile's unread pill, verbatim — the red the Dock draws, with
/// a lift so it reads over the icon it rides.
struct DockBadgePill: View {
    let text: String
    var size: CGFloat = 9.5

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, size * 0.42)
            .frame(minWidth: size * 1.7, minHeight: size * 1.7)
            .background(Capsule().fill(Color(red: 1.0, green: 0.23, blue: 0.19)))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
    }
}

/// A verb drawn as a quiet glass disc — the glyph in the secondary ink
/// until the pointer arrives, then the verb's own colour. `onStill`
/// darkens the resting disc so it reads over any window's pixels. The
/// label carries the tooltip and the accessibility name.
struct DockRoundVerb: View {
    let symbol: String
    var tint: Color = .accentColor
    let label: String
    var size: CGFloat = 22
    var onStill = false
    /// Held in its colour — Quit's second life as Force Quit.
    var lit = false
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                // scaledToFit, not a font size alone: a small symbol rides
                // its text baseline and floats off the disc's centre.
                .resizable()
                .scaledToFit()
                .fontWeight(.bold)
                .frame(width: size * 0.4, height: size * 0.4)
                .foregroundStyle(glyph)
                .frame(width: size, height: size)
                .background(Circle().fill(disc))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }

    private var glyph: AnyShapeStyle {
        if hovering || lit { return AnyShapeStyle(Color.white) }
        return onStill ? AnyShapeStyle(Color.white.opacity(0.92)) : AnyShapeStyle(.secondary)
    }

    private var disc: AnyShapeStyle {
        if hovering || lit { return AnyShapeStyle(tint) }
        return onStill ? AnyShapeStyle(Color.black.opacity(0.5)) : AnyShapeStyle(Color.primary.opacity(0.08))
    }
}

/// A small capsule button that keeps its colour in a panel that never
/// becomes key — AppKit's bordered buttons go grey there, and a grey
/// Approve read as disabled on the one row that most needs it clear.
/// Prominent fills with `tint` and picks white or black ink by the
/// tint's own lightness, so a yellow provider still reads.
struct DockCapsuleButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        DockCapsuleFace(configuration: configuration, prominent: prominent, tint: tint)
    }
}

private struct DockCapsuleFace: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let tint: Color
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .foregroundStyle(ink)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(prominent ? 0 : 0.1), lineWidth: 0.5))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
    }

    private var ink: Color {
        guard prominent else { return .primary }
        return Self.isLight(tint) ? Color.black.opacity(0.85) : .white
    }

    private var fill: Color {
        if prominent { return tint.opacity(configuration.isPressed ? 0.75 : 1) }
        return Color.primary.opacity(configuration.isPressed ? 0.16 : 0.09)
    }

    /// Whether `color` is light enough that white ink would wash out.
    static func isLight(_ color: Color) -> Bool {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.68
    }
}
