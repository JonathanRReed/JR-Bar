import AppKit
import JRBarCore
import SwiftUI

/// The burst's colours and marks, resolved once when it fires so a frame
/// never mixes a colour: each palette slot's paper in eight steps of
/// light, front and back, near and far, plus the glyphs a glyph fleck
/// draws and the colour the pop wears.
struct ConfettiLook {
    /// One colour as plain sRGB, so a frame's fill needs no resolving.
    struct Paint: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(_ color: Color) {
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
            self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
        }

        var shading: GraphicsContext.Shading { .color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

        /// Brightness scaled, hue and saturation kept — a paper turned
        /// from the light darkens without greying.
        func lit(_ shade: Double) -> Paint {
            Paint(red: red * shade, green: green * shade, blue: blue * shade)
        }

        func mixed(with other: Paint, by amount: Double) -> Paint {
            Paint(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
                  blue: blue + (other.blue - blue) * amount)
        }
    }

    /// A mark a glyph fleck draws: a provider's real mark (a
    /// `ProviderLogo` id), an SF Symbol or one or two letters.
    enum Glyph: Equatable {
        case symbol(String)
        case text(String)
        case logo(String)
    }

    /// The palette's colours and how often each is dealt.
    var slots: [Color]
    var weights: [Double]
    /// The pop and the Reduce Motion glow.
    var theme: Color
    var glyphs: [Glyph]

    /// How many light steps each paper is resolved in.
    static let lightSteps = 8

    /// [layer: near 0, far 1][side: front 0, back 1][slot][step].
    let papers: [[[[Paint]]]]
    /// A far piece is softened toward the desktop's neutral, like air.
    static let haze = Paint(red: 0.55, green: 0.56, blue: 0.62)

    init(slots: [Color], weights: [Double], theme: Color, glyphs: [Glyph]) {
        self.slots = slots
        self.weights = weights
        self.theme = theme
        self.glyphs = glyphs
        let fronts = slots.map { Paint($0) }
        let backs = slots.map { Paint(ConfettiView.deeper($0)) }
        func steps(_ paint: Paint) -> [Paint] {
            (0..<Self.lightSteps).map { paint.lit(0.7 + 0.3 * Double($0) / Double(Self.lightSteps - 1)) }
        }
        let near = [fronts.map(steps), backs.map(steps)]
        let far = [fronts.map { steps($0.mixed(with: Self.haze, by: 0.15)) },
                   backs.map { steps($0.mixed(with: Self.haze, by: 0.15)) }]
        papers = [near, far]
    }

    /// The paper for a piece: its layer, which face shows, its slot, and
    /// the Lambert shade (0.7…1) snapped to a step.
    func paper(far: Bool, front: Bool, slot: Int, shade: Double) -> Paint {
        let step = Int(((shade - 0.7) / 0.3 * Double(Self.lightSteps - 1)).rounded())
        let clamped = min(Self.lightSteps - 1, max(0, step))
        let layer = papers[far ? 1 : 0][front ? 0 : 1]
        return layer[slot % max(1, layer.count)][clamped]
    }
}

extension ConfettiView {
    /// The Toys page tint — the `toys` palette's base and the colour of a
    /// burst no provider owns.
    static let toysTint = Color(red: 0.93, green: 0.30, blue: 0.62)

    /// The colour a burst for `provider` wears: a colour the person set
    /// for it in `colors.agent_colors` first, then the app's accent for a
    /// provider it knows — and the Toys tint for no provider, an empty
    /// one or one it doesn't know, never the unknown-provider grey.
    static func burstTint(provider: String?, document: SettingsDocument?) -> Color {
        guard let id = provider?.lowercased(), !id.isEmpty else { return toysTint }
        if let hex = document?.agentColorHex(id), let color = NSColor(hex: hex) {
            return Color(nsColor: color)
        }
        return ProviderStyle.table[id]?.accent ?? toysTint
    }

    /// The burst's look for a palette choice. `tint` is the burst's own
    /// colour (`burstTint`), `provider` its provider (for the glyph),
    /// `everyone` the accents and ids of the providers working now.
    static func look(_ choice: ConfettiPalette, tint: Color, provider: String?,
                     everyone: [(id: String, color: Color)] = [],
                     season: ConfettiSeason? = nil) -> ConfettiLook {
        if let season {
            let (slots, weights) = season.palette
            return ConfettiLook(slots: slots, weights: weights, theme: slots[0], glyphs: [])
        }
        let glyphs = glyph(for: provider).map { [$0] } ?? []
        switch choice {
        case .provider:
            let (slots, weights) = steps(around: tint)
            return ConfettiLook(slots: slots, weights: weights, theme: tint, glyphs: glyphs)
        case .toys:
            let (slots, weights) = steps(around: toysTint)
            return ConfettiLook(slots: slots, weights: weights, theme: toysTint, glyphs: [])
        case .party:
            let slots = ["#26CCFF", "#A25AFD", "#FF5E7E", "#88FF5A", "#FCFF42", "#FFA62D", "#FF36FF", "#FFFFFF"]
                .map(hex)
            return ConfettiLook(slots: slots, weights: [14, 13, 14, 12, 12, 13, 12, 10], theme: .white, glyphs: [])
        case .gold:
            let slots = ["#FFD76A", "#F2BF3F", "#FFF1C9", "#FFFFFF", "#E0A43A", "#F8E2A6"].map(hex)
            return ConfettiLook(slots: slots, weights: [26, 16, 18, 18, 12, 10], theme: slots[0], glyphs: [])
        case .pastel:
            let slots = ["#FFB3C7", "#B5EAD7", "#A7C7E7", "#FFF1A8", "#D7B8F3", "#FFD3B0", "#FFFFFF"].map(hex)
            return ConfettiLook(slots: slots, weights: [16, 15, 15, 14, 15, 15, 10], theme: slots[0], glyphs: [])
        case .mono:
            let (slots, weights) = shades(of: tint)
            return ConfettiLook(slots: slots, weights: weights, theme: tint, glyphs: glyphs)
        case .everyone:
            guard !everyone.isEmpty else {
                let (slots, weights) = steps(around: tint)
                return ConfettiLook(slots: slots, weights: weights, theme: tint, glyphs: glyphs)
            }
            // Each working provider's accent, dealt evenly, with its own
            // glyph on the same slot — plus white and a little gold.
            let share = 77.0 / Double(everyone.count)
            let slots = everyone.map(\.color) + [.white, hex("#FFD76A")]
            let weights = everyone.map { _ in share } + [15, 8]
            let marks = everyone.map { glyph(for: $0.id) ?? .symbol("star.fill") }
            return ConfettiLook(slots: slots, weights: weights, theme: everyone[0].color, glyphs: marks)
        }
    }

    /// Provider and Toys tint: the colour itself most, a lighter step, an
    /// accent leaning to gold (warm colours) or cyan (cool ones), white,
    /// gold and a pale step. The deeper shade is only ever a paper's back.
    nonisolated static func steps(around color: Color) -> (slots: [Color], weights: [Double]) {
        ([color, color.mix(with: .white, by: 0.4), accent(for: color), .white,
          Color(red: 0.99, green: 0.80, blue: 0.33), color.mix(with: .white, by: 0.65)],
         [35, 20, 10, 20, 10, 5])
    }

    /// Mono: the tint alone, from deep to pale.
    nonisolated static func shades(of color: Color) -> (slots: [Color], weights: [Double]) {
        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return ([color], [1]) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let hue = Double(h), sat = Double(s), bright = Double(b)
        return ([Color(hue: hue, saturation: sat, brightness: bright * 0.72),
                 color,
                 Color(hue: hue, saturation: sat * 0.75, brightness: min(1, bright * 1.1 + 0.05)),
                 Color(hue: hue, saturation: sat * 0.5, brightness: 1),
                 Color(hue: hue, saturation: sat * 0.28, brightness: 1)],
                [18, 32, 20, 18, 12])
    }

    /// A tint's accent: its hue moved 0.08 toward gold for warm colours,
    /// toward cyan for cool ones; a grey gets gold.
    nonisolated static func accent(for color: Color) -> Color {
        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        guard s > 0.12 else { return Color(hue: 0.12, saturation: 0.7, brightness: 1) }
        let hue = Double(h)
        func distance(_ a: Double, _ b: Double) -> Double {
            let d = abs(a - b).truncatingRemainder(dividingBy: 1)
            return min(d, 1 - d)
        }
        let target = distance(hue, 0.12) <= distance(hue, 0.5) ? 0.12 : 0.5
        let forward = (target - hue + 1).truncatingRemainder(dividingBy: 1) < 0.5
        let moved = (hue + (forward ? 0.08 : -0.08) + 1).truncatingRemainder(dividingBy: 1)
        return Color(hue: moved, saturation: max(0.6, Double(s)), brightness: 1)
    }

    /// The provider's own mark, when the app knows one.
    nonisolated static func glyph(for provider: String?) -> ConfettiLook.Glyph? {
        guard let id = provider?.lowercased(), let style = ProviderStyle.table[id] else { return nil }
        switch style.glyph {
        case .symbol(let name): return .symbol(name)
        case .text(let text): return .text(text)
        }
    }

    nonisolated static func hex(_ string: String) -> Color {
        Color(nsColor: NSColor(hex: string) ?? .white)
    }

    /// The same colour, darker and a little richer — the shaded side of
    /// a coloured paper. Mixing in black would grey it toward mud, and a
    /// yellow darkened in place turns olive, so the shade leans the way a
    /// painter's does: yellows and oranges toward amber, greens toward
    /// teal.
    nonisolated static func deeper(_ color: Color) -> Color {
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

/// The holidays the Seasonal switch knows, each with its own colours and
/// fleck — read off the Mac's own calendar, nothing asked of the network.
enum ConfettiSeason: String, CaseIterable, Sendable {
    case newYear, valentine, lunarNewYear, easter, halloween, christmas

    /// Today's holiday, if there is one: New Year's Eve and Day,
    /// Valentine's Day, the first two days of the Lunar New Year, Easter
    /// Sunday, Halloween, and Christmas Eve and Day.
    static func on(_ date: Date, calendar: Calendar = .current) -> ConfettiSeason? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        switch (month, day) {
        case (12, 31), (1, 1): return .newYear
        case (2, 14): return .valentine
        case (10, 31): return .halloween
        case (12, 24), (12, 25): return .christmas
        default: break
        }
        if let easter = easterSunday(year), easter == (month, day) { return .easter }
        var lunar = Calendar(identifier: .chinese)
        lunar.timeZone = calendar.timeZone
        let moon = lunar.dateComponents([.month, .day, .isLeapMonth], from: date)
        if moon.month == 1, let moonDay = moon.day, moonDay <= 2, moon.isLeapMonth != true { return .lunarNewYear }
        return nil
    }

    /// Easter Sunday in the Gregorian calendar (the anonymous computus).
    static func easterSunday(_ year: Int) -> (month: Int, day: Int)? {
        guard year > 1582 else { return nil }
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return (month, day)
    }

    /// The day's colours and how often each is dealt.
    var palette: (slots: [Color], weights: [Double]) {
        let hexes: [String]
        switch self {
        case .newYear: hexes = ["#FFD76A", "#FFF1C9", "#D8DCE3", "#FFFFFF", "#E0A43A"]
        case .valentine: hexes = ["#FF4D6D", "#FF8FA3", "#FFCCD5", "#C9184A", "#FFFFFF"]
        case .lunarNewYear: hexes = ["#D7263D", "#F4C542", "#FF6B35", "#FFD166", "#9E0031"]
        case .easter: hexes = ["#FFB3C7", "#B5EAD7", "#A7C7E7", "#FFF1A8", "#D7B8F3"]
        case .halloween: hexes = ["#FF7518", "#7B2CBF", "#2B2B2B", "#8BD346", "#FFB347"]
        case .christmas: hexes = ["#C1121F", "#1B7F3B", "#FFFFFF", "#F4C542", "#E63946"]
        }
        return (hexes.map(ConfettiView.hex), [26, 20, 20, 18, 16])
    }

    /// The fleck the day swaps in for stars and glyphs.
    var special: ConfettiPieceShape {
        switch self {
        case .valentine: return .heart
        case .easter: return .dot
        case .newYear, .lunarNewYear, .halloween, .christmas: return .star
        }
    }
}
