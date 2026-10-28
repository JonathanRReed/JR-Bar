import SwiftUI

/// The spring and summer sets' motifs: Valentine's Day, St. Patrick's,
/// Ramadan & Eid, Easter, Earth Day, Pride and Independence Day.
extension SeasonArt {
    static let rainbow: [Color] = [
        paint(0.93, 0.22, 0.26), paint(0.98, 0.55, 0.16),
        paint(0.99, 0.84, 0.2), paint(0.25, 0.7, 0.36),
        paint(0.2, 0.47, 0.92), paint(0.55, 0.3, 0.82),
    ]
    static let usRed = paint(0.84, 0.16, 0.2)
    static let usBlue = paint(0.16, 0.26, 0.6)

    /// A heart, lit and glossed.
    static func heart(_ c: inout Context, at p: CGPoint, size s: Double, color: Color) {
        let path = heartPath(p, s)
        let rect = CGRect(x: p.x - s * 0.55, y: p.y - s * 0.45, width: s * 1.1, height: s * 0.95)
        c.fill(path, with: lit(color, in: rect, light: 0.35, dark: 0.25))
        gloss(&c, in: CGRect(x: rect.minX + s * 0.05, y: rect.minY + s * 0.05, width: s * 0.5, height: s * 0.4),
              opacity: 0.4)
    }

    /// A shamrock: three heart leaves on a stem.
    static func shamrock(_ c: inout Context, at p: CGPoint, size s: Double, angle: Double = 0) {
        let green = paint(0.2, 0.66, 0.3)
        var local = c
        local.translateBy(x: p.x, y: p.y)
        local.rotate(by: .radians(angle))
        var stem = Path()
        stem.move(to: CGPoint(x: 0, y: 0))
        stem.addQuadCurve(to: CGPoint(x: s * 0.1, y: s * 0.5), control: CGPoint(x: -s * 0.02, y: s * 0.3))
        local.stroke(stem, with: .color(green.mix(with: .black, by: 0.2)),
                     style: StrokeStyle(lineWidth: max(0.5, s * 0.07), lineCap: .round))
        for k in 0..<3 {
            let a = -.pi / 2 + Double(k) * 2 * .pi / 3
            var leafContext = local
            leafContext.rotate(by: .radians(a + .pi / 2))
            let leaf = heartPath(CGPoint(x: 0, y: -s * 0.2), s * 0.42)
            leafContext.fill(leaf, with: lit(green, in: CGRect(x: -s * 0.24, y: -s * 0.42, width: s * 0.48, height: s * 0.42)))
        }
    }

    /// A black pot brimming with gold coins.
    static func potOfGold(_ c: inout Context, at p: CGPoint, size s: Double) {
        shadow(&c, at: CGPoint(x: p.x, y: p.y + s * 0.42), width: s * 1.0)
        let coin = paint(0.98, 0.78, 0.24)
        for k in 0..<7 {
            let x = p.x + (Double(k) - 3) * s * 0.12
            let y = p.y - s * 0.12 - (k == 3 ? s * 0.1 : (abs(k - 3) == 1 ? s * 0.05 : 0))
            let r = CGRect(x: x - s * 0.11, y: y - s * 0.07, width: s * 0.22, height: s * 0.14)
            c.fill(Path(ellipseIn: r), with: lit(coin, in: r, light: 0.45))
        }
        var pot = Path()
        pot.move(to: CGPoint(x: p.x - s * 0.44, y: p.y - s * 0.08))
        pot.addLine(to: CGPoint(x: p.x + s * 0.44, y: p.y - s * 0.08))
        pot.addCurve(to: CGPoint(x: p.x, y: p.y + s * 0.42), control1: CGPoint(x: p.x + s * 0.62, y: p.y + s * 0.2),
                     control2: CGPoint(x: p.x + s * 0.4, y: p.y + s * 0.42))
        pot.addCurve(to: CGPoint(x: p.x - s * 0.44, y: p.y - s * 0.08), control1: CGPoint(x: p.x - s * 0.4, y: p.y + s * 0.42),
                     control2: CGPoint(x: p.x - s * 0.62, y: p.y + s * 0.2))
        let rect = CGRect(x: p.x - s * 0.5, y: p.y - s * 0.1, width: s, height: s * 0.52)
        c.fill(pot, with: lit(Color(white: 0.2), in: rect, light: 0.3))
        let lip = CGRect(x: p.x - s * 0.48, y: p.y - s * 0.13, width: s * 0.96, height: s * 0.1)
        c.fill(Path(roundedRect: lip, cornerRadius: s * 0.05), with: .color(Color(white: 0.28)))
        shamrock(&c, at: CGPoint(x: p.x + s * 0.32, y: p.y - s * 0.3), size: s * 0.36, angle: 0.4)
    }

    /// A crescent moon, horns to the right.
    static func crescent(_ c: inout Context, at p: CGPoint, size s: Double, color: Color = gold) {
        var moon = Path(ellipseIn: CGRect(x: p.x - s * 0.5, y: p.y - s * 0.5, width: s, height: s))
        moon.addPath(Path(ellipseIn: CGRect(x: p.x - s * 0.22, y: p.y - s * 0.56, width: s * 0.94, height: s * 0.94)))
        let rect = CGRect(x: p.x - s * 0.5, y: p.y - s * 0.5, width: s, height: s)
        glow(&c, at: p, radius: s * 0.75, color: color, strength: 0.25)
        c.fill(moon, with: lit(color, in: rect, light: 0.4), style: FillStyle(eoFill: true))
    }

    /// A fanous: a lantern with coloured glass panes in a gold frame.
    static func fanous(_ c: inout Context, top: CGPoint, size s: Double, glowing: Double = 0.7) {
        let frame = gold.mix(with: .black, by: 0.1)
        let body = CGRect(x: top.x - s * 0.24, y: top.y + s * 0.26, width: s * 0.48, height: s * 0.42)
        if glowing > 0 {
            glow(&c, at: CGPoint(x: body.midX, y: body.midY), radius: s * 0.7,
                 color: paint(1, 0.75, 0.35), strength: 0.45 * glowing)
        }
        var roof = Path()
        roof.move(to: CGPoint(x: top.x, y: top.y + s * 0.04))
        roof.addLine(to: CGPoint(x: top.x + s * 0.3, y: top.y + s * 0.26))
        roof.addLine(to: CGPoint(x: top.x - s * 0.3, y: top.y + s * 0.26))
        roof.closeSubpath()
        c.fill(roof, with: lit(frame, in: CGRect(x: top.x - s * 0.3, y: top.y, width: s * 0.6, height: s * 0.26)))
        let panes = [paint(0.95, 0.35, 0.4), paint(1, 0.8, 0.35),
                     paint(0.35, 0.7, 0.95)]
        for k in 0..<3 {
            let pane = CGRect(x: body.minX + Double(k) * body.width / 3, y: body.minY, width: body.width / 3, height: body.height)
            c.fill(Path(pane), with: lit(panes[k], in: pane, light: 0.45, dark: 0.1))
        }
        c.stroke(Path(body), with: .color(frame), lineWidth: max(0.5, s * 0.05))
        var mullions = Path()
        for k in 1..<3 {
            let x = body.minX + Double(k) * body.width / 3
            mullions.move(to: CGPoint(x: x, y: body.minY))
            mullions.addLine(to: CGPoint(x: x, y: body.maxY))
        }
        c.stroke(mullions, with: .color(frame), lineWidth: max(0.4, s * 0.035))
        var base = Path()
        base.move(to: CGPoint(x: body.minX - s * 0.04, y: body.maxY))
        base.addLine(to: CGPoint(x: body.maxX + s * 0.04, y: body.maxY))
        base.addLine(to: CGPoint(x: top.x + s * 0.12, y: body.maxY + s * 0.12))
        base.addLine(to: CGPoint(x: top.x - s * 0.12, y: body.maxY + s * 0.12))
        base.closeSubpath()
        c.fill(base, with: .color(frame))
        let ring = CGRect(x: top.x - s * 0.06, y: top.y - s * 0.06, width: s * 0.12, height: s * 0.12)
        c.stroke(Path(ellipseIn: ring), with: .color(frame), lineWidth: max(0.4, s * 0.03))
    }

    /// An Easter egg with a zig-zag band and dots.
    static func egg(_ c: inout Context, at p: CGPoint, size s: Double, color: Color, band: Color, tilt: Double = 0) {
        var local = c
        local.translateBy(x: p.x, y: p.y)
        local.rotate(by: .radians(tilt))
        let rect = CGRect(x: -s * 0.36, y: -s * 0.5, width: s * 0.72, height: s)
        var shape = Path()
        shape.move(to: CGPoint(x: 0, y: rect.minY))
        shape.addCurve(to: CGPoint(x: 0, y: rect.maxY), control1: CGPoint(x: s * 0.46, y: rect.minY),
                       control2: CGPoint(x: s * 0.42, y: rect.maxY))
        shape.addCurve(to: CGPoint(x: 0, y: rect.minY), control1: CGPoint(x: -s * 0.42, y: rect.maxY),
                       control2: CGPoint(x: -s * 0.46, y: rect.minY))
        local.fill(shape, with: lit(color, in: rect, light: 0.35, dark: 0.18))
        var inside = local
        inside.clip(to: shape)
        var zig = Path()
        zig.move(to: CGPoint(x: -s * 0.5, y: s * 0.02))
        for k in 0..<8 {
            zig.addLine(to: CGPoint(x: -s * 0.5 + Double(k + 1) * s * 0.13, y: k.isMultiple(of: 2) ? -s * 0.06 : s * 0.06))
        }
        inside.stroke(zig, with: .color(band), style: StrokeStyle(lineWidth: max(0.5, s * 0.08), lineJoin: .round))
        for dx in [-0.16, 0.0, 0.16] {
            let dot = CGRect(x: dx * s - s * 0.04, y: -s * 0.26, width: s * 0.08, height: s * 0.08)
            inside.fill(Path(ellipseIn: dot), with: .color(band.opacity(0.9)))
        }
        gloss(&local, in: rect, opacity: 0.35)
    }

    /// The Earth, lit from the left, with a sprout growing from the top.
    static func globe(_ c: inout Context, at p: CGPoint, size s: Double) {
        let ocean = paint(0.22, 0.55, 0.9)
        let land = paint(0.3, 0.72, 0.38)
        let rect = CGRect(x: p.x - s * 0.4, y: p.y - s * 0.3, width: s * 0.8, height: s * 0.8)
        shadow(&c, at: CGPoint(x: p.x, y: rect.maxY), width: s * 0.7)
        let ball = Path(ellipseIn: rect)
        c.fill(ball, with: lit(ocean, in: rect))
        var inside = c
        inside.clip(to: ball)
        let continents: [CGRect] = [
            CGRect(x: rect.minX + s * 0.06, y: rect.minY + s * 0.14, width: s * 0.3, height: s * 0.24),
            CGRect(x: rect.minX + s * 0.18, y: rect.minY + s * 0.42, width: s * 0.18, height: s * 0.26),
            CGRect(x: rect.minX + s * 0.46, y: rect.minY + s * 0.1, width: s * 0.3, height: s * 0.2),
            CGRect(x: rect.minX + s * 0.5, y: rect.minY + s * 0.36, width: s * 0.2, height: s * 0.24),
        ]
        for blob in continents {
            inside.fill(Path(roundedRect: blob, cornerRadius: blob.height * 0.45), with: lit(land, in: blob, light: 0.25))
        }
        gloss(&c, in: rect, opacity: 0.4)
        sprout(&c, base: CGPoint(x: p.x, y: rect.minY + s * 0.02), size: s * 0.36)
    }

    /// Two leaves on a short stem, rooted at `base`.
    static func sprout(_ c: inout Context, base: CGPoint, size s: Double) {
        let green = paint(0.36, 0.74, 0.3)
        var stem = Path()
        stem.move(to: base)
        stem.addLine(to: CGPoint(x: base.x, y: base.y - s * 0.6))
        c.stroke(stem, with: .color(green.mix(with: .black, by: 0.2)),
                 style: StrokeStyle(lineWidth: max(0.5, s * 0.1), lineCap: .round))
        leaf(&c, at: CGPoint(x: base.x - s * 0.24, y: base.y - s * 0.58), size: s * 0.55, angle: -1.0, color: green)
        leaf(&c, at: CGPoint(x: base.x + s * 0.24, y: base.y - s * 0.66), size: s * 0.55, angle: 1.0, color: green)
    }

    /// A rainbow arc with two little clouds at its feet.
    static func rainbowArc(_ c: inout Context, at p: CGPoint, size s: Double) {
        let band = s * 0.085
        for (k, color) in rainbow.enumerated() {
            let r = s * 0.62 - Double(k) * band
            var arc = Path()
            arc.addArc(center: CGPoint(x: p.x, y: p.y + s * 0.3), radius: r,
                       startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            c.stroke(arc, with: .color(color), lineWidth: band * 1.05)
        }
        for side in [-1.0, 1.0] {
            let at = CGPoint(x: p.x + side * s * 0.46, y: p.y + s * 0.3)
            cloud(&c, at: at, size: s * 0.34)
        }
    }

    /// A puff of cloud.
    static func cloud(_ c: inout Context, at p: CGPoint, size s: Double) {
        let white = paint(0.98, 0.98, 1)
        let puffs = [CGRect(x: p.x - s * 0.5, y: p.y - s * 0.2, width: s * 0.56, height: s * 0.46),
                     CGRect(x: p.x - s * 0.2, y: p.y - s * 0.4, width: s * 0.6, height: s * 0.6),
                     CGRect(x: p.x + s * 0.06, y: p.y - s * 0.18, width: s * 0.5, height: s * 0.44)]
        for puff in puffs {
            c.fill(Path(ellipseIn: puff), with: lit(white, in: puff, light: 0, dark: 0.12))
        }
    }

    /// A star, lit and glossed.
    static func star(_ c: inout Context, at p: CGPoint, size s: Double, color: Color) {
        let rect = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
        c.fill(starPath(p, s / 2), with: lit(color, in: rect, light: 0.4, dark: 0.2))
    }

    /// A little stars-and-stripes flag on a pole, planted at `base`.
    static func flag(_ c: inout Context, base: CGPoint, size s: Double, wave: Double = 0) {
        var pole = Path()
        pole.move(to: base)
        pole.addLine(to: CGPoint(x: base.x, y: base.y - s))
        c.stroke(pole, with: .color(Color(white: 0.78)), style: StrokeStyle(lineWidth: max(0.6, s * 0.05), lineCap: .round))
        let w = s * 0.8
        let h = s * 0.48
        let top = base.y - s * 0.96
        var cloth = Path()
        cloth.move(to: CGPoint(x: base.x, y: top))
        cloth.addQuadCurve(to: CGPoint(x: base.x + w, y: top), control: CGPoint(x: base.x + w / 2, y: top - s * 0.06 * wave))
        cloth.addLine(to: CGPoint(x: base.x + w, y: top + h))
        cloth.addQuadCurve(to: CGPoint(x: base.x, y: top + h), control: CGPoint(x: base.x + w / 2, y: top + h - s * 0.06 * wave))
        cloth.closeSubpath()
        c.fill(cloth, with: .color(.white))
        var stripes = c
        stripes.clip(to: cloth)
        for k in 0..<4 {
            let y = top + Double(k) * h / 3.5
            stripes.fill(Path(CGRect(x: base.x, y: y, width: w, height: h / 7)), with: .color(usRed))
        }
        stripes.fill(Path(CGRect(x: base.x, y: top - s * 0.05, width: w * 0.42, height: h * 0.56)), with: .color(usBlue))
        for k in 0..<3 {
            let at = CGPoint(x: base.x + w * (0.08 + Double(k) * 0.12), y: top + h * 0.2)
            stripes.fill(starPath(at, s * 0.04), with: .color(.white))
        }
        rim(&c, cloth, Color(white: 0.7), width: max(0.3, s * 0.02))
    }

    /// A rosette: a fan of bunting, the Fourth's red, white and blue.
    static func rosette(_ c: inout Context, at p: CGPoint, size s: Double) {
        let colors = [usRed, .white, usBlue]
        for (k, color) in colors.enumerated() {
            let r = s * (0.5 - Double(k) * 0.14)
            var fan = Path()
            fan.move(to: p)
            fan.addArc(center: p, radius: r, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            fan.closeSubpath()
            c.fill(fan, with: lit(color, in: CGRect(x: p.x - r, y: p.y, width: r * 2, height: r)))
        }
        star(&c, at: CGPoint(x: p.x, y: p.y + s * 0.04), size: s * 0.22, color: .white)
    }
}
