import Foundation

/// Whether two light colours stay apart for everyone who looks at them.
///
/// The state and provider colours are editable, and a pair that reads
/// clearly with typical vision can collapse into one colour for a person
/// with a red-, green- or blue-cone deficiency — the dichromacy-safe
/// defaults stop being safe the moment someone edits a well. This
/// simulates the three dichromacies (Machado, Oliveira & Fernandes 2009,
/// severity 1, applied in linear sRGB), measures the distance in CIELAB
/// (ΔE 1976), and names the pairs that collapse, with a nudge that pulls
/// one colour apart by lightness while keeping its hue.
public enum ColorVision: String, CaseIterable, Sendable {
    case typical
    case protan
    case deutan
    case tritan

    /// How the Settings row names the vision.
    public var name: String {
        switch self {
        case .typical: return "typical colour vision"
        case .protan: return "protanopia (red-blind)"
        case .deutan: return "deuteranopia (green-blind)"
        case .tritan: return "tritanopia (blue-blind)"
        }
    }

    /// Below this ΔE two lights read as the same colour at a glance.
    /// Lights are seen small and quickly; this is deliberately wider than
    /// the print "just noticeable" of 2–3.
    public static let collisionDistance = 18.0

    private var matrix: [[Double]]? {
        switch self {
        case .typical:
            return nil
        case .protan:
            return [[0.152286, 1.052583, -0.204868],
                    [0.114503, 0.786281, 0.099216],
                    [-0.003882, -0.048116, 1.051998]]
        case .deutan:
            return [[0.367322, 0.860646, -0.227968],
                    [0.280085, 0.672501, 0.047413],
                    [-0.011820, 0.042940, 0.968881]]
        case .tritan:
            return [[1.255528, -0.076749, -0.178779],
                    [-0.078411, 0.930809, 0.147602],
                    [0.004733, 0.691367, 0.303900]]
        }
    }

    // MARK: Colour maths

    /// `#RRGGBB` → sRGB 0…1, nil for anything else.
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        guard let canonical = normalizedColorHex(hex),
              let value = UInt32(canonical.dropFirst(), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ c: Double) -> Double {
        let clamped = min(1, max(0, c))
        return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }

    /// The colour as this vision sees it, in linear sRGB.
    func simulate(_ color: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
        let linearColor = [Self.linear(color.r), Self.linear(color.g), Self.linear(color.b)]
        guard let matrix else { return (linearColor[0], linearColor[1], linearColor[2]) }
        let out = matrix.map { row in zip(row, linearColor).map(*).reduce(0, +) }
        return (min(1, max(0, out[0])), min(1, max(0, out[1])), min(1, max(0, out[2])))
    }

    /// Linear sRGB → CIELAB (D65).
    static func lab(linear c: (r: Double, g: Double, b: Double)) -> (l: Double, a: Double, b: Double) {
        let x = (0.4124564 * c.r + 0.3575761 * c.g + 0.1804375 * c.b) / 0.95047
        let y = 0.2126729 * c.r + 0.7151522 * c.g + 0.0721750 * c.b
        let z = (0.0193339 * c.r + 0.1191920 * c.g + 0.9503041 * c.b) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// ΔE 1976 between two hex colours as this vision sees them.
    public func distance(_ a: String, _ b: String) -> Double? {
        guard let x = Self.rgb(a), let y = Self.rgb(b) else { return nil }
        let p = Self.lab(linear: simulate(x)), q = Self.lab(linear: simulate(y))
        return sqrt(pow(p.l - q.l, 2) + pow(p.a - q.a, 2) + pow(p.b - q.b, 2))
    }

    /// The smallest distance across every vision, and which vision it is.
    public static func worst(_ a: String, _ b: String) -> (vision: ColorVision, distance: Double)? {
        let all = allCases.compactMap { vision in vision.distance(a, b).map { (vision, $0) } }
        return all.min { $0.1 < $1.1 }
    }

    // MARK: Collisions

    /// A pair of named colours that collapse for some vision.
    public struct Collision: Equatable, Sendable, Identifiable {
        public let first: String
        public let second: String
        public let vision: ColorVision
        public let distance: Double

        public var id: String { first + "|" + second }
    }

    /// Every pair among `colors` (id → hex, in the given order) that
    /// reads as one colour for at least one vision — the worst vision
    /// named. Pairs already identical to typical vision are named too:
    /// that is a choice worth seeing, not a simulation artefact.
    public static func collisions(_ colors: [(id: String, hex: String)],
                                  threshold: Double = collisionDistance) -> [Collision] {
        var found: [Collision] = []
        for i in colors.indices {
            for j in colors.indices where j > i {
                guard let worst = worst(colors[i].hex, colors[j].hex), worst.distance < threshold else { continue }
                found.append(Collision(first: colors[i].id, second: colors[j].id,
                                       vision: worst.vision, distance: worst.distance))
            }
        }
        return found
    }

    /// `hex` moved apart from `other` by lightness alone — hue and
    /// saturation kept — just far enough that every vision tells them
    /// apart; nil when no lightness step up to ±45 L* does it. Smaller
    /// steps win, lighter before darker on a tie (a light should not go
    /// dim to be told apart).
    public static func nudge(_ hex: String, awayFrom other: String,
                             threshold: Double = collisionDistance) -> String? {
        guard let rgb = rgb(hex) else { return nil }
        let base = lab(linear: (linear(rgb.r), linear(rgb.g), linear(rgb.b)))
        for step in stride(from: 3.0, through: 45.0, by: 3.0) {
            for sign in [1.0, -1.0] {
                let l = min(100, max(0, base.l + sign * step))
                guard let candidate = hexFromLab(l: l, a: base.a, b: base.b) else { continue }
                if let worst = worst(candidate, other), worst.distance >= threshold { return candidate }
            }
        }
        return nil
    }

    /// CIELAB (D65) → `#RRGGBB`, clamped into gamut.
    static func hexFromLab(l: Double, a: Double, b: Double) -> String? {
        let fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        func inverse(_ t: Double) -> Double { t * t * t > 216.0 / 24389.0 ? t * t * t : (116 * t - 16) / (24389.0 / 27.0) }
        let x = inverse(fx) * 0.95047, y = inverse(fy), z = inverse(fz) * 1.08883
        let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let bl = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        func byte(_ c: Double) -> Int { Int((encoded(c) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(bl))
    }
}
