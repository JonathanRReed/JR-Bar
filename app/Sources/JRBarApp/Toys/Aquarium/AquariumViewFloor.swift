import AppKit
import JRBarCore
import SwiftUI

/// The floor: the substrate's sand, its grains, crest and ripples.
extension AquariumView {
    // MARK: Floor

    /// Seeded phases for the dune profile — fixed across launches.
    static let dunePhase1 =
        Double(AquariumModel.stableHash("dune-p1") & 0xFFFF) / 0xFFFF * .pi * 2
    static let dunePhase2 =
        Double(AquariumModel.stableHash("dune-p2") & 0xFFFF) / 0xFFFF * .pi * 2

    /// The dune crest the whole floor agrees on — closed form, so a
    /// chest, a fish shadow or a kelp root can sit exactly on the sand
    /// at any x. Three stacked harmonics give two or three overlapping
    /// rounded humps rather than a flat bar; the bed stands ~10–14% of
    /// the tank tall: a real floor, not a sliver.
    func sandTop(atX x: Double, in size: CGSize) -> Double {
        let u = x / max(1, size.width)
        return size.height
            - (76 + 9 * sin(u * .pi * 2.3 + Self.dunePhase1)
               + 5 * sin(u * .pi * 4.9 + Self.dunePhase2)
               + 2.5 * sin(u * .pi * 8.1 + Self.dunePhase1 * 2))
    }

    /// The back dune's crest, a layer higher on screen: the bed
    /// running away from the glass. A good stone's throw behind the
    /// front crest so the two dunes read as separate layers.
    func backDuneTop(atX x: Double, in size: CGSize) -> Double {
        let u = x / max(1, size.width)
        return sandTop(atX: x, in: size) - 30 - 8 * sin(u * .pi * 3.4 + Self.dunePhase2 * 1.7)
    }

    /// The bed under a crest line, closed down past the glass's foot.
    func sandPath(in size: CGSize, top: (Double) -> Double) -> Path {
        var p = Path()
        let step = max(4, size.width / 200)
        p.move(to: CGPoint(x: -2, y: top(-2)))
        var x = -2.0
        while x <= size.width + 2 {
            p.addLine(to: CGPoint(x: x, y: top(x)))
            x += step
        }
        p.addLine(to: CGPoint(x: size.width + 2, y: top(size.width + 2)))
        p.addLine(to: CGPoint(x: size.width + 2, y: size.height + 2))
        p.addLine(to: CGPoint(x: -2, y: size.height + 2))
        p.closeSubpath()
        return p
    }

    /// One seeded grain of sand, in unit space.
    private struct Speck {
        var x, y, r: Double
        var light: Bool
    }

    /// ~420 grains scattered over the bed, seeded once. The hash goes
    /// through the same murmur-style finalizer `decorSet` uses —
    /// FNV-1a's low bits cluster on sequential tags and would lay the
    /// grains out in rows.
    private static let sandSpeckles: [Speck] = (0..<420).map { i in
        var h = AquariumModel.stableHash("speck-\(i)")
        h ^= h >> 33
        h &*= 0xff51afd7ed558ccd
        h ^= h >> 33
        return Speck(x: Double(h & 0xFFFF) / 0xFFFF,
                     y: Double((h >> 16) & 0xFFFF) / 0xFFFF,
                     r: 0.5 + Double((h >> 32) & 0xF) / 0xF * 1.0,
                     light: (h >> 48) & 1 == 0)
    }

    /// One substrate's colours (docs/TOYS.md shop) as plain numbers:
    /// the sun-lit crest, the body of the bed and its shaded foot, the
    /// ripples' two faces, and the grains.
    struct SandPalette {
        var lit, body, foot: TankPaint.RGB
        var crest, rippleShade, rippleLight: TankPaint.RGB
        var speckLight, speckDark: TankPaint.RGB
        /// Grain size and contrast: basalt gravel is chunky, aragonite
        /// fine.
        var grain: Double
        var grainAlpha: Double
    }

    var sandPalette: SandPalette { Self.sandPalette(forSubstrate: substrateKey) }

    /// A substrate's sand as a swatch, crest to foot — the shop's tile.
    static func sandSwatch(forSubstrate substrate: String) -> [Color] {
        let sand = sandPalette(forSubstrate: substrate)
        return [TankPaint.color(sand.lit), TankPaint.color(sand.body), TankPaint.color(sand.foot)]
    }

    /// The palette for a substrate key — "classic" tan when unknown.
    static func sandPalette(forSubstrate substrate: String) -> SandPalette {
        switch substrate {
        case "white":
            return SandPalette(lit: .init(0.98, 0.96, 0.89), body: .init(0.84, 0.81, 0.72),
                               foot: .init(0.50, 0.47, 0.40), crest: .init(1.0, 1.0, 0.95),
                               rippleShade: .init(0.58, 0.54, 0.46), rippleLight: .init(1.0, 1.0, 0.96),
                               speckLight: .init(1.0, 0.99, 0.95), speckDark: .init(0.46, 0.42, 0.34),
                               grain: 0.9, grainAlpha: 0.9)
        case "black":
            return SandPalette(lit: .init(0.30, 0.31, 0.35), body: .init(0.15, 0.16, 0.19),
                               foot: .init(0.05, 0.05, 0.07), crest: .init(0.66, 0.69, 0.76),
                               rippleShade: .init(0.03, 0.03, 0.04), rippleLight: .init(0.45, 0.48, 0.55),
                               speckLight: .init(0.62, 0.65, 0.72), speckDark: .init(0.01, 0.01, 0.02),
                               grain: 2.0, grainAlpha: 1.6)
        default:
            return SandPalette(lit: .init(0.86, 0.74, 0.52), body: .init(0.64, 0.51, 0.33),
                               foot: .init(0.24, 0.18, 0.11), crest: .init(1.0, 0.92, 0.70),
                               rippleShade: .init(0.40, 0.29, 0.16), rippleLight: .init(1.0, 0.90, 0.68),
                               speckLight: .init(0.95, 0.86, 0.66), speckDark: .init(0.22, 0.16, 0.09),
                               grain: 1.0, grainAlpha: 1.0)
        }
    }

    /// The floor's palette as colours, for the pieces that sit on it —
    /// the far bank hazed into the water, the near bed's three bands,
    /// crest, rim and ripple, the grains.
    var sandTones: (backA: Color, backB: Color, frontA: Color,
                    frontB: Color, frontC: Color, crest: Color,
                    rim: Color, ripple: Color,
                    speckLight: Color, speckDark: Color) {
        let sand = sandPalette
        let haze = horizonRGB
        return (TankPaint.color(TankPaint.mix(sand.lit, haze, 0.46)),
                TankPaint.color(TankPaint.mix(sand.body, haze, 0.34)),
                TankPaint.color(sand.lit), TankPaint.color(sand.body), TankPaint.color(sand.foot),
                TankPaint.color(sand.crest), TankPaint.color(sand.crest),
                TankPaint.color(sand.rippleShade),
                TankPaint.color(sand.speckLight), TankPaint.color(sand.speckDark))
    }

    /// The colour of the distance at the bed's horizon: the mid water,
    /// lifted a little by the light that fills it.
    var horizonRGB: TankPaint.RGB {
        TankPaint.mix(waterRGB(at: 0.5), water.light, isDarkTheme ? 0.02 : 0.10)
    }

    /// The far bank: the bed running away from the glass — the same
    /// sand, bluer and softer with the distance, its crest melting into
    /// the horizon's haze. Drawn in the far still pass, behind the kelp.
    func drawFarSand(canvas: inout GraphicsContext, size: CGSize) {
        let sand = sandPalette
        let haze = horizonRGB
        let bank = sandPath(in: size) { backDuneTop(atX: $0, in: size) }
        let top = backDuneTop(atX: size.width / 2, in: size) - 12
        canvas.fill(bank, with: .linearGradient(
            Gradient(colors: [TankPaint.color(TankPaint.mix(sand.lit, haze, 0.42)),
                              TankPaint.color(TankPaint.mix(sand.lit, haze, 0.28))]),
            startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: top + 60)))
        // Long, low ripples far off: fine lines, barely there.
        var far = canvas
        far.clip(to: bank)
        var lines = Path()
        var rng = TankPaint.Seeded(0xFA2)
        for row in 0..<4 {
            var x = rng.next(-40, 0)
            while x < size.width {
                let len = rng.next(40, 140)
                let y0 = backDuneTop(atX: x, in: size) + 5 + Double(row) * 6 + rng.next(-1, 1)
                lines.move(to: CGPoint(x: x, y: y0))
                lines.addQuadCurve(to: CGPoint(x: x + len, y: y0 + rng.next(-1.5, 1.5)),
                                   control: CGPoint(x: x + len / 2, y: y0 - rng.next(1, 2.5)))
                x += len + rng.next(10, 50)
            }
        }
        far.stroke(lines, with: .color(TankPaint.color(TankPaint.mix(sand.rippleShade, haze, 0.5), 0.22)),
                   lineWidth: 0.7)
        // The crest's lit lip, hazed, and the haze rolling over it.
        var lip = Path()
        var x = -2.0
        lip.move(to: CGPoint(x: x, y: backDuneTop(atX: x, in: size)))
        while x <= size.width + 2 {
            lip.addLine(to: CGPoint(x: x, y: backDuneTop(atX: x, in: size)))
            x += max(4, size.width / 200)
        }
        canvas.stroke(lip, with: .color(TankPaint.color(TankPaint.mix(sand.crest, haze, 0.4), 0.35)),
                      lineWidth: 1.2)
        canvas.fill(Path(CGRect(x: 0, y: top - 30, width: size.width, height: 70)),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: TankPaint.color(haze, 0), location: 0),
                            .init(color: TankPaint.color(haze, 0.28), location: 0.5),
                            .init(color: TankPaint.color(haze, 0), location: 1),
                        ]),
                        startPoint: CGPoint(x: 0, y: top - 30), endPoint: CGPoint(x: 0, y: top + 40)))
    }

    /// The near bed: the lit sand from the crest to the glass — a soft
    /// shadow where it drops behind the crest, ripple marks that widen
    /// toward the glass, mottling, a scatter of grains, pebbles and
    /// shell chips half set into it, and the foot darkening where the
    /// light fades. Drawn in the near still pass.
    func drawSand(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let sand = sandPalette
        let front = sandPath(in: size) { sandTop(atX: $0, in: size) }
        let crestY = sandTop(atX: size.width / 2, in: size)
        // The near crest's shadow on the far bank behind it.
        var dip = canvas
        dip.clip(to: sandPath(in: size) { backDuneTop(atX: $0, in: size) })
        dip.stroke(front.offsetBy(dx: 0, dy: -3), with: .color(.black.opacity(0.10)), lineWidth: 8)
        canvas.fill(front, with: .linearGradient(
            Gradient(stops: [
                .init(color: TankPaint.color(sand.lit), location: 0),
                .init(color: TankPaint.color(TankPaint.mix(sand.lit, sand.body, 0.6)), location: 0.22),
                .init(color: TankPaint.color(sand.body), location: 0.5),
                .init(color: TankPaint.color(TankPaint.mix(sand.body, sand.foot, 0.55)), location: 0.8),
                .init(color: TankPaint.color(sand.foot), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: crestY - 10),
            endPoint: CGPoint(x: 0, y: size.height)))
        var bed = canvas
        bed.clip(to: front)
        // Mottling: broad soft patches of darker and paler sand, so the
        // bed is not one flat gradient.
        var rng = TankPaint.Seeded(0x5A4D)
        for k in 0..<16 {
            let mx = rng.next(0, size.width)
            let top = sandTop(atX: mx, in: size)
            let my = top + rng.next(0.15, 0.9) * max(0, size.height - top)
            let mw = rng.next(70, 190), mh = rng.next(8, 20)
            let tone = k.isMultiple(of: 2) ? TankPaint.color(sand.speckDark, 0.09)
                : TankPaint.color(sand.speckLight, 0.10)
            bed.fill(Path(ellipseIn: CGRect(x: mx - mw / 2, y: my - mh / 2, width: mw, height: mh)),
                     with: .radialGradient(Gradient(colors: [tone, tone.opacity(0)]),
                                           center: CGPoint(x: mx, y: my), startRadius: 0, endRadius: mw / 2))
        }
        drawRipples(canvas: &bed, size: size, sand: sand)
        // Grains: fine and bright on aragonite, chunky on basalt.
        var lightGrains = Path()
        var darkGrains = Path()
        for speck in Self.sandSpeckles {
            let sx = speck.x * size.width
            let top = sandTop(atX: sx, in: size)
            let depth = speck.y
            let sy = top + 3 + depth * depth * max(0, size.height - top - 4)
            let r = speck.r * sand.grain * (0.6 + depth * 0.8)
            let rect = CGRect(x: sx - r, y: sy - r * 0.6, width: r * 2, height: r * 1.2)
            if speck.light { lightGrains.addEllipse(in: rect) } else { darkGrains.addEllipse(in: rect) }
        }
        bed.fill(lightGrains, with: .color(TankPaint.color(sand.speckLight, min(1, 0.30 * sand.grainAlpha))))
        bed.fill(darkGrains, with: .color(TankPaint.color(sand.speckDark, min(1, 0.26 * sand.grainAlpha))))
        drawPebbles(canvas: &bed, size: size, sand: sand)
        // The crest: a broad soft glow under a thin bright edge, so the
        // dune tops read lit from above.
        var crest = Path()
        var x = -2.0
        crest.move(to: CGPoint(x: x, y: sandTop(atX: x, in: size)))
        while x <= size.width + 2 {
            crest.addLine(to: CGPoint(x: x, y: sandTop(atX: x, in: size)))
            x += max(4, size.width / 200)
        }
        var glow = bed
        glow.blendMode = .plusLighter
        glow.stroke(crest, with: .color(TankPaint.color(sand.crest, 0.14)),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round))
        bed.stroke(crest, with: .color(TankPaint.color(sand.crest, 0.55)), lineWidth: 1.4)
        // Night and the dark themes take the bed down with the water.
        let night = isDarkTheme ? max(0.55, nightFactor(t: t)) : nightFactor(t: t)
        if night > 0.01 {
            var n = bed
            n.blendMode = .multiply
            let tint = TankPaint.mix(TankPaint.RGB(1, 1, 1), TankPaint.RGB(0.20, 0.28, 0.52), night * 0.62)
            n.fill(front, with: .color(TankPaint.color(tint)))
        }
    }

    /// Ripple marks: long low crests the current has combed into the
    /// bed, each a soft shaded lee under a faint lit brow, closer
    /// together and finer toward the crest and broader toward the glass
    /// — the perspective of a flat floor. They wander, break and pick
    /// up again, so they never read as ruled lines.
    private func drawRipples(canvas: inout GraphicsContext, size: CGSize, sand: SandPalette) {
        var shade = Path()
        var light = Path()
        var rng = TankPaint.Seeded(0x21_99)
        let rows = 7
        for row in 0..<rows {
            let v = Double(row + 1) / Double(rows + 1)
            let depth = v * v
            let amplitude = 1.2 + depth * 3.5
            let wavelength = 90 + depth * 120
            let phase = rng.next(0, .pi * 2)
            var x = rng.next(-80, 0)
            while x < size.width + 20 {
                let len = rng.next(140, 380)
                let offset = rng.next(-3, 3)
                var seg = Path()
                var sx = x
                var first = true
                while sx <= x + len {
                    let top = sandTop(atX: sx, in: size)
                    let y = top + 8 + depth * max(0, size.height - top - 14) + offset
                        + amplitude * sin(sx / wavelength * .pi * 2 + phase)
                    if first { seg.move(to: CGPoint(x: sx, y: y)); first = false } else {
                        seg.addLine(to: CGPoint(x: sx, y: y))
                    }
                    sx += 10
                }
                shade.addPath(seg)
                light.addPath(seg.offsetBy(dx: 0, dy: -(1 + depth * 1.4)))
                x += len + rng.next(20, 90)
            }
        }
        canvas.stroke(shade, with: .color(TankPaint.color(sand.rippleShade, 0.16)),
                      style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        canvas.stroke(light, with: .color(TankPaint.color(sand.rippleLight, 0.16)),
                      style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
    }

    /// Pebbles and shell chips half set into the sand, bigger toward the
    /// glass, each lit from above with a tight contact shadow.
    private func drawPebbles(canvas: inout GraphicsContext, size: CGSize, sand: SandPalette) {
        var rng = TankPaint.Seeded(0x9EB)
        for k in 0..<30 {
            let px = rng.next(0, size.width)
            let top = sandTop(atX: px, in: size)
            let depth = rng.next(0.05, 0.95)
            let py = top + 4 + depth * depth * max(0, size.height - top - 8)
            let pw = (2.4 + rng.next(0, 3.4)) * (0.6 + depth * 0.9) * (substrateKey == "black" ? 1.3 : 1)
            let ph = pw * rng.next(0.55, 0.72)
            let shellChip = k % 5 == 0
            let lit = shellChip ? TankPaint.RGB(1.0, 0.93, 0.88) : TankPaint.mix(sand.speckLight, .init(1, 1, 1), 0.2)
            let base = shellChip ? TankPaint.RGB(0.90, 0.70, 0.62) : TankPaint.mix(sand.body, sand.foot, 0.3)
            let shade = shellChip ? TankPaint.RGB(0.55, 0.36, 0.30) : sand.foot
            contactShadow(canvas: &canvas, x: px + pw * 0.12, y: py + ph * 0.38, halfW: pw * 0.62, alpha: 0.28)
            canvas.fill(Path(ellipseIn: CGRect(x: px - pw / 2, y: py - ph / 2, width: pw, height: ph)),
                        with: .radialGradient(
                            Gradient(colors: [TankPaint.color(lit, 0.95), TankPaint.color(base, 0.95),
                                              TankPaint.color(shade, 0.95)]),
                            center: CGPoint(x: px - pw * 0.18, y: py - ph * 0.32),
                            startRadius: 0, endRadius: pw * 0.72))
        }
    }

    /// A soft elliptical shadow pooled on the sand — the gradient is
    /// drawn in a scaled context so it fades on every side.
    func groundShadow(canvas: inout GraphicsContext, x: Double, y: Double,
                      halfW: Double, halfH: Double = 4.5, alpha: Double) {
        var s = canvas
        s.translateBy(x: x, y: y)
        s.scaleBy(x: halfW, y: halfH)
        s.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
               with: .radialGradient(
                   Gradient(colors: [.black.opacity(alpha), .clear]),
                   center: .zero, startRadius: 0, endRadius: 1))
    }

    /// Where a piece meets the sand: a wide soft pool, offset a touch
    /// away from the light, over a tight dark core right under its foot
    /// — what makes a thing sit on the bed instead of hovering on it.
    func contactShadow(canvas: inout GraphicsContext, x: Double, y: Double,
                       halfW: Double, alpha: Double = 0.34) {
        groundShadow(canvas: &canvas, x: x + halfW * 0.10, y: y + 1,
                     halfW: halfW * 1.25, halfH: max(2.5, halfW * 0.16), alpha: alpha * 0.7)
        groundShadow(canvas: &canvas, x: x, y: y,
                     halfW: halfW * 0.92, halfH: max(1.4, halfW * 0.06), alpha: alpha)
    }

    /// The glass itself: the tank's corners fall away, darkness pools
    /// along the bottom, a faint reflection streaks the upper left and
    /// a thin cool edge catches the light along the pane's rim — the
    /// pane you look through.
    func drawGlass(canvas: inout GraphicsContext, size: CGSize) {
        let radius = max(size.width, size.height)
        canvas.fill(Path(CGRect(origin: .zero, size: size)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: .clear, location: 0.5),
                            .init(color: .black.opacity(0.26), location: 1),
                        ]),
                        center: CGPoint(x: size.width * 0.5, y: size.height * 0.45),
                        startRadius: radius * 0.30, endRadius: radius * 0.80))
        canvas.fill(Path(CGRect(x: 0, y: size.height * 0.80,
                                width: size.width, height: size.height * 0.20)),
                    with: .linearGradient(
                        Gradient(colors: [.clear, .black.opacity(0.20)]),
                        startPoint: CGPoint(x: 0, y: size.height * 0.80),
                        endPoint: CGPoint(x: 0, y: size.height)))
        var g = canvas
        g.blendMode = .plusLighter
        var streak = g
        streak.translateBy(x: size.width * 0.16, y: size.height * 0.12)
        streak.rotate(by: .radians(-0.55))
        streak.fill(Path(roundedRect: CGRect(x: -size.width * 0.30, y: -16,
                                             width: size.width * 0.60, height: 32),
                         cornerRadius: 16),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.045), location: 0.5),
                            .init(color: .clear, location: 1),
                        ]),
                        startPoint: CGPoint(x: 0, y: -16), endPoint: CGPoint(x: 0, y: 16)))
        // The pane's rim: a hairline of light down the left edge and
        // along the bottom, where the glass's thickness shows.
        g.fill(Path(CGRect(x: 0, y: 0, width: 1.5, height: size.height)),
               with: .linearGradient(
                   Gradient(colors: [.white.opacity(0.10), .white.opacity(0.02)]),
                   startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        g.fill(Path(CGRect(x: 0, y: size.height - 1.5, width: size.width, height: 1.5)),
               with: .color(.white.opacity(0.05)))
    }

    /// Slow flecks drifting with the water as soft glowing motes, in
    /// two depth layers — the near ones are bigger, brighter & a touch
    /// faster. `density` scales the count; Reduce Motion stills them.
    /// The seed goes through `scatter` (a murmur-style scramble):
    /// FNV-1a's low bits cluster on sequential tags, which used to
    /// park the motes in visible rows.
    func drawPlankton(canvas: inout GraphicsContext, size: CGSize, t: Double,
                      density: Double, front: Bool) {
        let still = reduceMotion
        let tt = still ? 0.0 : t
        let count = Int((44 * density).rounded())
        // The dark themes' motes are bioluminescent — cyan and teal
        // pulses instead of dust catching the light.
        let lit = isDarkTheme
        let light = water.light
        for i in 0..<count {
            let h = scatter(AquariumModel.stableHash("plankton-field"), i)
            let isFront = (h >> 56) & 1 == 1
            guard isFront == front else { continue }
            let x0 = Double(h & 0xFFFF) / 0xFFFF
            let y0 = Double((h >> 16) & 0xFFFF) / 0xFFFF
            let phase = Double((h >> 32) & 0xFF) / 0xFF * .pi * 2
            let drift = (h >> 40) & 1 == 0 ? 1.0 : -1.0
            // Near layer 1.6–3.4 px and soft, far layer 0.8–1.8 px.
            let r = (front ? 1.6 : 0.8) + Double((h >> 44) & 0xFF) / 0xFF * (front ? 1.8 : 1.0)
            let x = frac(x0 + drift * tt * (front ? 0.010 : 0.005)
                         + 0.018 * sin(tt * 0.20 + phase)) * size.width
            // Stay in the water column, off the bed.
            let y = (0.10 + frac(y0 + 0.018 * sin(tt * 0.26 + phase)) * 0.70) * size.height
            let twinkle = still ? 0.8 : 0.55 + 0.45 * sin(t * 0.6 + phase)
            let alpha = (front ? 0.14 : 0.08)
                + Double((h >> 48) & 0xFF) / 0xFF * (front ? 0.16 : 0.10)
            let moteColor = lit
                ? (((h >> 50) & 1) == 0
                   ? Color(red: 0.30, green: 0.95, blue: 0.85)
                   : Color(red: 0.25, green: 0.70, blue: 0.95))
                : TankPaint.color(TankPaint.mix(light, .init(1, 1, 1), 0.5))
            canvas.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(
                            Gradient(colors: [moteColor.opacity(alpha * twinkle * (lit ? 1.6 : 1)),
                                              .clear]),
                            center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
        }
        // Deeper still in the dark themes: the lantern-fish glimmers —
        // a handful of distant dots blinking on their own slow clocks.
        if lit && !front {
            for i in 0..<9 {
                var h = AquariumModel.stableHash("lantern-\(i)")
                h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
                let lx = Double(h & 0xFFFF) / 0xFFFF * size.width
                let ly = (0.35 + Double((h >> 16) & 0xFFFF) / 0xFFFF * 0.5) * size.height
                // Each blinks on a seeded ~2–6 s window.
                let period = 2 + Double((h >> 32) & 0xFF) / 0xFF * 4
                let on = frac(t / period + Double((h >> 40) & 0xFF) / 0xFF) < 0.18
                guard on else { continue }
                let lr = 1.2 + Double((h >> 48) & 0x3) * 0.6
                var g = canvas
                g.blendMode = .plusLighter
                g.fill(Path(ellipseIn: CGRect(x: lx - lr * 3, y: ly - lr * 3,
                                              width: lr * 6, height: lr * 6)),
                       with: .radialGradient(
                           Gradient(colors: [Color(red: 0.60, green: 0.95, blue: 0.90).opacity(0.55),
                                             .clear]),
                           center: CGPoint(x: lx, y: ly), startRadius: 0,
                           endRadius: lr * 3))
            }
        }
    }

    /// Ambient bubbles — half streaming off the chest, half seeded at
    /// random spots in the sand — each a glassy sphere: a faint body
    /// that darkens toward its lower rim, a bright rim on top and a
    /// glint where the surface light catches it. They wobble up from
    /// the bed and pop just under the surface. The seed goes through
    /// `scatter` so the rise phases don't fall into a ladder.
    func drawBubbles(canvas: inout GraphicsContext, size: CGSize, t: Double, density: Double) {
        let count = Int((9 * density).rounded())
        let chestX = Self.decor.first(where: { $0.kind == .chest })?.x ?? 0.5
        let still = reduceMotion
        for i in 0..<count {
            let h = scatter(AquariumModel.stableHash("bubble-seed"), i)
            let nearChest = (h >> 52) & 1 == 0
            let x0 = nearChest
                ? chestX + (Double((h >> 54) & 0xFF) / 0xFF - 0.5) * 0.10
                : Double(h & 0xFFFF) / 0xFFFF
            let phase = Double((h >> 16) & 0xFF) / 0xFF * .pi * 2
            let speed = 0.04 + Double((h >> 24) & 0xFF) / 0xFF * 0.09
            let r = 1.2 + Double((h >> 32) & 0xFF) / 0xFF * 3.4
            let rise = frac(Double((h >> 40) & 0xFF) / 0xFF + (still ? 0 : t) * speed)
            // Each bubble staggers its own amount at its own rate.
            let wobble = 2.5 + Double((h >> 48) & 0xF) / 0xF * 8.5
            let x = x0 * size.width
                + (still ? 0 : sin(t * (0.9 + speed * 6) + phase) * wobble)
            if rise > 0.92 {
                // The pop: a quick expanding ring just under the
                // meniscus, then gone — where a bubble's story ends.
                let pop = clamp01((rise - 0.92) / 0.08)
                let pr = r + pop * 6
                var ring = canvas
                ring.opacity = (1 - pop) * 0.35
                ring.stroke(Path(ellipseIn: CGRect(x: x - pr, y: 9 - pr,
                                                   width: pr * 2, height: pr * 2)),
                            with: .color(.white), lineWidth: 0.8)
                continue
            }
            let floorY = sandTop(atX: x, in: size) - 3
            let y = floorY - rise * (floorY - 8)
            drawBubble(canvas: &canvas, at: CGPoint(x: x, y: y), radius: r, alpha: 1)
        }
    }

    /// One glassy bubble — the tank's single bubble look, shared by the
    /// ambient stream, the bubble wall and the trick rings' spray.
    func drawBubble(canvas: inout GraphicsContext, at p: CGPoint, radius r: Double, alpha: Double) {
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        canvas.fill(Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: .white.opacity(0.04 * alpha), location: 0),
                            .init(color: .white.opacity(0.10 * alpha), location: 0.75),
                            .init(color: .white.opacity(0.26 * alpha), location: 1),
                        ]),
                        center: CGPoint(x: p.x, y: p.y + r * 0.1), startRadius: 0, endRadius: r))
        canvas.stroke(Path(ellipseIn: rect),
                      with: .linearGradient(
                          Gradient(colors: [.white.opacity(0.55 * alpha), .white.opacity(0.15 * alpha)]),
                          startPoint: CGPoint(x: p.x, y: rect.minY), endPoint: CGPoint(x: p.x, y: rect.maxY)),
                      lineWidth: max(0.6, r * 0.16))
        canvas.fill(Path(ellipseIn: CGRect(x: p.x - r * 0.52, y: p.y - r * 0.58,
                                           width: r * 0.42, height: r * 0.32)),
                    with: .color(.white.opacity(0.75 * alpha)))
    }
}
