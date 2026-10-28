import SwiftUI

/// The winter sets' motifs: Hanukkah, Christmas, Kwanzaa, New Year,
/// Lunar New Year and Groundhog Day.
extension SeasonArt {
    static let gold = paint(0.96, 0.76, 0.3)
    static let hanukkahBlue = paint(0.24, 0.48, 0.9)

    /// A gold menorah: eight candles and the taller shamash in the
    /// middle. `nights` candles burn, from the right, as on the nights;
    /// the shamash is lit whenever any are.
    static func menorah(_ c: inout Context, at p: CGPoint, size s: Double, nights: Int, flicker: Double = 0) {
        let w = s * 1.3
        shadow(&c, at: CGPoint(x: p.x, y: p.y + s * 0.5), width: w * 0.55)
        let metal = gold
        let base = CGRect(x: p.x - s * 0.2, y: p.y + s * 0.38, width: s * 0.4, height: s * 0.1)
        c.fill(Path(roundedRect: base, cornerRadius: s * 0.04), with: lit(metal, in: base))
        let stem = CGRect(x: p.x - s * 0.035, y: p.y - s * 0.05, width: s * 0.07, height: s * 0.45)
        c.fill(Path(stem), with: lit(metal, in: stem))
        // The arms: nested arcs from the stem out to each pair.
        var arms = Path()
        for k in 1...4 {
            let dx = w * 0.5 * Double(k) / 4
            arms.move(to: CGPoint(x: p.x - dx, y: p.y - s * 0.12))
            arms.addQuadCurve(to: CGPoint(x: p.x + dx, y: p.y - s * 0.12),
                              control: CGPoint(x: p.x, y: p.y - s * 0.12 + dx * 1.15))
        }
        c.stroke(arms, with: .color(metal.mix(with: .black, by: 0.12)), lineWidth: max(0.6, s * 0.045))
        // Nine candles: index 4 is the shamash.
        let candle = paint(0.78, 0.86, 1)
        for i in 0..<9 {
            let x = p.x - w * 0.5 + Double(i) * w / 8
            let shamash = i == 4
            let top = p.y - s * (shamash ? 0.42 : 0.3)
            let rect = CGRect(x: x - s * 0.035, y: top, width: s * 0.07, height: s * 0.18)
            c.fill(Path(rect), with: fall(shamash ? Color(white: 0.97) : candle, in: rect))
            let cup = CGRect(x: x - s * 0.06, y: rect.maxY - s * 0.02, width: s * 0.12, height: s * 0.05)
            c.fill(Path(roundedRect: cup, cornerRadius: s * 0.02), with: .color(metal))
            // Night n lights the rightmost n of the eight.
            let slot = i > 4 ? 8 - i : 7 - i
            let burning = nights > 0 && (shamash || slot < nights)
            if burning {
                flame(&c, base: CGPoint(x: x, y: top), h: s * 0.15, flicker: flicker * (i.isMultiple(of: 2) ? 1 : -1))
            }
        }
    }

    /// A dreidel, spinning on its point.
    static func dreidel(_ c: inout Context, at p: CGPoint, size s: Double, tilt: Double = 0.2) {
        var local = c
        local.translateBy(x: p.x, y: p.y)
        local.rotate(by: .radians(tilt))
        let body = CGRect(x: -s * 0.28, y: -s * 0.3, width: s * 0.56, height: s * 0.5)
        var shape = Path()
        shape.addRoundedRect(in: body, cornerSize: CGSize(width: s * 0.08, height: s * 0.08))
        shape.move(to: CGPoint(x: -s * 0.28, y: s * 0.12))
        shape.addLine(to: CGPoint(x: 0, y: s * 0.48))
        shape.addLine(to: CGPoint(x: s * 0.28, y: s * 0.12))
        shape.closeSubpath()
        local.fill(shape, with: lit(hanukkahBlue, in: CGRect(x: -s * 0.3, y: -s * 0.3, width: s * 0.6, height: s * 0.8)))
        let handle = CGRect(x: -s * 0.05, y: -s * 0.5, width: s * 0.1, height: s * 0.22)
        local.fill(Path(roundedRect: handle, cornerRadius: s * 0.04), with: lit(gold, in: handle))
        // A gold letter-like mark on the face.
        var mark = Path()
        mark.move(to: CGPoint(x: -s * 0.1, y: -s * 0.16))
        mark.addLine(to: CGPoint(x: s * 0.1, y: -s * 0.16))
        mark.addLine(to: CGPoint(x: s * 0.1, y: s * 0.06))
        local.stroke(mark, with: .color(gold), style: StrokeStyle(lineWidth: max(0.5, s * 0.06), lineCap: .round))
    }

    /// A six-pointed star, the Hanukkah blue on white.
    static func hexagram(_ c: inout Context, at p: CGPoint, size s: Double, color: Color = hanukkahBlue) {
        for flip in [-Double.pi / 2, Double.pi / 2] {
            var tri = Path()
            for k in 0..<3 {
                let a = flip + Double(k) * 2 * .pi / 3
                let point = CGPoint(x: p.x + cos(a) * s * 0.5, y: p.y + sin(a) * s * 0.5)
                if k == 0 { tri.move(to: point) } else { tri.addLine(to: point) }
            }
            tri.closeSubpath()
            c.stroke(tri, with: .color(color), lineWidth: max(0.5, s * 0.12))
        }
    }

    /// A fir tree in three tiers, baubles and a star.
    static func tree(_ c: inout Context, at p: CGPoint, size s: Double, twinkle: Double = 0) {
        let green = paint(0.16, 0.55, 0.32)
        shadow(&c, at: CGPoint(x: p.x, y: p.y + s * 0.5), width: s * 0.8)
        let trunk = CGRect(x: p.x - s * 0.07, y: p.y + s * 0.32, width: s * 0.14, height: s * 0.18)
        c.fill(Path(trunk), with: lit(paint(0.5, 0.3, 0.16), in: trunk))
        let tiers: [(top: Double, bottom: Double, half: Double)] = [(-0.36, -0.02, 0.24), (-0.18, 0.18, 0.32), (0.0, 0.36, 0.4)]
        for tier in tiers.reversed() {
            var cone = Path()
            cone.move(to: CGPoint(x: p.x, y: p.y + s * tier.top))
            cone.addQuadCurve(to: CGPoint(x: p.x + s * tier.half, y: p.y + s * tier.bottom),
                              control: CGPoint(x: p.x + s * tier.half * 0.4, y: p.y + s * (tier.top + tier.bottom) / 2))
            cone.addQuadCurve(to: CGPoint(x: p.x - s * tier.half, y: p.y + s * tier.bottom),
                              control: CGPoint(x: p.x, y: p.y + s * tier.bottom + s * 0.06))
            cone.addQuadCurve(to: CGPoint(x: p.x, y: p.y + s * tier.top),
                              control: CGPoint(x: p.x - s * tier.half * 0.4, y: p.y + s * (tier.top + tier.bottom) / 2))
            let rect = CGRect(x: p.x - s * tier.half, y: p.y + s * tier.top, width: s * tier.half * 2,
                              height: s * (tier.bottom - tier.top))
            c.fill(cone, with: lit(green, in: rect, light: 0.25, dark: 0.3))
        }
        let baubles: [(x: Double, y: Double, color: Color)] = [
            (-0.12, -0.08, paint(0.92, 0.22, 0.24)), (0.1, 0.02, gold),
            (-0.2, 0.22, paint(0.3, 0.55, 0.95)), (0.18, 0.26, paint(0.92, 0.22, 0.24)),
            (0.0, 0.14, paint(0.95, 0.95, 1)),
        ]
        for (k, b) in baubles.enumerated() {
            let r = s * 0.05
            let rect = CGRect(x: p.x + s * b.x - r, y: p.y + s * b.y - r, width: r * 2, height: r * 2)
            if twinkle > 0 {
                let on = 0.5 + 0.5 * sin(twinkle * 2 + Double(k) * 1.7)
                glow(&c, at: CGPoint(x: rect.midX, y: rect.midY), radius: r * 2.6, color: b.color, strength: 0.4 * on)
            }
            c.fill(Path(ellipseIn: rect), with: lit(b.color, in: rect))
        }
        let star = CGPoint(x: p.x, y: p.y - s * 0.4)
        glow(&c, at: star, radius: s * 0.16, color: gold, strength: 0.5)
        c.fill(starPath(star, s * 0.1), with: lit(gold, in: CGRect(x: star.x - s * 0.1, y: star.y - s * 0.1,
                                                                   width: s * 0.2, height: s * 0.2), light: 0.4))
    }

    /// A string-light bulb hanging from `top`, glowing in `color`.
    static func bulb(_ c: inout Context, top: CGPoint, size s: Double, color: Color, glowing: Double = 1) {
        let cap = CGRect(x: top.x - s * 0.16, y: top.y, width: s * 0.32, height: s * 0.22)
        c.fill(Path(roundedRect: cap, cornerRadius: s * 0.06), with: .color(paint(0.25, 0.36, 0.24)))
        let glass = CGRect(x: top.x - s * 0.22, y: top.y + s * 0.18, width: s * 0.44, height: s * 0.7)
        if glowing > 0 {
            glow(&c, at: CGPoint(x: glass.midX, y: glass.midY), radius: s * 0.75, color: color, strength: 0.42 * glowing)
        }
        c.fill(Path(ellipseIn: glass), with: lit(color, in: glass, light: 0.45, dark: 0.15))
        gloss(&c, in: glass, opacity: 0.5)
    }

    /// A glass bauble with its cap, `color`, hanging from `top`.
    static func bauble(_ c: inout Context, top: CGPoint, size s: Double, color: Color) {
        let cap = CGRect(x: top.x - s * 0.12, y: top.y, width: s * 0.24, height: s * 0.14)
        c.fill(Path(cap), with: .color(gold))
        let ball = CGRect(x: top.x - s * 0.42, y: top.y + s * 0.1, width: s * 0.84, height: s * 0.84)
        c.fill(Path(ellipseIn: ball), with: lit(color, in: ball))
        gloss(&c, in: ball)
    }

    /// A snowflake: six arms, each with a pair of twigs.
    static func snowflake(_ c: inout Context, at p: CGPoint, size s: Double, opacity: Double = 0.95) {
        var flake = Path()
        for k in 0..<6 {
            let a = Double(k) * .pi / 3
            let tip = CGPoint(x: p.x + cos(a) * s * 0.5, y: p.y + sin(a) * s * 0.5)
            flake.move(to: p)
            flake.addLine(to: tip)
            let mid = CGPoint(x: p.x + cos(a) * s * 0.3, y: p.y + sin(a) * s * 0.3)
            for side in [-1.0, 1.0] {
                let b = a + side * 0.7
                flake.move(to: mid)
                flake.addLine(to: CGPoint(x: mid.x + cos(b) * s * 0.14, y: mid.y + sin(b) * s * 0.14))
            }
        }
        // A soft blue-grey edge first, so a flake holds on a light ground.
        c.stroke(flake, with: .color(paint(0.45, 0.55, 0.72).opacity(0.45 * opacity)),
                 style: StrokeStyle(lineWidth: max(1.1, s * 0.2), lineCap: .round))
        c.stroke(flake, with: .color(.white.opacity(opacity)),
                 style: StrokeStyle(lineWidth: max(0.5, s * 0.09), lineCap: .round))
    }

    /// A wrapped present with a bow.
    static func gift(_ c: inout Context, at p: CGPoint, size s: Double, color: Color, ribbon: Color = gold) {
        let box = CGRect(x: p.x - s * 0.4, y: p.y - s * 0.2, width: s * 0.8, height: s * 0.6)
        shadow(&c, at: CGPoint(x: p.x, y: box.maxY), width: s * 0.9)
        c.fill(Path(roundedRect: box, cornerRadius: s * 0.05), with: lit(color, in: box))
        c.fill(Path(CGRect(x: p.x - s * 0.06, y: box.minY, width: s * 0.12, height: box.height)), with: .color(ribbon))
        let lid = CGRect(x: p.x - s * 0.45, y: box.minY - s * 0.06, width: s * 0.9, height: s * 0.16)
        c.fill(Path(roundedRect: lid, cornerRadius: s * 0.04), with: lit(color.mix(with: .white, by: 0.08), in: lid))
        c.fill(Path(CGRect(x: p.x - s * 0.06, y: lid.minY, width: s * 0.12, height: lid.height)), with: .color(ribbon))
        for side in [-1.0, 1.0] {
            let loop = CGRect(x: p.x + side * s * 0.14 - s * 0.12, y: lid.minY - s * 0.16, width: s * 0.24, height: s * 0.18)
            c.fill(Path(ellipseIn: loop), with: lit(ribbon, in: loop))
        }
    }

    /// The kinara: seven candles, three red, the black one in the middle,
    /// three green. Day 1 lights the black, then red and green in turn
    /// from the outside in; `days` candles burn.
    static func kinara(_ c: inout Context, at p: CGPoint, size s: Double, days: Int, flicker: Double = 0) {
        let w = s * 1.3
        shadow(&c, at: CGPoint(x: p.x, y: p.y + s * 0.42), width: w * 1.05)
        let wood = paint(0.55, 0.33, 0.17)
        var stand = Path()
        stand.move(to: CGPoint(x: p.x - w * 0.5, y: p.y + s * 0.12))
        stand.addQuadCurve(to: CGPoint(x: p.x + w * 0.5, y: p.y + s * 0.12), control: CGPoint(x: p.x, y: p.y + s * 0.36))
        stand.addLine(to: CGPoint(x: p.x + w * 0.42, y: p.y + s * 0.22))
        stand.addQuadCurve(to: CGPoint(x: p.x - w * 0.42, y: p.y + s * 0.22), control: CGPoint(x: p.x, y: p.y + s * 0.44))
        stand.closeSubpath()
        let standRect = CGRect(x: p.x - w * 0.5, y: p.y + s * 0.1, width: w, height: s * 0.34)
        c.fill(stand, with: lit(wood, in: standRect))
        let foot = CGRect(x: p.x - s * 0.22, y: p.y + s * 0.3, width: s * 0.44, height: s * 0.12)
        c.fill(Path(roundedRect: foot, cornerRadius: s * 0.04), with: lit(wood, in: foot))
        let red = paint(0.86, 0.16, 0.16)
        let green = paint(0.12, 0.6, 0.3)
        let black = Color(white: 0.16)
        let colors = [red, red, red, black, green, green, green]
        // Order lit: centre, then outermost red, outermost green, inward.
        let order = [3, 0, 6, 1, 5, 2, 4]
        let burning = Set(order.prefix(max(0, min(7, days))))
        for i in 0..<7 {
            let x = p.x - w * 0.42 + Double(i) * w * 0.84 / 6
            let lift = abs(Double(i - 3)) * s * 0.035
            let top = p.y - s * 0.3 + lift
            let rect = CGRect(x: x - s * 0.04, y: top, width: s * 0.08, height: p.y + s * 0.12 - top + lift * 0.4)
            c.fill(Path(roundedRect: rect, cornerRadius: s * 0.015), with: fall(colors[i], in: rect, light: 0.3, dark: 0.1))
            if burning.contains(i) {
                flame(&c, base: CGPoint(x: x, y: top), h: s * 0.15, flicker: flicker * (i.isMultiple(of: 2) ? 1 : -1))
            }
        }
    }

    /// A party hat: a striped cone with a pom, `color` and `stripe`.
    static func partyHat(_ c: inout Context, base: CGPoint, w: Double, h: Double, color: Color, stripe: Color,
                         dots: Bool = false) {
        var cone = Path()
        cone.move(to: CGPoint(x: base.x - w / 2, y: base.y))
        cone.addLine(to: CGPoint(x: base.x, y: base.y - h))
        cone.addLine(to: CGPoint(x: base.x + w / 2, y: base.y))
        cone.addQuadCurve(to: CGPoint(x: base.x - w / 2, y: base.y), control: CGPoint(x: base.x, y: base.y + h * 0.12))
        cone.closeSubpath()
        let rect = CGRect(x: base.x - w / 2, y: base.y - h, width: w, height: h)
        c.fill(cone, with: lit(color, in: rect))
        var inside = c
        inside.clip(to: cone)
        if dots {
            for k in 0..<5 {
                let y = base.y - h * (0.18 + Double(k % 3) * 0.24)
                let x = base.x + (Double(k) - 2) * w * 0.17
                inside.fill(Path(ellipseIn: CGRect(x: x - w * 0.06, y: y - w * 0.06, width: w * 0.12, height: w * 0.12)),
                            with: .color(stripe))
            }
        } else {
            for k in 0..<3 {
                let y = base.y - h * (0.2 + Double(k) * 0.26)
                var band = Path()
                band.move(to: CGPoint(x: base.x - w, y: y + h * 0.1))
                band.addLine(to: CGPoint(x: base.x + w, y: y - h * 0.06))
                inside.stroke(band, with: .color(stripe), lineWidth: h * 0.09)
            }
        }
        let pom = CGRect(x: base.x - w * 0.16, y: base.y - h - w * 0.16, width: w * 0.32, height: w * 0.32)
        c.fill(Path(ellipseIn: pom), with: lit(stripe, in: pom))
    }

    /// A piece of confetti: a little rotated rectangle.
    static func confettiBit(_ c: inout Context, at p: CGPoint, size s: Double, angle: Double, color: Color) {
        var local = c
        local.translateBy(x: p.x, y: p.y)
        local.rotate(by: .radians(angle))
        local.fill(Path(roundedRect: CGRect(x: -s / 2, y: -s * 0.22, width: s, height: s * 0.44), cornerRadius: s * 0.1),
                   with: .color(color))
    }

    /// A firework: a ring of sparks round `p`, `r` across.
    static func firework(_ c: inout Context, at p: CGPoint, r: Double, color: Color, sparks: Int = 12) {
        glow(&c, at: p, radius: r * 1.2, color: color, strength: 0.25)
        for k in 0..<sparks {
            let a = Double(k) / Double(sparks) * 2 * .pi
            var ray = Path()
            ray.move(to: CGPoint(x: p.x + cos(a) * r * 0.35, y: p.y + sin(a) * r * 0.35))
            ray.addLine(to: CGPoint(x: p.x + cos(a) * r * 0.85, y: p.y + sin(a) * r * 0.85))
            c.stroke(ray, with: .color(color.mix(with: .white, by: 0.2)),
                     style: StrokeStyle(lineWidth: max(0.5, r * 0.09), lineCap: .round))
            let tip = CGPoint(x: p.x + cos(a) * r, y: p.y + sin(a) * r)
            c.fill(Path(ellipseIn: CGRect(x: tip.x - r * 0.07, y: tip.y - r * 0.07, width: r * 0.14, height: r * 0.14)),
                   with: .color(.white.opacity(0.9)))
        }
    }

    /// A party popper: a gold cone spilling streamers and confetti.
    static func partyPopper(_ c: inout Context, at p: CGPoint, size s: Double) {
        let colors = [paint(0.98, 0.4, 0.5), paint(0.35, 0.7, 1),
                      gold, paint(0.55, 0.85, 0.4), paint(0.75, 0.5, 1)]
        for k in 0..<9 {
            let a = -1.9 + Double(k) * 0.16
            let d = s * (0.45 + Double(k % 3) * 0.13)
            let at = CGPoint(x: p.x - s * 0.18 + cos(a) * d, y: p.y + s * 0.1 + sin(a) * d)
            confettiBit(&c, at: at, size: s * 0.13, angle: Double(k) * 0.9, color: colors[k % colors.count])
        }
        for k in 0..<2 {
            var streamer = Path()
            let start = CGPoint(x: p.x - s * 0.12, y: p.y - s * 0.02)
            streamer.move(to: start)
            streamer.addCurve(to: CGPoint(x: p.x - s * (0.25 + Double(k) * 0.2), y: p.y - s * 0.55),
                              control1: CGPoint(x: p.x + s * 0.1, y: p.y - s * 0.25),
                              control2: CGPoint(x: p.x - s * 0.45, y: p.y - s * 0.3))
            c.stroke(streamer, with: .color(colors[k + 2]), style: StrokeStyle(lineWidth: max(0.6, s * 0.05), lineCap: .round))
        }
        var cone = Path()
        cone.move(to: CGPoint(x: p.x + s * 0.32, y: p.y + s * 0.44))
        cone.addLine(to: CGPoint(x: p.x - s * 0.22, y: p.y + s * 0.02))
        cone.addLine(to: CGPoint(x: p.x - s * 0.02, y: p.y - s * 0.18))
        cone.closeSubpath()
        c.fill(cone, with: lit(gold, in: CGRect(x: p.x - s * 0.22, y: p.y - s * 0.18, width: s * 0.54, height: s * 0.62)))
        rim(&c, cone, gold, width: max(0.4, s * 0.03))
    }

    /// A round red paper lantern with gold caps and a tassel.
    static func redLantern(_ c: inout Context, top: CGPoint, size s: Double, glowing: Double = 0.6) {
        let red = paint(0.88, 0.12, 0.12)
        let body = CGRect(x: top.x - s * 0.45, y: top.y + s * 0.1, width: s * 0.9, height: s * 0.66)
        if glowing > 0 {
            glow(&c, at: CGPoint(x: body.midX, y: body.midY), radius: s * 0.8,
                 color: paint(1, 0.45, 0.2), strength: 0.35 * glowing)
        }
        c.fill(Path(ellipseIn: body), with: lit(red, in: body, light: 0.3, dark: 0.3))
        var ribs = Path()
        for k in [-0.5, 0.0, 0.5] {
            ribs.move(to: CGPoint(x: body.midX + k * body.width * 0.5, y: body.minY + 1))
            ribs.addQuadCurve(to: CGPoint(x: body.midX + k * body.width * 0.5, y: body.maxY - 1),
                              control: CGPoint(x: body.midX + k * body.width * 0.95, y: body.midY))
        }
        c.stroke(ribs, with: .color(red.mix(with: .black, by: 0.35).opacity(0.6)), lineWidth: max(0.3, s * 0.03))
        for y in [body.minY - s * 0.02, body.maxY - s * 0.06] {
            let cap = CGRect(x: top.x - s * 0.2, y: y, width: s * 0.4, height: s * 0.09)
            c.fill(Path(roundedRect: cap, cornerRadius: s * 0.03), with: lit(gold, in: cap))
        }
        var tassel = Path()
        for k in -1...1 {
            tassel.move(to: CGPoint(x: top.x, y: body.maxY + s * 0.02))
            tassel.addLine(to: CGPoint(x: top.x + Double(k) * s * 0.05, y: body.maxY + s * 0.24))
        }
        c.stroke(tassel, with: .color(gold), style: StrokeStyle(lineWidth: max(0.4, s * 0.04), lineCap: .round))
        gloss(&c, in: body, opacity: 0.3)
    }

    /// A red envelope with a gold seal.
    static func redEnvelope(_ c: inout Context, at p: CGPoint, size s: Double) {
        let rect = CGRect(x: p.x - s * 0.3, y: p.y - s * 0.42, width: s * 0.6, height: s * 0.84)
        shadow(&c, at: CGPoint(x: p.x, y: rect.maxY), width: s * 0.7)
        c.fill(Path(roundedRect: rect, cornerRadius: s * 0.05), with: lit(paint(0.86, 0.1, 0.12), in: rect))
        var flap = Path()
        flap.move(to: CGPoint(x: rect.minX, y: rect.minY + s * 0.06))
        flap.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + s * 0.06), control: CGPoint(x: p.x, y: p.y - s * 0.02))
        c.stroke(flap, with: .color(paint(0.6, 0.05, 0.06)), lineWidth: max(0.4, s * 0.03))
        let seal = CGRect(x: p.x - s * 0.1, y: p.y - s * 0.12, width: s * 0.2, height: s * 0.2)
        c.fill(Path(ellipseIn: seal), with: lit(gold, in: seal))
    }

    /// A groundhog peeking out of its burrow, its mound under it.
    static func groundhog(_ c: inout Context, at p: CGPoint, size s: Double, ground: Color, peek: Double = 1) {
        let fur = paint(0.6, 0.42, 0.26)
        let rise = (1 - peek) * s * 0.4
        let head = CGRect(x: p.x - s * 0.32, y: p.y - s * 0.42 + rise, width: s * 0.64, height: s * 0.6)
        var body = c
        body.clip(to: Path(CGRect(x: p.x - s, y: p.y - s * 2, width: s * 2, height: s * 2.15)))
        for side in [-1.0, 1.0] {
            let ear = CGRect(x: p.x + side * s * 0.22 - s * 0.08, y: head.minY - s * 0.02, width: s * 0.16, height: s * 0.14)
            body.fill(Path(ellipseIn: ear), with: lit(fur.mix(with: .black, by: 0.12), in: ear))
        }
        body.fill(Path(ellipseIn: head), with: lit(fur, in: head))
        let muzzle = CGRect(x: p.x - s * 0.16, y: head.minY + s * 0.28, width: s * 0.32, height: s * 0.22)
        body.fill(Path(ellipseIn: muzzle), with: lit(paint(0.86, 0.74, 0.6), in: muzzle))
        let nose = CGRect(x: p.x - s * 0.05, y: muzzle.minY + s * 0.02, width: s * 0.1, height: s * 0.07)
        body.fill(Path(ellipseIn: nose), with: .color(paint(0.25, 0.15, 0.12)))
        body.fill(Path(CGRect(x: p.x - s * 0.035, y: muzzle.maxY - s * 0.06, width: s * 0.07, height: s * 0.07)),
                  with: .color(.white))
        for side in [-1.0, 1.0] {
            let eye = CGRect(x: p.x + side * s * 0.12 - s * 0.04, y: head.minY + s * 0.17, width: s * 0.08, height: s * 0.09)
            body.fill(Path(ellipseIn: eye), with: .color(paint(0.1, 0.07, 0.06)))
            body.fill(Path(ellipseIn: CGRect(x: eye.minX + s * 0.015, y: eye.minY + s * 0.012, width: s * 0.03, height: s * 0.03)),
                      with: .color(.white))
        }
        // The mound in front.
        var mound = Path()
        mound.move(to: CGPoint(x: p.x - s * 0.62, y: p.y + s * 0.3))
        mound.addQuadCurve(to: CGPoint(x: p.x + s * 0.62, y: p.y + s * 0.3), control: CGPoint(x: p.x, y: p.y - s * 0.08))
        mound.closeSubpath()
        c.fill(mound, with: lit(ground, in: CGRect(x: p.x - s * 0.62, y: p.y, width: s * 1.24, height: s * 0.3),
                                 light: 0.18, dark: 0.18))
        let hole = CGRect(x: p.x - s * 0.36, y: p.y + s * 0.06, width: s * 0.72, height: s * 0.12)
        c.fill(Path(ellipseIn: hole), with: .color(ground.mix(with: .black, by: 0.4).opacity(0.6)))
    }

    /// A little sun with soft rays.
    static func sun(_ c: inout Context, at p: CGPoint, size s: Double) {
        let yellow = paint(1, 0.8, 0.25)
        glow(&c, at: p, radius: s * 0.8, color: yellow, strength: 0.35)
        for k in 0..<8 {
            let a = Double(k) / 8 * 2 * .pi
            var ray = Path()
            ray.move(to: CGPoint(x: p.x + cos(a) * s * 0.34, y: p.y + sin(a) * s * 0.34))
            ray.addLine(to: CGPoint(x: p.x + cos(a) * s * 0.5, y: p.y + sin(a) * s * 0.5))
            c.stroke(ray, with: .color(yellow), style: StrokeStyle(lineWidth: max(0.5, s * 0.08), lineCap: .round))
        }
        let disc = CGRect(x: p.x - s * 0.26, y: p.y - s * 0.26, width: s * 0.52, height: s * 0.52)
        c.fill(Path(ellipseIn: disc), with: lit(yellow, in: disc))
    }

    /// A birthday cake: two tiers, icing drips and lit candles.
    static func cake(_ c: inout Context, at p: CGPoint, size s: Double, candles: Int = 3, flicker: Double = 0) {
        let sponge = paint(0.98, 0.82, 0.86)
        let icing = paint(1, 0.97, 0.97)
        shadow(&c, at: CGPoint(x: p.x, y: p.y + s * 0.44), width: s * 1.2)
        let plate = CGRect(x: p.x - s * 0.6, y: p.y + s * 0.36, width: s * 1.2, height: s * 0.1)
        c.fill(Path(ellipseIn: plate), with: lit(Color(white: 0.92), in: plate))
        let tiers = [CGRect(x: p.x - s * 0.48, y: p.y + s * 0.02, width: s * 0.96, height: s * 0.38),
                     CGRect(x: p.x - s * 0.32, y: p.y - s * 0.24, width: s * 0.64, height: s * 0.28)]
        for tier in tiers {
            c.fill(Path(roundedRect: tier, cornerRadius: s * 0.06), with: lit(sponge, in: tier, light: 0.2, dark: 0.15))
            var drip = Path()
            drip.move(to: CGPoint(x: tier.minX, y: tier.minY + s * 0.02))
            let drops = 5
            for k in 0..<drops {
                let x0 = tier.minX + Double(k) * tier.width / Double(drops)
                let x1 = x0 + tier.width / Double(drops)
                let depth = s * (k.isMultiple(of: 2) ? 0.12 : 0.07)
                drip.addQuadCurve(to: CGPoint(x: x1, y: tier.minY + s * 0.02),
                                  control: CGPoint(x: (x0 + x1) / 2, y: tier.minY + depth * 1.6))
            }
            drip.addLine(to: CGPoint(x: tier.maxX, y: tier.minY))
            drip.addLine(to: CGPoint(x: tier.minX, y: tier.minY))
            drip.closeSubpath()
            c.fill(drip, with: .color(icing))
        }
        let candleColors = [paint(0.4, 0.7, 1), paint(1, 0.55, 0.6),
                            paint(0.6, 0.86, 0.45)]
        let count = max(1, min(5, candles))
        for k in 0..<count {
            let x = p.x + (Double(k) - Double(count - 1) / 2) * s * 0.16
            let top = p.y - s * 0.44
            let rect = CGRect(x: x - s * 0.03, y: top, width: s * 0.06, height: s * 0.2)
            c.fill(Path(roundedRect: rect, cornerRadius: s * 0.02), with: fall(candleColors[k % 3], in: rect))
            flame(&c, base: CGPoint(x: x, y: top), h: s * 0.13, flicker: flicker * (k.isMultiple(of: 2) ? 1 : -1))
        }
    }
}
