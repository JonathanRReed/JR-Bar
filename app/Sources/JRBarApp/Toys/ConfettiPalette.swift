import AppKit
import JRBarCore
import SwiftUI

/// The burst's colours: which slots a palette choice deals, and the
/// deeper shade a paper's back shows.
extension ConfettiView {
    /// Six colour slots for a palette choice. Provider & Toys tint build
    /// the same steps around a base — light, dark, white, a gold fleck, a
    /// pale step for the glyph flecks; Rainbow is a six-colour spectrum
    /// kept inside the app's saturation range.
    static func paletteColors(_ choice: ConfettiPalette, provider color: Color) -> [Color] {
        switch choice {
        case .provider: return steps(around: color)
        case .toys: return steps(around: toysTint)
        case .rainbow:
            return [0.0, 0.08, 0.15, 0.36, 0.56, 0.76].map {
                Color(hue: $0, saturation: 0.62, brightness: 0.96)
            }
        }
    }

    private static func steps(around color: Color) -> [Color] {
        [color,
         color.mix(with: .white, by: 0.4),
         deeper(color),
         .white,
         Color(red: 0.98, green: 0.78, blue: 0.3),   // warm gold fleck
         color.mix(with: .white, by: 0.62)]         // pale — glyph flecks
    }

    /// The same colour, darker and a little richer — the shaded side of
    /// a coloured paper. Mixing in black would grey it toward mud, and a
    /// yellow darkened in place turns olive, so the shade leans the way a
    /// painter's does: yellows and oranges toward amber, greens toward
    /// teal.
    static func deeper(_ color: Color) -> Color {
        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else {
            return color.mix(with: .black, by: 0.25)
        }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // White has no hue to deepen: it turns a cool pearl grey instead.
        guard saturation > 0.05 else { return Color(white: 0.78) }
        let lean: CGFloat
        if (0.06..<0.2).contains(hue) {
            lean = -0.045
        } else if (0.2..<0.45).contains(hue) {
            lean = 0.03
        } else {
            lean = 0
        }
        return Color(hue: Double(hue + lean), saturation: Double(min(1, saturation * 1.15 + 0.05)),
                     brightness: Double(brightness * 0.72), opacity: Double(alpha))
    }
}
