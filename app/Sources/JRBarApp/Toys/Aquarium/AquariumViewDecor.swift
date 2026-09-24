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
           clearZone.contains(CGPoint(x: piece.x * size.width,
                                      y: decorBaseY(piece, in: size))) {
            return false
        }
        return true
    }

    /// The still dressing → the cached bed pass: every piece that
    /// doesn't move, back layer only (deep pieces sit under the fish;
    /// near pieces stay live so nothing ends up behind a fish it
    /// should shade). Kelp & grass sway and stay out of the cache —
    /// the live pass draws them.
    func drawStaticDecor(canvas: inout GraphicsContext, size: CGSize,
                                 density: Double, keepClear: CGRect? = nil) {
        let shown = Int((Double(Self.decor.count) * min(1, density)).rounded(.up))
        // The capsule sits on the sand face below the dune line; the
        // zone reaches up over the dune face behind it so nothing is
        // rooted inside the plaque's footprint either.
        let clearZone = keepClear?.insetBy(dx: -10, dy: -34)
        for piece in Self.decor where piece.depth <= 0.6 {
            guard decorVisible(piece, shown: shown,
                               clearZone: clearZone, in: size) else { continue }
            switch piece.kind {
            case .rock: drawRocks(canvas: &canvas, size: size, piece: piece)
            case .coral: drawCoral(canvas: &canvas, size: size, piece: piece)
            case .shell: drawShell(canvas: &canvas, size: size, piece: piece)
            case .bottle: drawBottle(canvas: &canvas, size: size, piece: piece)
            case .starfish: drawStarfish(canvas: &canvas, size: size, piece: piece)
            case .chest: drawChest(canvas: &canvas, size: size, piece: piece)
            case .kelp, .grass: break // they sway — the live pass draws them
            }
        }
    }

    /// The moving dressing → the live pass: kelp & grass on both depth
    /// passes (they sway), the chest's occasional burp bubble, and any
    /// near-glass piece — `front` splits the set at depth 0.6 so near
    /// pieces draw over the fish as foreground parallax.
    func drawLiveDecor(canvas: inout GraphicsContext, size: CGSize, t: Double,
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
            case .kelp where front:
                // The near-glass fronds sit a hair out of focus — the
                // foreground falls off like a camera's would.
                var g = canvas
                g.addFilter(.blur(radius: 1.6))
                drawKelp(canvas: &g, size: size, t: t, piece: piece, tone: tone)
            case .kelp: drawKelp(canvas: &canvas, size: size, t: t, piece: piece, tone: tone)
            case .grass: drawGrass(canvas: &canvas, size: size, t: t, piece: piece)
            case .chest where !front:
                drawChestBurp(canvas: &canvas, size: size, t: t, piece: piece)
            case .chest: // a front chest can't sit in the bed cache — draw it live
                drawChest(canvas: &canvas, size: size, piece: piece)
                drawChestBurp(canvas: &canvas, size: size, t: t, piece: piece)
            case .rock where front: drawRocks(canvas: &canvas, size: size, piece: piece)
            case .coral where front: drawCoral(canvas: &canvas, size: size, piece: piece)
            case .shell where front: drawShell(canvas: &canvas, size: size, piece: piece)
            case .bottle where front: drawBottle(canvas: &canvas, size: size, piece: piece)
            case .starfish where front: drawStarfish(canvas: &canvas, size: size, piece: piece)
            default: break
            }
        }
    }

    /// Where a piece stands: on the dune line under it, with a couple
    /// of pixels of sink so nothing floats over the sand.
    func decorBaseY(_ piece: TankDecor, in size: CGSize) -> Double {
        sandTop(atX: piece.x * size.width, in: size) + 2
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

    /// A smoothed polyline through `pts` — midpoint anchors, point
    /// controls. The stand-in for hand-drawn curves everywhere below.
    private func smoothPath(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard pts.count > 1 else { return p }
        p.move(to: pts[0])
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2,
                              y: (pts[i - 1].y + pts[i].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i - 1])
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }

    /// A tapered ribbon along a cubic Bézier: `fill` is the closed
    /// blade (width `w0` at the root tapering to a soft point),
    /// `midrib` the centreline for a darker stroke, `edge` one side
    /// for a highlight. Sampled once per draw — nine steps is smooth
    /// at these sizes. `belly` switches the width profile from a plain
    /// taper to a kelp blade's: narrow at the root, fullest mid-blade,
    /// soft point. `ruffle` ripples the two margins on independent
    /// phases, which is what turns a strip into a leaf.
    private func ribbon(from p0: CGPoint, c1: CGPoint, c2: CGPoint, to p1: CGPoint,
                        width w0: Double, litLeft: Bool = true,
                        steps: Int = 9,
                        belly: Double = 0, ruffle: Double = 0,
                        rufflePhase: Double = 0) -> (fill: Path, midrib: Path, edge: Path) {
        var mid: [CGPoint] = []
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        mid.reserveCapacity(steps + 1)
        left.reserveCapacity(steps + 1)
        right.reserveCapacity(steps + 1)
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            let v = 1 - u
            let px = v * v * v * p0.x + 3 * v * v * u * c1.x + 3 * v * u * u * c2.x + u * u * u * p1.x
            let py = v * v * v * p0.y + 3 * v * v * u * c1.y + 3 * v * u * u * c2.y + u * u * u * p1.y
            let dx = 3 * v * v * (c1.x - p0.x) + 6 * v * u * (c2.x - c1.x) + 3 * u * u * (p1.x - c2.x)
            let dy = 3 * v * v * (c1.y - p0.y) + 6 * v * u * (c2.y - c1.y) + 3 * u * u * (p1.y - c2.y)
            let len = max(0.001, (dx * dx + dy * dy).squareRoot())
            let nx = -dy / len, ny = dx / len
            let hw: Double
            if belly > 0 {
                // sin(π·(0.05+0.95u))^0.65 ≈ 0.3 at the root, 1 at
                // mid-blade, 0 at the tip — a leaf outline. The 0.9
                // floor blunts the tip: kelp ends rounded, not
                // needle-pointed.
                hw = w0 / 2 * pow(sin(.pi * (0.05 + 0.95 * u)), 0.65) + 0.9
            } else {
                hw = w0 / 2 * (1 - u) + 0.35
            }
            let hwL = hw * (1 + ruffle * sin(u * 10.5 + rufflePhase))
            let hwR = hw * (1 + ruffle * sin(u * 11.2 + rufflePhase + 2.1))
            mid.append(CGPoint(x: px, y: py))
            left.append(CGPoint(x: px + nx * hwL, y: py + ny * hwL))
            right.append(CGPoint(x: px - nx * hwR, y: py - ny * hwR))
        }
        // Closed midpoint spline through both sides.
        let outline = left + right.reversed()
        let n = outline.count
        var fill = Path()
        fill.move(to: CGPoint(x: (outline[0].x + outline[1].x) / 2,
                              y: (outline[0].y + outline[1].y) / 2))
        for i in 1...n {
            let a = outline[i % n]
            let bpt = outline[(i + 1) % n]
            fill.addQuadCurve(to: CGPoint(x: (a.x + bpt.x) / 2, y: (a.y + bpt.y) / 2),
                              control: a)
        }
        fill.closeSubpath()
        return (fill, smoothPath(mid), smoothPath(litLeft ? left : right))
    }

    /// One kelp cluster: two or three broad blades fanning from a
    /// root — narrow at the foot, fullest mid-blade, ruffled margins,
    /// a soft point — each bending in a slow S as it sways. The fill is
    /// a root→tip gradient of translucent green, so the tip reads lit
    /// and the water shows through; a midrib and a lit margin pick out
    /// the blade. Deep clusters melt toward the water colour;
    /// near-glass ones draw as wider, darker teal silhouettes over the
    /// fish — translucent, so they stay plants, not slabs. Reduce
    /// Motion freezes the sway.
    private func drawKelp(canvas: inout GraphicsContext, size: CGSize, t: Double, piece: TankDecor,
                          tone: TankPaint.Tone = .none) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = decorBaseY(piece, in: size)
        let front = piece.depth > 0.6
        let fronds = 2 + Int(scatter(b, 90) % 2)
        let wash = 1 - piece.depth
        let widthScale = size.width / 1024
        for k in 0..<fronds {
            let fb = scatter(b, k)
            let phase = Double(fb & 0xFF) / 0xFF * .pi * 2
            // Heights vary inside the cluster; the tallest fronds
            // reach ~45% of the tank.
            let hgt = min(size.height * (0.20 + Double((fb >> 8) & 0xFF) / 0xFF * 0.30)
                          * (0.8 + piece.scale * 0.25),
                          size.height * (front ? 0.55 : 0.48))
            let spread = (Double(k) - Double(fronds - 1) / 2) * 15 * piece.scale
            let lean = (Double((fb >> 16) & 0xFF) / 0xFF - 0.5) * 50 + spread
            let sway = reduceMotion ? 0
                : sin(t * (0.24 + Double((fb >> 24) & 0xFF) / 0xFF * 0.20) + phase)
                  * (9 + hgt * 0.06)
            let w0 = (32 + Double((fb >> 32) & 0xFF) / 0xFF * 14) * widthScale
                * (0.7 + piece.scale * 0.3) * (front ? 1.3 : 1.0)

            let root = CGPoint(x: baseX + spread * 0.6, y: baseY)
            let tip = CGPoint(x: baseX + lean + sway, y: baseY - hgt)
            // A gentle S: the lower third of the blade bows one side
            // of the root→tip chord, the upper third the other.
            let drift = lean + sway
            let chLen = max(1, (drift * drift + hgt * hgt).squareRoot())
            let sAmp = hgt * (0.11 + (reduceMotion ? 0 : 0.035 * sin(t * 0.4 + phase)))
            let perpX = hgt / chLen * sAmp
            let perpY = drift / chLen * sAmp
            let c1 = CGPoint(x: root.x + drift * 0.33 - perpX,
                             y: baseY - hgt * 0.33 - perpY)
            let c2 = CGPoint(x: root.x + drift * 0.68 + perpX,
                             y: baseY - hgt * 0.68 + perpY)
            let rib = ribbon(from: root, c1: c1, c2: c2, to: tip,
                             width: w0, litLeft: drift < 0, steps: 14,
                             belly: 1,
                             ruffle: 0.14 + Double((fb >> 40) & 0xFF) / 0xFF * 0.10,
                             rufflePhase: phase)

            let rootColor: Color
            let tipColor: Color
            let ribColor: Color
            let edgeColor: Color
            let shadeColor: Color
            if front {
                // Foreground: a glass-side frond sliding over the fish,
                // out of focus — a soft, lit green veil, never a slab.
                rootColor = Color(red: 0.10, green: 0.32, blue: 0.22).opacity(0.50)
                tipColor = Color(red: 0.36, green: 0.62, blue: 0.34).opacity(0.34)
                ribColor = Color(red: 0.70, green: 0.88, blue: 0.52).opacity(0.18)
                edgeColor = Color(red: 0.78, green: 0.96, blue: 0.70).opacity(0.34)
                shadeColor = Color(red: 0.02, green: 0.10, blue: 0.08).opacity(0.22)
            } else {
                // Olive at the holdfast, golden-lime where the light
                // comes through the tip, melted toward the water by
                // depth.
                let g0 = Self.waterNS.blended(
                    withFraction: 1 - wash * 0.55,
                    of: NSColor(srgbRed: 0.12, green: 0.34, blue: 0.14, alpha: 1))
                    ?? Self.waterNS
                let g1 = Self.waterNS.blended(
                    withFraction: 1 - wash * 0.45,
                    of: NSColor(srgbRed: 0.58, green: 0.76, blue: 0.30, alpha: 1))
                    ?? Self.waterNS
                rootColor = tone(Color(nsColor: g0)).opacity(0.88 - wash * 0.18)
                tipColor = tone(Color(nsColor: g1)).opacity(0.72 - wash * 0.16)
                ribColor = Color(red: 0.80, green: 0.92, blue: 0.50).opacity(0.34 * (1 - wash * 0.5))
                edgeColor = Color(red: 0.86, green: 1.0, blue: 0.66).opacity(0.52 * (1 - wash * 0.5))
                shadeColor = Color(red: 0.02, green: 0.12, blue: 0.06).opacity(0.34 * (1 - wash * 0.4))
            }
            canvas.fill(rib.fill, with: .linearGradient(
                Gradient(stops: [
                    .init(color: rootColor, location: 0),
                    .init(color: tipColor, location: 1),
                ]),
                startPoint: root, endPoint: tip))
            // The blade's far margin falls into shade; the near one
            // catches the light.
            var shaded = canvas
            shaded.clip(to: rib.fill)
            shaded.stroke(rib.fill, with: .color(shadeColor),
                          style: StrokeStyle(lineWidth: max(2, w0 * 0.22)))
            // Light through the upper blade — the sun behind the leaf.
            if !front {
                var glow = shaded
                glow.blendMode = .plusLighter
                glow.fill(rib.fill, with: .radialGradient(
                    Gradient(colors: [Color(red: 0.55, green: 0.70, blue: 0.25).opacity(0.28 * (1 - wash * 0.6)),
                                      .clear]),
                    center: CGPoint(x: (tip.x * 2 + root.x) / 3, y: (tip.y * 2 + root.y) / 3),
                    startRadius: 0, endRadius: hgt * 0.45))
            }
            canvas.stroke(rib.midrib, with: .color(ribColor),
                          style: StrokeStyle(lineWidth: max(1.0, w0 * 0.06), lineCap: .round))
            canvas.stroke(rib.edge, with: .color(edgeColor),
                          style: StrokeStyle(lineWidth: max(1.0, w0 * 0.045), lineCap: .round))
            // A float bladder where the blade meets its stipe.
            if !front {
                let bladder = CGPoint(x: root.x + (c1.x - root.x) * 0.18, y: baseY - hgt * 0.06)
                let r = max(2.2, w0 * 0.10)
                canvas.fill(Path(ellipseIn: CGRect(x: bladder.x - r, y: bladder.y - r * 1.2,
                                                   width: r * 2, height: r * 2.4)),
                            with: .radialGradient(
                                Gradient(colors: [Color(red: 0.72, green: 0.78, blue: 0.36).opacity(0.85 - wash * 0.3),
                                                  Color(red: 0.24, green: 0.34, blue: 0.12).opacity(0.85 - wash * 0.3)]),
                                center: CGPoint(x: bladder.x - r * 0.3, y: bladder.y - r * 0.5),
                                startRadius: 0, endRadius: r * 1.4))
            }
        }
    }

    /// A tuft of thin sea-grass blades — the same ribbon as kelp but
    /// short, thin and quick-swaying.
    private func drawGrass(canvas: inout GraphicsContext, size: CGSize, t: Double, piece: TankDecor) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = decorBaseY(piece, in: size) + 1
        let blades = 5 + Int((b >> 36) % 4)
        let wash = 1 - piece.depth
        let green = Self.waterNS.blended(
            withFraction: 1 - wash * 0.5,
            of: NSColor(srgbRed: 0.15, green: 0.48, blue: 0.27, alpha: 1))
            ?? Self.waterNS
        let scale = piece.scale * max(0.7, min(1.5, size.height / 240)) * 1.3
        for k in 0..<blades {
            let fb = scatter(b, k &+ 11)
            let spread = (Double((fb >> 40) & 0xFF) / 0xFF - 0.5) * 16 * scale
            let hgt = (14 + Double((fb >> 8) & 0xFF) / 0xFF * 30) * scale
            let phase = Double(fb & 0xFF) / 0xFF * .pi * 2
            let sway = reduceMotion ? 0
                : sin(t * (0.5 + Double((fb >> 24) & 0xFF) / 0xFF * 0.4) + phase) * 3.5
            let root = CGPoint(x: baseX + spread * 0.3, y: baseY)
            let tip = CGPoint(x: baseX + spread + (Double((fb >> 16) & 0xFF) / 0xFF - 0.5) * 14 + sway,
                              y: baseY - hgt)
            let rib = ribbon(from: root,
                             c1: CGPoint(x: root.x, y: baseY - hgt * 0.5),
                             c2: CGPoint(x: tip.x - sway * 0.6, y: tip.y + hgt * 0.3),
                             to: tip, width: 2.6 * scale, litLeft: tip.x < baseX, steps: 6)
            canvas.fill(rib.fill,
                        with: .color(Color(nsColor: green).opacity(0.78 - wash * 0.28)))
        }
    }

    /// A couple of boulders leaning together on the dune line: tall
    /// domed stones rather than pebbles, each lit from above-left
    /// with a shaded underbelly and a cool water wash by depth. The
    /// cluster pools one shadow under itself.
    private func drawRocks(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = decorBaseY(piece, in: size)
        let wash = 1 - piece.depth
        let scale = piece.scale * Self.decorBoost
        let count = 2 + Int(scatter(b, 7) & 1)
        groundShadow(canvas: &canvas, x: baseX, y: baseY + 2,
                     halfW: 34 * scale, halfH: 6.5, alpha: 0.30)
        for r in 0..<count {
            let rb = scatter(b, r &+ 3)
            let rw = (15 + Double(rb & 0xFF) / 0xFF * 12) * scale
            let rh = rw * (0.66 + Double((rb >> 8) & 0xFF) / 0xFF * 0.28)
            let rx = baseX + (Double(r) - Double(count - 1) / 2) * rw * 0.60
                + (Double((rb >> 16) & 0xF) - 7.5)
            // Later boulders ride up on the first, piled stone style.
            let ry = baseY - rh * 0.40 - (r > 0 ? rh * 0.14 * Double(r) : 0)
            let rect = CGRect(x: rx - rw / 2, y: ry - rh / 2, width: rw, height: rh)
            let boulder = Path(ellipseIn: rect)
            canvas.fill(boulder,
                        with: .radialGradient(
                            Gradient(colors: [Color(red: 0.50, green: 0.48, blue: 0.44)
                                                .opacity(0.92 - wash * 0.25),
                                              Color(red: 0.13, green: 0.12, blue: 0.12)
                                                .opacity(0.92 - wash * 0.2)]),
                            center: CGPoint(x: rx - rw * 0.20, y: ry - rh * 0.30),
                            startRadius: 0, endRadius: rw * 0.72))
            // The shaded underbelly, clipped to the boulder.
            var shade = canvas
            shade.clip(to: boulder)
            shade.fill(Path(ellipseIn: CGRect(x: rx - rw * 0.55, y: ry + rh * 0.05,
                                              width: rw * 1.1, height: rh * 0.7)),
                       with: .color(.black.opacity(0.30 - wash * 0.10)))
            // The lit brow.
            canvas.fill(Path(ellipseIn: CGRect(x: rx - rw * 0.30, y: ry - rh * 0.40,
                                               width: rw * 0.36, height: rh * 0.22)),
                        with: .color(.white.opacity(0.18 - wash * 0.07)))
            // Grain, a dark edge, and weed where it meets the sand.
            TankPaint.speckle(&canvas, boulder, seed: rb, count: Int(rw * 1.2), size: max(0.8, rw * 0.05),
                              dark: .black.opacity(0.24 - wash * 0.08), light: .white.opacity(0.12 - wash * 0.05))
            canvas.stroke(boulder, with: .color(.black.opacity(0.32 - wash * 0.12)), lineWidth: 0.8)
            TankPaint.moss(&canvas, clip: boulder, from: rx - rw / 2, to: rx + rw / 2, y: ry + rh / 2,
                           height: rh * 0.22, seed: rb >> 3, fade: 0.85 - wash * 0.4)
        }
    }

    /// One of two corals by seed: a branching fan (round-stroked
    /// forks with pale tips) or a rounded brain (a domed mound with
    /// concentric grooves). Both get a ground shadow; deep corals
    /// mute toward the water colour.
    private func drawCoral(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        if (piece.bits >> 40) & 1 == 0 {
            drawFanCoral(canvas: &canvas, size: size, piece: piece)
        } else {
            drawBrainCoral(canvas: &canvas, size: size, piece: piece)
        }
    }

    /// The branching fan: a trunk that forks twice, stroked dark
    /// underneath then bright over it, with paler tips.
    private func drawFanCoral(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = decorBaseY(piece, in: size)
        let hgt = min((30 + Double(b & 0xFF) / 0xFF * 26) * piece.scale
                      * max(0.7, min(1.5, size.height / 240)) * Self.decorBoost,
                      size.height * 0.26)
        let wash = 1 - piece.depth
        // Two palettes: rose or amber.
        let bright = (b >> 48) & 1 == 0
            ? Color(red: 0.88, green: 0.46, blue: 0.48)
            : Color(red: 0.90, green: 0.60, blue: 0.34)
        let shadow = (b >> 48) & 1 == 0
            ? Color(red: 0.48, green: 0.18, blue: 0.22)
            : Color(red: 0.50, green: 0.28, blue: 0.12)
        groundShadow(canvas: &canvas, x: baseX, y: baseY + 1,
                     halfW: 14 * piece.scale * Self.decorBoost, halfH: 4.5, alpha: 0.25)

        var tips: [CGPoint] = []
        func grow(_ from: CGPoint, _ angle: Double, _ len: Double, _ forks: Int, _ w: Double) {
            let to = CGPoint(x: from.x + cos(angle) * len, y: from.y + sin(angle) * len)
            let bend = (Double((b >> UInt64(forks * 9 + 2)) & 0xFF) / 0xFF - 0.5) * 10
            var seg = Path()
            seg.move(to: from)
            seg.addQuadCurve(to: to,
                             control: CGPoint(x: (from.x + to.x) / 2 + bend,
                                              y: (from.y + to.y) / 2))
            canvas.stroke(seg, with: .color(shadow.opacity(0.8 - wash * 0.3)),
                          style: StrokeStyle(lineWidth: w + 1.6, lineCap: .round))
            canvas.stroke(seg, with: .color(bright.opacity(0.85 - wash * 0.35)),
                          style: StrokeStyle(lineWidth: w, lineCap: .round))
            guard forks > 0 else {
                tips.append(to)
                return
            }
            let spread = 0.45 + Double((b >> UInt64(forks * 7 + 12)) & 0xFF) / 0xFF * 0.4
            grow(to, angle - spread, len * 0.66, forks - 1, w * 0.72)
            grow(to, angle + spread * 0.8, len * 0.66, forks - 1, w * 0.72)
        }
        grow(CGPoint(x: baseX, y: baseY),
             -.pi / 2 + (Double((b >> 8) & 0xFF) / 0xFF - 0.5) * 0.4,
             hgt * 0.5, 2, 3.0 * piece.scale * Self.decorBoost * 0.75)
        for tip in tips {
            canvas.fill(Path(ellipseIn: CGRect(x: tip.x - 1.4, y: tip.y - 1.4,
                                               width: 2.8, height: 2.8)),
                        with: .color(Color(red: 0.98, green: 0.80, blue: 0.72)
                                        .opacity(0.7 - wash * 0.3)))
        }
    }

    /// The brain coral: a shaded dome with concentric groove arcs and
    /// a scatter of pores.
    private func drawBrainCoral(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = decorBaseY(piece, in: size)
        let r = (13 + Double(b & 0xFF) / 0xFF * 9) * piece.scale * Self.decorBoost
        let wash = 1 - piece.depth
        groundShadow(canvas: &canvas, x: baseX, y: baseY + 1,
                     halfW: r * 1.1, halfH: 4, alpha: 0.28)
        // A squat dome.
        var dome = Path()
        dome.move(to: CGPoint(x: baseX - r, y: baseY))
        dome.addCurve(to: CGPoint(x: baseX + r, y: baseY),
                      control1: CGPoint(x: baseX - r, y: baseY - r * 1.15),
                      control2: CGPoint(x: baseX + r, y: baseY - r * 1.15))
        dome.closeSubpath()
        let purple = (b >> 48) & 1 == 0
        let lit = purple ? Color(red: 0.62, green: 0.46, blue: 0.62)
                         : Color(red: 0.72, green: 0.56, blue: 0.38)
        let dark = purple ? Color(red: 0.30, green: 0.18, blue: 0.34)
                          : Color(red: 0.36, green: 0.24, blue: 0.16)
        canvas.fill(dome, with: .radialGradient(
            Gradient(colors: [lit.opacity(0.9 - wash * 0.3), dark.opacity(0.9 - wash * 0.25)]),
            center: CGPoint(x: baseX - r * 0.2, y: baseY - r * 0.8),
            startRadius: 0, endRadius: r * 1.5))
        // The ridges: meandering grooves across the dome, a lit lip on
        // each, the way a brain coral folds.
        var ridges = canvas
        ridges.clip(to: dome)
        var maze = Path()
        let rows = 6
        for k in 0..<rows {
            let gy = baseY - r * 0.95 + Double(k) * r * 0.19
            var gx = baseX - r
            maze.move(to: CGPoint(x: gx, y: gy))
            var flip = k.isMultiple(of: 2)
            while gx < baseX + r {
                let step = r * 0.22
                maze.addQuadCurve(to: CGPoint(x: gx + step, y: gy + (flip ? r * 0.05 : -r * 0.05)),
                                  control: CGPoint(x: gx + step * 0.5, y: gy + (flip ? -r * 0.09 : r * 0.09)))
                gx += step
                flip.toggle()
            }
        }
        ridges.stroke(maze, with: .color(dark.opacity(0.62 - wash * 0.2)),
                      style: StrokeStyle(lineWidth: max(0.8, r * 0.06), lineCap: .round))
        ridges.stroke(maze.offsetBy(dx: 0, dy: -max(0.6, r * 0.04)), with: .color(.white.opacity(0.16 - wash * 0.06)),
                      style: StrokeStyle(lineWidth: max(0.5, r * 0.03), lineCap: .round))
        canvas.stroke(dome, with: .color(dark.opacity(0.7 - wash * 0.25)), lineWidth: 0.8)
        // Pores.
        for i in 0..<5 {
            let pb = scatter(b, i &+ 31)
            let px = baseX + (Double(pb & 0xFF) / 0xFF - 0.5) * r * 1.3
            let py = baseY - Double((pb >> 8) & 0xFF) / 0xFF * r * 0.6 - r * 0.1
            canvas.fill(Path(ellipseIn: CGRect(x: px - 1, y: py - 1, width: 2, height: 2)),
                        with: .color(dark.opacity(0.5)))
        }
    }

    /// A shell on the sand — a ribbed scallop or a spiral, by seed.
    private func drawShell(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = decorBaseY(piece, in: size) + 1
        let s = 6.5 * piece.scale * Self.decorBoost
        groundShadow(canvas: &canvas, x: baseX, y: baseY + 1,
                     halfW: s * 1.15, halfH: 2.6, alpha: 0.24)
        var c = canvas
        c.translateBy(x: baseX, y: baseY)
        c.rotate(by: .radians((Double(b & 0xFF) / 0xFF - 0.5) * 0.7))
        c.scaleBy(x: s, y: s)
        if (b >> 12) & 1 == 0 {
            // Scallop: a fan off the hinge with ribs out to the rim.
            var fan = Path()
            fan.move(to: CGPoint(x: 0, y: 0.18))
            fan.addCurve(to: CGPoint(x: -0.55, y: -0.22),
                         control1: CGPoint(x: -0.32, y: 0.10),
                         control2: CGPoint(x: -0.54, y: 0.02))
            fan.addQuadCurve(to: CGPoint(x: 0.55, y: -0.22),
                             control: CGPoint(x: 0, y: -0.75))
            fan.addCurve(to: CGPoint(x: 0, y: 0.18),
                         control1: CGPoint(x: 0.54, y: 0.02),
                         control2: CGPoint(x: 0.32, y: 0.10))
            fan.closeSubpath()
            c.fill(fan, with: .linearGradient(
                Gradient(colors: [Color(red: 0.88, green: 0.70, blue: 0.62),
                                  Color(red: 0.58, green: 0.38, blue: 0.32)]),
                startPoint: CGPoint(x: 0, y: -0.6), endPoint: CGPoint(x: 0, y: 0.2)))
            for ribX in [-0.36, -0.18, 0.0, 0.18, 0.36] as [Double] {
                var ribPath = Path()
                ribPath.move(to: CGPoint(x: 0, y: 0.14))
                ribPath.addQuadCurve(to: CGPoint(x: ribX, y: -0.44 + abs(ribX) * 0.55),
                                     control: CGPoint(x: ribX * 0.5, y: -0.12))
                c.stroke(ribPath,
                         with: .color(Color(red: 0.44, green: 0.27, blue: 0.22).opacity(0.5)),
                         lineWidth: 0.05)
            }
        } else {
            // A spiral whelk.
            c.fill(Path(ellipseIn: CGRect(x: -0.42, y: -0.42, width: 0.84, height: 0.84)),
                   with: .radialGradient(
                       Gradient(colors: [Color(red: 0.84, green: 0.68, blue: 0.52),
                                         Color(red: 0.50, green: 0.33, blue: 0.21)]),
                       center: CGPoint(x: -0.1, y: -0.12), startRadius: 0.02, endRadius: 0.55))
            var spiral = Path()
            var rr = 0.34
            var a = 0.0
            spiral.move(to: CGPoint(x: rr, y: 0))
            while a < .pi * 3.6 {
                a += 0.22
                rr *= 0.955
                spiral.addLine(to: CGPoint(x: cos(a) * rr, y: sin(a) * rr))
            }
            c.stroke(spiral,
                     with: .color(Color(red: 0.40, green: 0.25, blue: 0.16).opacity(0.6)),
                     lineWidth: 0.05)
        }
    }

    /// A bottle sunk to its shoulder: dark sea-green glass tilted into
    /// the sand, a highlight down its flank, and a lip of sand piled
    /// over its low corner.
    private func drawBottle(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = decorBaseY(piece, in: size) + 2
        let s = 13 * piece.scale * Self.decorBoost
        let tilt = -0.5 - Double(b & 0xFF) / 0xFF * 0.3
        groundShadow(canvas: &canvas, x: baseX, y: baseY + 1,
                     halfW: s * 1.0, halfH: 3.5, alpha: 0.26)
        var c = canvas
        c.translateBy(x: baseX, y: baseY - s * 0.1)
        c.rotate(by: .radians(tilt))
        c.scaleBy(x: s, y: s)
        let glass = Color(red: 0.10, green: 0.26, blue: 0.20)
        var body = Path()
        body.addRoundedRect(in: CGRect(x: -0.55, y: -0.26, width: 0.78, height: 0.52),
                            cornerSize: CGSize(width: 0.20, height: 0.24))
        var neck = Path()
        neck.move(to: CGPoint(x: 0.20, y: -0.20))
        neck.addQuadCurve(to: CGPoint(x: 0.50, y: -0.085),
                          control: CGPoint(x: 0.36, y: -0.17))
        neck.addLine(to: CGPoint(x: 0.62, y: -0.085))
        neck.addLine(to: CGPoint(x: 0.62, y: 0.085))
        neck.addLine(to: CGPoint(x: 0.50, y: 0.085))
        neck.addQuadCurve(to: CGPoint(x: 0.20, y: 0.20),
                          control: CGPoint(x: 0.36, y: 0.17))
        neck.closeSubpath()
        c.fill(body, with: .linearGradient(
            Gradient(colors: [glass.opacity(0.85), Color(red: 0.04, green: 0.12, blue: 0.10).opacity(0.9)]),
            startPoint: CGPoint(x: 0, y: -0.3), endPoint: CGPoint(x: 0, y: 0.3)))
        c.fill(neck, with: .color(glass.opacity(0.85)))
        // The cork & a highlight down the flank.
        c.fill(Path(CGRect(x: 0.60, y: -0.075, width: 0.08, height: 0.15)),
               with: .color(Color(red: 0.55, green: 0.40, blue: 0.24).opacity(0.9)))
        // A message rolled up inside, and the glass's shine.
        var note = c
        note.clip(to: body)
        note.fill(Path(roundedRect: CGRect(x: -0.36, y: -0.08, width: 0.44, height: 0.16), cornerRadius: 0.06),
                  with: .color(Color(red: 0.92, green: 0.86, blue: 0.66).opacity(0.55)))
        note.stroke(Path(roundedRect: CGRect(x: -0.36, y: -0.08, width: 0.44, height: 0.16), cornerRadius: 0.06),
                    with: .color(Color(red: 0.55, green: 0.40, blue: 0.20).opacity(0.5)), lineWidth: 0.02)
        c.fill(Path(roundedRect: CGRect(x: -0.44, y: -0.20, width: 0.56, height: 0.06),
                    cornerRadius: 0.03),
               with: .color(.white.opacity(0.32)))
        c.stroke(body, with: .color(Color(red: 0.55, green: 0.85, blue: 0.70).opacity(0.45)), lineWidth: 0.03)
        // A lip of sand over the low corner buries it.
        canvas.fill(Path(ellipseIn: CGRect(x: baseX - s * 0.6, y: baseY - 3,
                                           width: s * 1.1, height: 5)),
                    with: .color(Color(red: 0.48, green: 0.40, blue: 0.27).opacity(0.9)))
    }

    /// A five-pointed star resting on the sand, with a rim, a raised
    /// centre and a row of bumps down each arm.
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

    private func drawStarfish(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        let x = piece.x * size.width
        let y = decorBaseY(piece, in: size)
        let s = 16 * piece.scale * Self.decorBoost
        groundShadow(canvas: &canvas, x: x, y: y + 1.5,
                     halfW: s * 0.6, halfH: 3.5, alpha: 0.26)
        var c = canvas
        c.translateBy(x: x, y: y - s * 0.18)
        c.rotate(by: .radians(Double(piece.bits & 0xFF) / 0xFF * .pi * 2))
        c.scaleBy(x: s, y: s)
        c.fill(Self.starPath, with: .radialGradient(
            Gradient(colors: [Color(red: 1.0, green: 0.70, blue: 0.46), Color(red: 0.86, green: 0.40, blue: 0.24),
                              Color(red: 0.56, green: 0.20, blue: 0.10)]),
            center: CGPoint(x: -0.06, y: -0.08), startRadius: 0, endRadius: 0.55))
        TankPaint.speckle(&c, Self.starPath, seed: piece.bits, count: 40, size: 0.05,
                          dark: Color(red: 0.45, green: 0.14, blue: 0.06).opacity(0.45),
                          light: Color(red: 1.0, green: 0.90, blue: 0.75).opacity(0.7))
        c.stroke(Self.starPath,
                 with: .color(Color(red: 0.45, green: 0.18, blue: 0.08).opacity(0.75)),
                 lineWidth: 0.04)
        // A smaller, lighter star on top reads as the raised centre.
        var inner = c
        inner.scaleBy(x: 0.5, y: 0.5)
        inner.fill(Self.starPath,
                   with: .color(Color(red: 0.96, green: 0.70, blue: 0.46).opacity(0.7)))
        // Arm bumps.
        for i in 0..<5 {
            let a = Double(i) * .pi * 2 / 5 - .pi / 2
            c.fill(Path(ellipseIn: CGRect(x: cos(a) * 0.28 - 0.035,
                                          y: sin(a) * 0.28 - 0.035,
                                          width: 0.07, height: 0.07)),
                   with: .color(Color(red: 0.60, green: 0.33, blue: 0.16).opacity(0.6)))
        }
        c.fill(Path(ellipseIn: CGRect(x: -0.09, y: -0.09, width: 0.18, height: 0.18)),
               with: .color(Color(red: 0.62, green: 0.34, blue: 0.17).opacity(0.55)))
    }

    /// The treasure chest on the dune floor: a domed lid, wood planks
    /// shaded top to bottom, brass bands & a latch, a pool of shadow
    /// under it. The chest itself is still — it lives in the cached
    /// bed pass; its one moving part (the burp bubble) is
    /// `drawChestBurp` in the live pass.
    private func drawChest(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        let w = 40 * piece.scale * Self.decorBoost
        let h = 26 * piece.scale * Self.decorBoost
        let x = piece.x * size.width
        let y = decorBaseY(piece, in: size) + 2
        groundShadow(canvas: &canvas, x: x, y: y + 1, halfW: w * 0.62, halfH: 5, alpha: 0.34)
        var c = canvas
        c.translateBy(x: x, y: y)
        Self.paintChest(&c, width: w, height: h, open: 0, t: 0, reduceMotion: true, tone: decorTone())
        // Half sunk: a lip of sand over its foot.
        c.fill(Path(ellipseIn: CGRect(x: -w * 0.62, y: -3, width: w * 1.24, height: 6)),
               with: .color(Color(red: 0.62, green: 0.52, blue: 0.36).opacity(0.85)))
    }

    /// Every few seconds the chest burps a single bubble, the tank's
    /// smallest joke — the only moving part, so it draws in the live
    /// pass. Reduce Motion holds it in.
    private func drawChestBurp(canvas: inout GraphicsContext, size: CGSize,
                               t: Double, piece: TankDecor) {
        guard !reduceMotion else { return }
        let h = 26 * piece.scale * Self.decorBoost
        let x = piece.x * size.width
        let y = decorBaseY(piece, in: size) + 2
        let period = 6 + Double(piece.bits & 0xFF) / 0xFF * 5
        let rise = frac(t / period + Double((piece.bits >> 8) & 0xFF) / 0xFF)
        guard rise < 0.6 else { return }
        let br = 2.0 + rise * 2.5
        let by = y - h - rise * size.height * 0.35
        canvas.stroke(Path(ellipseIn: CGRect(x: x - br, y: by - br, width: br * 2, height: br * 2)),
                      with: .color(.white.opacity(0.5 * (1 - rise / 0.6))), lineWidth: 0.8)
    }
}
