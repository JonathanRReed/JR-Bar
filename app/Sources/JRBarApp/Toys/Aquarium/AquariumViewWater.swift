import AppKit
import JRBarCore
import SwiftUI

/// The water column: each theme's gradient and the light through it.
extension AquariumView {
    // MARK: Water

    /// One theme's water (docs/TOYS.md shop): the column's colour from
    /// the surface (0) down to the floor (1), the colour of the light
    /// that comes through the surface, and how strongly it falls in
    /// shafts — the abyss has no sun at all.
    struct TankWater {
        var stops: [(location: Double, rgb: TankPaint.RGB)]
        var light: TankPaint.RGB
        var shafts: Double
    }

    /// Seven stops down the column, at the depths every theme shares.
    private static func column(_ rgbs: [(Double, Double, Double)]) -> [(location: Double, rgb: TankPaint.RGB)] {
        let locations = [0, 0.12, 0.30, 0.52, 0.72, 0.88, 1.0]
        return zip(locations, rgbs).map { ($0, TankPaint.RGB($1.0, $1.1, $1.2)) }
    }

    /// The water the game starts with: aquamarine under the surface,
    /// teal, then a deep blue that keeps a green cast all the way down.
    private static let classicWater = TankWater(stops: column([
        (0.50, 0.84, 0.78), (0.29, 0.69, 0.70), (0.13, 0.51, 0.63), (0.06, 0.33, 0.54),
        (0.04, 0.22, 0.45), (0.03, 0.15, 0.37), (0.02, 0.09, 0.27)]),
        light: TankPaint.RGB(1.0, 0.97, 0.84), shafts: 1)

    /// Every theme's water. The deep stops keep their cast all the way
    /// down, so the far water reads as distance, not as a flat wall.
    private static let waters: [String: TankWater] = [
        "classic": classicWater,
        "reef": TankWater(stops: column([
            (0.40, 0.78, 0.84), (0.22, 0.62, 0.76), (0.10, 0.45, 0.68), (0.05, 0.30, 0.57),
            (0.03, 0.19, 0.47), (0.02, 0.12, 0.37), (0.015, 0.07, 0.27)]),
            light: TankPaint.RGB(1.0, 0.98, 0.88), shafts: 1),
        "lagoon": TankWater(stops: column([
            (0.60, 0.93, 0.82), (0.40, 0.84, 0.76), (0.22, 0.66, 0.70), (0.11, 0.46, 0.60),
            (0.06, 0.30, 0.49), (0.04, 0.19, 0.38), (0.03, 0.11, 0.28)]),
            light: TankPaint.RGB(1.0, 0.99, 0.86), shafts: 1.15),
        "twilight": TankWater(stops: column([
            (0.44, 0.54, 0.80), (0.30, 0.42, 0.70), (0.17, 0.30, 0.58), (0.10, 0.19, 0.46),
            (0.06, 0.12, 0.36), (0.04, 0.08, 0.28), (0.025, 0.05, 0.20)]),
            light: TankPaint.RGB(0.88, 0.86, 1.0), shafts: 0.6),
        "midnight": TankWater(stops: column([
            (0.11, 0.18, 0.33), (0.08, 0.14, 0.29), (0.055, 0.10, 0.24), (0.035, 0.07, 0.20),
            (0.025, 0.05, 0.16), (0.018, 0.035, 0.13), (0.012, 0.025, 0.10)]),
            light: TankPaint.RGB(0.70, 0.80, 1.0), shafts: 0.35),
        "dawn": TankWater(stops: column([
            (0.88, 0.64, 0.66), (0.70, 0.57, 0.69), (0.44, 0.50, 0.68), (0.23, 0.38, 0.60),
            (0.12, 0.26, 0.49), (0.06, 0.16, 0.38), (0.035, 0.09, 0.28)]),
            light: TankPaint.RGB(1.0, 0.84, 0.72), shafts: 0.8),
        "kelp": TankWater(stops: column([
            (0.56, 0.77, 0.45), (0.37, 0.64, 0.42), (0.21, 0.50, 0.39), (0.11, 0.36, 0.35),
            (0.06, 0.24, 0.29), (0.035, 0.15, 0.22), (0.02, 0.09, 0.16)]),
            light: TankPaint.RGB(1.0, 0.97, 0.74), shafts: 1),
        "abyss": TankWater(stops: column([
            (0.05, 0.08, 0.17), (0.035, 0.06, 0.14), (0.025, 0.045, 0.11), (0.018, 0.03, 0.08),
            (0.012, 0.02, 0.06), (0.008, 0.015, 0.045), (0.005, 0.01, 0.03)]),
            light: TankPaint.RGB(0.55, 0.75, 1.0), shafts: 0),
        "sunset": TankWater(stops: column([
            (0.94, 0.58, 0.32), (0.82, 0.44, 0.39), (0.57, 0.31, 0.49), (0.33, 0.21, 0.51),
            (0.19, 0.13, 0.45), (0.10, 0.08, 0.35), (0.055, 0.045, 0.26)]),
            light: TankPaint.RGB(1.0, 0.76, 0.50), shafts: 0.9),
        "blackwater": TankWater(stops: column([
            (0.55, 0.44, 0.27), (0.44, 0.35, 0.21), (0.33, 0.25, 0.16), (0.23, 0.17, 0.11),
            (0.15, 0.11, 0.075), (0.095, 0.07, 0.05), (0.055, 0.04, 0.03)]),
            light: TankPaint.RGB(1.0, 0.84, 0.54), shafts: 0.45),
    ]

    /// The water for a theme key — "classic" when the key is unknown.
    static func water(forTheme themeKey: String) -> TankWater {
        waters[themeKey] ?? classicWater
    }

    var water: TankWater { Self.water(forTheme: themeKey) }

    /// The water column's gradient per theme — the shop's theme items
    /// recolour the tank.
    var waterStops: [Gradient.Stop] { Self.waterStops(forTheme: themeKey) }

    /// The water column's stops for a theme key — also the shop's
    /// swatch for that theme.
    static func waterStops(forTheme themeKey: String) -> [Gradient.Stop] {
        water(forTheme: themeKey).stops.map {
            Gradient.Stop(color: TankPaint.color($0.rgb), location: $0.location)
        }
    }

    /// The water's colour at a height (0 the surface … 1 the floor) —
    /// what a thing at that depth fades into, and what the far water
    /// behind it looks like.
    func waterRGB(at unitY: Double) -> TankPaint.RGB {
        let stops = water.stops
        let y = min(1, max(0, unitY))
        var lower = stops[0]
        for stop in stops {
            if stop.location >= y {
                let span = max(0.0001, stop.location - lower.location)
                return TankPaint.mix(lower.rgb, stop.rgb, (y - lower.location) / span)
            }
            lower = stop
        }
        return stops[stops.count - 1].rgb
    }

    /// Where the light comes from: the sun sits above the surface a
    /// little left of centre, so every lit crown, shaft and shadow in
    /// the tank agrees on one direction.
    func sunPoint(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * 0.34, y: -size.height * 0.10)
    }

    /// The veil for a thing standing at `depth` (0 the back of the bed
    /// … 1 the glass): the water's colour low in the column, pulled
    /// toward the night water as the night deepens.
    func atmosphere(depth: Double, t: Double) -> TankPaint.Atmosphere {
        let night = isDarkTheme ? max(0.55, nightFactor(t: t)) : nightFactor(t: t)
        let far = 1 - min(1, max(0, depth))
        let deep = waterRGB(at: 0.62)
        let haze = TankPaint.mix(deep, Self.nightWater, night * 0.55)
        return TankPaint.Atmosphere(haze: 0.08 + 0.46 * far * far + night * 0.30,
                                    hazeColor: haze, light: water.light, night: night)
    }

    /// The deep blue the whole tank sinks toward after dark.
    static let nightWater = TankPaint.RGB(0.015, 0.035, 0.11)

    /// The column of water itself: the theme's gradient, the sky's
    /// light pooled under the surface over the sun's side, a moon by
    /// night, and a cool counter-glow low on the far side so the deep
    /// never goes dead flat. Drawn in the still pass; the only moving
    /// light is the shafts and caustics of the light pass.
    func drawWater(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let rect = Path(CGRect(origin: .zero, size: size))
        canvas.fill(rect, with: .linearGradient(
            Gradient(stops: waterStops),
            startPoint: CGPoint(x: size.width / 2, y: 0),
            endPoint: CGPoint(x: size.width / 2, y: size.height)))
        let w = water
        let night = nightFactor(t: t)
        let day = (1 - night * 0.85) * (isDarkTheme ? 0.45 : 1)
        let reach = max(size.width, size.height)
        var glow = canvas
        glow.blendMode = .plusLighter
        let sun = sunPoint(in: size)
        glow.fill(rect, with: .radialGradient(
            Gradient(stops: [
                .init(color: TankPaint.color(w.light, 0.34 * day), location: 0),
                .init(color: TankPaint.color(w.light, 0.12 * day), location: 0.28),
                .init(color: TankPaint.color(w.light, 0.03 * day), location: 0.6),
                .init(color: .clear, location: 1),
            ]),
            center: sun, startRadius: 0, endRadius: reach * 0.78))
        // The moon: a small cool bloom where the sun was.
        if night > 0.05 {
            let moon = TankPaint.RGB(0.72, 0.82, 1.0)
            glow.fill(rect, with: .radialGradient(
                Gradient(stops: [
                    .init(color: TankPaint.color(moon, 0.16 * night), location: 0),
                    .init(color: TankPaint.color(moon, 0.04 * night), location: 0.4),
                    .init(color: .clear, location: 1),
                ]),
                center: sun, startRadius: 0, endRadius: reach * 0.5))
        }
        let cool = waterRGB(at: 0.3)
        glow.fill(rect, with: .radialGradient(
            Gradient(colors: [TankPaint.color(cool, 0.10 * day), .clear]),
            center: CGPoint(x: size.width * 0.90, y: size.height * 0.58),
            startRadius: 0, endRadius: size.width * 0.45))
        drawFleetMood(canvas: &canvas, size: size, t: t)
    }

    /// The night over the far half of the tank — the water, the back
    /// wall and the far bed sink toward the night blue together. The
    /// near pieces carry their own night in their veil, and the fish
    /// stay the brightest thing in the water.
    func drawNight(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let night = nightFactor(t: t)
        let strength = isDarkTheme ? 0.18 + 0.18 * night : 0.72 * night
        guard strength > 0.01 else { return }
        var n = canvas
        n.blendMode = .multiply
        let tint = TankPaint.mix(TankPaint.RGB(1, 1, 1), TankPaint.RGB(0.16, 0.24, 0.50), strength)
        n.fill(Path(CGRect(origin: .zero, size: size)), with: .color(TankPaint.color(tint)))
    }

    /// The water reading the fleet, very subtly (docs/TOYS.md) — no
    /// words, only the column: a quota window running low cools and
    /// dims it, an unreviewed failure hazes it with silt settling toward
    /// the sand, and a fresh reset lands one warm shaft that fades over a
    /// few minutes. Calm water draws nothing extra.
    private func drawFleetMood(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let mood = fixture.map { $0.mood ?? .calm }
            ?? toy?.waterMood(at: Date(timeIntervalSince1970: t)) ?? .calm
        guard mood != .calm else { return }
        let rect = Path(CGRect(origin: .zero, size: size))
        if mood.low > 0 {
            canvas.fill(rect, with: .color(Color(red: 0.03, green: 0.06, blue: 0.19)
                                             .opacity(0.24 * mood.low)))
        }
        if mood.cloud > 0 {
            let silt = Color(red: 0.52, green: 0.56, blue: 0.50)
            canvas.fill(rect, with: .linearGradient(
                Gradient(stops: [
                    .init(color: silt.opacity(0.02 * mood.cloud), location: 0),
                    .init(color: silt.opacity(0.11 * mood.cloud), location: 1),
                ]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
        if mood.shaft > 0 {
            var lit = canvas
            lit.blendMode = .plusLighter
            var beam = Path()
            beam.move(to: CGPoint(x: size.width * 0.52, y: 0))
            beam.addLine(to: CGPoint(x: size.width * 0.64, y: 0))
            beam.addLine(to: CGPoint(x: size.width * 0.74, y: size.height))
            beam.addLine(to: CGPoint(x: size.width * 0.50, y: size.height))
            beam.closeSubpath()
            let warm = Color(red: 1.0, green: 0.93, blue: 0.74)
            lit.fill(beam, with: .linearGradient(
                Gradient(stops: [
                    .init(color: warm.opacity(0.20 * mood.shaft), location: 0),
                    .init(color: warm.opacity(0.07 * mood.shaft), location: 0.6),
                    .init(color: warm.opacity(0), location: 1),
                ]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
    }

    /// One light shaft: its lean off straight down, how wide it is,
    /// its brightness and its slow clocks. Seeded once.
    private struct Shaft {
        var angle, halfWidth, strength, swayRate, breatheRate, phase: Double
    }

    /// Seven shafts fanning out of the sun, wide and narrow mixed.
    private static let shafts: [Shaft] = (0..<7).map { i in
        var rng = TankPaint.Seeded(AquariumModel.stableHash("shaft-\(i)"))
        let spread = (Double(i) - 3) / 3
        return Shaft(angle: spread * 0.34 + rng.next(-0.04, 0.04),
                     halfWidth: rng.next(0.012, 0.042),
                     strength: rng.next(0.55, 1.0),
                     swayRate: rng.next(0.030, 0.065),
                     breatheRate: rng.next(0.05, 0.11),
                     phase: rng.next(0, .pi * 2))
    }

    /// Soft light shafts fanning down from the sun through the surface.
    /// Each shaft is one long soft ellipse — a radial gradient squeezed
    /// across the beam — so its edges and its fade with depth come from
    /// a single fill, no layers. They sway a degree or two and breathe;
    /// Reduce Motion holds them still. This draws in the additive pass,
    /// so a shaft that reaches the floor lights the sand it lands on.
    func drawGodRays(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let w = water
        let blackwater = themeKey == "blackwater"
        guard w.shafts > 0 else { return }
        let night = nightFactor(t: t)
        let light = TankPaint.mix(w.light, TankPaint.RGB(0.70, 0.80, 1.0), night)
        let level = w.shafts * (1 - night * 0.72)
        let apex = CGPoint(x: size.width * 0.34, y: -size.height * 0.62)
        let length = size.height * 1.05
        let still = reduceMotion
        for (i, shaft) in Self.shafts.enumerated() where !blackwater || i % 3 == 1 {
            let sway = still ? 0 : sin(t * shaft.swayRate + shaft.phase) * 0.022
            let breathe = still ? 0.75
                : 0.62 + 0.38 * sin(t * shaft.breatheRate + shaft.phase * 1.7)
            let alpha = 0.16 * shaft.strength * breathe * level
            // Where the shaft crosses the surface: its brightest point
            // sits a little under it.
            let angle = shaft.angle + sway
            let toSurface = -apex.y / max(0.2, cos(angle))
            var r = canvas
            r.translateBy(x: apex.x, y: apex.y)
            r.rotate(by: .radians(-angle))
            r.translateBy(x: 0, y: toSurface + size.height * 0.08)
            r.scaleBy(x: shaft.halfWidth * size.width / length, y: 1)
            r.fill(Path(ellipseIn: CGRect(x: -length, y: -length, width: length * 2, height: length * 2)),
                   with: .radialGradient(
                       Gradient(stops: [
                           .init(color: TankPaint.color(light, alpha), location: 0),
                           .init(color: TankPaint.color(light, alpha * 0.55), location: 0.35),
                           .init(color: TankPaint.color(light, alpha * 0.15), location: 0.7),
                           .init(color: .clear, location: 1),
                       ]),
                       center: .zero, startRadius: 0, endRadius: length))
        }
    }

    /// Where the shafts land on the bed, 0…1 across the tank — the
    /// sand's caustics burn brightest there.
    private func shaftLandings(in size: CGSize) -> [Double] {
        let apex = CGPoint(x: size.width * 0.34, y: -size.height * 0.62)
        let floor = size.height * 0.88 - apex.y
        return Self.shafts.map { (apex.x + tan($0.angle) * floor) / max(1, size.width) }
    }

    /// One corner of the sand's caustic lattice: where it sits on the
    /// bed (u across, v from the far bank to the glass) and its own
    /// slow wobble.
    private struct CausticCorner {
        var u, v, phase, rate: Double
    }

    /// The lattice's corners, seeded once: 46 columns by 9 rows,
    /// jittered hard so no two cells match.
    private static let causticColumns = 46
    private static let causticRows = 9
    private static let causticCorners: [CausticCorner] = {
        var rng = TankPaint.Seeded(0xCA05_71C5)
        var corners: [CausticCorner] = []
        for row in 0...causticRows {
            for col in 0...causticColumns {
                let stagger = row.isMultiple(of: 2) ? 0 : 0.5
                corners.append(CausticCorner(
                    u: (Double(col) + stagger + rng.next(-0.42, 0.42)) / Double(causticColumns) - 0.02,
                    v: min(1, max(0, (Double(row) + rng.next(-0.32, 0.32)) / Double(causticRows))),
                    phase: rng.next(0, .pi * 2), rate: rng.next(0.5, 1.1)))
            }
        }
        return corners
    }()

    /// Caustics on the bed: the net of light the rippling surface
    /// focuses onto the sand. The whole bed is lit in a layer, then
    /// each cell of a wobbling lattice is cut back out — rounded, a
    /// little smaller than its corners — so what stays lit is the net
    /// between the cells, fine and flat far off, broader toward the
    /// glass. The net burns brightest where the shafts land. Reduce
    /// Motion holds it still.
    func drawSandCaustics(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let w = water
        guard w.shafts > 0, size.width > 1, size.height > 1 else { return }
        let night = nightFactor(t: t)
        let level = w.shafts * (1 - night * 0.8)
        guard level > 0.05 else { return }
        // White aragonite bounces the light back — its net burns
        // brighter; dark gravel drinks it.
        let boost = substrateKey == "white" ? 1.4 : substrateKey == "black" ? 0.55 : 1.0
        let tt = reduceMotion ? 0 : t
        let bed = sandPath(in: size) { sandTop(atX: $0, in: size) }
        let far = sandTop(atX: size.width / 2, in: size) - 14
        let depth = size.height + 6 - far
        let columns = Self.causticColumns + 1
        let points: [CGPoint] = Self.causticCorners.map { corner in
            // Rows crowd together far off: the bed seen at a slant.
            let v = corner.v * corner.v * 0.85 + corner.v * 0.15
            let cell = size.width / Double(Self.causticColumns)
            let wobble = 0.22 * cell * (0.4 + 0.6 * v)
            let x = corner.u * size.width + sin(tt * corner.rate + corner.phase) * wobble
            let y = far + v * depth + cos(tt * corner.rate * 0.8 + corner.phase) * wobble * (0.15 + 0.35 * v)
            return CGPoint(x: x, y: y)
        }
        var holes = Path()
        for row in 0..<Self.causticRows {
            for col in 0..<Self.causticColumns {
                let a = points[row * columns + col], b = points[row * columns + col + 1]
                let c = points[(row + 1) * columns + col + 1], d = points[(row + 1) * columns + col]
                let cx = (a.x + b.x + c.x + d.x) / 4, cy = (a.y + b.y + c.y + d.y) / 4
                let v = Double(row) / Double(Self.causticRows)
                let seed = Self.causticCorners[row * columns + col].phase
                let keep = 0.86 - 0.03 * v + 0.05 * sin(seed * 3.7)
                func pull(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: cx + (p.x - cx) * keep, y: cy + (p.y - cy) * keep)
                }
                let q = [pull(a), pull(b), pull(c), pull(d)]
                holes.move(to: CGPoint(x: (q[3].x + q[0].x) / 2, y: (q[3].y + q[0].y) / 2))
                for k in 0..<4 {
                    let next = q[(k + 1) % 4]
                    holes.addQuadCurve(to: CGPoint(x: (q[k].x + next.x) / 2, y: (q[k].y + next.y) / 2),
                                       control: q[k])
                }
                holes.closeSubpath()
            }
        }
        // Where the shafts land the net is bright; between them it dims.
        var stops: [Gradient.Stop] = [.init(color: .white.opacity(0.35), location: 0)]
        for x in shaftLandings(in: size).sorted() where x > 0.02 && x < 0.98 {
            stops.append(.init(color: .white.opacity(0.35), location: x - 0.09))
            stops.append(.init(color: .white, location: x))
            stops.append(.init(color: .white.opacity(0.35), location: x + 0.09))
        }
        stops.append(.init(color: .white.opacity(0.35), location: 1))
        stops.sort { $0.location < $1.location }
        let light = w.light
        var lit = canvas
        lit.opacity = min(1, level * boost)
        lit.drawLayer { layer in
            layer.clip(to: bed)
            layer.fill(bed, with: .linearGradient(
                Gradient(stops: [
                    .init(color: TankPaint.color(light, 0.03), location: 0),
                    .init(color: TankPaint.color(light, 0.10), location: 0.3),
                    .init(color: TankPaint.color(light, 0.03), location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: far), endPoint: CGPoint(x: 0, y: size.height)))
            layer.blendMode = .destinationOut
            layer.fill(holes, with: .color(.black))
            layer.blendMode = .destinationIn
            layer.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(stops: stops), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
        }
    }

    /// A slow luminance drift through the column: two broad, soft
    /// light pools sliding against each other on multi-minute periods.
    /// The water feels like it moves even between the rays; Reduce
    /// Motion holds both still.
    func drawWaterSheen(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let spots: [(cx: Double, cy: Double, r: Double, period: Double,
                     phase: Double, alpha: Double)] = [
            (0.42, 0.26, 0.34, 190, 0, 0.045),
            (0.68, 0.58, 0.26, 310, 2.1, 0.030),
        ]
        let light = water.light
        let day = 1 - nightFactor(t: t) * 0.8
        for spot in spots {
            let drift = reduceMotion ? 0 : sin(t * .pi * 2 / spot.period + spot.phase)
            var s = canvas
            s.translateBy(x: size.width * (spot.cx + 0.15 * drift), y: size.height * spot.cy)
            s.rotate(by: .radians(-0.45))
            s.scaleBy(x: 1, y: 0.62)
            s.fill(Path(ellipseIn: CGRect(x: -size.width * spot.r, y: -size.width * spot.r,
                                          width: size.width * spot.r * 2,
                                          height: size.width * spot.r * 2)),
                   with: .radialGradient(
                       Gradient(colors: [TankPaint.color(light, spot.alpha * day), .clear]),
                       center: .zero, startRadius: 0,
                       endRadius: size.width * spot.r))
        }
    }

    /// The glints under the surface: short bright slivers where the
    /// ripples focus the light, seeded once.
    private static let glints: [(x: Double, y: Double, len: Double, rate: Double, phase: Double)] =
        (0..<64).map { i in
            var rng = TankPaint.Seeded(AquariumModel.stableHash("glint-\(i)"))
            return (rng.next(0, 1), rng.next(0, 1), rng.next(0.4, 1), rng.next(0.5, 1.4),
                    rng.next(0, .pi * 2))
        }

    /// The water's surface seen from below: a bright band where the sky
    /// comes through, the rippled underside of the surface catching the
    /// light, a row of glints shimmering where the ripples focus it, and
    /// the thin bright meniscus against the glass. Reduce Motion holds
    /// the ripples still.
    func drawSurface(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let light = water.light
        let day = (1 - nightFactor(t: t) * 0.7) * (isDarkTheme ? 0.5 : 1)
        let still = reduceMotion
        let tt = still ? 0 : t
        let band = min(48, size.height * 0.08)
        canvas.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: band)),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: TankPaint.color(light, 0.22 * day), location: 0),
                            .init(color: TankPaint.color(light, 0.07 * day), location: 0.35),
                            .init(color: .clear, location: 1),
                        ]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: band)))
        // The underside: the surface's ripples, lit above and shadowed
        // below, so the waterline reads as a moving sheet.
        var underside = Path()
        underside.move(to: CGPoint(x: 0, y: 0))
        var x = 0.0
        while x <= size.width + 8 {
            let y = 7 + sin(x * 0.021 + tt * 0.55) * 2.2 + sin(x * 0.057 - tt * 0.8) * 1.2
            underside.addLine(to: CGPoint(x: x, y: y))
            x += 8
        }
        underside.addLine(to: CGPoint(x: size.width + 8, y: 0))
        underside.closeSubpath()
        canvas.fill(underside, with: .linearGradient(
            Gradient(colors: [TankPaint.color(light, 0.20 * day), TankPaint.color(light, 0.06 * day)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: 10)))
        var lip = Path()
        x = 0
        while x <= size.width + 8 {
            let y = 7 + sin(x * 0.021 + tt * 0.55) * 2.2 + sin(x * 0.057 - tt * 0.8) * 1.2
            if x == 0 { lip.move(to: CGPoint(x: x, y: y)) } else { lip.addLine(to: CGPoint(x: x, y: y)) }
            x += 8
        }
        canvas.stroke(lip, with: .color(TankPaint.color(light, 0.30 * day)), lineWidth: 1.1)
        canvas.stroke(lip.offsetBy(dx: 0, dy: 2), with: .color(.black.opacity(0.05 * day)), lineWidth: 2)
        // Glints: three brightness buckets, one fill each.
        var buckets = [Path(), Path(), Path()]
        for g in Self.glints {
            let shimmer = still ? 0.5 : 0.5 + 0.5 * sin(tt * g.rate + g.phase)
            guard shimmer > 0.25 else { continue }
            let gx = (g.x * (size.width + 60) + tt * 6 * g.rate).truncatingRemainder(dividingBy: size.width + 60) - 30
            let gy = 10 + g.y * g.y * band * 0.8
            let len = (8 + 22 * g.len) * (1 - g.y * 0.5)
            let hgt = max(0.8, 1.8 * (1 - g.y * 0.6))
            buckets[min(2, Int(shimmer * 3))].addEllipse(in: CGRect(x: gx - len / 2, y: gy - hgt / 2,
                                                                    width: len, height: hgt))
        }
        var glow = canvas
        glow.blendMode = .plusLighter
        for (k, bucket) in buckets.enumerated() {
            glow.fill(bucket, with: .color(TankPaint.color(light, (0.08 + Double(k) * 0.08) * day)))
        }
        // The meniscus: a bright hairline with a soft halo under it.
        var line = Path()
        line.move(to: CGPoint(x: 0, y: 1.2))
        x = 0
        while x <= size.width {
            line.addLine(to: CGPoint(x: x, y: 1.2 + sin(x * 0.05 + tt * 0.4) * 0.6))
            x += 8
        }
        canvas.stroke(line, with: .color(.white.opacity(0.16 * max(0.4, day))), lineWidth: 3.4)
        canvas.stroke(line, with: .color(.white.opacity(0.45 * max(0.4, day))), lineWidth: 1.1)
    }
}
