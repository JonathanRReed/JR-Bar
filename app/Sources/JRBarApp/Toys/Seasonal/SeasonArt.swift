import SwiftUI

/// The seasonal touches' drawings, in the toys' illustrated style: soft
/// gradients lit from the top left, a gloss highlight, a darker rim and a
/// small cast shadow, the way the tank's decor and the buddy's wardrobe
/// are drawn. Every motif draws into a `GraphicsContext` at a centre and
/// a size, so the notch garland, the card's centrepiece, the tank's sand
/// and the Settings accent all share one drawing.
///
/// Sizes are the motif's height in points. Nothing here animates by
/// itself: a caller that wants a flicker passes its own phase.
enum SeasonArt {
    typealias Context = GraphicsContext

    // MARK: Paint

    /// One of the drawings' own paints. These colour illustrations — a
    /// pumpkin, a lantern, a bauble — the way the tank's and the buddy's
    /// art do, so they are not interface colours and take no token.
    static func paint(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red, green: green, blue: blue) // jrbar-token-exception: illustration paint for the seasonal drawings, not interface colour
    }

    /// A body lit from the top left: lighter there, deeper at the far edge.
    static func lit(_ base: Color, in rect: CGRect, light: Double = 0.32, dark: Double = 0.26) -> GraphicsContext.Shading {
        let colors = [base.mix(with: .white, by: light), base, base.mix(with: .black, by: dark)]
        let centre = CGPoint(x: rect.minX + rect.width * 0.34, y: rect.minY + rect.height * 0.3)
        let reach = max(rect.width, rect.height) * 0.85
        return .radialGradient(Gradient(colors: colors), center: centre, startRadius: 0, endRadius: reach)
    }

    /// Top to bottom, for flat pieces: paper, cloth, wood.
    static func fall(_ base: Color, in rect: CGRect, light: Double = 0.2, dark: Double = 0.2) -> GraphicsContext.Shading {
        let colors = [base.mix(with: .white, by: light), base.mix(with: .black, by: dark)]
        return .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: rect.midX, y: rect.minY),
                               endPoint: CGPoint(x: rect.midX, y: rect.maxY))
    }

    /// The gloss: a small soft ellipse near the top left.
    static func gloss(_ c: inout Context, in rect: CGRect, opacity: Double = 0.45) {
        let spot = CGRect(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.14,
                          width: rect.width * 0.32, height: rect.height * 0.2)
        c.fill(Path(ellipseIn: spot), with: .color(.white.opacity(opacity)))
    }

    /// A darker rim, so a piece holds its edge on any ground.
    static func rim(_ c: inout Context, _ path: Path, _ base: Color, width: Double) {
        c.stroke(path, with: .color(base.mix(with: .black, by: 0.45).opacity(0.55)), lineWidth: width)
    }

    /// A soft cast shadow on whatever the piece stands on.
    static func shadow(_ c: inout Context, at centre: CGPoint, width: Double, opacity: Double = 0.22) {
        let rect = CGRect(x: centre.x - width / 2, y: centre.y - width * 0.09, width: width, height: width * 0.18)
        c.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [.black.opacity(opacity), .black.opacity(0)]),
            center: centre, startRadius: 0, endRadius: width / 2))
    }

    /// A warm glow behind a flame or a lantern.
    static func glow(_ c: inout Context, at centre: CGPoint, radius: Double, color: Color, strength: Double = 0.5) {
        c.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
               with: .radialGradient(Gradient(colors: [color.opacity(strength), color.opacity(0)]),
                                     center: centre, startRadius: 0, endRadius: radius))
    }

    /// One candle flame, `h` tall, its base at `base`.
    static func flame(_ c: inout Context, base: CGPoint, h: Double, flicker: Double = 0) {
        let w = h * 0.55
        let lean = flicker * w * 0.2
        var p = Path()
        p.move(to: CGPoint(x: base.x, y: base.y))
        p.addQuadCurve(to: CGPoint(x: base.x + lean, y: base.y - h),
                       control: CGPoint(x: base.x - w * 0.9, y: base.y - h * 0.45))
        p.addQuadCurve(to: CGPoint(x: base.x, y: base.y),
                       control: CGPoint(x: base.x + w * 0.9, y: base.y - h * 0.45))
        glow(&c, at: CGPoint(x: base.x, y: base.y - h * 0.45), radius: h * 1.1,
             color: paint(1, 0.78, 0.3), strength: 0.45)
        c.fill(p, with: .linearGradient(Gradient(colors: [paint(1, 0.97, 0.75),
                                                          paint(1, 0.66, 0.16)]),
                                        startPoint: CGPoint(x: base.x, y: base.y),
                                        endPoint: CGPoint(x: base.x, y: base.y - h)))
    }

    // MARK: Shapes

    /// A heart `s` tall, centred.
    static func heartPath(_ p: CGPoint, _ s: Double) -> Path {
        let w = s * 1.08
        var path = Path()
        path.move(to: CGPoint(x: p.x, y: p.y + s * 0.5))
        path.addCurve(to: CGPoint(x: p.x - w * 0.5, y: p.y - s * 0.12),
                      control1: CGPoint(x: p.x - w * 0.18, y: p.y + s * 0.3),
                      control2: CGPoint(x: p.x - w * 0.5, y: p.y + s * 0.12))
        path.addArc(center: CGPoint(x: p.x - w * 0.25, y: p.y - s * 0.16), radius: w * 0.25,
                    startAngle: .degrees(170), endAngle: .degrees(355), clockwise: false)
        path.addArc(center: CGPoint(x: p.x + w * 0.25, y: p.y - s * 0.16), radius: w * 0.25,
                    startAngle: .degrees(185), endAngle: .degrees(10), clockwise: false)
        path.addCurve(to: CGPoint(x: p.x, y: p.y + s * 0.5),
                      control1: CGPoint(x: p.x + w * 0.5, y: p.y + s * 0.12),
                      control2: CGPoint(x: p.x + w * 0.18, y: p.y + s * 0.3))
        path.closeSubpath()
        return path
    }

    /// A star with `points` tips, outer radius `r`.
    static func starPath(_ p: CGPoint, _ r: Double, points: Int = 5, inner: Double = 0.45,
                         rotation: Double = -.pi / 2) -> Path {
        var path = Path()
        for i in 0..<(points * 2) {
            let radius = i.isMultiple(of: 2) ? r : r * inner
            let angle = rotation + Double(i) * .pi / Double(points)
            let point = CGPoint(x: p.x + cos(angle) * radius, y: p.y + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// A rounded triangle pennant hanging from its top edge at `top`.
    static func pennantPath(top: CGPoint, w: Double, h: Double) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: top.x - w / 2, y: top.y))
        path.addLine(to: CGPoint(x: top.x + w / 2, y: top.y))
        path.addQuadCurve(to: CGPoint(x: top.x, y: top.y + h),
                          control: CGPoint(x: top.x + w * 0.18, y: top.y + h * 0.62))
        path.addQuadCurve(to: CGPoint(x: top.x - w / 2, y: top.y),
                          control: CGPoint(x: top.x - w * 0.18, y: top.y + h * 0.62))
        path.closeSubpath()
        return path
    }

    // MARK: Motifs, by holiday

    /// A pumpkin; carved, it grins with a warm light inside.
    static func pumpkin(_ c: inout Context, at p: CGPoint, size s: Double, carved: Bool = false,
                        glow glowing: Double = 0) {
        let orange = paint(0.98, 0.55, 0.13)
        let w = s * 1.25
        let body = CGRect(x: p.x - w / 2, y: p.y - s * 0.38, width: w, height: s * 0.86)
        shadow(&c, at: CGPoint(x: p.x, y: body.maxY), width: w * 0.95)
        if glowing > 0 {
            glow(&c, at: p, radius: s * 1.3, color: paint(1, 0.6, 0.15), strength: 0.35 * glowing)
        }
        // Three lobes, the outer two behind.
        let lobes: [(dx: Double, sw: Double)] = [(-0.27, 0.56), (0.27, 0.56), (0, 0.62)]
        for lobe in lobes {
            let rect = CGRect(x: p.x + w * lobe.dx - w * lobe.sw / 2, y: body.minY,
                              width: w * lobe.sw, height: body.height)
            let path = Path(ellipseIn: rect)
            c.fill(path, with: lit(orange, in: rect))
            rim(&c, path, orange, width: max(0.4, s * 0.025))
        }
        gloss(&c, in: CGRect(x: p.x - w * 0.12, y: body.minY, width: w * 0.42, height: body.height), opacity: 0.35)
        // The stem.
        var stem = Path()
        stem.move(to: CGPoint(x: p.x - s * 0.05, y: body.minY + s * 0.04))
        stem.addQuadCurve(to: CGPoint(x: p.x + s * 0.12, y: body.minY - s * 0.2),
                          control: CGPoint(x: p.x - s * 0.04, y: body.minY - s * 0.14))
        c.stroke(stem, with: .color(paint(0.36, 0.5, 0.22)),
                 style: StrokeStyle(lineWidth: max(0.8, s * 0.1), lineCap: .round))
        guard carved else { return }
        let ink = paint(0.34, 0.12, 0.02)
        let light = paint(1, 0.86, 0.36)
        let face = glowing > 0 ? light : ink
        for side in [-1.0, 1.0] {
            var eye = Path()
            eye.move(to: CGPoint(x: p.x + side * s * 0.24, y: p.y - s * 0.12))
            eye.addLine(to: CGPoint(x: p.x + side * s * 0.11, y: p.y + s * 0.04))
            eye.addLine(to: CGPoint(x: p.x + side * s * 0.36, y: p.y + s * 0.04))
            eye.closeSubpath()
            c.fill(eye, with: .color(face))
        }
        var mouth = Path()
        let my = p.y + s * 0.18
        mouth.move(to: CGPoint(x: p.x - s * 0.36, y: my))
        mouth.addQuadCurve(to: CGPoint(x: p.x + s * 0.36, y: my), control: CGPoint(x: p.x, y: my + s * 0.32))
        mouth.addLine(to: CGPoint(x: p.x + s * 0.2, y: my + s * 0.02))
        mouth.addLine(to: CGPoint(x: p.x + s * 0.1, y: my + s * 0.1))
        mouth.addLine(to: CGPoint(x: p.x, y: my + s * 0.02))
        mouth.addLine(to: CGPoint(x: p.x - s * 0.1, y: my + s * 0.1))
        mouth.addLine(to: CGPoint(x: p.x - s * 0.2, y: my + s * 0.02))
        mouth.closeSubpath()
        c.fill(mouth, with: .color(face))
    }

    /// A little bat, wings out; `flap` (−1…1) lifts them.
    static func bat(_ c: inout Context, at p: CGPoint, size s: Double, flap: Double = 0) {
        let ink = paint(0.26, 0.18, 0.36)
        let lift = flap * s * 0.25
        for side in [-1.0, 1.0] {
            var wing = Path()
            wing.move(to: CGPoint(x: p.x + side * s * 0.12, y: p.y - s * 0.1))
            wing.addQuadCurve(to: CGPoint(x: p.x + side * s * 0.95, y: p.y - s * 0.3 - lift),
                              control: CGPoint(x: p.x + side * s * 0.5, y: p.y - s * 0.55 - lift))
            wing.addQuadCurve(to: CGPoint(x: p.x + side * s * 0.62, y: p.y + s * 0.05 - lift * 0.5),
                              control: CGPoint(x: p.x + side * s * 0.88, y: p.y - s * 0.02 - lift))
            wing.addQuadCurve(to: CGPoint(x: p.x + side * s * 0.36, y: p.y + s * 0.12),
                              control: CGPoint(x: p.x + side * s * 0.5, y: p.y - s * 0.04))
            wing.addQuadCurve(to: CGPoint(x: p.x + side * s * 0.12, y: p.y + s * 0.15),
                              control: CGPoint(x: p.x + side * s * 0.22, y: p.y + s * 0.02))
            wing.closeSubpath()
            c.fill(wing, with: .linearGradient(Gradient(colors: [ink.mix(with: .white, by: 0.25), ink]),
                                               startPoint: CGPoint(x: p.x, y: p.y - s * 0.4),
                                               endPoint: CGPoint(x: p.x, y: p.y + s * 0.2)))
        }
        let body = CGRect(x: p.x - s * 0.17, y: p.y - s * 0.22, width: s * 0.34, height: s * 0.46)
        c.fill(Path(ellipseIn: body), with: lit(ink, in: body, light: 0.3))
        for side in [-1.0, 1.0] {
            var ear = Path()
            ear.move(to: CGPoint(x: p.x + side * s * 0.05, y: body.minY + s * 0.04))
            ear.addLine(to: CGPoint(x: p.x + side * s * 0.13, y: body.minY - s * 0.1))
            ear.addLine(to: CGPoint(x: p.x + side * s * 0.15, y: body.minY + s * 0.08))
            ear.closeSubpath()
            c.fill(ear, with: .color(ink))
            let eye = CGRect(x: p.x + side * s * 0.07 - s * 0.03, y: p.y - s * 0.08, width: s * 0.06, height: s * 0.06)
            c.fill(Path(ellipseIn: eye), with: .color(paint(1, 0.85, 0.4)))
        }
    }

    /// A marigold: rings of ruffled petals round a deep centre.
    static func marigold(_ c: inout Context, at p: CGPoint, size s: Double,
                         hue: Color = paint(1, 0.62, 0.08)) {
        let r = s / 2
        for ring in 0..<3 {
            let rr = r * (1 - Double(ring) * 0.26)
            let count = 9 - ring * 2
            let tone = hue.mix(with: ring == 0 ? .black : .white, by: ring == 0 ? 0.12 : 0.12 * Double(ring))
            for k in 0..<count {
                let a = Double(k) / Double(count) * 2 * .pi + Double(ring) * 0.35
                let cx = p.x + cos(a) * rr * 0.55
                let cy = p.y + sin(a) * rr * 0.55
                let petal = CGRect(x: cx - rr * 0.42, y: cy - rr * 0.42, width: rr * 0.84, height: rr * 0.84)
                c.fill(Path(ellipseIn: petal), with: lit(tone, in: petal, light: 0.25, dark: 0.15))
            }
        }
        let core = CGRect(x: p.x - r * 0.24, y: p.y - r * 0.24, width: r * 0.48, height: r * 0.48)
        c.fill(Path(ellipseIn: core), with: .color(hue.mix(with: .black, by: 0.35)))
    }

    /// A papel picado flag: tissue paper with punched holes and a
    /// scalloped hem, hanging from `top`.
    static func papelPicado(_ c: inout Context, top: CGPoint, w: Double, h: Double, color: Color) {
        var sheet = Path()
        sheet.move(to: CGPoint(x: top.x - w / 2, y: top.y))
        sheet.addLine(to: CGPoint(x: top.x + w / 2, y: top.y))
        sheet.addLine(to: CGPoint(x: top.x + w / 2, y: top.y + h * 0.82))
        let scallops = 4
        for k in 0..<scallops {
            let x0 = top.x + w / 2 - Double(k) * w / Double(scallops)
            let x1 = x0 - w / Double(scallops)
            sheet.addQuadCurve(to: CGPoint(x: x1, y: top.y + h * 0.82),
                               control: CGPoint(x: (x0 + x1) / 2, y: top.y + h * 1.08))
        }
        sheet.closeSubpath()
        let rect = CGRect(x: top.x - w / 2, y: top.y, width: w, height: h)
        c.fill(sheet, with: fall(color, in: rect, light: 0.18, dark: 0.12))
        // The punched pattern: a flower and four diamonds, cut through.
        var cut = c
        cut.blendMode = .destinationOut
        let flower = CGPoint(x: top.x, y: top.y + h * 0.42)
        for k in 0..<6 {
            let a = Double(k) / 6 * 2 * .pi
            let petal = CGRect(x: flower.x + cos(a) * w * 0.12 - w * 0.07, y: flower.y + sin(a) * w * 0.12 - w * 0.07,
                               width: w * 0.14, height: w * 0.14)
            cut.fill(Path(ellipseIn: petal), with: .color(.black.opacity(0.85)))
        }
        for dx in [-0.33, 0.33] {
            for dy in [0.18, 0.66] {
                let d = CGPoint(x: top.x + dx * w, y: top.y + dy * h)
                var diamond = Path()
                diamond.move(to: CGPoint(x: d.x, y: d.y - w * 0.07))
                diamond.addLine(to: CGPoint(x: d.x + w * 0.05, y: d.y))
                diamond.addLine(to: CGPoint(x: d.x, y: d.y + w * 0.07))
                diamond.addLine(to: CGPoint(x: d.x - w * 0.05, y: d.y))
                diamond.closeSubpath()
                cut.fill(diamond, with: .color(.black.opacity(0.85)))
            }
        }
    }

    /// A sugar skull: white icing, flower eyes, a smile of stitches.
    static func sugarSkull(_ c: inout Context, at p: CGPoint, size s: Double) {
        let bone = paint(0.98, 0.96, 0.92)
        let head = CGRect(x: p.x - s * 0.42, y: p.y - s * 0.5, width: s * 0.84, height: s * 0.72)
        var skull = Path(ellipseIn: head)
        skull.addRoundedRect(in: CGRect(x: p.x - s * 0.26, y: p.y + s * 0.05, width: s * 0.52, height: s * 0.38),
                             cornerSize: CGSize(width: s * 0.12, height: s * 0.12))
        shadow(&c, at: CGPoint(x: p.x, y: p.y + s * 0.46), width: s * 0.8)
        c.fill(skull, with: lit(bone, in: head, light: 0.1, dark: 0.12))
        rim(&c, skull, paint(0.75, 0.7, 0.66), width: max(0.4, s * 0.025))
        let eyeColors = [paint(0.95, 0.3, 0.55), paint(0.2, 0.62, 0.95)]
        for (i, side) in [-1.0, 1.0].enumerated() {
            let eye = CGPoint(x: p.x + side * s * 0.17, y: p.y - s * 0.12)
            marigold(&c, at: eye, size: s * 0.3, hue: eyeColors[i])
            c.fill(Path(ellipseIn: CGRect(x: eye.x - s * 0.06, y: eye.y - s * 0.06, width: s * 0.12, height: s * 0.12)),
                   with: .color(paint(0.2, 0.12, 0.2)))
        }
        var nose = Path()
        nose.move(to: CGPoint(x: p.x, y: p.y + s * 0.02))
        nose.addLine(to: CGPoint(x: p.x - s * 0.05, y: p.y + s * 0.1))
        nose.addLine(to: CGPoint(x: p.x + s * 0.05, y: p.y + s * 0.1))
        nose.closeSubpath()
        c.fill(nose, with: .color(paint(0.2, 0.12, 0.2)))
        var teeth = Path()
        teeth.move(to: CGPoint(x: p.x - s * 0.2, y: p.y + s * 0.24))
        teeth.addLine(to: CGPoint(x: p.x + s * 0.2, y: p.y + s * 0.24))
        for k in 0..<5 {
            let x = p.x - s * 0.16 + Double(k) * s * 0.08
            teeth.move(to: CGPoint(x: x, y: p.y + s * 0.19))
            teeth.addLine(to: CGPoint(x: x, y: p.y + s * 0.29))
        }
        c.stroke(teeth, with: .color(paint(0.2, 0.12, 0.2).opacity(0.8)), lineWidth: max(0.4, s * 0.025))
        marigold(&c, at: CGPoint(x: p.x, y: p.y - s * 0.4), size: s * 0.26, hue: paint(1, 0.62, 0.08))
    }

    /// An autumn leaf, tip up, turned by `angle` radians.
    static func leaf(_ c: inout Context, at p: CGPoint, size s: Double, angle: Double = 0, color: Color) {
        var local = c
        local.translateBy(x: p.x, y: p.y)
        local.rotate(by: .radians(angle))
        var blade = Path()
        blade.move(to: CGPoint(x: 0, y: -s * 0.5))
        blade.addCurve(to: CGPoint(x: 0, y: s * 0.38), control1: CGPoint(x: s * 0.5, y: -s * 0.3),
                       control2: CGPoint(x: s * 0.42, y: s * 0.2))
        blade.addCurve(to: CGPoint(x: 0, y: -s * 0.5), control1: CGPoint(x: -s * 0.42, y: s * 0.2),
                       control2: CGPoint(x: -s * 0.5, y: -s * 0.3))
        let rect = CGRect(x: -s * 0.4, y: -s * 0.5, width: s * 0.8, height: s)
        local.fill(blade, with: lit(color, in: rect, light: 0.25, dark: 0.2))
        var vein = Path()
        vein.move(to: CGPoint(x: 0, y: -s * 0.4))
        vein.addLine(to: CGPoint(x: 0, y: s * 0.5))
        for k in 0..<2 {
            let y = -s * 0.15 + Double(k) * s * 0.22
            vein.move(to: CGPoint(x: 0, y: y + s * 0.08))
            vein.addLine(to: CGPoint(x: s * 0.2, y: y - s * 0.04))
            vein.move(to: CGPoint(x: 0, y: y + s * 0.08))
            vein.addLine(to: CGPoint(x: -s * 0.2, y: y - s * 0.04))
        }
        local.stroke(vein, with: .color(color.mix(with: .black, by: 0.35).opacity(0.7)), lineWidth: max(0.3, s * 0.04))
    }

    /// An acorn with its cap.
    static func acorn(_ c: inout Context, at p: CGPoint, size s: Double) {
        let nut = CGRect(x: p.x - s * 0.28, y: p.y - s * 0.12, width: s * 0.56, height: s * 0.6)
        c.fill(Path(ellipseIn: nut), with: lit(paint(0.8, 0.55, 0.28), in: nut))
        let cap = CGRect(x: p.x - s * 0.34, y: p.y - s * 0.34, width: s * 0.68, height: s * 0.36)
        c.fill(Path(roundedRect: cap, cornerRadius: s * 0.16), with: lit(paint(0.48, 0.32, 0.18), in: cap))
        c.stroke(Path { $0.move(to: CGPoint(x: p.x, y: cap.minY)); $0.addLine(to: CGPoint(x: p.x + s * 0.06, y: cap.minY - s * 0.14)) },
                 with: .color(paint(0.4, 0.26, 0.14)), lineWidth: max(0.5, s * 0.07))
    }

    /// A pumpkin pie on its dish, a dollop of cream on top.
    static func pie(_ c: inout Context, at p: CGPoint, size s: Double) {
        let w = s * 1.5
        shadow(&c, at: CGPoint(x: p.x, y: p.y + s * 0.32), width: w * 1.05)
        let dish = CGRect(x: p.x - w / 2, y: p.y - s * 0.05, width: w, height: s * 0.42)
        c.fill(Path(roundedRect: dish, cornerRadius: s * 0.16), with: fall(paint(0.86, 0.9, 0.95), in: dish))
        let crust = CGRect(x: p.x - w * 0.46, y: p.y - s * 0.28, width: w * 0.92, height: s * 0.48)
        c.fill(Path(ellipseIn: crust), with: lit(paint(0.86, 0.6, 0.3), in: crust))
        let filling = crust.insetBy(dx: s * 0.1, dy: s * 0.06)
        c.fill(Path(ellipseIn: filling), with: lit(paint(0.85, 0.45, 0.14), in: filling, light: 0.2))
        for k in 0..<10 {
            let a = Double(k) / 10 * 2 * .pi
            let bump = CGRect(x: p.x + cos(a) * crust.width * 0.46 - s * 0.06, y: p.y - s * 0.04 + sin(a) * crust.height * 0.46 - s * 0.06,
                              width: s * 0.12, height: s * 0.12)
            c.fill(Path(ellipseIn: bump), with: .color(paint(0.92, 0.7, 0.4)))
        }
        let cream = CGRect(x: p.x - s * 0.18, y: p.y - s * 0.3, width: s * 0.36, height: s * 0.26)
        c.fill(Path(ellipseIn: cream), with: lit(.white, in: cream, light: 0, dark: 0.1))
        let peak = CGRect(x: p.x - s * 0.08, y: p.y - s * 0.4, width: s * 0.16, height: s * 0.16)
        c.fill(Path(ellipseIn: peak), with: .color(.white))
    }
}
