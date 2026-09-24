import AppKit
import JRBarCore
import SwiftUI

/// The back wall's backdrop.
extension AquariumView {
    // MARK: Backdrop

    /// The back wall an owned backdrop item papers over the tank
    /// (docs/TOYS.md shop): "classic" leaves the open water, reefwall
    /// hangs a dim rock face with coral nubs behind the dunes, rocky
    /// stacks boulders along the back. Drawn on the still bed, dimmed
    /// into the water so it reads as metres away.
    func drawBackdrop(canvas: inout GraphicsContext, size: CGSize) {
        // Rock & sponge tones pulled toward the water's floor colour
        // so the wall recedes with the theme instead of floating on it.
        func tinted(_ r: Double, _ g: Double, _ b: Double,
                    _ toward: Double, _ alpha: Double) -> Color {
            let base = NSColor(Color(red: r, green: g, blue: b))
            return Color(nsColor: base.blended(withFraction: toward,
                                               of: floorNS) ?? base)
                .opacity(alpha)
        }
        // The wall's rumpled crest, ~40% up the tank — above the
        // seeded kelp line so the wall reads behind everything.
        func wallTop(atX x: Double) -> Double {
            let u = x / max(1, size.width)
            return size.height * 0.58
                + size.height * 0.035 * sin(u * .pi * 5.2 + Self.dunePhase2)
                + size.height * 0.014 * sin(u * .pi * 13.7 + Self.dunePhase1)
        }
        switch backdropKey {
        case "reefwall":
            var wall = Path()
            wall.move(to: CGPoint(x: 0, y: wallTop(atX: 0)))
            var x = 0.0
            while x <= size.width {
                wall.addLine(to: CGPoint(x: x, y: wallTop(atX: x)))
                x += 10
            }
            wall.addLine(to: CGPoint(x: size.width, y: size.height))
            wall.addLine(to: CGPoint(x: 0, y: size.height))
            wall.closeSubpath()
            canvas.fill(wall, with: .linearGradient(
                Gradient(stops: [
                    .init(color: tinted(0.30, 0.36, 0.40, 0.35, 0.9), location: 0),
                    .init(color: tinted(0.18, 0.23, 0.27, 0.45, 1), location: 0.45),
                    .init(color: tinted(0.06, 0.08, 0.11, 0.6, 1), location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: size.height * 0.56),
                endPoint: CGPoint(x: 0, y: size.height)))
            // The crest's fade into the water above it.
            canvas.stroke(wall, with: .color(tinted(0.45, 0.52, 0.55, 0.3, 0.25)),
                          lineWidth: 1.2)
            // Rock plates: seeded courses of uneven, hand-cut slabs —
            // lit along their top lips, dark in the crevices between —
            // a reef wall, not a hill.
            var inner = canvas
            inner.clip(to: wall)
            for row in 0..<4 {
                var px = -24.0
                var i = 0
                let rowTop = size.height * (0.58 + Double(row) * 0.10)
                while px < size.width + 24 {
                    var h = AquariumModel.stableHash("plate-\(row)-\(i)")
                    h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
                    var rng = TankPaint.Seeded(h)
                    let pw = size.height * rng.next(0.09, 0.19)
                    let ph = size.height * rng.next(0.09, 0.14)
                    let py = rowTop + rng.next(0, 1) * size.height * 0.04
                    let tone = rng.next(0.18, 0.30)
                    // A jittered six-point slab, smoothed.
                    let corners = [
                        CGPoint(x: px + rng.next(0, 0.12) * pw, y: py + rng.next(0, 0.2) * ph),
                        CGPoint(x: px + pw * rng.next(0.4, 0.6), y: py - rng.next(0, 0.12) * ph),
                        CGPoint(x: px + pw - rng.next(0, 0.12) * pw, y: py + rng.next(0, 0.2) * ph),
                        CGPoint(x: px + pw + rng.next(-0.05, 0.05) * pw, y: py + ph * rng.next(0.8, 1.0)),
                        CGPoint(x: px + pw * rng.next(0.4, 0.6), y: py + ph * rng.next(0.95, 1.1)),
                        CGPoint(x: px - rng.next(-0.05, 0.05) * pw, y: py + ph * rng.next(0.8, 1.0)),
                    ]
                    var slab = Path()
                    slab.move(to: CGPoint(x: (corners[5].x + corners[0].x) / 2, y: (corners[5].y + corners[0].y) / 2))
                    for k in 0..<corners.count {
                        let a = corners[k], b = corners[(k + 1) % corners.count]
                        slab.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
                    }
                    slab.closeSubpath()
                    inner.fill(slab, with: .linearGradient(
                        Gradient(colors: [tinted(tone + 0.16, tone + 0.20, tone + 0.22, 0.42, 0.95),
                                          tinted(tone * 0.55, tone * 0.62, tone * 0.70, 0.5, 1)]),
                        startPoint: CGPoint(x: px, y: py), endPoint: CGPoint(x: px, y: py + ph)))
                    TankPaint.speckle(&inner, slab, seed: h, count: 10, size: size.height * 0.004,
                                      dark: tinted(0.02, 0.03, 0.05, 0.5, 0.35),
                                      light: tinted(0.7, 0.75, 0.78, 0.5, 0.18))
                    var lip = inner
                    lip.clip(to: slab)
                    lip.stroke(slab.offsetBy(dx: 0, dy: 1.2),
                               with: .color(tinted(0.70, 0.78, 0.80, 0.45, 0.22)), lineWidth: 1.4)
                    inner.stroke(slab, with: .color(tinted(0.01, 0.02, 0.04, 0.5, 0.7)),
                                 style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                    px += pw * rng.next(0.86, 1.05)
                    i += 1
                }
            }
            // Dressing: tube sponges, sea fans in silhouette, brain
            // mounds and coral nubs on the face — muted by the water.
            for i in 0..<18 {
                var h = AquariumModel.stableHash("reefdress-\(i)")
                h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
                var rng = TankPaint.Seeded(h)
                let rx = size.width * Double(h & 0xFFFF) / 0xFFFF
                let ry = wallTop(atX: rx) + size.height * 0.03
                    + Double((h >> 16) & 0xFFFF) / 0xFFFF * size.height * 0.28
                let unit = size.height * 0.02
                switch (h >> 32) % 4 {
                case 0:
                    // Tube sponges: two or three stalks with dark mouths.
                    let tubes = 2 + Int(rng.next(0, 1.99))
                    let hue = (h >> 36) & 1 == 0
                    for k in 0..<tubes {
                        let tx = rx + (Double(k) - Double(tubes - 1) / 2) * unit * 0.9
                        let th = unit * rng.next(1.6, 2.8)
                        let tube = Path(roundedRect: CGRect(x: tx - unit * 0.35, y: ry - th, width: unit * 0.7, height: th),
                                        cornerRadius: unit * 0.3)
                        inner.fill(tube, with: .linearGradient(
                            Gradient(colors: hue ? [tinted(0.40, 0.70, 0.66, 0.35, 0.95), tinted(0.14, 0.34, 0.34, 0.45, 0.95)]
                                                 : [tinted(0.62, 0.48, 0.78, 0.35, 0.95), tinted(0.28, 0.18, 0.40, 0.45, 0.95)]),
                            startPoint: CGPoint(x: tx - unit * 0.35, y: 0), endPoint: CGPoint(x: tx + unit * 0.35, y: 0)))
                        inner.fill(Path(ellipseIn: CGRect(x: tx - unit * 0.28, y: ry - th - unit * 0.1,
                                                          width: unit * 0.56, height: unit * 0.26)),
                                   with: .color(tinted(0.02, 0.03, 0.05, 0.4, 0.85)))
                    }
                case 1:
                    // A sea fan: a flat lace of branches.
                    var fan = Path()
                    for k in 0..<7 {
                        let a = -.pi / 2 + (Double(k) / 6 - 0.5) * 1.5
                        let reach = unit * rng.next(2.2, 3.4)
                        fan.move(to: CGPoint(x: rx, y: ry))
                        fan.addQuadCurve(to: CGPoint(x: rx + cos(a) * reach, y: ry + sin(a) * reach),
                                         control: CGPoint(x: rx + cos(a) * reach * 0.4, y: ry + sin(a) * reach * 0.7))
                    }
                    inner.stroke(fan, with: .color(tinted(0.80, 0.42, 0.52, 0.4, 0.55)),
                                 style: StrokeStyle(lineWidth: max(0.8, unit * 0.12), lineCap: .round))
                case 2:
                    // A brain mound with a lit crown.
                    let mound = Path(ellipseIn: CGRect(x: rx - unit, y: ry - unit * 0.9, width: unit * 2, height: unit * 1.3))
                    inner.fill(mound, with: .radialGradient(
                        Gradient(colors: [tinted(0.80, 0.66, 0.42, 0.35, 0.9), tinted(0.36, 0.26, 0.14, 0.45, 0.9)]),
                        center: CGPoint(x: rx - unit * 0.3, y: ry - unit * 0.7), startRadius: 0, endRadius: unit * 1.3))
                    var folds = Path()
                    for k in 0..<3 {
                        let fy = ry - unit * (0.7 - Double(k) * 0.28)
                        folds.move(to: CGPoint(x: rx - unit * 0.8, y: fy))
                        folds.addQuadCurve(to: CGPoint(x: rx + unit * 0.8, y: fy), control: CGPoint(x: rx, y: fy - unit * 0.25))
                    }
                    var fc = inner
                    fc.clip(to: mound)
                    fc.stroke(folds, with: .color(tinted(0.25, 0.16, 0.08, 0.45, 0.6)), lineWidth: max(0.6, unit * 0.08))
                default:
                    // A coral nub: a warm cluster of dots.
                    var nubs = Path()
                    for k in 0..<4 {
                        let nr = unit * rng.next(0.25, 0.45)
                        nubs.addEllipse(in: CGRect(x: rx + rng.next(-0.6, 0.6) * unit - nr,
                                                   y: ry - Double(k) * unit * 0.25 - nr, width: nr * 2, height: nr * 2))
                    }
                    inner.fill(nubs, with: .color(tinted(0.86, 0.50, 0.50, 0.3, 0.8)))
                }
            }
            // The wall recedes: a veil of the water's own colour at
            // that depth over its face — metres of blue between us.
            let haze = waterStops.first(where: { $0.location >= 0.52 })?.color ?? floorColor
            inner.fill(wall, with: .linearGradient(
                Gradient(colors: [haze.opacity(0.42), haze.opacity(0.18)]),
                startPoint: CGPoint(x: 0, y: size.height * 0.56), endPoint: CGPoint(x: 0, y: size.height)))
        case "rocky":
            // Stacked boulders: a tall back course under the crest,
            // a nearer course overlapping its feet — dark joints
            // between stones, dimming with depth like the wall.
            for row in 0..<2 {
                var bx = -30.0
                var i = 0
                let baseY = size.height * (row == 0 ? 0.92 : 0.99)
                while bx < size.width + 30 {
                    var h = AquariumModel.stableHash("boulder-\(row)-\(i)")
                    h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
                    let bw = size.height * (0.16 + Double(h & 0xFF) / 0xFF * 0.12)
                    let bh = bw * (0.55 + Double((h >> 8) & 0xFF) / 0xFF * 0.28)
                    let by = baseY + Double((h >> 16) & 0x3F) / 0x3F * size.height * 0.03
                    let tone = row == 0 ? 0.30 : 0.22
                    var boulder = Path()
                    boulder.move(to: CGPoint(x: bx, y: by))
                    boulder.addCurve(to: CGPoint(x: bx + bw, y: by),
                                     control1: CGPoint(x: bx, y: by - bh * 1.5),
                                     control2: CGPoint(x: bx + bw, y: by - bh * 1.5))
                    boulder.closeSubpath()
                    canvas.fill(boulder, with: .linearGradient(
                        Gradient(colors: [tinted(tone + 0.12, tone + 0.13,
                                                 tone + 0.16, 0.4, 0.95),
                                          tinted(tone * 0.3, tone * 0.3,
                                                 tone * 0.35, 0.5, 1)]),
                        startPoint: CGPoint(x: bx + bw / 2, y: by - bh),
                        endPoint: CGPoint(x: bx + bw / 2, y: by)))
                    TankPaint.speckle(&canvas, boulder, seed: h, count: 24, size: size.height * 0.005,
                                      dark: tinted(0.02, 0.03, 0.05, 0.5, 0.35),
                                      light: tinted(0.75, 0.78, 0.80, 0.5, 0.16))
                    var rim = canvas
                    rim.clip(to: boulder)
                    rim.stroke(boulder.offsetBy(dx: 1.5, dy: 2), with: .color(tinted(0.72, 0.76, 0.80, 0.45, 0.22)),
                               lineWidth: 2.2)
                    canvas.stroke(boulder,
                                  with: .color(tinted(0.02, 0.03, 0.04, 0.5, 0.6)),
                                  lineWidth: 1.2)
                    bx += bw * (0.80 + Double((h >> 20) & 0xF) / 0xF * 0.3)
                    i += 1
                }
            }
        default:
            break
        }
    }
}
