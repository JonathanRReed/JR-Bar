import AppKit
import CoreGraphics
import Synchronization

/// A provider's real mark (the Claude spark, the OpenAI blossom, the
/// Gemini sparkle…) as one vector path, so every surface draws the mark
/// people recognise instead of a stand-in symbol.
///
/// The marks ship in the source (`ProviderLogoData`, written by
/// `scripts/gen_provider_logos.py` from the pinned SVGs under
/// `app/Resources/ProviderLogos`): nothing is fetched. Each is one
/// non-zero path in a unit square, already fitted, centred and optically
/// scaled, so a caller only places it. A mark is parsed the first time it
/// is asked for and kept for the life of the process.
public final class ProviderLogo: @unchecked Sendable {
    // @unchecked: both properties are immutable after init, and a CGPath is
    // immutable and safe to read from any thread.

    /// The mark's key in `ProviderLogoData` ("openai", "claude", …): what
    /// the mark depicts, not which provider uses it.
    public let id: String
    /// The mark in the unit square, y-down (SwiftUI's orientation).
    public let unitPath: CGPath

    init(id: String, unitPath: CGPath) {
        self.id = id
        self.unitPath = unitPath
    }

    // MARK: Lookup

    private static let cache = Mutex<[String: ProviderLogo]>([:])

    /// The mark called `id`, parsed once and then shared; nil for a name
    /// the data does not carry (the caller draws its fallback).
    public static func named(_ id: String) -> ProviderLogo? {
        if let hit = cache.withLock({ $0[id] }) { return hit }
        guard let data = ProviderLogoData.paths[id], let built = try? make(id: id, data: data) else { return nil }
        return cache.withLock { cache in
            if let raced = cache[id] { return raced }
            cache[id] = built
            return built
        }
    }

    /// Every mark the data carries, sorted.
    public static var ids: [String] { ProviderLogoData.paths.keys.sorted() }

    /// The data's square: its paths are in 0…1000.
    static let dataUnits: CGFloat = 1000

    static func make(id: String, data: String) throws -> ProviderLogo {
        let parsed = try SVGPathParser.parse(data)
        var toUnit = CGAffineTransform(scaleX: 1 / dataUnits, y: 1 / dataUnits)
        return ProviderLogo(id: id, unitPath: parsed.copy(using: &toUnit) ?? parsed)
    }

    // MARK: Drawing

    /// The mark fitted into `rect` (the shorter side, centred), y-down, for
    /// SwiftUI shapes and canvases.
    public func path(in rect: CGRect) -> CGPath {
        let side = min(rect.width, rect.height)
        var place = CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
            .scaledBy(x: side, y: side)
        return unitPath.copy(using: &place) ?? unitPath
    }

    /// Fills the mark into `rect` of a y-up context (an `NSImage` drawing
    /// handler) with the context's current fill colour, plus a `weight`
    /// hairline in its stroke colour. The path is placed through the CTM,
    /// so nothing is copied.
    public func fill(in rect: CGRect, context: CGContext, weight: CGFloat = 0) {
        let side = min(rect.width, rect.height)
        guard side > 0 else { return }
        context.saveGState()
        context.translateBy(x: rect.midX - side / 2, y: rect.midY + side / 2)
        context.scaleBy(x: side, y: -side)
        context.addPath(unitPath)
        if weight > 0 {
            context.setLineWidth(weight / side)
            context.setLineJoin(.round)
            context.drawPath(using: .fillStroke)
        } else {
            context.fillPath(using: .winding)
        }
        context.restoreGState()
    }

    /// The hairline of the mark's own ink a small mark gets, in points of
    /// its side: it keeps Claude's thin rays and Grok's slash on the pixel
    /// grid at 11 pt and below. The detailed marks (the OpenAI knot, Devin,
    /// Hermes) clog up with one, and solid marks gain nothing, so they get
    /// none.
    public static func hairline(for id: String, side: CGFloat) -> CGFloat {
        guard id == "claude" || id == "grok" else { return 0 }
        if side <= 9 { return 0.45 }
        if side <= 11 { return 0.3 }
        return 0
    }
}

/// How a mark's ink keeps its contrast: a provider accent is tuned for the
/// LEDs, and some of them (Grok's grey, Kiro's crimson, OpenClaw's rust)
/// all but vanish as a mark on a dark tile or the notch's black, while the
/// pale ones (Antigravity's green, Cursor's yellow) fade on a light tile.
/// The ink is the accent itself when it already clears the floor, and
/// otherwise the accent moved just far enough toward white (on dark) or
/// black (on light) to clear it: the hue stays, and the LEDs and the
/// tile's own plate keep the raw accent.
public enum ProviderMarkInk {
    /// Where a mark sits.
    public enum Surface: Sendable {
        /// A tile's plate (the accent at 18 % over a dark window).
        case darkPlate
        /// A tile's plate over a light window. The same tile can sit in the
        /// notch's black while the Mac is in light mode, so this ink also
        /// clears the floor on a plate over black.
        case lightPlate
        /// Bare black: the Screen Bar's ears and the notch.
        case black
    }

    /// WCAG's floor for a graphic that has to be seen (1.4.11).
    public static let minimumContrast: CGFloat = 3
    /// The tile's plate: the accent at this opacity over the surface.
    public static let plateOpacity: CGFloat = 0.18
    /// A dark window's rows and panels (`#2C2C2C`) and a light window's
    /// background (`#ECECEC`), the plates' surfaces.
    static let darkSurface = RGB(red: 44 / 255, green: 44 / 255, blue: 44 / 255)
    static let lightSurface = RGB(red: 236 / 255, green: 236 / 255, blue: 236 / 255)

    struct RGB: Equatable {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat

        static let white = RGB(red: 1, green: 1, blue: 1)
        static let black = RGB(red: 0, green: 0, blue: 0)

        func mixed(with other: RGB, by amount: CGFloat) -> RGB {
            RGB(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
                blue: blue + (other.blue - blue) * amount)
        }

        /// WCAG relative luminance of an sRGB colour.
        var luminance: CGFloat {
            func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let r = linear(red), g = linear(green), b = linear(blue)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        func contrast(with other: RGB) -> CGFloat {
            let a = luminance, b = other.luminance
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }

    /// The ink for `accent` on `surface`: the accent when it clears
    /// `minimumContrast`, else the nearest mix toward white or black that
    /// does.
    public static func ink(for accent: NSColor, on surface: Surface) -> NSColor {
        guard let rgb = accent.usingColorSpace(.sRGB) else { return accent }
        let raw = RGB(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
        let inked = ink(raw, on: surface)
        if inked == raw { return accent }
        return NSColor(srgbRed: inked.red, green: inked.green, blue: inked.blue, alpha: rgb.alphaComponent)
    }

    static func ink(_ accent: RGB, on surface: Surface) -> RGB {
        switch surface {
        case .darkPlate:
            return lifted(accent, toward: .white, against: plate(accent, over: darkSurface))
        case .black:
            return lifted(accent, toward: .white, against: .black)
        case .lightPlate:
            let clearOfBlack = lifted(accent, toward: .white, against: plate(accent, over: .black))
            return lifted(clearOfBlack, toward: .black, against: plate(accent, over: lightSurface))
        }
    }

    static func plate(_ accent: RGB, over surface: RGB) -> RGB {
        surface.mixed(with: accent, by: plateOpacity)
    }

    /// `ink` moved toward `target` by the least amount (to 1/4096) that
    /// reaches the floor against `background`.
    static func lifted(_ ink: RGB, toward target: RGB, against background: RGB) -> RGB {
        guard ink.contrast(with: background) < minimumContrast else { return ink }
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<12 {
            let middle = (low + high) / 2
            if ink.mixed(with: target, by: middle).contrast(with: background) >= minimumContrast {
                high = middle
            } else {
                low = middle
            }
        }
        return ink.mixed(with: target, by: high)
    }
}

/// SVG path data to a `CGPath`: every command (M L H V C S Q T A Z,
/// absolute and relative), implicit repeats, packed numbers (`.5.5`,
/// `1-2`), packed arc flags and exponents. The shipped marks use only
/// absolute M L Q C Z, but a hand-pasted path works too. Bad data throws;
/// it never traps.
enum SVGPathParser {
    struct ParseError: Error, CustomStringConvertible {
        let offset: Int
        let reason: String
        var description: String { "SVG path error at \(offset): \(reason)" }
    }

    static func parse(_ data: String) throws -> CGMutablePath {
        var scanner = Scanner(bytes: Array(data.utf8))
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastCubic: CGPoint?
        var lastQuad: CGPoint?
        var command: UInt8 = 0
        var started = false

        while true {
            scanner.skipSeparators()
            guard let byte = scanner.peek else { break }
            if Scanner.isCommand(byte) {
                command = byte
                scanner.index += 1
            } else if command == 0 {
                throw ParseError(offset: scanner.index, reason: "data before a command")
            }
            let relative = command >= 97
            let base = relative ? current : .zero
            let lower = command | 0x20
            if lower != 109, !started {
                // CGPath traps on a segment with no current point.
                throw ParseError(offset: scanner.index, reason: "a path starts with M")
            }
            switch lower {
            case 109: // m
                let point = try scanner.point(offset: base)
                path.move(to: point)
                current = point
                start = point
                started = true
                lastCubic = nil
                lastQuad = nil
                // Pairs after a moveto are implicit linetos.
                command = relative ? 108 : 76
            case 108: // l
                let point = try scanner.point(offset: base)
                path.addLine(to: point)
                current = point
                lastCubic = nil
                lastQuad = nil
            case 104: // h
                let x = try scanner.number() + (relative ? current.x : 0)
                current = CGPoint(x: x, y: current.y)
                path.addLine(to: current)
                lastCubic = nil
                lastQuad = nil
            case 118: // v
                let y = try scanner.number() + (relative ? current.y : 0)
                current = CGPoint(x: current.x, y: y)
                path.addLine(to: current)
                lastCubic = nil
                lastQuad = nil
            case 99: // c
                let control1 = try scanner.point(offset: base)
                let control2 = try scanner.point(offset: base)
                let point = try scanner.point(offset: base)
                path.addCurve(to: point, control1: control1, control2: control2)
                current = point
                lastCubic = control2
                lastQuad = nil
            case 115: // s
                let control1 = reflected(lastCubic, about: current)
                let control2 = try scanner.point(offset: base)
                let point = try scanner.point(offset: base)
                path.addCurve(to: point, control1: control1, control2: control2)
                current = point
                lastCubic = control2
                lastQuad = nil
            case 113: // q
                let control = try scanner.point(offset: base)
                let point = try scanner.point(offset: base)
                path.addQuadCurve(to: point, control: control)
                current = point
                lastQuad = control
                lastCubic = nil
            case 116: // t
                let control = reflected(lastQuad, about: current)
                let point = try scanner.point(offset: base)
                path.addQuadCurve(to: point, control: control)
                current = point
                lastQuad = control
                lastCubic = nil
            case 97: // a
                let rx = try scanner.number()
                let ry = try scanner.number()
                let rotation = try scanner.number()
                let large = try scanner.flag()
                let sweep = try scanner.flag()
                let point = try scanner.point(offset: base)
                addArc(to: path, from: current, rx: rx, ry: ry, degrees: rotation, large: large, sweep: sweep,
                       end: point)
                current = point
                lastCubic = nil
                lastQuad = nil
            case 122: // z
                path.closeSubpath()
                current = start
                lastCubic = nil
                lastQuad = nil
                // Z takes no numbers; the next segment needs its own command.
                scanner.skipSeparators()
                if let next = scanner.peek, !Scanner.isCommand(next) {
                    throw ParseError(offset: scanner.index, reason: "a number after Z")
                }
                command = 0
            default:
                throw ParseError(offset: scanner.index, reason: "unknown command")
            }
        }
        return path
    }

    private static func reflected(_ control: CGPoint?, about point: CGPoint) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    /// SVG's endpoint arc as cubic Béziers (SVG 1.1 F.6.5–F.6.6), one per
    /// quarter turn at most.
    static func addArc(to path: CGMutablePath, from p0: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                       degrees: CGFloat, large: Bool, sweep: Bool, end p1: CGPoint) {
        if p0 == p1 { return }
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if rx == 0 || ry == 0 {
            path.addLine(to: p1)
            return
        }
        let phi = degrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx2 = (p0.x - p1.x) / 2
        let dy2 = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx2 + sinPhi * dy2
        let y1 = -sinPhi * dx2 + cosPhi * dy2
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            let grow = lambda.squareRoot()
            rx *= grow
            ry *= grow
        }
        let rx2 = rx * rx
        let ry2 = ry * ry
        let numerator = rx2 * ry2 - rx2 * y1 * y1 - ry2 * x1 * x1
        let denominator = rx2 * y1 * y1 + ry2 * x1 * x1
        let sign: CGFloat = large != sweep ? 1 : -1
        let coefficient = sign * max(0, numerator / denominator).squareRoot()
        let cxp = coefficient * rx * y1 / ry
        let cyp = -coefficient * ry * x1 / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let ux = (x1 - cxp) / rx
        let uy = (y1 - cyp) / ry
        let vx = (-x1 - cxp) / rx
        let vy = (-y1 - cyp) / ry
        let theta = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep && delta > 0 {
            delta -= 2 * .pi
        } else if sweep && delta < 0 {
            delta += 2 * .pi
        }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        func place(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            let x = cx + rx * cosPhi * u - ry * sinPhi * v
            let y = cy + rx * sinPhi * u + ry * cosPhi * v
            return CGPoint(x: x, y: y)
        }
        var a = theta
        for index in 0..<segments {
            let b = a + step
            let control1 = place(cos(a) - t * sin(a), sin(a) + t * cos(a))
            let control2 = place(cos(b) + t * sin(b), sin(b) - t * cos(b))
            let end = index == segments - 1 ? p1 : place(cos(b), sin(b))
            path.addCurve(to: end, control1: control1, control2: control2)
            a = b
        }
    }

    struct Scanner {
        let bytes: [UInt8]
        var index = 0

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        static func isCommand(_ byte: UInt8) -> Bool {
            switch byte {
            case 77, 109, 76, 108, 72, 104, 86, 118, 67, 99, 83, 115, 81, 113, 84, 116, 65, 97, 90, 122: return true
            default: return false
            }
        }

        static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }

        mutating func skipSeparators() {
            while index < bytes.count {
                switch bytes[index] {
                case 32, 44, 9, 10, 13: index += 1
                default: return
                }
            }
        }

        mutating func point(offset: CGPoint) throws -> CGPoint {
            let x = try number()
            let y = try number()
            return CGPoint(x: x + offset.x, y: y + offset.y)
        }

        mutating func flag() throws -> Bool {
            skipSeparators()
            guard let byte = peek, byte == 48 || byte == 49 else {
                throw ParseError(offset: index, reason: "an arc flag")
            }
            index += 1
            return byte == 49
        }

        /// A decimal read in place (no string is made per number): the
        /// digits as one mantissa, then a power of ten.
        mutating func number() throws -> CGFloat {
            skipSeparators()
            let begin = index
            var negative = false
            if let sign = peek, sign == 43 || sign == 45 {
                negative = sign == 45
                index += 1
            }
            var mantissa: Double = 0
            var digits = 0
            var exponent = 0
            while let byte = peek, Self.isDigit(byte) {
                mantissa = mantissa * 10 + Double(byte - 48)
                digits += 1
                index += 1
            }
            if peek == 46 {
                index += 1
                while let byte = peek, Self.isDigit(byte) {
                    mantissa = mantissa * 10 + Double(byte - 48)
                    digits += 1
                    exponent -= 1
                    index += 1
                }
            }
            guard digits > 0 else { throw ParseError(offset: begin, reason: "expected a number") }
            if let marker = peek, marker == 101 || marker == 69 {
                let save = index
                index += 1
                var exponentNegative = false
                if let sign = peek, sign == 43 || sign == 45 {
                    exponentNegative = sign == 45
                    index += 1
                }
                var written = 0
                var exponentDigits = 0
                while let byte = peek, Self.isDigit(byte) {
                    // Capped: past 10^999 the value is out of range anyway.
                    written = min(999, written * 10 + Int(byte - 48))
                    exponentDigits += 1
                    index += 1
                }
                if exponentDigits == 0 {
                    index = save
                } else {
                    exponent += exponentNegative ? -written : written
                }
            }
            var value = mantissa
            if exponent < 0 {
                value /= pow(10, Double(-exponent))
            } else if exponent > 0 {
                value *= pow(10, Double(exponent))
            }
            guard value.isFinite else { throw ParseError(offset: begin, reason: "a number out of range") }
            return CGFloat(negative ? -value : value)
        }
    }
}
