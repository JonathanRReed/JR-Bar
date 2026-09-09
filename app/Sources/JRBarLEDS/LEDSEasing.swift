import Foundation

/// The eight easing names the firmware accepts.
public enum LEDSEasing: String, CaseIterable, Sendable, Hashable, Codable {
    case linear
    case ease
    case easeIn = "ease-in"
    case easeOut = "ease-out"
    case easeInOut = "ease-in-out"
    case cosine
    case pulse
    case none

    /// Case-insensitive lookup, the way the firmware tokenizes.
    public init?(token: String) {
        self.init(rawValue: token.lowercased())
    }

    /// The transition progress for phase `p` in 0...1.
    ///
    /// Measured against `sdled.wasm` (colour fades, and rolls, which multiply
    /// the easing by the LED count and so expose it at 8x resolution):
    ///
    /// * the four CSS names are the exact CSS cubic beziers;
    /// * `cosine` is a half cosine sampled into a 16-segment piecewise-linear
    ///   table (exact at multiples of 1/16, slightly above the true curve in
    ///   between -- visible as a few codes on a roll, under one on a fade);
    /// * `pulse` walks that same table out and back: peak at the midpoint,
    ///   start colour again at the end;
    /// * `none` is a jump to the target.
    public func value(_ p: Double) -> Double {
        if p <= 0 { return self == .none ? 1.0 : 0.0 }
        if p >= 1 { return self == .pulse ? 0.0 : 1.0 }
        switch self {
        case .linear: return p
        case .ease: return CubicBezier.ease.solve(p)
        case .easeIn: return CubicBezier.easeIn.solve(p)
        case .easeOut: return CubicBezier.easeOut.solve(p)
        case .easeInOut: return CubicBezier.easeInOut.solve(p)
        case .cosine: return CosineTable.value(p)
        case .pulse: return p <= 0.5 ? CosineTable.value(2.0 * p) : CosineTable.value(2.0 - 2.0 * p)
        case .none: return 1.0
        }
    }
}

/// The firmware's half-cosine ramp: 17 nodes, linear in between.
enum CosineTable {
    static let segments = 16
    static let nodes: [Double] = (0...segments).map { 0.5 - 0.5 * cos(Double.pi * Double($0) / Double(segments)) }

    static func value(_ p: Double) -> Double {
        if p <= 0 { return 0 }
        if p >= 1 { return 1 }
        let x = p * Double(segments)
        let index = min(segments - 1, Int(x.rounded(.down)))
        let fraction = x - Double(index)
        return nodes[index] + (nodes[index + 1] - nodes[index]) * fraction
    }
}

/// A CSS-style cubic bezier timing function, solved for x by bisection.
struct CubicBezier: Sendable {
    let x1: Double, y1: Double, x2: Double, y2: Double

    static let ease = CubicBezier(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1.0)
    static let easeIn = CubicBezier(x1: 0.42, y1: 0.0, x2: 1.0, y2: 1.0)
    static let easeOut = CubicBezier(x1: 0.0, y1: 0.0, x2: 0.58, y2: 1.0)
    static let easeInOut = CubicBezier(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0)

    @inline(__always)
    private func curve(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let mt = 1.0 - t
        return 3.0 * mt * mt * t * a + 3.0 * mt * t * t * b + t * t * t
    }

    func solve(_ x: Double) -> Double {
        var lo = 0.0
        var hi = 1.0
        var t = x
        // Newton first: converges in a handful of steps for these gentle curves.
        for _ in 0..<8 {
            let mt = 1.0 - t
            let xt = curve(t, x1, x2) - x
            let dx = 3.0 * mt * mt * x1 + 6.0 * mt * t * (x2 - x1) + 3.0 * t * t * (1.0 - x2)
            if abs(xt) < 1e-9 { return curve(t, y1, y2) }
            if dx.magnitude < 1e-9 { break }
            t -= xt / dx
            if t < 0 || t > 1 { break }
        }
        // Bisection as the guaranteed fallback.
        for _ in 0..<40 {
            t = (lo + hi) / 2.0
            if curve(t, x1, x2) < x { lo = t } else { hi = t }
        }
        return curve((lo + hi) / 2.0, y1, y2)
    }
}
