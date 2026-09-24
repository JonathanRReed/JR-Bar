import JRBarCore
import SwiftUI

/// What the fish wear (docs/TOYS.md): hats on the head, accessories
/// in a slot of their own — lit and outlined like the fish, drawn in
/// the fish's unit space so the swim's flip, pitch and squash carry
/// them.
extension CartoonFish {
    // MARK: Hats

    /// A purchased hat drawn at `anchor` (the kit's `hatAnchor`),
    /// `scale` times its standard size and tipped `tilt` radians
    /// forward to sit on the brow.
    static func drawHat(_ item: ShopItem, into f: inout GraphicsContext,
                        at anchor: CGPoint, scale: Double = 1, tilt: Double = 0,
                        lineWidth lw: Double = 0.02) {
        var h = f
        h.translateBy(x: anchor.x, y: anchor.y)
        h.rotate(by: .radians(tilt))
        h.scaleBy(x: scale, y: scale)
        let line = lw / max(0.1, scale)
        switch item {
        case .hatBeanie:
            let red = Color(red: 0.86, green: 0.25, blue: 0.30)
            let ink = Color(red: 0.36, green: 0.06, blue: 0.10)
            var dome = Path()
            dome.move(to: CGPoint(x: -0.135, y: 0.01))
            dome.addCurve(to: CGPoint(x: 0.0, y: -0.19), control1: CGPoint(x: -0.14, y: -0.12),
                          control2: CGPoint(x: -0.07, y: -0.19))
            dome.addCurve(to: CGPoint(x: 0.135, y: 0.01), control1: CGPoint(x: 0.07, y: -0.19),
                          control2: CGPoint(x: 0.14, y: -0.12))
            dome.closeSubpath()
            CreaturePaint.solid(&h, dome, lit: Color(red: 1.0, green: 0.52, blue: 0.52), base: red,
                                shade: Color(red: 0.55, green: 0.10, blue: 0.16), outline: ink, lineWidth: line)
            // The knit: soft ribs running up the dome.
            var ribs = Path()
            for x in stride(from: -0.09, through: 0.09, by: 0.045) {
                ribs.move(to: CGPoint(x: x, y: 0.0))
                ribs.addQuadCurve(to: CGPoint(x: x * 0.3, y: -0.17), control: CGPoint(x: x * 1.1, y: -0.10))
            }
            var knit = h
            knit.clip(to: dome)
            knit.stroke(ribs, with: .color(ink.opacity(0.28)), lineWidth: line * 0.7)
            let cuff = Path(roundedRect: CGRect(x: -0.15, y: -0.035, width: 0.30, height: 0.075),
                            cornerRadius: 0.035)
            CreaturePaint.solid(&h, cuff, lit: Color(red: 0.96, green: 0.40, blue: 0.42),
                                base: Color(red: 0.70, green: 0.16, blue: 0.22),
                                shade: Color(red: 0.45, green: 0.07, blue: 0.12), outline: ink, lineWidth: line)
            CreaturePaint.pompom(&h, at: CGPoint(x: 0.0, y: -0.21), r: 0.048, lineWidth: line,
                                 tint: .white, outline: ink.opacity(0.6))
        case .hatParty:
            let ink = Color(red: 0.10, green: 0.18, blue: 0.42)
            var cone = Path()
            cone.move(to: CGPoint(x: -0.11, y: 0.0))
            cone.addQuadCurve(to: CGPoint(x: 0.02, y: -0.29), control: CGPoint(x: -0.05, y: -0.14))
            cone.addQuadCurve(to: CGPoint(x: 0.11, y: 0.0), control: CGPoint(x: 0.08, y: -0.13))
            cone.addQuadCurve(to: CGPoint(x: -0.11, y: 0.0), control: CGPoint(x: 0.0, y: 0.035))
            cone.closeSubpath()
            CreaturePaint.solid(&h, cone, lit: Color(red: 0.55, green: 0.80, blue: 1.0),
                                base: Color(red: 0.26, green: 0.52, blue: 0.96),
                                shade: Color(red: 0.14, green: 0.28, blue: 0.70), outline: ink, lineWidth: line)
            // Two bright swirl stripes and a scatter of confetti dots.
            var stripes = h
            stripes.clip(to: cone)
            for (y, tint) in [(-0.07, Color(red: 1.0, green: 0.84, blue: 0.30)),
                              (-0.16, Color(red: 1.0, green: 0.45, blue: 0.62))] as [(Double, Color)] {
                var s = Path()
                s.move(to: CGPoint(x: -0.2, y: y + 0.05))
                s.addQuadCurve(to: CGPoint(x: 0.2, y: y - 0.05), control: CGPoint(x: 0, y: y + 0.03))
                stripes.stroke(s, with: .color(tint), lineWidth: 0.035)
            }
            for (x, y) in [(-0.04, -0.03), (0.05, -0.11), (-0.01, -0.20), (0.06, -0.03)] as [(Double, Double)] {
                stripes.fill(Path(ellipseIn: CGRect(x: x - 0.012, y: y - 0.012, width: 0.024, height: 0.024)),
                             with: .color(.white.opacity(0.9)))
            }
            h.stroke(cone, with: .color(ink), style: StrokeStyle(lineWidth: line, lineJoin: .round))
            CreaturePaint.pompom(&h, at: CGPoint(x: 0.02, y: -0.305), r: 0.042, lineWidth: line,
                                 tint: Color(red: 1.0, green: 0.82, blue: 0.30),
                                 outline: Color(red: 0.55, green: 0.36, blue: 0.05))
        case .hatCrown:
            let ink = Color(red: 0.45, green: 0.28, blue: 0.02)
            var band = Path()
            band.move(to: CGPoint(x: -0.125, y: 0.01))
            band.addLine(to: CGPoint(x: -0.135, y: -0.12))
            band.addLine(to: CGPoint(x: -0.065, y: -0.06))
            band.addLine(to: CGPoint(x: 0.0, y: -0.155))
            band.addLine(to: CGPoint(x: 0.065, y: -0.06))
            band.addLine(to: CGPoint(x: 0.135, y: -0.12))
            band.addLine(to: CGPoint(x: 0.125, y: 0.01))
            band.addQuadCurve(to: CGPoint(x: -0.125, y: 0.01), control: CGPoint(x: 0, y: 0.035))
            band.closeSubpath()
            CreaturePaint.solid(&h, band, lit: Color(red: 1.0, green: 0.93, blue: 0.55),
                                base: Color(red: 0.98, green: 0.76, blue: 0.22),
                                shade: Color(red: 0.70, green: 0.46, blue: 0.06), outline: ink, lineWidth: line)
            var rim = h
            rim.clip(to: band)
            rim.fill(Path(CGRect(x: -0.2, y: -0.035, width: 0.4, height: 0.05)),
                     with: .color(Color(red: 0.80, green: 0.54, blue: 0.10).opacity(0.7)))
            for x in [-0.135, 0.0, 0.135] {
                let y = x == 0 ? -0.155 : -0.12
                CreaturePaint.pompom(&h, at: CGPoint(x: x, y: y), r: 0.022, lineWidth: line * 0.8,
                                     tint: Color(red: 1.0, green: 0.95, blue: 0.70), outline: ink)
            }
            CreaturePaint.gem(&h, at: CGPoint(x: 0, y: -0.01), r: 0.026,
                              tint: Color(red: 0.92, green: 0.20, blue: 0.36), lineWidth: line)
            CreaturePaint.gem(&h, at: CGPoint(x: -0.08, y: -0.01), r: 0.017,
                              tint: Color(red: 0.25, green: 0.62, blue: 1.0), lineWidth: line)
            CreaturePaint.gem(&h, at: CGPoint(x: 0.08, y: -0.01), r: 0.017,
                              tint: Color(red: 0.25, green: 0.62, blue: 1.0), lineWidth: line)
        default:
            break
        }
    }

    // MARK: Accessories

    /// A purchased accessory drawn in the second wearable slot (docs/
    /// TOYS.md): eyewear anchors on the `Art`'s eye, headwear on its
    /// `hatAnchor` (the view skips a hat while headwear wins the
    /// slot), the bow tie knots under the chin and the scarf wraps the
    /// collar. Same unit space as `drawHat` — the body's flip, pitch
    /// and squash carry it. `trail` (−1…1) lifts the scarf's loose end;
    /// `thin` is the swim's turn, so eyewear follows the eyes round.
    static func drawAccessory(_ item: ShopItem, into f: inout GraphicsContext,
                              art: Art, trail: Double = 0, thin: Double = 1,
                              lineWidth lw: Double = 0.02) {
        let e = art.eye, r = art.eyeR
        switch item {
        case .sunglasses:
            // A big dark lens over the near eye, the arm running back
            // to the gill. Through a turn the frames come round with
            // the face: the far lens shows and the bridge spans them.
            let face = faceTurn(art: art, thin: thin)
            let near = CGPoint(x: e.x + face.spread, y: e.y)
            let far = CGPoint(x: e.x - face.spread, y: e.y)
            let frame = Color(red: 0.05, green: 0.05, blue: 0.07)
            if face.turn > 0.05 {
                var back = f
                back.opacity = face.far
                sunglassLens(&back, at: far, r: r * 0.94, sx: face.sx, lw: lw)
                var bridge = Path()
                bridge.move(to: CGPoint(x: far.x + r * 1.3 * face.sx, y: e.y - r * 0.8))
                bridge.addQuadCurve(to: CGPoint(x: near.x - r * 1.25 * face.sx, y: e.y - r * 0.8),
                                    control: CGPoint(x: e.x, y: e.y - r * 1.15))
                back.stroke(bridge, with: .color(frame), style: StrokeStyle(lineWidth: r * 0.26, lineCap: .round))
            }
            var side = f
            side.opacity = 1 - face.turn
            var arm = Path()
            arm.move(to: CGPoint(x: e.x - r * 1.2, y: e.y - r * 0.55))
            arm.addQuadCurve(to: CGPoint(x: e.x - r * 3.4, y: e.y - r * 0.9),
                             control: CGPoint(x: e.x - r * 2.4, y: e.y - r * 0.95))
            side.stroke(arm, with: .color(Color(red: 0.08, green: 0.08, blue: 0.10)),
                        style: StrokeStyle(lineWidth: r * 0.32, lineCap: .round))
            var nose = Path()
            nose.move(to: CGPoint(x: e.x + r * 1.45, y: e.y - r * 0.85))
            nose.addLine(to: CGPoint(x: e.x + r * 2.0, y: e.y - r * 0.75))
            side.stroke(nose, with: .color(frame), style: StrokeStyle(lineWidth: r * 0.26, lineCap: .round))
            sunglassLens(&f, at: near, r: r, sx: face.sx, lw: lw)
        case .monocle:
            // A gold rim over the eye, faintly tinted glass, a glint and
            // a fine chain looping down to the chin; it stays on the near
            // eye through a turn.
            let face = faceTurn(art: art, thin: thin)
            let eye = CGPoint(x: e.x + face.spread, y: e.y)
            var chain = Path()
            chain.move(to: CGPoint(x: eye.x - r * 0.9 * face.sx, y: e.y + r * 1.15))
            chain.addQuadCurve(to: art.chin, control: CGPoint(x: eye.x - r * 1.3, y: art.chin.y + r * 1.4))
            f.stroke(chain, with: .color(Color(red: 0.86, green: 0.68, blue: 0.26)),
                     style: StrokeStyle(lineWidth: max(lw * 0.8, r * 0.12), lineCap: .round,
                                        dash: [r * 0.18, r * 0.14]))
            var m = f
            m.translateBy(x: eye.x, y: eye.y)
            m.scaleBy(x: face.sx, y: 1)
            let ringR = r * 1.45
            let ring = Path(ellipseIn: CGRect(x: -ringR, y: -ringR, width: ringR * 2, height: ringR * 2))
            m.fill(ring, with: .radialGradient(
                Gradient(colors: [Color(red: 0.85, green: 0.95, blue: 1.0).opacity(0.10),
                                  Color(red: 0.85, green: 0.95, blue: 1.0).opacity(0.28)]),
                center: .zero, startRadius: 0, endRadius: ringR))
            m.stroke(ring, with: .color(Color(red: 0.52, green: 0.36, blue: 0.06)), lineWidth: r * 0.42)
            m.stroke(ring, with: .linearGradient(
                Gradient(colors: [Color(red: 1.0, green: 0.93, blue: 0.60), Color(red: 0.86, green: 0.62, blue: 0.16)]),
                startPoint: CGPoint(x: -ringR, y: -ringR), endPoint: CGPoint(x: ringR, y: ringR)),
                lineWidth: r * 0.26)
            var glint = Path()
            glint.addArc(center: .zero, radius: ringR * 0.72, startAngle: .degrees(200), endAngle: .degrees(250),
                         clockwise: false)
            m.stroke(glint, with: .color(.white.opacity(0.85)),
                     style: StrokeStyle(lineWidth: r * 0.16, lineCap: .round))
        case .topHat:
            var h = f
            h.translateBy(x: art.hatAnchor.x, y: art.hatAnchor.y)
            h.rotate(by: .radians(art.hatTilt))
            h.scaleBy(x: art.hatScale, y: art.hatScale)
            let line = lw / max(0.1, art.hatScale)
            let ink = Color(red: 0.02, green: 0.02, blue: 0.04)
            let brim = Path(ellipseIn: CGRect(x: -0.17, y: -0.045, width: 0.34, height: 0.075))
            CreaturePaint.solid(&h, brim, lit: Color(red: 0.34, green: 0.35, blue: 0.42),
                                base: Color(red: 0.12, green: 0.12, blue: 0.16),
                                shade: Color(red: 0.04, green: 0.04, blue: 0.06), outline: ink, lineWidth: line)
            var crown = Path()
            crown.move(to: CGPoint(x: -0.105, y: -0.02))
            crown.addLine(to: CGPoint(x: -0.115, y: -0.30))
            crown.addQuadCurve(to: CGPoint(x: 0.115, y: -0.30), control: CGPoint(x: 0, y: -0.33))
            crown.addLine(to: CGPoint(x: 0.105, y: -0.02))
            crown.addQuadCurve(to: CGPoint(x: -0.105, y: -0.02), control: CGPoint(x: 0, y: 0.005))
            crown.closeSubpath()
            h.fill(crown, with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(red: 0.07, green: 0.07, blue: 0.10), location: 0),
                    .init(color: Color(red: 0.36, green: 0.37, blue: 0.45), location: 0.28),
                    .init(color: Color(red: 0.13, green: 0.13, blue: 0.17), location: 0.5),
                    .init(color: Color(red: 0.04, green: 0.04, blue: 0.06), location: 1),
                ]),
                startPoint: CGPoint(x: -0.12, y: 0), endPoint: CGPoint(x: 0.12, y: 0)))
            var band = h
            band.clip(to: crown)
            band.fill(Path(CGRect(x: -0.2, y: -0.10, width: 0.4, height: 0.055)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.90, green: 0.30, blue: 0.36), Color(red: 0.55, green: 0.10, blue: 0.16)]),
                startPoint: CGPoint(x: 0, y: -0.10), endPoint: CGPoint(x: 0, y: -0.045)))
            h.stroke(crown, with: .color(ink), style: StrokeStyle(lineWidth: line, lineJoin: .round))
            let top = Path(ellipseIn: CGRect(x: -0.115, y: -0.325, width: 0.23, height: 0.05))
            h.fill(top, with: .color(Color(red: 0.20, green: 0.20, blue: 0.26)))
            h.stroke(top, with: .color(ink), lineWidth: line)
        case .headphones:
            var h = f
            h.translateBy(x: art.hatAnchor.x, y: art.hatAnchor.y)
            h.rotate(by: .radians(art.hatTilt))
            h.scaleBy(x: art.hatScale, y: art.hatScale)
            let line = lw / max(0.1, art.hatScale)
            let ink = Color(red: 0.05, green: 0.06, blue: 0.09)
            // The band arcs over the crown to a cup behind the eye.
            var band = Path()
            band.move(to: CGPoint(x: 0.10, y: 0.05))
            band.addCurve(to: CGPoint(x: -0.13, y: 0.10), control1: CGPoint(x: 0.10, y: -0.16),
                          control2: CGPoint(x: -0.14, y: -0.16))
            h.stroke(band, with: .color(ink), style: StrokeStyle(lineWidth: 0.052, lineCap: .round))
            h.stroke(band, with: .linearGradient(
                Gradient(colors: [Color(red: 0.95, green: 0.96, blue: 0.98), Color(red: 0.62, green: 0.65, blue: 0.72)]),
                startPoint: CGPoint(x: 0, y: -0.14), endPoint: CGPoint(x: 0, y: 0.08)),
                style: StrokeStyle(lineWidth: 0.030, lineCap: .round))
            let cup = Path(roundedRect: CGRect(x: -0.19, y: 0.04, width: 0.12, height: 0.17), cornerRadius: 0.055)
            CreaturePaint.solid(&h, cup, lit: Color(red: 1.0, green: 1.0, blue: 1.0),
                                base: Color(red: 0.86, green: 0.88, blue: 0.92),
                                shade: Color(red: 0.55, green: 0.58, blue: 0.66), outline: ink, lineWidth: line)
            let plate = Path(ellipseIn: CGRect(x: -0.165, y: 0.075, width: 0.07, height: 0.10))
            h.fill(plate, with: .linearGradient(
                Gradient(colors: [Color(red: 0.45, green: 0.80, blue: 1.0), Color(red: 0.20, green: 0.45, blue: 0.95)]),
                startPoint: CGPoint(x: 0, y: 0.075), endPoint: CGPoint(x: 0, y: 0.175)))
        case .bowTie:
            // Under the chin: two ruffled wings pinched at a knot.
            let knot = art.chin
            let s = max(0.7, min(1.1, r / 0.088))
            var wings = Path()
            for side in [-1.0, 1.0] {
                wings.move(to: knot)
                wings.addQuadCurve(to: CGPoint(x: knot.x + side * 0.11 * s, y: knot.y - 0.065 * s),
                                   control: CGPoint(x: knot.x + side * 0.05 * s, y: knot.y - 0.06 * s))
                wings.addQuadCurve(to: CGPoint(x: knot.x + side * 0.11 * s, y: knot.y + 0.065 * s),
                                   control: CGPoint(x: knot.x + side * 0.135 * s, y: knot.y))
                wings.addQuadCurve(to: knot,
                                   control: CGPoint(x: knot.x + side * 0.05 * s, y: knot.y + 0.06 * s))
                wings.closeSubpath()
            }
            let ink = Color(red: 0.36, green: 0.05, blue: 0.10)
            CreaturePaint.solid(&f, wings, lit: Color(red: 1.0, green: 0.45, blue: 0.48),
                                base: Color(red: 0.84, green: 0.18, blue: 0.26),
                                shade: Color(red: 0.50, green: 0.08, blue: 0.14), outline: ink, lineWidth: lw)
            var folds = Path()
            for side in [-1.0, 1.0] {
                folds.move(to: CGPoint(x: knot.x + side * 0.03 * s, y: knot.y - 0.02 * s))
                folds.addLine(to: CGPoint(x: knot.x + side * 0.08 * s, y: knot.y - 0.035 * s))
                folds.move(to: CGPoint(x: knot.x + side * 0.03 * s, y: knot.y + 0.02 * s))
                folds.addLine(to: CGPoint(x: knot.x + side * 0.08 * s, y: knot.y + 0.035 * s))
            }
            f.stroke(folds, with: .color(ink.opacity(0.5)), lineWidth: lw * 0.7)
            let middle = Path(roundedRect: CGRect(x: knot.x - 0.026 * s, y: knot.y - 0.034 * s,
                                                  width: 0.052 * s, height: 0.068 * s),
                              cornerRadius: 0.02 * s)
            CreaturePaint.solid(&f, middle, lit: Color(red: 0.95, green: 0.35, blue: 0.40),
                                base: Color(red: 0.70, green: 0.12, blue: 0.20),
                                shade: Color(red: 0.45, green: 0.06, blue: 0.12), outline: ink, lineWidth: lw)
        case .scarf:
            // A knit wrap round the collar, its loose end streaming back
            // and lifting with the swim.
            let top = art.collar.top, bottom = art.collar.bottom
            let w = max(0.06, min(0.10, (bottom.y - top.y) * 0.22))
            let knit = Color(red: 0.93, green: 0.42, blue: 0.20)
            let knitDark = Color(red: 0.62, green: 0.20, blue: 0.08)
            let cream = Color(red: 1.0, green: 0.93, blue: 0.80)
            var wrap = Path()
            wrap.move(to: CGPoint(x: top.x + 0.01, y: top.y - w * 0.3))
            wrap.addQuadCurve(to: CGPoint(x: bottom.x, y: bottom.y + w * 0.3),
                              control: CGPoint(x: top.x - w * 1.4, y: (top.y + bottom.y) / 2))
            let tailStart = CGPoint(x: bottom.x - w * 0.2, y: bottom.y - w * 0.4)
            let tailEnd = CGPoint(x: tailStart.x - 0.30, y: tailStart.y + 0.02 - trail * 0.08)
            var tail = Path()
            tail.move(to: tailStart)
            tail.addCurve(to: tailEnd,
                          control1: CGPoint(x: tailStart.x - 0.10, y: tailStart.y + 0.06),
                          control2: CGPoint(x: tailEnd.x + 0.10, y: tailEnd.y - 0.05 - trail * 0.04))
            for path in [tail, wrap] {
                f.stroke(path, with: .color(knitDark), style: StrokeStyle(lineWidth: w + lw * 2, lineCap: .round))
                f.stroke(path, with: .color(knit), style: StrokeStyle(lineWidth: w, lineCap: .round))
                f.stroke(path, with: .color(cream.opacity(0.9)),
                         style: StrokeStyle(lineWidth: w, lineCap: .butt, dash: [w * 0.35, w * 0.65]))
                f.stroke(path.offsetBy(dx: w * 0.15, dy: -w * 0.18), with: .color(.white.opacity(0.22)),
                         style: StrokeStyle(lineWidth: w * 0.25, lineCap: .round))
            }
            var fringe = Path()
            for k in 0..<4 {
                let fy = tailEnd.y + (Double(k) - 1.5) * w * 0.28
                fringe.move(to: CGPoint(x: tailEnd.x - w * 0.3, y: fy))
                fringe.addLine(to: CGPoint(x: tailEnd.x - w * 0.9, y: fy + trail * 0.01))
            }
            f.stroke(fringe, with: .color(knitDark), style: StrokeStyle(lineWidth: lw * 0.9, lineCap: .round))
        case .tinyLaptop:
            // A clamshell tucked under the chin, its screen glowing with
            // a few lines of code.
            var lap = f
            lap.translateBy(x: art.chin.x - 0.10, y: art.chin.y + 0.05)
            lap.rotate(by: .radians(-0.22))
            let ink = Color(red: 0.20, green: 0.22, blue: 0.27)
            let lid = Path(roundedRect: CGRect(x: -0.10, y: -0.15, width: 0.19, height: 0.14), cornerRadius: 0.018)
            CreaturePaint.solid(&lap, lid, lit: Color(red: 0.92, green: 0.93, blue: 0.96),
                                base: Color(red: 0.72, green: 0.74, blue: 0.80),
                                shade: Color(red: 0.48, green: 0.50, blue: 0.56), outline: ink, lineWidth: lw)
            let screen = Path(roundedRect: CGRect(x: -0.087, y: -0.137, width: 0.164, height: 0.114),
                              cornerRadius: 0.01)
            lap.fill(screen, with: .linearGradient(
                Gradient(colors: [Color(red: 0.12, green: 0.18, blue: 0.30), Color(red: 0.05, green: 0.08, blue: 0.16)]),
                startPoint: CGPoint(x: 0, y: -0.137), endPoint: CGPoint(x: 0, y: -0.023)))
            var code = lap
            code.blendMode = .plusLighter
            for (i, tint) in [Color(red: 0.55, green: 0.85, blue: 1.0), Color(red: 1.0, green: 0.70, blue: 0.45),
                              Color(red: 0.60, green: 1.0, blue: 0.70), Color(red: 0.85, green: 0.65, blue: 1.0)]
                    .enumerated() {
                let indent = [0.0, 0.025, 0.025, 0.0][i]
                let length = [0.09, 0.07, 0.10, 0.05][i]
                code.fill(Path(roundedRect: CGRect(x: -0.072 + indent, y: -0.122 + Double(i) * 0.024,
                                                   width: length, height: 0.011), cornerRadius: 0.005),
                          with: .color(tint.opacity(0.85)))
            }
            let base = Path(roundedRect: CGRect(x: -0.12, y: -0.012, width: 0.23, height: 0.035),
                            cornerRadius: 0.014)
            CreaturePaint.solid(&lap, base, lit: Color(red: 0.95, green: 0.96, blue: 0.98),
                                base: Color(red: 0.76, green: 0.78, blue: 0.84),
                                shade: Color(red: 0.50, green: 0.52, blue: 0.58), outline: ink, lineWidth: lw)
        default:
            break
        }
    }

    /// One sunglass lens centred on `e`, `sx` wide against a turn's
    /// squash: dark glass with the sky caught in it and a crisp frame.
    private static func sunglassLens(_ c: inout GraphicsContext, at e: CGPoint, r: Double,
                                     sx: Double, lw: Double) {
        var g = c
        g.translateBy(x: e.x, y: e.y)
        g.scaleBy(x: sx, y: 1)
        var lens = Path()
        lens.move(to: CGPoint(x: -r * 1.35, y: -r * 1.05))
        lens.addLine(to: CGPoint(x: r * 1.45, y: -r * 1.05))
        lens.addQuadCurve(to: CGPoint(x: r * 0.5, y: r * 1.15), control: CGPoint(x: r * 1.45, y: r * 1.0))
        lens.addQuadCurve(to: CGPoint(x: -r * 1.35, y: -r * 0.2), control: CGPoint(x: -r * 1.35, y: r * 1.1))
        lens.closeSubpath()
        g.fill(lens, with: .linearGradient(
            Gradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.26), Color(red: 0.03, green: 0.03, blue: 0.06)]),
            startPoint: CGPoint(x: 0, y: -r), endPoint: CGPoint(x: 0, y: r)))
        var glass = g
        glass.clip(to: lens)
        // Sky caught in the lens: a bright streak and a soft band.
        var streak = Path()
        streak.move(to: CGPoint(x: -r * 0.9, y: r * 0.1))
        streak.addLine(to: CGPoint(x: -r * 0.1, y: -r * 1.1))
        glass.stroke(streak, with: .color(.white.opacity(0.55)), lineWidth: r * 0.28)
        glass.fill(Path(CGRect(x: -r * 2, y: -r * 1.1, width: r * 4, height: r * 0.5)),
                   with: .color(Color(red: 0.55, green: 0.80, blue: 1.0).opacity(0.18)))
        g.stroke(lens, with: .color(Color(red: 0.05, green: 0.05, blue: 0.07)),
                 style: StrokeStyle(lineWidth: max(lw * 1.2, r * 0.18), lineJoin: .round))
    }
}
