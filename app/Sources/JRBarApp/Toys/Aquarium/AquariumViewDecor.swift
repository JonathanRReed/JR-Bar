import AppKit
import JRBarCore
import SwiftUI

/// The seeded decor every tank starts with.
extension AquariumView {
    // MARK: Decor

    /// The seeded layout, built once — the tank never rearranges.
    static let decor = AquariumModel.decorSet()

    /// The bed is ~12% of the tank now; the dressing grows with it —
    /// roughly twice the original footprint.
    static let decorBoost = 2.0

    /// The seeded dressing (docs/TOYS.md): kelp, rocks, corals, sea
    /// grass, shells, a starfish, a bottle & a treasure chest, laid
    /// out by `AquariumModel.decorSet` so the tank looks the same
    /// every launch. `density` decides how much of the set shows —
    /// the signature pieces come first, so a sparse tank keeps them.
    /// `keepClear` (the empty-tank caption's capsule) culls any piece
    /// rooted inside it — nothing sits under the plaque.
    private func decorVisible(_ piece: TankDecor, shown: Int,
                              clearZone: CGRect?, in size: CGSize) -> Bool {
        guard piece.id < shown else { return false }
        if let clearZone,
           clearZone.contains(CGPoint(x: decorX(piece) * size.width,
                                      y: decorBaseY(piece, in: size))) {
            return false
        }
        return true
    }

    /// The still dressing → the near still pass: every piece that
    /// doesn't move and stands behind the fish (a piece past depth 0.6
    /// stands at the glass and draws live, over them). Kelp & grass
    /// sway and draw on their own plant pass, behind these.
    func drawStaticDecor(canvas: inout GraphicsContext, size: CGSize, t: Double,
                         density: Double, keepClear: CGRect? = nil) {
        let shown = Int((Double(Self.decor.count) * min(1, density)).rounded(.up))
        // The capsule sits on the sand face below the dune line; the
        // zone reaches up over the dune face behind it so nothing is
        // rooted inside the plaque's footprint either.
        let clearZone = keepClear?.insetBy(dx: -10, dy: -34)
        for piece in Self.decor where piece.depth <= 0.6 {
            guard decorVisible(piece, shown: shown,
                               clearZone: clearZone, in: size) else { continue }
            drawStill(piece, canvas: &canvas, size: size, atmosphere: atmosphere(depth: nearDepth(piece), t: t))
        }
    }

    /// How far into the water a seeded still piece stands. Every one
    /// roots on the near crest, so its seeded depth only nudges it —
    /// they read as near things, crisp against the far bed.
    private func nearDepth(_ piece: TankDecor) -> Double {
        0.55 + piece.depth * 0.4
    }

    /// One still piece, seated in the water.
    private func drawStill(_ piece: TankDecor, canvas: inout GraphicsContext, size: CGSize,
                           atmosphere: TankPaint.Atmosphere?) {
        switch piece.kind {
        case .rock: drawRocks(canvas: &canvas, size: size, piece: piece, atmosphere: atmosphere)
        case .coral: drawCoral(canvas: &canvas, size: size, piece: piece, atmosphere: atmosphere)
        case .shell: drawShell(canvas: &canvas, size: size, piece: piece, atmosphere: atmosphere)
        case .bottle: drawBottle(canvas: &canvas, size: size, piece: piece, atmosphere: atmosphere)
        case .starfish: drawStarfish(canvas: &canvas, size: size, piece: piece, atmosphere: atmosphere)
        case .chest: drawChest(canvas: &canvas, size: size, piece: piece, atmosphere: atmosphere)
        case .kelp, .grass: break // they sway — the plant pass draws them
        }
    }

    /// Paints `draw` seated in the water when there is an atmosphere to
    /// seat it in (the baked passes), or straight onto the canvas on
    /// the live pass, where a layer per piece per frame would cost more
    /// than the glass-side veil is worth.
    private func seated(_ canvas: inout GraphicsContext, _ atmosphere: TankPaint.Atmosphere?,
                        rect: CGRect, seed: UInt64, draw: (inout GraphicsContext) -> Void) {
        if let atmosphere {
            TankPaint.seat(&canvas, in: rect, atmosphere: atmosphere, seed: seed, draw: draw)
        } else {
            draw(&canvas)
        }
    }

    /// The swaying dressing: kelp and grass, on the plant pass behind
    /// the near still pieces (`front` false) or at the glass over the
    /// fish (`front` true, past depth 0.6).
    func drawPlants(canvas: inout GraphicsContext, size: CGSize, t: Double,
                    density: Double, front: Bool, keepClear: CGRect? = nil) {
        let shown = Int((Double(Self.decor.count) * min(1, density)).rounded(.up))
        let clearZone = keepClear?.insetBy(dx: -10, dy: -34)
        let tone = decorTone()
        // The kelp forest theme thickens the stand — three extra
        // seeded strands behind the lane on top of the usual set.
        if themeKey == "kelp" && !front {
            for i in 0..<3 {
                var h = AquariumModel.stableHash("kelpx-\(i)")
                h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
                let extra = TankDecor(
                    id: 900 + i, kind: .kelp,
                    x: 0.10 + 0.80 * Double(h & 0xFFFF) / 0xFFFF,
                    depth: 0.30 + Double((h >> 16) & 0xFF) / 0xFF * 0.25,
                    scale: 0.85 + Double((h >> 24) & 0xFF) / 0xFF * 0.45,
                    bits: h)
                drawKelp(canvas: &canvas, size: size, t: t, piece: extra, tone: tone)
            }
        }
        for piece in Self.decor where (piece.depth > 0.6) == front {
            guard decorVisible(piece, shown: shown,
                               clearZone: clearZone, in: size) else { continue }
            switch piece.kind {
            case .kelp: drawKelp(canvas: &canvas, size: size, t: t, piece: piece, tone: tone)
            case .grass: drawGrass(canvas: &canvas, size: size, t: t, piece: piece, tone: tone)
            default: break
            }
        }
    }

    /// The moving dressing's odd jobs on the live pass: the chest's
    /// occasional burp bubble, and — at the glass, over the fish — the
    /// few still pieces seeded past depth 0.6.
    func drawLiveDecor(canvas: inout GraphicsContext, size: CGSize, t: Double,
                       density: Double, front: Bool, keepClear: CGRect? = nil) {
        let shown = Int((Double(Self.decor.count) * min(1, density)).rounded(.up))
        let clearZone = keepClear?.insetBy(dx: -10, dy: -34)
        for piece in Self.decor where (piece.depth > 0.6) == front {
            guard decorVisible(piece, shown: shown,
                               clearZone: clearZone, in: size) else { continue }
            switch piece.kind {
            case .kelp, .grass: break
            case .chest where !front:
                drawChestBurp(canvas: &canvas, size: size, t: t, piece: piece)
            case .chest:
                drawChest(canvas: &canvas, size: size, piece: piece, atmosphere: nil)
                drawChestBurp(canvas: &canvas, size: size, t: t, piece: piece)
            default:
                if front { drawStill(piece, canvas: &canvas, size: size, atmosphere: nil) }
            }
        }
    }

    /// Where a piece stands: on the dune line under it, with a couple
    /// of pixels of sink so nothing floats over the sand.
    func decorBaseY(_ piece: TankDecor, in size: CGSize) -> Double {
        sandTop(atX: decorX(piece) * size.width, in: size) + 2
    }

    /// Where a piece stands across the tank, 0…1. The seeded spot for
    /// everything but the glass-side kelp, which the view moves out to
    /// the tank's two ends: foreground fronds frame the water instead
    /// of standing in the middle of it.
    func decorX(_ piece: TankDecor) -> Double {
        guard piece.kind == .kelp, piece.depth > 0.6 else { return piece.x }
        let side = (piece.bits >> 7) & 1 == 0
        let inset = 0.015 + Double((piece.bits >> 20) & 0xFF) / 0xFF * 0.07
        return side ? inset : 1 - inset
    }

    /// Per-item hash scramble: folds an index into a piece's bits so
    /// every frond/blade/branch of one piece varies independently.
    func scatter(_ bits: UInt64, _ k: Int) -> UInt64 {
        var h = bits &+ UInt64(k) &* 0x9E3779B97F4A7C15
        h ^= h >> 29
        h &*= 0xBF58476D1CE4E5B9
        h ^= h >> 32
        return h
    }

    /// A point along a cubic Bézier and the unit normal there.
    private func bezier(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint,
                        _ u: Double) -> (point: CGPoint, normal: CGVector) {
        let v = 1 - u
        let px = v * v * v * p0.x + 3 * v * v * u * c1.x + 3 * v * u * u * c2.x + u * u * u * p1.x
        let py = v * v * v * p0.y + 3 * v * v * u * c1.y + 3 * v * u * u * c2.y + u * u * u * p1.y
        let dx = 3 * v * v * (c1.x - p0.x) + 6 * v * u * (c2.x - c1.x) + 3 * u * u * (p1.x - c2.x)
        let dy = 3 * v * v * (c1.y - p0.y) + 6 * v * u * (c2.y - c1.y) + 3 * u * u * (p1.y - c2.y)
        let len = max(0.001, (dx * dx + dy * dy).squareRoot())
        return (CGPoint(x: px, y: py), CGVector(dx: -dy / len, dy: dx / len))
    }

    /// One leaf: a pointed blade from `base` along `angle`, fullest a
    /// third of the way out, its tip curling a little with `curl`.
    func leaf(from base: CGPoint, angle: Double, length: Double, width: Double,
                      curl: Double) -> Path {
        let dx = cos(angle), dy = sin(angle)
        let nx = -dy, ny = dx
        let tip = CGPoint(x: base.x + dx * length + nx * curl, y: base.y + dy * length + ny * curl)
        var p = Path()
        p.move(to: base)
        p.addCurve(to: tip,
                   control1: CGPoint(x: base.x + dx * length * 0.30 + nx * width,
                                     y: base.y + dy * length * 0.30 + ny * width),
                   control2: CGPoint(x: base.x + dx * length * 0.75 + nx * width * 0.6 + nx * curl,
                                     y: base.y + dy * length * 0.75 + ny * width * 0.6 + ny * curl))
        p.addCurve(to: base,
                   control1: CGPoint(x: base.x + dx * length * 0.75 - nx * width * 0.5 + nx * curl,
                                     y: base.y + dy * length * 0.75 - ny * width * 0.5 + ny * curl),
                   control2: CGPoint(x: base.x + dx * length * 0.30 - nx * width * 0.8,
                                     y: base.y + dy * length * 0.30 - ny * width * 0.8))
        p.closeSubpath()
        return p
    }

    /// One kelp stand: two or three slender stipes rising in a slow S,
    /// each carrying alternate blades that flutter a beat behind the
    /// stem and a gold float at every blade's foot — giant kelp, not a
    /// wall of leaves, so the water and the fish show between the
    /// blades. Olive at the holdfast, gold where the light comes through
    /// the tips, veiled by depth; a stand at the glass is a short dark
    /// frond framing a corner. A whole stand goes down in four calls —
    /// stipes, blades, ribs, floats. Reduce Motion freezes the sway.
    private func drawKelp(canvas: inout GraphicsContext, size: CGSize, t: Double, piece: TankDecor,
                          tone: TankPaint.Tone = .none) {
        let b = piece.bits
        let baseX = decorX(piece) * size.width
        let baseY = decorBaseY(piece, in: size)
        let front = piece.depth > 0.6
        let fronds = 2 + Int(scatter(b, 90) % 2)
        // Behind the fish the water veils a stand (night included); at
        // the glass only the night's tone reaches it.
        let veil = atmosphere(depth: piece.depth, t: t)
        let haze = min(0.36, veil.haze)
        let dim = 1 - veil.night * 0.55
        func kelp(_ rgb: TankPaint.RGB, _ alpha: Double = 1) -> Color {
            front ? tone(TankPaint.color(rgb, alpha))
                : TankPaint.color(TankPaint.mix(rgb * dim, veil.hazeColor, haze), alpha)
        }
        let stem = front ? kelp(.init(0.10, 0.16, 0.06)) : kelp(.init(0.24, 0.26, 0.09))
        let root = front ? kelp(.init(0.07, 0.13, 0.06)) : kelp(.init(0.26, 0.32, 0.10))
        let mid = front ? kelp(.init(0.14, 0.24, 0.09)) : kelp(.init(0.40, 0.50, 0.17))
        let tip = front ? kelp(.init(0.24, 0.34, 0.12)) : kelp(.init(0.72, 0.70, 0.32))
        let rib = front ? kelp(.init(0.30, 0.40, 0.16), 0.5) : kelp(.init(0.92, 0.86, 0.48), 0.55)
        let float = front ? kelp(.init(0.24, 0.30, 0.10)) : kelp(.init(0.66, 0.60, 0.26))
        let unit = size.height / 700
        let still = reduceMotion
        var stipes = Path()
        var blades = Path()
        var floats = Path()
        var ribs = Path()
        var top = baseY
        for k in 0..<fronds {
            let fb = scatter(b, k)
            let phase = Double(fb & 0xFF) / 0xFF * .pi * 2
            // The tallest stipes reach ~40% of the tank; a glass-side
            // frond stays low, a frame, not a curtain.
            let reach = 0.20 + Double((fb >> 8) & 0xFF) / 0xFF * 0.18
            let hgt = size.height * (front ? min(0.24, reach * 0.62) : min(0.40, reach * (0.75 + piece.scale * 0.22)))
            let spread = (Double(k) - Double(fronds - 1) / 2) * 12 * unit * piece.scale
            let lean = (Double((fb >> 16) & 0xFF) / 0xFF - 0.5) * 40 * unit + spread
            let sway = still ? 0
                : sin(t * (0.22 + Double((fb >> 24) & 0xFF) / 0xFF * 0.18) + phase) * (6 + hgt * 0.05)
            let p0 = CGPoint(x: baseX + spread * 0.4, y: baseY)
            let p1 = CGPoint(x: baseX + lean + sway, y: baseY - hgt)
            let drift = lean + sway
            let sAmp = hgt * (0.10 + (still ? 0 : 0.03 * sin(t * 0.4 + phase)))
            let c1 = CGPoint(x: p0.x + drift * 0.30 - sAmp * 0.6, y: baseY - hgt * 0.34)
            let c2 = CGPoint(x: p0.x + drift * 0.70 + sAmp * 0.6, y: baseY - hgt * 0.70)
            stipes.move(to: p0)
            stipes.addCurve(to: p1, control1: c1, control2: c2)
            // Blades, alternating sides up the stipe, all leaning a
            // little downstream with the current; the crown blade
            // carries on from the tip.
            let count = front ? 5 : 7 + Int((fb >> 36) % 2)
            let bladeLength = hgt * (front ? 0.38 : 0.30)
            let current = 0.22 + (still ? 0 : 0.08 * sin(t * 0.3 + phase))
            for i in 0..<count {
                let u = 0.12 + 0.88 * Double(i) / Double(count - 1)
                let at = bezier(p0, c1, c2, p1, u)
                let side = i.isMultiple(of: 2) ? 1.0 : -1.0
                let flutter = still ? 0 : sin(t * 1.1 + Double(i) * 0.9 + phase) * 0.10
                let stemAngle = atan2(-at.normal.dx, at.normal.dy)
                let bh = scatter(fb, i &+ 50)
                let jitter = (Double(bh & 0xFF) / 0xFF - 0.5) * 0.3
                let angle = i == count - 1
                    ? stemAngle + flutter + current * 0.5
                    : stemAngle + side * (0.42 + 0.14 * (1 - u)) + current + flutter + jitter
                let length = bladeLength * (i == count - 1 ? 1.0 : 0.70 + 0.40 * sin(u * .pi))
                    * (0.75 + Double((bh >> 8) & 0xFF) / 0xFF * 0.45)
                let width = length * 0.21
                let blade = leaf(from: at.point, angle: angle, length: length, width: width,
                                 curl: length * 0.12)
                blades.addPath(blade)
                guard !front else { continue }
                ribs.move(to: at.point)
                ribs.addQuadCurve(to: CGPoint(x: at.point.x + cos(angle) * length * 0.82 - sin(angle) * length * 0.08,
                                              y: at.point.y + sin(angle) * length * 0.82 + cos(angle) * length * 0.08),
                                  control: CGPoint(x: at.point.x + cos(angle) * length * 0.4,
                                                   y: at.point.y + sin(angle) * length * 0.4))
                let r = max(1.2, length * 0.038)
                floats.addEllipse(in: CGRect(x: at.point.x + cos(angle) * r * 0.9 - r,
                                             y: at.point.y + sin(angle) * r * 0.9 - r,
                                             width: r * 2, height: r * 2))
            }
            top = min(top, p1.y - bladeLength)
        }
        canvas.stroke(stipes, with: .color(stem),
                      style: StrokeStyle(lineWidth: max(1.2, 2.4 * unit), lineCap: .round))
        canvas.fill(blades, with: .linearGradient(
            Gradient(stops: [
                .init(color: root, location: 0),
                .init(color: mid, location: 0.45),
                .init(color: tip, location: 1),
            ]),
            startPoint: CGPoint(x: baseX, y: baseY), endPoint: CGPoint(x: baseX, y: top)))
        canvas.stroke(ribs, with: .color(rib), lineWidth: max(0.6, 0.9 * unit))
        canvas.fill(floats, with: .color(float))
    }

    /// A tuft of sea grass: thin tapered blades fanning from one root,
    /// dark at the foot and lit toward the tips, each swaying on its
    /// own quick clock. One fill for the whole tuft.
    private func drawGrass(canvas: inout GraphicsContext, size: CGSize, t: Double, piece: TankDecor,
                           tone: TankPaint.Tone) {
        let b = piece.bits
        let baseX = decorX(piece) * size.width
        let baseY = decorBaseY(piece, in: size) + 1
        let blades = 7 + Int((b >> 36) % 4)
        let front = piece.depth > 0.6
        let veil = atmosphere(depth: piece.depth, t: t)
        let haze = min(0.5, veil.haze)
        let dim = 1 - veil.night * 0.55
        func green(_ rgb: TankPaint.RGB) -> Color {
            front ? tone(TankPaint.color(rgb))
                : TankPaint.color(TankPaint.mix(rgb * dim, veil.hazeColor, haze))
        }
        let scale = piece.scale * max(0.7, min(1.5, size.height / 240)) * 1.1
        let still = reduceMotion
        var tuft = Path()
        var top = baseY
        for k in 0..<blades {
            let fb = scatter(b, k &+ 11)
            let spread = (Double((fb >> 40) & 0xFF) / 0xFF - 0.5) * 18 * scale
            let hgt = (12 + Double((fb >> 8) & 0xFF) / 0xFF * 26) * scale
            let phase = Double(fb & 0xFF) / 0xFF * .pi * 2
            let sway = still ? 0
                : sin(t * (0.5 + Double((fb >> 24) & 0xFF) / 0xFF * 0.4) + phase) * 3.5
            let rootX = baseX + spread * 0.25
            let tipX = baseX + spread + (Double((fb >> 16) & 0xFF) / 0xFF - 0.5) * 12 + sway
            let w = 1.5 * scale
            top = min(top, baseY - hgt)
            tuft.move(to: CGPoint(x: rootX - w, y: baseY))
            tuft.addQuadCurve(to: CGPoint(x: tipX, y: baseY - hgt),
                              control: CGPoint(x: rootX - w * 0.4, y: baseY - hgt * 0.55))
            tuft.addQuadCurve(to: CGPoint(x: rootX + w, y: baseY),
                              control: CGPoint(x: rootX + w * 0.8, y: baseY - hgt * 0.5))
            tuft.closeSubpath()
        }
        canvas.fill(tuft, with: .linearGradient(
            Gradient(colors: [green(.init(0.07, 0.22, 0.14)), green(.init(0.24, 0.46, 0.26)),
                              green(.init(0.54, 0.70, 0.40))]),
            startPoint: CGPoint(x: baseX, y: baseY), endPoint: CGPoint(x: baseX, y: top)))
    }

    /// A rounded stone outline: a jittered ring of points smoothed into
    /// one pebble-like curve, its underside flattened where it sits.
    func stonePath(center c: CGPoint, width w: Double, height h: Double, seed: UInt64) -> Path {
        var rng = TankPaint.Seeded(seed)
        let n = 9
        var pts: [CGPoint] = []
        for i in 0..<n {
            let a = Double(i) / Double(n) * .pi * 2 + rng.next(-0.12, 0.12)
            let r = rng.next(0.86, 1.08)
            let y = sin(a) > 0 ? sin(a) * 0.55 : sin(a)
            pts.append(CGPoint(x: c.x + cos(a) * w / 2 * r, y: c.y + y * h / 2 * r))
        }
        var p = Path()
        p.move(to: CGPoint(x: (pts[n - 1].x + pts[0].x) / 2, y: (pts[n - 1].y + pts[0].y) / 2))
        for i in 0..<n {
            let a = pts[i], next = pts[(i + 1) % n]
            p.addQuadCurve(to: CGPoint(x: (a.x + next.x) / 2, y: (a.y + next.y) / 2), control: a)
        }
        p.closeSubpath()
        return p
    }

    /// A boulder lit from the surface: light on the brow, the body
    /// turning into shade, a warm bounce off the sand along its belly,
    /// grain, and weed where it meets the bed. No outline — the light
    /// draws its edge.
    func paintStone(_ c: inout GraphicsContext, _ stone: Path, lit: TankPaint.RGB, base: TankPaint.RGB,
                    shade: TankPaint.RGB, bounce: TankPaint.RGB, seed: UInt64, moss: Double = 0.8) {
        let r = stone.boundingRect
        c.fill(stone, with: .radialGradient(
            Gradient(stops: [
                .init(color: TankPaint.color(lit), location: 0),
                .init(color: TankPaint.color(base), location: 0.45),
                .init(color: TankPaint.color(shade), location: 1),
            ]),
            center: CGPoint(x: r.minX + r.width * 0.34, y: r.minY + r.height * 0.18),
            startRadius: 0, endRadius: max(r.width, r.height) * 0.95))
        var inner = c
        inner.clip(to: stone)
        inner.stroke(stone.offsetBy(dx: 0, dy: -2), with: .color(TankPaint.color(bounce, 0.22)), lineWidth: 2.5)
        inner.stroke(stone.offsetBy(dx: 1, dy: 1.6), with: .color(.white.opacity(0.16)), lineWidth: 1.4)
        TankPaint.speckle(&c, stone, seed: seed, count: Int(max(8, r.width * 0.8)),
                          size: max(0.7, r.width * 0.035),
                          dark: TankPaint.color(shade, 0.35), light: .white.opacity(0.10))
        if moss > 0 {
            TankPaint.moss(&c, clip: stone, from: r.minX, to: r.maxX, y: r.maxY,
                           height: r.height * 0.20, seed: seed >> 3, fade: moss)
        }
    }

    /// A couple of boulders leaning together on the dune line, the
    /// later ones riding up on the first, pooling one shadow under the
    /// cluster.
    private func drawRocks(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor,
                           atmosphere: TankPaint.Atmosphere?) {
        let b = piece.bits
        let baseX = decorX(piece) * size.width
        let baseY = decorBaseY(piece, in: size)
        let scale = piece.scale * Self.decorBoost
        let count = 2 + Int(scatter(b, 7) & 1)
        contactShadow(canvas: &canvas, x: baseX, y: baseY, halfW: 30 * scale)
        var stones: [(Path, UInt64)] = []
        for r in 0..<count {
            let rb = scatter(b, r &+ 3)
            let rw = (16 + Double(rb & 0xFF) / 0xFF * 12) * scale
            let rh = rw * (0.62 + Double((rb >> 8) & 0xFF) / 0xFF * 0.26)
            let rx = baseX + (Double(r) - Double(count - 1) / 2) * rw * 0.62
                + (Double((rb >> 16) & 0xF) - 7.5)
            let ry = baseY - rh * 0.40 - (r > 0 ? rh * 0.12 * Double(r) : 0)
            stones.append((stonePath(center: CGPoint(x: rx, y: ry), width: rw, height: rh, seed: rb), rb))
        }
        let bounds = stones.reduce(CGRect.null) { $0.union($1.0.boundingRect) }
        let sand = sandPalette
        seated(&canvas, atmosphere, rect: bounds, seed: b) { c in
            for (stone, seed) in stones {
                paintStone(&c, stone, lit: .init(0.76, 0.72, 0.64), base: .init(0.46, 0.43, 0.40),
                           shade: .init(0.15, 0.15, 0.17), bounce: sand.lit, seed: seed)
            }
        }
    }

    /// One of two corals by seed: a branching fan or a rounded brain.
    private func drawCoral(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor,
                           atmosphere: TankPaint.Atmosphere?) {
        if (piece.bits >> 40) & 1 == 0 {
            drawFanCoral(canvas: &canvas, size: size, piece: piece, atmosphere: atmosphere)
        } else {
            drawBrainCoral(canvas: &canvas, size: size, piece: piece, atmosphere: atmosphere)
        }
    }

    /// A branching coral: a trunk that forks three times, each branch
    /// tapering, shaded along its lower side and lit along its upper,
    /// with pale polyp tips.
    private func drawFanCoral(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor,
                              atmosphere: TankPaint.Atmosphere?) {
        let b = piece.bits
        let baseX = decorX(piece) * size.width
        let baseY = decorBaseY(piece, in: size)
        let hgt = min((30 + Double(b & 0xFF) / 0xFF * 26) * piece.scale
                      * max(0.7, min(1.5, size.height / 240)) * Self.decorBoost,
                      size.height * 0.24)
        let rose = (b >> 48) & 1 == 0
        let bright: TankPaint.RGB = rose ? .init(0.94, 0.48, 0.50) : .init(0.96, 0.62, 0.34)
        let deep: TankPaint.RGB = rose ? .init(0.52, 0.16, 0.24) : .init(0.56, 0.26, 0.10)
        let pale: TankPaint.RGB = rose ? .init(1.0, 0.86, 0.84) : .init(1.0, 0.90, 0.72)
        contactShadow(canvas: &canvas, x: baseX, y: baseY, halfW: 14 * piece.scale * Self.decorBoost)
        var segments: [(Path, Double)] = []
        var tips: [CGPoint] = []
        func grow(_ from: CGPoint, _ angle: Double, _ len: Double, _ forks: Int, _ w: Double) {
            let to = CGPoint(x: from.x + cos(angle) * len, y: from.y + sin(angle) * len)
            let bend = (Double((b >> UInt64(forks * 9 + 2)) & 0xFF) / 0xFF - 0.5) * 10
            var seg = Path()
            seg.move(to: from)
            seg.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2 + bend, y: (from.y + to.y) / 2))
            segments.append((seg, w))
            guard forks > 0 else {
                tips.append(to)
                return
            }
            let spread = 0.45 + Double((b >> UInt64(forks * 7 + 12)) & 0xFF) / 0xFF * 0.4
            grow(to, angle - spread, len * 0.68, forks - 1, w * 0.72)
            grow(to, angle + spread * 0.8, len * 0.68, forks - 1, w * 0.72)
        }
        grow(CGPoint(x: baseX, y: baseY),
             -.pi / 2 + (Double((b >> 8) & 0xFF) / 0xFF - 0.5) * 0.4,
             hgt * 0.42, 3, 3.2 * piece.scale * Self.decorBoost * 1.15)
        let bounds = CGRect(x: baseX - hgt * 0.8, y: baseY - hgt * 1.1, width: hgt * 1.6, height: hgt * 1.1 + 4)
        seated(&canvas, atmosphere, rect: bounds, seed: b) { c in
            for (seg, w) in segments {
                c.stroke(seg.offsetBy(dx: w * 0.18, dy: w * 0.12), with: .color(TankPaint.color(deep)),
                         style: StrokeStyle(lineWidth: w, lineCap: .round))
            }
            for (seg, w) in segments {
                c.stroke(seg, with: .linearGradient(
                    Gradient(colors: [TankPaint.color(TankPaint.mix(deep, bright, 0.6)), TankPaint.color(bright)]),
                    startPoint: CGPoint(x: baseX, y: baseY), endPoint: CGPoint(x: baseX, y: baseY - hgt)),
                         style: StrokeStyle(lineWidth: w * 0.86, lineCap: .round))
            }
            for (seg, w) in segments {
                c.stroke(seg.offsetBy(dx: -w * 0.2, dy: -w * 0.1), with: .color(TankPaint.color(pale, 0.45)),
                         style: StrokeStyle(lineWidth: max(0.6, w * 0.26), lineCap: .round))
            }
            var beads = Path()
            for tip in tips {
                beads.addEllipse(in: CGRect(x: tip.x - 2.2, y: tip.y - 2.2, width: 4.4, height: 4.4))
            }
            c.fill(beads, with: .color(TankPaint.color(pale)))
        }
    }

    /// The brain coral: a squat dome lit on its crown, meandering
    /// ridges with a lit lip on each, a scatter of pores.
    private func drawBrainCoral(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor,
                                atmosphere: TankPaint.Atmosphere?) {
        let b = piece.bits
        let baseX = decorX(piece) * size.width
        let baseY = decorBaseY(piece, in: size)
        let r = (13 + Double(b & 0xFF) / 0xFF * 9) * piece.scale * Self.decorBoost
        contactShadow(canvas: &canvas, x: baseX, y: baseY, halfW: r * 1.05)
        var dome = Path()
        dome.move(to: CGPoint(x: baseX - r, y: baseY))
        dome.addCurve(to: CGPoint(x: baseX + r, y: baseY),
                      control1: CGPoint(x: baseX - r * 1.02, y: baseY - r * 1.15),
                      control2: CGPoint(x: baseX + r * 1.02, y: baseY - r * 1.15))
        dome.closeSubpath()
        let purple = (b >> 48) & 1 == 0
        let lit: TankPaint.RGB = purple ? .init(0.78, 0.62, 0.80) : .init(0.92, 0.76, 0.50)
        let base: TankPaint.RGB = purple ? .init(0.54, 0.38, 0.58) : .init(0.70, 0.52, 0.30)
        let dark: TankPaint.RGB = purple ? .init(0.26, 0.15, 0.32) : .init(0.34, 0.22, 0.12)
        seated(&canvas, atmosphere, rect: dome.boundingRect, seed: b) { c in
            c.fill(dome, with: .radialGradient(
                Gradient(stops: [
                    .init(color: TankPaint.color(lit), location: 0),
                    .init(color: TankPaint.color(base), location: 0.5),
                    .init(color: TankPaint.color(dark), location: 1),
                ]),
                center: CGPoint(x: baseX - r * 0.25, y: baseY - r * 0.75),
                startRadius: 0, endRadius: r * 1.45))
            var ridges = c
            ridges.clip(to: dome)
            var maze = Path()
            for k in 0..<7 {
                let gy = baseY - r * 0.98 + Double(k) * r * 0.165
                var gx = baseX - r
                maze.move(to: CGPoint(x: gx, y: gy))
                var flip = k.isMultiple(of: 2)
                while gx < baseX + r {
                    let step = r * 0.2
                    maze.addQuadCurve(to: CGPoint(x: gx + step, y: gy + (flip ? r * 0.05 : -r * 0.05)),
                                      control: CGPoint(x: gx + step * 0.5, y: gy + (flip ? -r * 0.09 : r * 0.09)))
                    gx += step
                    flip.toggle()
                }
            }
            ridges.stroke(maze, with: .color(TankPaint.color(dark, 0.55)),
                          style: StrokeStyle(lineWidth: max(0.8, r * 0.07), lineCap: .round))
            ridges.stroke(maze.offsetBy(dx: 0, dy: -max(0.6, r * 0.045)), with: .color(TankPaint.color(lit, 0.45)),
                          style: StrokeStyle(lineWidth: max(0.5, r * 0.03), lineCap: .round))
        }
    }

    /// A shell on the sand — a ribbed scallop or a spiral whelk, by
    /// seed — half settled into the bed.
    private func drawShell(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor,
                           atmosphere: TankPaint.Atmosphere?) {
        let b = piece.bits
        let baseX = decorX(piece) * size.width
        let baseY = decorBaseY(piece, in: size) + 1
        let s = 6.5 * piece.scale * Self.decorBoost
        contactShadow(canvas: &canvas, x: baseX, y: baseY, halfW: s * 0.9, alpha: 0.30)
        let rect = CGRect(x: baseX - s, y: baseY - s, width: s * 2, height: s * 1.4)
        seated(&canvas, atmosphere, rect: rect, seed: b) { canvas in
            var c = canvas
            c.translateBy(x: baseX, y: baseY)
            c.rotate(by: .radians((Double(b & 0xFF) / 0xFF - 0.5) * 0.6))
            c.scaleBy(x: s, y: s)
            if (b >> 12) & 1 == 0 {
                // Scallop: a fan off the hinge, ribs out to the rim.
                var fan = Path()
                fan.move(to: CGPoint(x: 0, y: 0.16))
                fan.addCurve(to: CGPoint(x: -0.56, y: -0.22),
                             control1: CGPoint(x: -0.32, y: 0.10), control2: CGPoint(x: -0.55, y: 0.02))
                fan.addQuadCurve(to: CGPoint(x: 0.56, y: -0.22), control: CGPoint(x: 0, y: -0.78))
                fan.addCurve(to: CGPoint(x: 0, y: 0.16),
                             control1: CGPoint(x: 0.55, y: 0.02), control2: CGPoint(x: 0.32, y: 0.10))
                fan.closeSubpath()
                c.fill(fan, with: .radialGradient(
                    Gradient(colors: [Color(red: 1.0, green: 0.90, blue: 0.82),
                                      Color(red: 0.92, green: 0.66, blue: 0.56),
                                      Color(red: 0.62, green: 0.38, blue: 0.32)]),
                    center: CGPoint(x: -0.12, y: -0.40), startRadius: 0, endRadius: 0.8))
                var ribs = Path()
                for ribX in [-0.40, -0.24, -0.08, 0.08, 0.24, 0.40] as [Double] {
                    ribs.move(to: CGPoint(x: 0, y: 0.12))
                    ribs.addQuadCurve(to: CGPoint(x: ribX * 1.1, y: -0.46 + abs(ribX) * 0.55),
                                      control: CGPoint(x: ribX * 0.5, y: -0.12))
                }
                c.stroke(ribs, with: .color(Color(red: 0.52, green: 0.30, blue: 0.26).opacity(0.45)), lineWidth: 0.05)
                c.stroke(ribs.offsetBy(dx: -0.03, dy: 0), with: .color(.white.opacity(0.35)), lineWidth: 0.03)
            } else {
                // A spiral whelk.
                c.fill(Path(ellipseIn: CGRect(x: -0.44, y: -0.44, width: 0.88, height: 0.88)),
                       with: .radialGradient(
                           Gradient(colors: [Color(red: 0.98, green: 0.86, blue: 0.70),
                                             Color(red: 0.80, green: 0.60, blue: 0.42),
                                             Color(red: 0.46, green: 0.30, blue: 0.20)]),
                           center: CGPoint(x: -0.14, y: -0.18), startRadius: 0.02, endRadius: 0.6))
                var spiral = Path()
                var rr = 0.36
                var a = 0.0
                spiral.move(to: CGPoint(x: rr, y: 0))
                while a < .pi * 3.6 {
                    a += 0.22
                    rr *= 0.955
                    spiral.addLine(to: CGPoint(x: cos(a) * rr, y: sin(a) * rr))
                }
                c.stroke(spiral, with: .color(Color(red: 0.42, green: 0.26, blue: 0.16).opacity(0.55)), lineWidth: 0.05)
                c.stroke(spiral.offsetBy(dx: -0.025, dy: -0.025), with: .color(.white.opacity(0.35)), lineWidth: 0.025)
            }
        }
    }

    /// A bottle sunk to its shoulder: sea-green glass you can half see
    /// through, a rolled message inside, a long highlight down its
    /// flank, a cork, and a lip of sand piled over its low end.
    private func drawBottle(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor,
                            atmosphere: TankPaint.Atmosphere?) {
        let b = piece.bits
        let baseX = decorX(piece) * size.width
        let baseY = decorBaseY(piece, in: size) + 2
        let s = 13 * piece.scale * Self.decorBoost
        let tilt = -0.5 - Double(b & 0xFF) / 0xFF * 0.3
        contactShadow(canvas: &canvas, x: baseX, y: baseY - 1, halfW: s * 0.8, alpha: 0.30)
        let sand = sandPalette
        let rect = CGRect(x: baseX - s, y: baseY - s, width: s * 2, height: s * 1.2)
        seated(&canvas, atmosphere, rect: rect, seed: b) { canvas in
            var c = canvas
            c.translateBy(x: baseX, y: baseY - s * 0.1)
            c.rotate(by: .radians(tilt))
            c.scaleBy(x: s, y: s)
            var body = Path()
            body.addRoundedRect(in: CGRect(x: -0.55, y: -0.26, width: 0.78, height: 0.52),
                                cornerSize: CGSize(width: 0.20, height: 0.24))
            body.move(to: CGPoint(x: 0.20, y: -0.20))
            body.addQuadCurve(to: CGPoint(x: 0.50, y: -0.085), control: CGPoint(x: 0.36, y: -0.17))
            body.addLine(to: CGPoint(x: 0.62, y: -0.085))
            body.addLine(to: CGPoint(x: 0.62, y: 0.085))
            body.addLine(to: CGPoint(x: 0.50, y: 0.085))
            body.addQuadCurve(to: CGPoint(x: 0.20, y: 0.20), control: CGPoint(x: 0.36, y: 0.17))
            body.closeSubpath()
            c.fill(body, with: .linearGradient(
                Gradient(colors: [Color(red: 0.36, green: 0.64, blue: 0.50).opacity(0.72),
                                  Color(red: 0.10, green: 0.30, blue: 0.24).opacity(0.85)]),
                startPoint: CGPoint(x: 0, y: -0.3), endPoint: CGPoint(x: 0, y: 0.3)))
            var note = c
            note.clip(to: body)
            note.fill(Path(roundedRect: CGRect(x: -0.36, y: -0.08, width: 0.44, height: 0.16), cornerRadius: 0.06),
                      with: .color(Color(red: 0.95, green: 0.90, blue: 0.72).opacity(0.62)))
            note.stroke(Path(roundedRect: CGRect(x: -0.36, y: -0.08, width: 0.44, height: 0.16), cornerRadius: 0.06),
                        with: .color(Color(red: 0.55, green: 0.42, blue: 0.22).opacity(0.4)), lineWidth: 0.02)
            c.fill(Path(CGRect(x: 0.60, y: -0.075, width: 0.08, height: 0.15)),
                   with: .color(Color(red: 0.62, green: 0.46, blue: 0.28)))
            c.fill(Path(roundedRect: CGRect(x: -0.46, y: -0.21, width: 0.60, height: 0.06), cornerRadius: 0.03),
                   with: .color(.white.opacity(0.55)))
            c.fill(Path(roundedRect: CGRect(x: -0.40, y: 0.13, width: 0.40, height: 0.04), cornerRadius: 0.02),
                   with: .color(.white.opacity(0.14)))
            c.stroke(body, with: .color(Color(red: 0.70, green: 0.95, blue: 0.82).opacity(0.40)), lineWidth: 0.025)
            // A lip of sand over the low end buries it.
            canvas.fill(Path(ellipseIn: CGRect(x: baseX - s * 0.62, y: baseY - 3.5, width: s * 1.1, height: 6)),
                        with: .linearGradient(
                            Gradient(colors: [TankPaint.color(sand.lit), TankPaint.color(sand.body)]),
                            startPoint: CGPoint(x: 0, y: baseY - 3.5), endPoint: CGPoint(x: 0, y: baseY + 2.5)))
        }
    }

    /// A five-pointed star, unit-sized, for the starfish and every glint.
    static let starPath: Path = {
        var p = Path()
        for i in 0..<10 {
            let a = Double(i) * .pi / 5 - .pi / 2
            let r = i % 2 == 0 ? 0.5 : 0.22
            let pt = CGPoint(x: cos(a) * r, y: sin(a) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }()

    /// The starfish's softer outline: the same star with its points
    /// and valleys rounded.
    private static let starfishPath: Path = {
        var pts: [CGPoint] = []
        for i in 0..<10 {
            let a = Double(i) * .pi / 5 - .pi / 2
            let r = i % 2 == 0 ? 0.5 : 0.21
            pts.append(CGPoint(x: cos(a) * r, y: sin(a) * r))
        }
        var p = Path()
        p.move(to: CGPoint(x: (pts[9].x + pts[0].x) / 2, y: (pts[9].y + pts[0].y) / 2))
        for i in 0..<10 {
            let a = pts[i], next = pts[(i + 1) % 10]
            let mid = CGPoint(x: (a.x + next.x) / 2, y: (a.y + next.y) / 2)
            if i % 2 == 0 {
                // A rounded arm tip.
                p.addQuadCurve(to: mid, control: a)
            } else {
                p.addLine(to: a)
                p.addLine(to: mid)
            }
        }
        p.closeSubpath()
        return p
    }()

    /// A starfish resting on the sand: plump arms lit on top, a raised
    /// centre, a row of bumps down each arm.
    private func drawStarfish(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor,
                              atmosphere: TankPaint.Atmosphere?) {
        let x = decorX(piece) * size.width
        let y = decorBaseY(piece, in: size)
        let s = 16 * piece.scale * Self.decorBoost
        contactShadow(canvas: &canvas, x: x, y: y, halfW: s * 0.5, alpha: 0.30)
        let rect = CGRect(x: x - s * 0.6, y: y - s * 0.7, width: s * 1.2, height: s * 0.9)
        seated(&canvas, atmosphere, rect: rect, seed: piece.bits) { canvas in
            var c = canvas
            c.translateBy(x: x, y: y - s * 0.16)
            c.scaleBy(x: s, y: s * 0.62)
            c.rotate(by: .radians(Double(piece.bits & 0xFF) / 0xFF * .pi * 2))
            let star = Self.starfishPath
            c.fill(star, with: .radialGradient(
                Gradient(colors: [Color(red: 1.0, green: 0.76, blue: 0.52), Color(red: 0.92, green: 0.46, blue: 0.26),
                                  Color(red: 0.58, green: 0.20, blue: 0.10)]),
                center: CGPoint(x: -0.06, y: -0.08), startRadius: 0, endRadius: 0.55))
            TankPaint.speckle(&c, star, seed: piece.bits, count: 44, size: 0.05,
                              dark: Color(red: 0.50, green: 0.16, blue: 0.06).opacity(0.40),
                              light: Color(red: 1.0, green: 0.92, blue: 0.78).opacity(0.75))
            var bumps = Path()
            for i in 0..<5 {
                let a = Double(i) * .pi * 2 / 5 - .pi / 2
                for k in 1...2 {
                    let d = 0.12 + Double(k) * 0.11
                    bumps.addEllipse(in: CGRect(x: cos(a) * d - 0.03, y: sin(a) * d - 0.03,
                                                width: 0.06, height: 0.06))
                }
            }
            c.fill(bumps, with: .color(Color(red: 1.0, green: 0.88, blue: 0.70).opacity(0.8)))
            c.fill(Path(ellipseIn: CGRect(x: -0.1, y: -0.1, width: 0.2, height: 0.2)),
                   with: .radialGradient(Gradient(colors: [Color(red: 1.0, green: 0.84, blue: 0.62),
                                                           Color(red: 0.86, green: 0.44, blue: 0.24)]),
                                         center: CGPoint(x: -0.03, y: -0.03), startRadius: 0, endRadius: 0.12))
        }
    }

    /// The treasure chest on the dune floor, half sunk: its moving part
    /// (the burp bubble) is `drawChestBurp` on the live pass.
    private func drawChest(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor,
                           atmosphere: TankPaint.Atmosphere?) {
        let w = 40 * piece.scale * Self.decorBoost
        let h = 26 * piece.scale * Self.decorBoost
        let x = decorX(piece) * size.width
        let y = decorBaseY(piece, in: size) + 2
        contactShadow(canvas: &canvas, x: x, y: y - 1, halfW: w * 0.56, alpha: 0.40)
        let sand = sandPalette
        seated(&canvas, atmosphere, rect: CGRect(x: x - w * 0.6, y: y - h, width: w * 1.2, height: h + 4),
               seed: piece.bits) { canvas in
            var c = canvas
            c.translateBy(x: x, y: y)
            Self.paintChest(&c, width: w, height: h, open: 0, t: 0, reduceMotion: true)
            // Half sunk: a lip of sand over its foot.
            c.fill(Path(ellipseIn: CGRect(x: -w * 0.62, y: -3.5, width: w * 1.24, height: 7)),
                   with: .linearGradient(
                       Gradient(colors: [TankPaint.color(sand.lit), TankPaint.color(sand.body)]),
                       startPoint: CGPoint(x: 0, y: -3.5), endPoint: CGPoint(x: 0, y: 3.5)))
        }
    }

    /// Every few seconds the chest burps a single bubble, the tank's
    /// smallest joke — the only moving part, so it draws in the live
    /// pass. Reduce Motion holds it in.
    private func drawChestBurp(canvas: inout GraphicsContext, size: CGSize,
                               t: Double, piece: TankDecor) {
        guard !reduceMotion else { return }
        let h = 26 * piece.scale * Self.decorBoost
        let x = decorX(piece) * size.width
        let y = decorBaseY(piece, in: size) + 2
        let period = 6 + Double(piece.bits & 0xFF) / 0xFF * 5
        let rise = frac(t / period + Double((piece.bits >> 8) & 0xFF) / 0xFF)
        guard rise < 0.6 else { return }
        let br = 2.0 + rise * 2.5
        let by = y - h - rise * size.height * 0.35
        drawBubble(canvas: &canvas, at: CGPoint(x: x + sin(rise * 9) * 2, y: by), radius: br,
                   alpha: 1 - rise / 0.6)
    }
}
