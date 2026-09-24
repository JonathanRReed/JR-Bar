import AppKit
import JRBarCore
import SwiftUI

/// The water column: each theme's gradient and the light through it.
extension AquariumView {
    // MARK: Water

    /// The column of water itself: a many-stop gradient from the bright
    /// green-teal surface down to a deep indigo floor — more stops in
    /// the deep half now, so the column keeps a blue-green cast all the
    /// way down instead of collapsing to flat navy — a warm glow
    /// where the light comes in, and a faint cool counter-glow low on
    /// the right so the far side never goes dead flat. Drawn in the
    /// still pass; the only animated parts are the two slow washes.
    /// The water column's gradient per theme (docs/TOYS.md shop):
    /// the shop's theme items recolour the tank — a stop list per
    /// theme id, "classic" the default the game starts with.
    var waterStops: [Gradient.Stop] {
        switch themeKey {
        case "reef":
            return [
                .init(color: Color(red: 0.36, green: 0.72, blue: 0.78), location: 0),
                .init(color: Color(red: 0.20, green: 0.58, blue: 0.72), location: 0.12),
                .init(color: Color(red: 0.10, green: 0.42, blue: 0.64), location: 0.30),
                .init(color: Color(red: 0.05, green: 0.28, blue: 0.54), location: 0.52),
                .init(color: Color(red: 0.03, green: 0.17, blue: 0.44), location: 0.72),
                .init(color: Color(red: 0.02, green: 0.10, blue: 0.34), location: 0.88),
                .init(color: Color(red: 0.015, green: 0.05, blue: 0.24), location: 1),
            ]
        case "lagoon":
            return [
                .init(color: Color(red: 0.55, green: 0.90, blue: 0.78), location: 0),
                .init(color: Color(red: 0.36, green: 0.80, blue: 0.72), location: 0.12),
                .init(color: Color(red: 0.20, green: 0.62, blue: 0.66), location: 0.30),
                .init(color: Color(red: 0.10, green: 0.42, blue: 0.56), location: 0.52),
                .init(color: Color(red: 0.05, green: 0.26, blue: 0.45), location: 0.72),
                .init(color: Color(red: 0.03, green: 0.15, blue: 0.34), location: 0.88),
                .init(color: Color(red: 0.02, green: 0.08, blue: 0.25), location: 1),
            ]
        case "twilight":
            return [
                .init(color: Color(red: 0.42, green: 0.52, blue: 0.78), location: 0),
                .init(color: Color(red: 0.28, green: 0.40, blue: 0.68), location: 0.12),
                .init(color: Color(red: 0.16, green: 0.28, blue: 0.56), location: 0.30),
                .init(color: Color(red: 0.09, green: 0.17, blue: 0.44), location: 0.52),
                .init(color: Color(red: 0.05, green: 0.10, blue: 0.34), location: 0.72),
                .init(color: Color(red: 0.03, green: 0.06, blue: 0.26), location: 0.88),
                .init(color: Color(red: 0.02, green: 0.03, blue: 0.18), location: 1),
            ]
        case "midnight":
            return [
                .init(color: Color(red: 0.10, green: 0.16, blue: 0.30), location: 0),
                .init(color: Color(red: 0.07, green: 0.12, blue: 0.27), location: 0.12),
                .init(color: Color(red: 0.05, green: 0.09, blue: 0.23), location: 0.30),
                .init(color: Color(red: 0.03, green: 0.06, blue: 0.19), location: 0.52),
                .init(color: Color(red: 0.02, green: 0.04, blue: 0.15), location: 0.72),
                .init(color: Color(red: 0.015, green: 0.03, blue: 0.12), location: 0.88),
                .init(color: Color(red: 0.01, green: 0.02, blue: 0.09), location: 1),
            ]
        case "dawn":
            return [
                .init(color: Color(red: 0.86, green: 0.62, blue: 0.66), location: 0),
                .init(color: Color(red: 0.68, green: 0.55, blue: 0.68), location: 0.12),
                .init(color: Color(red: 0.42, green: 0.48, blue: 0.66), location: 0.30),
                .init(color: Color(red: 0.22, green: 0.36, blue: 0.58), location: 0.52),
                .init(color: Color(red: 0.11, green: 0.24, blue: 0.47), location: 0.72),
                .init(color: Color(red: 0.05, green: 0.14, blue: 0.36), location: 0.88),
                .init(color: Color(red: 0.03, green: 0.08, blue: 0.26), location: 1),
            ]
        case "kelp":
            return [
                .init(color: Color(red: 0.52, green: 0.74, blue: 0.42), location: 0),
                .init(color: Color(red: 0.34, green: 0.62, blue: 0.40), location: 0.12),
                .init(color: Color(red: 0.19, green: 0.48, blue: 0.38), location: 0.30),
                .init(color: Color(red: 0.10, green: 0.34, blue: 0.34), location: 0.52),
                .init(color: Color(red: 0.05, green: 0.22, blue: 0.28), location: 0.72),
                .init(color: Color(red: 0.03, green: 0.13, blue: 0.21), location: 0.88),
                .init(color: Color(red: 0.02, green: 0.08, blue: 0.15), location: 1),
            ]
        case "abyss":
            return [
                .init(color: Color(red: 0.05, green: 0.08, blue: 0.17), location: 0),
                .init(color: Color(red: 0.035, green: 0.06, blue: 0.14), location: 0.12),
                .init(color: Color(red: 0.025, green: 0.045, blue: 0.11), location: 0.30),
                .init(color: Color(red: 0.018, green: 0.03, blue: 0.08), location: 0.52),
                .init(color: Color(red: 0.012, green: 0.02, blue: 0.06), location: 0.72),
                .init(color: Color(red: 0.008, green: 0.015, blue: 0.045), location: 0.88),
                .init(color: Color(red: 0.005, green: 0.01, blue: 0.03), location: 1),
            ]
        case "sunset":
            return [
                .init(color: Color(red: 0.92, green: 0.55, blue: 0.30), location: 0),
                .init(color: Color(red: 0.80, green: 0.42, blue: 0.38), location: 0.12),
                .init(color: Color(red: 0.55, green: 0.30, blue: 0.48), location: 0.30),
                .init(color: Color(red: 0.32, green: 0.20, blue: 0.50), location: 0.52),
                .init(color: Color(red: 0.18, green: 0.12, blue: 0.44), location: 0.72),
                .init(color: Color(red: 0.09, green: 0.07, blue: 0.34), location: 0.88),
                .init(color: Color(red: 0.05, green: 0.04, blue: 0.25), location: 1),
            ]
        case "blackwater":
            return [
                .init(color: Color(red: 0.52, green: 0.42, blue: 0.26), location: 0),
                .init(color: Color(red: 0.42, green: 0.33, blue: 0.20), location: 0.12),
                .init(color: Color(red: 0.32, green: 0.24, blue: 0.15), location: 0.30),
                .init(color: Color(red: 0.22, green: 0.16, blue: 0.10), location: 0.52),
                .init(color: Color(red: 0.14, green: 0.10, blue: 0.07), location: 0.72),
                .init(color: Color(red: 0.09, green: 0.06, blue: 0.05), location: 0.88),
                .init(color: Color(red: 0.05, green: 0.04, blue: 0.03), location: 1),
            ]
        default:
            return [
                .init(color: Color(red: 0.46, green: 0.79, blue: 0.72), location: 0),
                .init(color: Color(red: 0.27, green: 0.65, blue: 0.65), location: 0.12),
                .init(color: Color(red: 0.13, green: 0.49, blue: 0.60), location: 0.30),
                .init(color: Color(red: 0.06, green: 0.31, blue: 0.51), location: 0.52),
                .init(color: Color(red: 0.035, green: 0.19, blue: 0.41), location: 0.72),
                .init(color: Color(red: 0.02, green: 0.11, blue: 0.31), location: 0.88),
                .init(color: Color(red: 0.015, green: 0.06, blue: 0.22), location: 1),
            ]
        }
    }

    func drawWater(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        canvas.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(stops: waterStops),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height)))
        // The dark themes' moonlight: the same warm glow dimmed &
        // cooled, and a deeper night wash below.
        let dark = isDarkTheme
        var glow = canvas
        glow.blendMode = .plusLighter
        glow.fill(Path(CGRect(origin: .zero, size: size)),
                  with: .radialGradient(
                      Gradient(colors: [(dark
                                         ? Color(red: 0.72, green: 0.80, blue: 0.98)
                                         : Color(red: 0.95, green: 0.88, blue: 0.66))
                                        .opacity(dark ? 0.13 : 0.22), .clear]),
                      center: CGPoint(x: size.width * 0.36, y: -size.height * 0.10),
                      startRadius: 0, endRadius: size.width * 0.62))
        glow.fill(Path(CGRect(origin: .zero, size: size)),
                  with: .radialGradient(
                      Gradient(colors: [Color(red: 0.20, green: 0.50, blue: 0.62)
                                        .opacity(dark ? 0.06 : 0.10), .clear]),
                      center: CGPoint(x: size.width * 0.88, y: size.height * 0.55),
                      startRadius: 0, endRadius: size.width * 0.5))
        // The day/night wash (docs/TOYS.md): the clock the settings
        // picked — the four-minute breathe or the real one. Reduce
        // Motion holds it at a soft dusk.
        let night = nightFactor(t: t)
        canvas.fill(Path(CGRect(origin: .zero, size: size)),
                    with: .color(Color(red: 0.02, green: 0.05, blue: 0.22)
                                 .opacity(dark ? 0.10 + 0.06 * night : 0.10 * night)))
        canvas.fill(Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: Color(red: 0.99, green: 0.82, blue: 0.45)
                                    .opacity(0.05 * (1 - night)), location: 0),
                            .init(color: .clear, location: 0.5),
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)))
        drawFleetMood(canvas: &canvas, size: size, t: t)
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

    /// Soft light shafts leaning down from the surface. Each ray is its
    /// own layer: a gradient across the beam gives the soft edges and a
    /// masking gradient fades it with depth, so there are no hard
    /// polygon sides. They breathe & sway a couple of degrees; Reduce
    /// Motion holds them still. This draws in the additive pass, so a
    /// ray that reaches the floor lights the sand it lands on.
    func drawGodRays(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        // The abyss has no sun; blackwater's tannin murk swallows all
        // but a few shafts; night dims whatever the theme allows.
        guard themeKey != "abyss" else { return }
        let count = themeKey == "blackwater" ? 2 : 5
        let daylight = 1 - nightFactor(t: t) * 0.55
        let rayColor = Color(red: 0.86, green: 0.97, blue: 0.93)
        for i in 0..<count {
            let h = AquariumModel.stableHash("ray-\(i)")
            let jitter = Double(h & 0xFF) / 0xFF
            let phase = Double((h >> 8) & 0xFF) / 0xFF * .pi * 2
            let speed = 0.030 + Double((h >> 16) & 0xFF) / 0xFF * 0.035
            let anchorX = size.width * (0.08 + 0.21 * Double(i) + jitter * 0.07)
            let halfW = 18 + Double((h >> 24) & 0xFF) / 0xFF * 34
            let lean = 0.20 + jitter * 0.18
            let sway = reduceMotion ? 0 : sin(t * speed + phase) * 0.030
            let breathe = (reduceMotion ? 0.45 : 0.36 + 0.32 * sin(t * 0.06 + phase * 1.7))
                * daylight
            // Off-centre bright core so the beam isn't a flat band.
            let core = 0.4 + Double((h >> 32) & 0xFF) / 0xFF * 0.2

            var r = canvas
            r.blendMode = .plusLighter
            r.drawLayer { layer in
                layer.translateBy(x: anchorX, y: -14)
                layer.rotate(by: .radians(lean + sway))
                let length = size.height * 1.35
                let beam = CGRect(x: -halfW, y: 0, width: halfW * 2, height: length)
                layer.fill(Path(beam), with: .linearGradient(
                    Gradient(stops: [
                        .init(color: rayColor.opacity(0), location: 0),
                        .init(color: rayColor.opacity(0.035 * breathe), location: core - 0.28),
                        .init(color: rayColor.opacity(0.10 * breathe), location: core),
                        .init(color: rayColor.opacity(0.035 * breathe), location: core + 0.28),
                        .init(color: rayColor.opacity(0), location: 1),
                    ]),
                    startPoint: CGPoint(x: -halfW, y: 0),
                    endPoint: CGPoint(x: halfW, y: 0)))
                // Fade with depth — destinationIn keeps the soft edges.
                layer.blendMode = .destinationIn
                layer.fill(Path(beam), with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.45),
                        .init(color: .white.opacity(0), location: 0.95),
                    ]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: length)))
            }
        }
    }

    /// Caustic dapples: a few soft pools of warm light riding the dune
    /// crest, wandering back and forth and breathing on slow, seeded
    /// phases — sunlight focused through the surface ripples onto the
    /// bed. Drawn in the additive pass so they read as light, and
    /// seeded through the same murmur-style scramble the speckles use
    /// so FNV-1a's low bits can't park them in a row.
    func drawSandCaustics(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        // White aragonite bounces the light back — its pools burn
        // brighter; dark gravel drinks it.
        let boost = substrateKey == "white" ? 1.7
            : substrateKey == "black" ? 0.6 : 1.0
        for i in 0..<4 {
            var h = AquariumModel.stableHash("caustic-\(i)")
            h ^= h >> 33
            h &*= 0xff51afd7ed558ccd
            h ^= h >> 33
            let x0 = Double(h & 0xFFFF) / 0xFFFF
            let phase = Double((h >> 16) & 0xFF) / 0xFF * .pi * 2
            // Ping-pong wander: sin keeps the pool sliding without the
            // wrap-around jump a `frac` drift would take at the wall.
            let wander = reduceMotion ? 0.5
                : 0.5 + 0.5 * sin(t * (0.05 + Double((h >> 24) & 0xFF) / 0xFF * 0.05) + phase)
            let cx = size.width * (0.08 + 0.84 * (x0 * 0.45 + wander * 0.55))
            let cy = sandTop(atX: cx, in: size) + 5 + Double((h >> 32) & 0xF)
            let rx = 46 + Double((h >> 40) & 0xFF) / 0xFF * 58
            let ry = rx * (0.15 + Double((h >> 48) & 0xF) / 0xF * 0.09)
            let breathe = reduceMotion ? 0.55
                : 0.55 + 0.45 * sin(t * 0.23 + phase * 1.9)
            var s = canvas
            s.translateBy(x: cx, y: cy)
            s.scaleBy(x: rx, y: ry)
            s.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                   with: .radialGradient(
                       Gradient(colors: [
                           Color(red: 1.0, green: 0.94, blue: 0.74).opacity(0.10 * breathe * boost),
                           .clear]),
                       center: .zero, startRadius: 0, endRadius: 1))
        }
    }

    /// A slow luminance drift through the column: two broad, soft
    /// light pools sliding against each other on multi-minute periods.
    /// The water feels like it moves even between the rays; Reduce
    /// Motion holds both still.
    func drawWaterSheen(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let spots: [(cx: Double, cy: Double, r: Double, period: Double,
                     phase: Double, alpha: Double)] = [
            (0.42, 0.26, 0.34, 190, 0, 0.050),
            (0.68, 0.58, 0.26, 310, 2.1, 0.034),
        ]
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
                       Gradient(colors: [
                           Color(red: 0.75, green: 0.95, blue: 0.88).opacity(spot.alpha),
                           .clear]),
                       center: .zero, startRadius: 0,
                       endRadius: size.width * spot.r))
        }
    }

    /// The water's surface: a soft bright band just under the glass,
    /// three wandering caustic bands (wide, low-contrast strokes), and
    /// the thin bright meniscus line on top.
    func drawSurface(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        canvas.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 36)),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .white.opacity(0.16), location: 0),
                            .init(color: .white.opacity(0.05), location: 0.5),
                            .init(color: .clear, location: 1),
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: 36)))
        for r in 0..<3 {
            let y0 = 10 + Double(r) * 9
            let amp = 2.0 + Double(r) * 0.8
            let drift = reduceMotion ? 0 : t * (0.34 + Double(r) * 0.13)
            var wave = Path()
            wave.move(to: CGPoint(x: 0, y: y0))
            var x = 0.0
            while x <= size.width {
                let y = y0 + sin(x * 0.045 + drift + Double(r) * 2.3) * amp
                    + sin(x * 0.011 - drift * 0.6) * amp * 0.5
                wave.addLine(to: CGPoint(x: x, y: y))
                x += 8
            }
            let shimmer = reduceMotion ? 0.6 : 0.60 + 0.40 * sin(t * 0.45 + Double(r) * 2.1)
            canvas.stroke(wave,
                          with: .color(.white.opacity((0.065 - Double(r) * 0.016) * shimmer)),
                          style: StrokeStyle(lineWidth: 7 - Double(r) * 1.8, lineCap: .round))
        }
        // The meniscus: a bright hairline with a barely-there wobble,
        // plus a soft halo a couple of pixels under it.
        var line = Path()
        line.move(to: CGPoint(x: 0, y: 1.4))
        var x = 0.0
        while x <= size.width {
            line.addLine(to: CGPoint(x: x, y: 1.4
                                     + sin(x * 0.05 + (reduceMotion ? 0 : t * 0.4)) * 0.7))
            x += 8
        }
        canvas.stroke(line, with: .color(.white.opacity(0.18)), lineWidth: 3.4)
        canvas.stroke(line, with: .color(.white.opacity(0.42)), lineWidth: 1.2)
    }
}
