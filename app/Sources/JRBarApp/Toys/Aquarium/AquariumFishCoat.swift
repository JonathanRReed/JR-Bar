import AppKit
import JRBarCore
import SwiftUI

/// The colours a fish is born with (docs/TOYS.md). Each species has its
/// own coat, chosen to stand off blue water: a clownfish is orange and a
/// tang is blue whoever runs them. The provider still shows, because the
/// provider picks the species (`FishSpecies.forProvider`).
extension CartoonFish {
    typealias RGB = (Double, Double, Double)

    /// One species' natural colours, before the tank's water washes them.
    struct Coat: Sendable {
        /// The flank.
        var base: RGB
        /// The back, where the surface lights it.
        var light: RGB
        /// The shaded lower flank and the soft markings.
        var dark: RGB
        /// The underside.
        var belly: RGB
        /// Plain fin membranes.
        var fin: RGB
        /// The fins that carry the species' second colour: an angelfish's
        /// sails, a betta's veils, a tang's tail.
        var accent: RGB
        /// The bold markings: bars, bands and the tang's sweep.
        var mark: RGB

        func map(_ f: (RGB) -> RGB) -> Coat {
            Coat(base: f(base), light: f(light), dark: f(dark), belly: f(belly),
                 fin: f(fin), accent: f(accent), mark: f(mark))
        }

        /// A coat grown from one colour, for the golden fish and for a
        /// fish painted by hand in a proof.
        static func mono(_ c: RGB) -> Coat {
            Coat(base: c,
                 light: CartoonFish.mix(c, (1, 1, 1), 0.42),
                 dark: CartoonFish.mix(c, (0.03, 0.07, 0.19), 0.42),
                 belly: CartoonFish.mix(c, (1, 0.97, 0.90), 0.62),
                 fin: CartoonFish.mix(c, (1, 1, 1), 0.12),
                 accent: CartoonFish.mix(c, (1, 1, 1), 0.12),
                 mark: CartoonFish.mix(c, (0.02, 0.03, 0.08), 0.70))
        }
    }

    private static func hex(_ value: UInt32) -> RGB {
        (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// Every species' coat.
    static func coat(for species: FishSpecies) -> Coat {
        switch species {
        case .clownfish:
            Coat(base: hex(0xFF7A2A), light: hex(0xFFB062), dark: hex(0xC4461A), belly: hex(0xFFD3A3),
                 fin: hex(0xFF8B3C), accent: hex(0xFF8B3C), mark: hex(0x1C1530))
        case .shark:
            Coat(base: hex(0x6E8798), light: hex(0xA9C0CE), dark: hex(0x3A4D5E), belly: hex(0xF5F2EA),
                 fin: hex(0x6A8394), accent: hex(0x6A8394), mark: hex(0x3A4D5E))
        case .angelfish:
            Coat(base: hex(0xE6DEC2), light: hex(0xFFFBEA), dark: hex(0x9A9174), belly: hex(0xFFF8E6),
                 fin: hex(0xE9DDAE), accent: hex(0x8DB4FF), mark: hex(0x2A2C5A))
        case .puffer:
            Coat(base: hex(0xF2C64A), light: hex(0xFFE89A), dark: hex(0xB98A1C), belly: hex(0xFFF5D8),
                 fin: hex(0xF8DB78), accent: hex(0xF8DB78), mark: hex(0x6B4A1A))
        case .seahorse:
            Coat(base: hex(0xFF8F5E), light: hex(0xFFC29C), dark: hex(0xC4522E), belly: hex(0xFFE2C8),
                 fin: hex(0xFFD4B4), accent: hex(0xFFB347), mark: hex(0xC4522E))
        case .betta:
            Coat(base: hex(0xC8325E), light: hex(0xF27392), dark: hex(0x7A1640), belly: hex(0xF7B6C6),
                 fin: hex(0x6B4FE6), accent: hex(0x6B4FE6), mark: hex(0x7A1640))
        case .tang:
            Coat(base: hex(0x2F63EA), light: hex(0x74A1FF), dark: hex(0x173A9E), belly: hex(0x8DB2FF),
                 fin: hex(0x2756D4), accent: hex(0xFFD23F), mark: hex(0x0D1430))
        case .tetra:
            Coat(base: hex(0xA9BCD0), light: hex(0xE2EEF8), dark: hex(0x5D7088), belly: hex(0xE3DCE6),
                 fin: hex(0xC3D3E2), accent: hex(0xC3D3E2), mark: hex(0x5D7088))
        case .minnow:
            Coat(base: hex(0x8FBFAE), light: hex(0xD6F2E4), dark: hex(0x3E6E68), belly: hex(0xF2F4E2),
                 fin: hex(0xA9D8C6), accent: hex(0xA9D8C6), mark: hex(0x2F5A57))
        }
    }

    /// The golden fish's coat: one fish in two dozen wears it.
    static let goldenCoat = Coat(
        base: (0.98, 0.76, 0.22), light: (1.0, 0.91, 0.56), dark: (0.74, 0.50, 0.08),
        belly: (1.0, 0.95, 0.78), fin: (1.0, 0.84, 0.38), accent: (1.0, 0.84, 0.38),
        mark: (0.45, 0.28, 0.04))

    /// What has happened to the fish's colour.
    enum Look: Sendable {
        /// Its own coat.
        case natural
        /// A failed run: the pattern stays and the colour drains out.
        case drained
    }

    static func mix(_ a: RGB, _ b: RGB, _ u: Double) -> RGB {
        (a.0 + (b.0 - a.0) * u, a.1 + (b.1 - a.1) * u, a.2 + (b.2 - a.2) * u)
    }

    /// `c` pulled toward its own grey by `t` (1 is fully grey).
    static func desaturated(_ c: RGB, _ t: Double) -> RGB {
        let l = 0.30 * c.0 + 0.59 * c.1 + 0.11 * c.2
        return mix(c, (l, l, l), t)
    }

    /// `c` with its hue turned by `degrees`, brightness kept: two fish of
    /// one provider differ by a few degrees, so they are two fish.
    static func hueTurned(_ c: RGB, degrees: Double) -> RGB {
        guard degrees != 0 else { return c }
        let a = degrees * .pi / 180
        let cosA = cos(a), sinA = sin(a)
        // A rotation about the grey axis, in RGB.
        let k = (1 - cosA) / 3, s = sinA / 3.0.squareRoot()
        let r = c.0 * (cosA + k) + c.1 * (k - s) + c.2 * (k + s)
        let g = c.0 * (k + s) + c.1 * (cosA + k) + c.2 * (k - s)
        let b = c.0 * (k - s) + c.1 * (k + s) + c.2 * (cosA + k)
        return (min(1, max(0, r)), min(1, max(0, g)), min(1, max(0, b)))
    }

    // MARK: The kit's fixed paints

    /// A plain sRGB colour from three numbers; a frame resolves it for free.
    static func paint(_ c: RGB) -> Color { Color(.sRGB, red: c.0, green: c.1, blue: c.2) }

    /// The warm light the sand throws back under a belly.
    static let sandBounce = paint((1.0, 0.914, 0.761))
    /// The white of an eye, and its cooler lower edge.
    static let eyeWhite = paint((0.969, 0.984, 1.0))
    static let eyeShade = paint((0.84, 0.89, 0.95))
    /// The iris: nearly black, a little blue.
    static let iris = paint((0.106, 0.141, 0.20))
    /// A clownfish's bars, top and bottom.
    static let barWhite = paint((1.0, 0.99, 0.97))
    static let barShade = paint((0.92, 0.94, 0.97))
    /// The gold of a finished run's sparkles.
    static let finishGold = paint((1.0, 0.83, 0.37))
    /// The dots and the drop shadow of an asking fish's speech bubble.
    static let askInk = paint((0.42, 0.21, 0))
    static let askShadow = paint((0.35, 0.19, 0))
}
