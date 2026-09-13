import AppKit
import JRBarCore
import SwiftUI

/// The tank (docs/TOYS.md): one `TimelineView` + `Canvas`. Fish
/// positions are integrated from each `Fish`'s constants and the frame
/// clock, so `toy.fish` only has to change when the session set does,
/// and the timeline pauses while the window is covered.
struct AquariumView: View {
    let toy: AquariumToy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Read the observable surface in `body` so the card's tracked
        // reads stay honest even while the timeline is paused.
        let fish = toy.fish
        let showLabels = toy.store?.state.aquarium.showLabels ?? true
        let density = max(0.1, toy.store?.state.aquarium.density ?? 1)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: toy.windowOccluded)) { context in
            let t = context.date.timeIntervalSince1970
            let mains = mainsByID(fish)
            // Deep lanes draw first: the near fish swim over them.
            let ordered = fish.sorted { depth(of: $0, mains: mains) > depth(of: $1, mains: mains) }
            Canvas { canvas, size in
                drawWater(canvas: &canvas, size: size)
                drawGodRays(canvas: &canvas, size: size, t: t)
                drawCaustics(canvas: &canvas, size: size, t: t)
                drawSand(canvas: &canvas, size: size)
                drawDecor(canvas: &canvas, size: size, t: t, density: density, front: false)
                drawJellyfish(canvas: &canvas, size: size, t: t)
                drawPlankton(canvas: &canvas, size: size, t: t, density: density, front: false)
                drawBubbles(canvas: &canvas, size: size, t: t, density: density)
                // Mains lay out first so fry can orbit their parents.
                var layouts: [String: Layout] = [:]
                for aFish in ordered where !aFish.isFry && !aFish.isRetired(at: context.date) {
                    layouts[aFish.id] = layout(of: aFish, in: size, at: t, now: context.date)
                }
                for aFish in ordered where !aFish.isRetired(at: context.date) {
                    let parent = parentContext(of: aFish, mains: mains, layouts: layouts)
                    let l = layouts[aFish.id]
                        ?? layout(of: aFish, in: size, at: t, now: context.date, parent: parent)
                    drawFish(canvas: &canvas, size: size, t: t, now: context.date,
                             fish: aFish, layout: l, parent: parent, showLabels: showLabels)
                }
                drawSnail(canvas: &canvas, size: size, t: t)
                drawDecor(canvas: &canvas, size: size, t: t, density: density, front: true)
                drawPlankton(canvas: &canvas, size: size, t: t, density: density, front: true)
                drawVignette(canvas: &canvas, size: size)
                if fish.isEmpty || fish.allSatisfy({ $0.isRetired(at: context.date) }) {
                    drawEmpty(canvas: &canvas, size: size, t: t)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.02, green: 0.10, blue: 0.24))
    }

    /// The tank's adult fish by id — fry anchor to these.
    private func mainsByID(_ fish: [Fish]) -> [String: Fish] {
        Dictionary(fish.filter { !$0.isFry }.map { ($0.id, $0) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Draw order: a fry rides at its school's depth, not its own lane.
    private func depth(of fish: Fish, mains: [String: Fish]) -> Double {
        if fish.isFry, let anchor = fish.anchorID.flatMap({ mains[$0] }) {
            return anchor.lane * 0.85
        }
        return fish.lane
    }

    /// The fish a fry schools around, with its already-computed layout.
    private func parentContext(of fish: Fish, mains: [String: Fish],
                               layouts: [String: Layout]) -> (fish: Fish, layout: Layout)? {
        guard let id = fish.anchorID, let parent = mains[id], let l = layouts[id] else { return nil }
        return (parent, l)
    }

    // MARK: Water

    /// The column of water itself: a gradient that warms & lightens
    /// toward the surface, a soft warm glow where the light comes in,
    /// and the bright surface line.
    private func drawWater(canvas: inout GraphicsContext, size: CGSize) {
        canvas.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(red: 0.40, green: 0.70, blue: 0.68), location: 0),
                    .init(color: Color(red: 0.17, green: 0.47, blue: 0.57), location: 0.22),
                    .init(color: Color(red: 0.07, green: 0.29, blue: 0.47), location: 0.55),
                    .init(color: Color(red: 0.03, green: 0.16, blue: 0.33), location: 0.82),
                    .init(color: Color(red: 0.01, green: 0.07, blue: 0.18), location: 1),
                ]),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height)))
        // Warmth where the light comes in, off-centre like a low sun.
        var glow = canvas
        glow.blendMode = .plusLighter
        glow.fill(Path(CGRect(origin: .zero, size: size)),
                  with: .radialGradient(
                      Gradient(colors: [Color(red: 0.95, green: 0.85, blue: 0.62).opacity(0.20), .clear]),
                      center: CGPoint(x: size.width * 0.36, y: -size.height * 0.08),
                      startRadius: 0, endRadius: size.width * 0.6))
        canvas.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 1)),
                    with: .color(.white.opacity(0.22)))
    }

    /// Three light shafts leaning down from the surface. They breathe
    /// & sway slowly; Reduce Motion holds them still.
    private func drawGodRays(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        for i in 0..<3 {
            let h = AquariumModel.stableHash("ray-\(i)")
            let jitter = Double(h & 0xFF) / 0xFF
            let phase = Double((h >> 8) & 0xFF) / 0xFF * .pi * 2
            let speed = 0.05 + Double((h >> 16) & 0xFF) / 0xFF * 0.06
            let anchorX = size.width * (0.14 + 0.34 * Double(i) + jitter * 0.10)
            let topWidth = 30 + Double((h >> 24) & 0xFF) / 0xFF * 44
            let lean = 0.28 + jitter * 0.16
            let sway = reduceMotion ? 0 : sin(t * speed + phase) * 0.07
            let breathe = reduceMotion ? 0.7 : 0.55 + 0.45 * sin(t * 0.09 + phase * 1.7)

            var r = canvas
            r.blendMode = .plusLighter
            r.translateBy(x: anchorX, y: -8)
            r.rotate(by: .radians(lean + sway))
            let length = size.height * 1.3
            // A widening beam, plus a brighter narrow core inside it.
            var beam = Path()
            beam.move(to: CGPoint(x: -topWidth / 2, y: 0))
            beam.addLine(to: CGPoint(x: topWidth / 2, y: 0))
            beam.addLine(to: CGPoint(x: topWidth, y: length))
            beam.addLine(to: CGPoint(x: -topWidth, y: length))
            beam.closeSubpath()
            r.fill(beam, with: .linearGradient(
                Gradient(colors: [Color(red: 0.82, green: 0.94, blue: 0.90).opacity(0.10 * breathe), .clear]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: length)))
            let core = topWidth * 0.38
            var inner = Path()
            inner.move(to: CGPoint(x: -core / 2, y: 0))
            inner.addLine(to: CGPoint(x: core / 2, y: 0))
            inner.addLine(to: CGPoint(x: core * 1.4, y: length))
            inner.addLine(to: CGPoint(x: -core * 1.4, y: length))
            inner.closeSubpath()
            r.fill(inner, with: .linearGradient(
                Gradient(colors: [Color(red: 0.90, green: 0.97, blue: 0.94).opacity(0.07 * breathe), .clear]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: length)))
        }
    }

    /// The shimmer band the surface throws just under the line: a soft
    /// bright wash plus three wandering wavelets that drift & glint.
    private func drawCaustics(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        canvas.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 30)),
                    with: .linearGradient(
                        Gradient(colors: [.white.opacity(0.10), .clear]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: 30)))
        for r in 0..<3 {
            let y0 = 8 + Double(r) * 7
            let amp = 1.6 + Double(r) * 0.6
            let drift = reduceMotion ? 0 : t * (0.5 + Double(r) * 0.18)
            var wave = Path()
            wave.move(to: CGPoint(x: 0, y: y0))
            var x = 0.0
            while x <= size.width {
                let y = y0 + sin(x * 0.05 + drift + Double(r) * 2.3) * amp
                    + sin(x * 0.013 - drift * 0.6) * amp * 0.5
                wave.addLine(to: CGPoint(x: x, y: y))
                x += 9
            }
            let shimmer = reduceMotion ? 0.7 : 0.5 + 0.5 * sin(t * 0.7 + Double(r) * 2.1)
            canvas.stroke(wave, with: .color(.white.opacity((0.09 - Double(r) * 0.02) * shimmer)),
                          lineWidth: 1)
        }
    }

    /// A soft floor: a few seeded dunes along the bottom with a lit rim.
    private func drawSand(canvas: inout GraphicsContext, size: CGSize) {
        func dune(_ i: Int) -> Double {
            10 + Double(AquariumModel.stableHash("dune-\(i)") & 0xFF) / 0xFF * 12
        }
        var sand = Path()
        var rim = Path()
        sand.move(to: CGPoint(x: 0, y: size.height))
        sand.addLine(to: CGPoint(x: 0, y: size.height - dune(0)))
        rim.move(to: CGPoint(x: 0, y: size.height - dune(0)))
        for i in 0..<4 {
            let x1 = size.width * Double(i + 1) / 4
            let y1 = size.height - dune(i + 1)
            let control = CGPoint(x: x1 - size.width / 8,
                                  y: min(size.height - dune(i), y1) - 4)
            sand.addQuadCurve(to: CGPoint(x: x1, y: y1), control: control)
            rim.addQuadCurve(to: CGPoint(x: x1, y: y1), control: control)
        }
        sand.addLine(to: CGPoint(x: size.width, y: size.height))
        sand.closeSubpath()
        canvas.fill(sand, with: .linearGradient(
            Gradient(colors: [Color(red: 0.42, green: 0.37, blue: 0.25).opacity(0.55),
                              Color(red: 0.10, green: 0.11, blue: 0.15)]),
            startPoint: CGPoint(x: 0, y: size.height - 26),
            endPoint: CGPoint(x: 0, y: size.height)))
        canvas.stroke(rim, with: .color(Color(red: 0.55, green: 0.48, blue: 0.33).opacity(0.30)),
                      lineWidth: 1)
    }

    /// Dark falls off into the bottom corners.
    private func drawVignette(canvas: inout GraphicsContext, size: CGSize) {
        let radius = max(size.width, size.height) * 0.55
        for cornerX in [0.0, size.width] {
            canvas.fill(Path(CGRect(origin: .zero, size: size)),
                        with: .radialGradient(
                            Gradient(colors: [.black.opacity(0.28), .clear]),
                            center: CGPoint(x: cornerX, y: size.height),
                            startRadius: 0, endRadius: radius))
        }
    }

    /// Slow flecks drifting with the water. `density` scales the count;
    /// a hashed few draw in front of the fish — bigger, brighter &
    /// a touch faster, so the water has a foreground too.
    private func drawPlankton(canvas: inout GraphicsContext, size: CGSize, t: Double,
                              density: Double, front: Bool) {
        let count = Int((24 * density).rounded())
        for i in 0..<count {
            let h = AquariumModel.stableHash("plankton-\(i)")
            let isFront = (h >> 56) & 1 == 1
            guard isFront == front else { continue }
            let x0 = Double(h & 0xFFFF) / 0xFFFF
            let y0 = Double((h >> 16) & 0xFFFF) / 0xFFFF
            let phase = Double((h >> 32) & 0xFF) / 0xFF * .pi * 2
            let drift = (h >> 40) & 1 == 0 ? 1.0 : -1.0
            let r = (0.8 + Double((h >> 44) & 0xF) / 0xF * 1.4) * (front ? 1.4 : 0.8)
            let x = frac(x0 + drift * t * (front ? 0.010 : 0.006)) * size.width
            let y = frac(y0 + 0.02 * sin(t * 0.35 + phase)) * size.height
            let twinkle = reduceMotion ? 0.8 : 0.6 + 0.4 * sin(t * 0.8 + phase)
            canvas.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .color(.white.opacity((front ? 0.20 : 0.12) * twinkle)))
        }
    }

    /// Ambient bubbles rising off the floor; they pop at the surface.
    private func drawBubbles(canvas: inout GraphicsContext, size: CGSize, t: Double, density: Double) {
        let count = Int((7 * density).rounded())
        for i in 0..<count {
            let h = AquariumModel.stableHash("bubble-\(i)")
            let x0 = Double(h & 0xFFFF) / 0xFFFF
            let phase = Double((h >> 16) & 0xFF) / 0xFF * .pi * 2
            let speed = 0.05 + Double((h >> 24) & 0xFF) / 0xFF * 0.05
            let r = 1.5 + Double((h >> 32) & 0xF) / 0xF * 2.5
            let rise = frac(Double((h >> 40) & 0xFF) / 0xFF + t * speed)
            if rise > 0.97 { continue }
            let x = x0 * size.width + sin(t * 1.6 + phase) * 7
            let y = size.height * (1 - rise) - 8
            canvas.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                          with: .color(.white.opacity(0.35)), lineWidth: 0.8)
        }
    }

    // MARK: Decor

    /// The seeded dressing (docs/TOYS.md): kelp, rocks, corals, a
    /// starfish & a treasure chest, laid out by `AquariumModel.decorSet`
    /// so the tank looks the same every launch. `density` decides how
    /// much of the set shows — the signature pieces come first, so a
    /// sparse tank keeps them. `front` splits the set at depth 0.6:
    /// near kelp draws over the fish for a touch of foreground.
    private func drawDecor(canvas: inout GraphicsContext, size: CGSize, t: Double,
                           density: Double, front: Bool) {
        let decor = AquariumModel.decorSet()
        let shown = Int((Double(decor.count) * min(1, density)).rounded(.up))
        for piece in decor.prefix(shown) where (piece.depth > 0.6) == front {
            switch piece.kind {
            case .kelp: drawKelp(canvas: &canvas, size: size, t: t, piece: piece)
            case .rock: drawRocks(canvas: &canvas, size: size, piece: piece)
            case .coral: drawCoral(canvas: &canvas, size: size, piece: piece)
            case .starfish: drawStarfish(canvas: &canvas, size: size, piece: piece)
            case .chest: drawChest(canvas: &canvas, size: size, t: t, piece: piece)
            }
        }
    }

    /// One kelp strand: a ribbon rooted in the sand, leaning &
    /// swaying on a slow sine. Deep strands melt toward the water
    /// colour; Reduce Motion freezes the sway.
    private func drawKelp(canvas: inout GraphicsContext, size: CGSize, t: Double, piece: TankDecor) {
        let b = piece.bits
        let phase = Double(b & 0xFF) / 0xFF * .pi * 2
        let hgt = size.height * (0.26 + Double((b >> 8) & 0xFF) / 0xFF * 0.30) * piece.scale
        let baseX = piece.x * size.width
        let baseY = size.height - 6
        let lean = (Double((b >> 16) & 0xFF) / 0xFF - 0.5) * 46
        let sway = reduceMotion ? 0
            : sin(t * (0.30 + Double((b >> 24) & 0xFF) / 0xFF * 0.25) + phase) * 10
        let w = (5 + Double((b >> 32) & 0xF)) * piece.scale

        let top = baseY - hgt
        let tipX = baseX + lean + sway
        var blade = Path()
        blade.move(to: CGPoint(x: baseX - w / 2, y: baseY))
        blade.addCurve(to: CGPoint(x: tipX - w * 0.15, y: top),
                       control1: CGPoint(x: baseX - w / 2 + sway * 0.25, y: baseY - hgt * 0.4),
                       control2: CGPoint(x: tipX - sway * 0.5, y: top + hgt * 0.35))
        blade.addQuadCurve(to: CGPoint(x: tipX + w * 0.15, y: top),
                           control: CGPoint(x: tipX, y: top - 5))
        blade.addCurve(to: CGPoint(x: baseX + w / 2, y: baseY),
                       control1: CGPoint(x: tipX + sway * 0.6, y: top + hgt * 0.4),
                       control2: CGPoint(x: baseX + w / 2 + sway * 0.3, y: baseY - hgt * 0.45))
        blade.closeSubpath()

        let wash = 1 - piece.depth
        let kelp = Self.waterNS.blended(withFraction: 1 - wash * 0.55,
                                      of: NSColor(srgbRed: 0.12, green: 0.42, blue: 0.24, alpha: 1))
            ?? Self.waterNS
        canvas.fill(blade, with: .color(Color(nsColor: kelp).opacity(0.85 - wash * 0.35)))
        // A few leaflets stepping up the stalk, alternating sides.
        for k in 1...3 {
            let f = Double(k) / 3.6
            let lw = w * (1.2 - f * 0.5)
            let lx = baseX + (tipX - baseX) * f + (k % 2 == 0 ? 1 : -1) * w * 1.1
            let ly = baseY - hgt * f
            canvas.fill(Path(ellipseIn: CGRect(x: lx - lw * 0.5, y: ly - lw,
                                               width: lw, height: lw * 1.7)),
                        with: .color(Color(nsColor: kelp).opacity(0.7 - wash * 0.3)))
        }
    }

    /// A little cluster of pebbles sitting on the dune line.
    private func drawRocks(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = size.height - 4
        let rock = Color(red: 0.34, green: 0.32, blue: 0.29)
        for r in 0..<3 {
            let rw = (10 + Double((b >> UInt64(r * 8)) & 0xFF) / 0xFF * 16) * piece.scale
            let rh = rw * (0.45 + Double((b >> UInt64(r * 8 + 20)) & 0xFF) / 0xFF * 0.25)
            let rx = baseX + (Double(r) - 1) * rw * 0.55 + (Double((b >> UInt64(r * 4 + 40)) & 0xF) - 7)
            // The middle pebble rides up on the other two.
            let ry = baseY - rh / 2 - (r == 1 ? rh * 0.35 : 0)
            canvas.fill(Path(ellipseIn: CGRect(x: rx - rw / 2, y: ry - rh / 2,
                                               width: rw, height: rh)),
                        with: .color(rock.opacity(0.85)))
        }
    }

    /// A small coral branch: a trunk that forks twice, drawn as round
    /// strokes so the tips read soft.
    private func drawCoral(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = size.height - 8
        let hgt = (30 + Double(b & 0xFF) / 0xFF * 26) * piece.scale
        var coral = Path()
        func branch(_ from: CGPoint, _ angle: Double, _ len: Double, _ forks: Int) {
            let to = CGPoint(x: from.x + cos(angle) * len, y: from.y + sin(angle) * len)
            coral.move(to: from)
            coral.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2 + 3,
                                                        y: (from.y + to.y) / 2))
            guard forks > 0 else { return }
            let spread = 0.5 + Double((b >> UInt64(forks * 7 + 12)) & 0xFF) / 0xFF * 0.4
            branch(to, angle - spread, len * 0.62, forks - 1)
            branch(to, angle + spread * 0.8, len * 0.62, forks - 1)
        }
        branch(CGPoint(x: baseX, y: baseY),
               -.pi / 2 + (Double((b >> 8) & 0xFF) / 0xFF - 0.5) * 0.4,
               hgt * 0.55, 2)
        canvas.stroke(coral,
                      with: .color(Color(red: 0.85, green: 0.45, blue: 0.45).opacity(0.75)),
                      style: StrokeStyle(lineWidth: 2.6 * piece.scale, lineCap: .round))
    }

    /// A five-pointed star resting on the sand.
    private static let starPath: Path = {
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
        var s = canvas
        s.translateBy(x: piece.x * size.width, y: size.height - 10)
        s.rotate(by: .radians(Double(piece.bits & 0xFF) / 0xFF * .pi * 2))
        s.scaleBy(x: 16 * piece.scale, y: 16 * piece.scale)
        s.fill(Self.starPath,
               with: .color(Color(red: 0.90, green: 0.55, blue: 0.35).opacity(0.85)))
        s.fill(Path(ellipseIn: CGRect(x: -0.10, y: -0.10, width: 0.20, height: 0.20)),
               with: .color(.white.opacity(0.35)))
    }

    /// The treasure chest on the dune floor. Every few seconds it
    /// burps a single bubble — the tank's smallest joke.
    private func drawChest(canvas: inout GraphicsContext, size: CGSize, t: Double, piece: TankDecor) {
        let w = 36 * piece.scale
        let h = 24 * piece.scale
        let x = piece.x * size.width
        let y = size.height - 6
        let body = CGRect(x: x - w / 2, y: y - h * 0.62, width: w, height: h * 0.62)
        let lid = CGRect(x: x - w / 2 - 2, y: y - h, width: w + 4, height: h * 0.45)
        canvas.fill(Path(roundedRect: body, cornerRadius: 3),
                    with: .color(Color(red: 0.32, green: 0.22, blue: 0.12).opacity(0.9)))
        canvas.fill(Path(roundedRect: lid, cornerRadius: 6),
                    with: .color(Color(red: 0.40, green: 0.28, blue: 0.15).opacity(0.9)))
        canvas.stroke(Path(roundedRect: lid, cornerRadius: 6),
                      with: .color(.black.opacity(0.3)), lineWidth: 1)
        // The band & latch.
        canvas.fill(Path(CGRect(x: x - 2, y: y - h, width: 4, height: h)),
                    with: .color(Color(red: 0.75, green: 0.60, blue: 0.30).opacity(0.7)))
        guard !reduceMotion else { return }
        let period = 6 + Double(piece.bits & 0xFF) / 0xFF * 5
        let rise = frac(t / period + Double((piece.bits >> 8) & 0xFF) / 0xFF)
        guard rise < 0.6 else { return }
        let br = 1.5 + rise * 2
        let by = y - h - rise * size.height * 0.35
        canvas.stroke(Path(ellipseIn: CGRect(x: x - br, y: by - br, width: br * 2, height: br * 2)),
                      with: .color(.white.opacity(0.5 * (1 - rise / 0.6))), lineWidth: 0.8)
    }

    // MARK: Ambient life

    /// A jellyfish drifts through the mid-water every ~40 s: a
    /// translucent bell pulsing over four trailing tentacles. Reduce
    /// Motion parks it mid-tank, unpulsed.
    private func drawJellyfish(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let progress: Double
        let pulse: Double
        let alpha: Double
        if reduceMotion {
            progress = 0.45
            pulse = 0
            alpha = 0.35
        } else {
            let life = frac(t / 40 + 0.31) * 40
            guard life < 15 else { return }
            progress = life / 15
            pulse = sin(t * 1.9) * 0.10
            alpha = 0.45 * smooth(clamp01(min(progress / 0.18, (1 - progress) / 0.12)))
        }
        let x = size.width * (1.08 - 1.24 * progress)
        let y = size.height * (0.30 + 0.10 * sin(progress * .pi * 2 + 1))
        var j = canvas
        j.opacity = alpha
        j.translateBy(x: x, y: y)
        j.scaleBy(x: 34 * (1 + pulse), y: 30 * (1 - pulse))
        var bell = Path()
        bell.move(to: CGPoint(x: -0.5, y: 0.12))
        bell.addCurve(to: CGPoint(x: 0.5, y: 0.12),
                      control1: CGPoint(x: -0.52, y: -0.52),
                      control2: CGPoint(x: 0.52, y: -0.52))
        bell.addQuadCurve(to: CGPoint(x: -0.5, y: 0.12), control: CGPoint(x: 0, y: 0.30))
        bell.closeSubpath()
        j.fill(bell, with: .linearGradient(
            Gradient(colors: [Color(red: 0.95, green: 0.80, blue: 0.90).opacity(0.9), .clear]),
            startPoint: CGPoint(x: 0, y: -0.5), endPoint: CGPoint(x: 0, y: 0.3)))
        for k in 0..<4 {
            let tx = -0.30 + Double(k) * 0.20
            var tent = Path()
            tent.move(to: CGPoint(x: tx, y: 0.12))
            tent.addCurve(to: CGPoint(x: tx + sin(t * 1.3 + Double(k) * 1.7) * 0.08, y: 0.85),
                          control1: CGPoint(x: tx - 0.06, y: 0.35),
                          control2: CGPoint(x: tx + 0.06, y: 0.60))
            j.stroke(tent, with: .color(Color(red: 0.9, green: 0.75, blue: 0.85).opacity(0.6)),
                     lineWidth: 0.05)
        }
        j.fill(Path(ellipseIn: CGRect(x: -0.16, y: -0.30, width: 0.32, height: 0.30)),
               with: .color(.white.opacity(0.5)))
    }

    /// A snail inches along the sand — about four minutes a crossing.
    /// Reduce Motion sits it mid-tank.
    private func drawSnail(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let crawl = reduceMotion ? 0.42 : frac(t * 0.0042 + 0.6)
        let x = size.width * (0.06 + crawl * 0.88)
        let y = size.height - 7
        var s = canvas
        s.opacity = 0.85
        s.translateBy(x: x, y: y)
        s.scaleBy(x: 13, y: 10)
        let flesh = Color(red: 0.55, green: 0.45, blue: 0.34)
        var body = Path()
        body.move(to: CGPoint(x: -0.5, y: 0.05))
        body.addQuadCurve(to: CGPoint(x: 0.62, y: 0.02), control: CGPoint(x: 0.1, y: 0.16))
        body.addQuadCurve(to: CGPoint(x: 0.55, y: -0.18), control: CGPoint(x: 0.66, y: -0.08))
        body.addQuadCurve(to: CGPoint(x: -0.1, y: -0.14), control: CGPoint(x: 0.2, y: -0.26))
        body.addQuadCurve(to: CGPoint(x: -0.5, y: 0.05), control: CGPoint(x: -0.36, y: -0.08))
        body.closeSubpath()
        s.fill(body, with: .color(flesh))
        // The shell, with a hint of spiral.
        s.fill(Path(ellipseIn: CGRect(x: -0.42, y: -0.62, width: 0.58, height: 0.58)),
               with: .color(Color(red: 0.62, green: 0.40, blue: 0.24)))
        s.stroke(Path(ellipseIn: CGRect(x: -0.30, y: -0.50, width: 0.34, height: 0.34)),
                 with: .color(Color(red: 0.40, green: 0.25, blue: 0.14).opacity(0.8)),
                 lineWidth: 0.06)
        // Two eyestalks, because it is a screensaver.
        for dx in [0.42, 0.55] {
            var stalk = Path()
            stalk.move(to: CGPoint(x: dx - 0.1, y: -0.14))
            stalk.addQuadCurve(to: CGPoint(x: dx, y: -0.42), control: CGPoint(x: dx - 0.05, y: -0.30))
            s.stroke(stalk, with: .color(flesh), lineWidth: 0.05)
            s.fill(Path(ellipseIn: CGRect(x: dx - 0.045, y: -0.47, width: 0.09, height: 0.09)),
                   with: .color(.white.opacity(0.9)))
        }
    }

    // MARK: Fish

    /// Where a fish is right now: position, which way it faces, how far
    /// through its turn it is.
    private struct Layout {
        var x: Double = 0
        var y: Double = 0
        /// +1 faces right, -1 faces left.
        var facing: Double = 1
        /// Screen-space radians; positive pitches the nose down for
        /// either facing (the draw rotates by `pitch * facing`).
        var pitch: Double = 0
        /// 1 at cruise, ~0.2 mid-turn: the fish seen head-on.
        var thin: Double = 1
        var scale: Double = 1
        var opacity: Double = 1
        /// 0 at cruise … 1 deepest into a wall turn.
        var turn: Double = 0
        /// Tail-beat amplitude multiplier (0 stills the tail).
        var wag: Double = 1
        /// Where a surfacing fish started its rise; the bubble trail
        /// climbs from there.
        var riseFrom: Double = 0
    }

    /// The cruise patrol: a sinusoidal sweep between the walls, so the
    /// fish eases to a stop at the glass instead of mirror-flipping.
    /// `u` is the velocity proxy (±1 mid-tank, 0 at a wall) and `turn`
    /// grows through the turnaround.
    private func patrol(of fish: Fish, in size: CGSize, at t: Double, margin: Double)
        -> (x: Double, u: Double, turn: Double) {
        let h = AquariumModel.stableHash(fish.id)
        let x0 = Double((h >> 33) & 0x3FF) / 0x3FF
        // Deep lanes swim slower: parallax.
        let omega = Double.pi * fish.speed * (1 - fish.lane * 0.3)
        // The phase picks the start point on the sweep AND the first
        // direction, so `fish.direction` still means something.
        let s = min(1, max(-1, x0 * 2 - 1))
        let phase = fish.direction > 0 ? asin(s) : Double.pi - asin(s)
        let theta = omega * t + phase
        let u = cos(theta)
        let turn = min(1, max(0, 1 - abs(u) / 0.5))
        // The nose pokes a touch past the patrol line mid-turn.
        let pos = 0.5 * (1 + sin(theta))
        let x = margin + pos * max(0, size.width - 2 * margin) + turn * 7 * sin(theta)
        return (x, u, turn)
    }

    private func layout(of fish: Fish, in size: CGSize, at t: Double, now: Date,
                        parent: (fish: Fish, layout: Layout)? = nil) -> Layout {
        if fish.isFry, let parent {
            return fryLayout(of: fish, at: t, now: now, parent: parent)
        }
        let h = AquariumModel.stableHash(fish.id)
        let phase = Double((h >> 43) & 0xFF) / 0xFF * .pi * 2
        // Half the fish loop up over the top, half dive under.
        let turnUp = (h >> 52) & 1 == 0
        let margin = 36.0
        let top = 34.0
        let bottom = size.height - 30.0
        let laneY = top + fish.lane * max(0, bottom - top)
        let bob = reduceMotion ? 0 : sin(t * 1.1 + phase) * 5
        let p = patrol(of: fish, in: size, at: t, margin: margin)

        var l = Layout()
        l.scale = 1.08 - fish.lane * 0.4
        l.riseFrom = laneY
        // The shared turn pose: the pitch stays level through cruise &
        // sweeps in at the glass (smoothstep), the head-on squash holds
        // a tighter window than the pitch, and the fish arcs a little
        // toward the side of the loop.
        let turnPitch = smooth(p.turn) * (turnUp ? -0.9 : 0.9)
        let turnArc = p.turn * (turnUp ? -6.0 : 6.0)
        let thin = 1 - smooth(clamp01(1 - abs(p.u) / 0.28)) * 0.82

        switch fish.state {
        case .swimming:
            l.x = p.x
            l.y = laneY + bob * (1 - p.turn * 0.5) + turnArc
            l.facing = p.u >= 0 ? 1 : -1
            l.pitch = turnPitch
            l.thin = thin
            l.turn = p.turn
        case .surfacing:
            // Rises from its lane to just under the surface over about
            // a second, nose up on the way, then bobs there.
            let age = now.timeIntervalSince(fish.stateSince)
            let rise = smooth(clamp01(age / 1.15))
            let t0 = fish.stateSince.timeIntervalSince1970
            l.riseFrom = laneY + sin(t0 * 1.1 + phase) * 5
            l.x = p.x
            l.y = l.riseFrom + (24 - l.riseFrom) * rise
                + (reduceMotion ? 0 : sin(t * 2.3 + phase) * 3.5 * rise)
            l.facing = p.u >= 0 ? 1 : -1
            l.pitch = turnPitch - (1 - rise) * 0.75
            l.thin = thin
            l.turn = p.turn
            l.wag = 0.45 + (1 - rise) * 0.7
        case .sinking:
            // It stops where it was, drops nose down onto the sand,
            // then rocks side to side as it settles.
            let t0 = fish.stateSince.timeIntervalSince1970
            let frozen = patrol(of: fish, in: size, at: t0, margin: margin)
            let age = now.timeIntervalSince(fish.stateSince)
            let drop = clamp01(age / 2.4)
            let eased = drop * drop
            let settle = smooth(clamp01((age - 2.4) / 1.0))
            let decay = exp(-max(0, age - 2.4) * 0.5)
            let rock = reduceMotion ? 0 : sin(age * 3.0 + phase) * 0.22 * decay
            l.x = frozen.x
            l.y = min(laneY + (size.height - 26 - laneY) * eased, size.height - 26) + rock * 4
            l.facing = frozen.u >= 0 ? 1 : -1
            l.pitch = 0.55 * eased + (0.16 - 0.55 * eased) * settle + rock
            // A failed fry doesn't get the full rock-on-sand: it just
            // drops & fades.
            l.opacity = fish.isFry ? 1 - 0.7 * drop : 1 - 0.15 * drop
            l.wag = 1 - drop
        case .leaving:
            // From wherever it was, easing off the right edge, rising
            // a little as it goes.
            let t0 = fish.stateSince.timeIntervalSince1970
            let progress = fish.leaveProgress(at: now)
            let eased = smooth(progress)
            let start = patrol(of: fish, in: size, at: t0, margin: margin).x
            l.x = start + (size.width + margin + 60 - start) * eased
            l.y = laneY + bob * (1 - progress) - progress * 12
            l.facing = 1
            l.pitch = -0.18 * eased
            l.opacity = 1 - 0.5 * progress
        }

        // A new fish swims in from the edge behind its heading instead
        // of popping into the middle of the tank.
        if fish.state == .swimming || fish.state == .surfacing {
            let enterDuration = 2.2
            let age = now.timeIntervalSince(fish.enteredAt)
            if age < enterDuration {
                let e = 1 - pow(1 - age / enterDuration, 3)
                let edge: Double = fish.direction > 0 ? -70 : size.width + 70
                l.x = edge + (l.x - edge) * e
                l.opacity *= 0.2 + 0.8 * e
                // The turn pose fades in with the entrance: the fish
                // comes through the glass fully formed.
                l.thin = 1 - (1 - l.thin) * e
                l.turn *= e
                l.pitch *= e
            }
        }
        return l
    }

    /// A fry's place in its school (docs/TOYS.md): a loose orbit
    /// around the parent fish — per-fry radius, direction & phase
    /// from its id's hash — riding a touch higher, because fry sit up
    /// in the water. The orbit follows the parent's layout, so an
    /// ask-rise, a sink or a drift off the edge carries the school.
    private func fryLayout(of fish: Fish, at t: Double, now: Date,
                           parent: (fish: Fish, layout: Layout)) -> Layout {
        let h = AquariumModel.stableHash(fish.id)
        let phase = Double(h & 0xFF) / 0xFF * .pi * 2
        let orbitR = 30 + Double((h >> 8) & 0xFF) / 0xFF * 26
        let omega = (0.45 + Double((h >> 16) & 0xFF) / 0xFF * 0.45)
            * ((h >> 24) & 1 == 0 ? 1.0 : -1.0)
        let angle = phase + (reduceMotion ? 0 : omega * t)
        let pl = parent.layout

        var l = Layout()
        l.scale = pl.scale * 1.08
        l.riseFrom = pl.riseFrom
        l.opacity = pl.opacity
        // Little tails beat faster.
        l.wag = pl.wag * 1.4

        switch fish.state {
        case .swimming, .surfacing:
            l.x = pl.x + cos(angle) * orbitR
            l.y = pl.y + sin(angle) * orbitR * 0.5 - 12
            // Face along the orbit's travel.
            l.facing = -sin(angle) * omega >= 0 ? 1 : -1
            l.pitch = pl.pitch * 0.5 + (reduceMotion ? 0 : sin(t * 1.7 + phase) * 0.12)
        case .sinking:
            // A failed worker just fades & drops a little.
            let age = now.timeIntervalSince(fish.stateSince)
            let drop = smooth(clamp01(age / 1.6))
            l.x = pl.x + cos(angle) * orbitR * 0.7
            l.y = pl.y + sin(angle) * orbitR * 0.5 - 12 + drop * 44
            l.facing = pl.facing
            l.pitch = 0.5 * drop
            l.opacity = pl.opacity * (1 - 0.72 * drop)
            l.wag = pl.wag * (1 - drop)
        case .leaving:
            // The school spirals in as it follows its parent off.
            let progress = fish.leaveProgress(at: now)
            let shrink = orbitR * (1 - 0.55 * progress)
            l.x = pl.x + cos(angle) * shrink
            l.y = pl.y + sin(angle) * shrink * 0.5 - 12
            l.facing = 1
            l.pitch = pl.pitch
        }
        return l
    }

    // MARK: Fish shape

    /// The silhouette kit for one species (docs/TOYS.md): unit-space
    /// paths built once — nose at +0.5, tail root near −0.4 — plus
    /// closures for the fins that animate (tail wag, pectoral flap).
    /// `FishSpecies` picks the kit; the provider picks the colour.
    private struct SpeciesArt {
        var body: Path
        var dorsal: Path?
        var anal: Path?
        /// Trailing fins & spikes drawn under the body silhouette.
        var extras: [Path]
        var gill: Path?
        var stripe: Path?
        var stripeWidth: Double
        var eye: CGPoint
        var eyeR: Double
        var tail: ((Double) -> Path)?
        var pectoral: ((Double) -> Path)?
    }

    /// The water colour fish & kelp wash toward with depth.
    private static let waterNS = NSColor(srgbRed: 0.05, green: 0.18, blue: 0.33, alpha: 1)

    /// The minnow's body silhouette in unit space: nose at +0.5, tail
    /// peduncle at −0.40, back to −0.44, belly to +0.33. Several
    /// species reuse it under a different pattern.
    private static let minnowBody: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.50, y: -0.02))
        p.addCurve(to: CGPoint(x: 0.10, y: -0.40),
                   control1: CGPoint(x: 0.46, y: -0.26),
                   control2: CGPoint(x: 0.28, y: -0.44))
        p.addCurve(to: CGPoint(x: -0.40, y: -0.10),
                   control1: CGPoint(x: -0.10, y: -0.34),
                   control2: CGPoint(x: -0.32, y: -0.16))
        p.addQuadCurve(to: CGPoint(x: -0.40, y: 0.10),
                       control: CGPoint(x: -0.42, y: 0))
        p.addCurve(to: CGPoint(x: 0.14, y: 0.26),
                   control1: CGPoint(x: -0.24, y: 0.20),
                   control2: CGPoint(x: -0.06, y: 0.33))
        p.addCurve(to: CGPoint(x: 0.50, y: -0.02),
                   control1: CGPoint(x: 0.30, y: 0.20),
                   control2: CGPoint(x: 0.47, y: 0.08))
        p.closeSubpath()
        return p
    }()

    /// The minnow's swept dorsal fin along the back, drawn under the
    /// body so its base disappears into the silhouette.
    private static let minnowDorsal: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.18, y: -0.32))
        p.addQuadCurve(to: CGPoint(x: -0.02, y: -0.58), control: CGPoint(x: 0.12, y: -0.52))
        p.addQuadCurve(to: CGPoint(x: -0.26, y: -0.28), control: CGPoint(x: -0.16, y: -0.56))
        p.closeSubpath()
        return p
    }()

    /// The minnow's small anal fin under the rear belly.
    private static let minnowAnal: Path = {
        var p = Path()
        p.move(to: CGPoint(x: -0.14, y: 0.22))
        p.addQuadCurve(to: CGPoint(x: -0.30, y: 0.34), control: CGPoint(x: -0.22, y: 0.36))
        p.addQuadCurve(to: CGPoint(x: -0.28, y: 0.16), control: CGPoint(x: -0.32, y: 0.26))
        p.closeSubpath()
        return p
    }()

    /// The minnow's gill line behind the head.
    private static let minnowGill: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.27, y: -0.20))
        p.addQuadCurve(to: CGPoint(x: 0.22, y: 0.14), control: CGPoint(x: 0.17, y: -0.02))
        return p
    }()

    /// The minnow's lateral-line highlight stripe.
    private static let minnowStripe: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.38, y: -0.09))
        p.addCurve(to: CGPoint(x: -0.38, y: -0.03),
                   control1: CGPoint(x: 0.14, y: -0.16),
                   control2: CGPoint(x: -0.18, y: -0.10))
        return p
    }()

    /// A fan tail: peduncle at −0.36 to a notched trailing edge at
    /// −`reach`, half-height `span`. Rebuilt per frame because `wag`
    /// sweeps the tips; most species ride the same fan at their own
    /// span & reach.
    private static func fanTail(wag: Double, span: Double = 0.32, reach: Double = 0.72) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: -0.36, y: -0.08))
        p.addCurve(to: CGPoint(x: -reach, y: -span + wag),
                   control1: CGPoint(x: -0.54, y: -0.24 + wag * 0.45),
                   control2: CGPoint(x: -0.66, y: -span + wag * 0.8))
        p.addQuadCurve(to: CGPoint(x: -0.58, y: wag * 0.55),
                       control: CGPoint(x: -0.70, y: -0.02 + wag * 0.85))
        p.addCurve(to: CGPoint(x: -reach, y: span + wag),
                   control1: CGPoint(x: -0.52, y: 0.12 + wag * 0.7),
                   control2: CGPoint(x: -0.66, y: span + wag * 0.8))
        p.addQuadCurve(to: CGPoint(x: -0.36, y: 0.08),
                       control: CGPoint(x: -0.54, y: 0.24 + wag * 0.45))
        p.closeSubpath()
        return p
    }

    /// The shark's crescent tail: a long upper lobe, a short lower one.
    private static func lunateTail(wag: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: -0.38, y: -0.05))
        p.addCurve(to: CGPoint(x: -0.85, y: -0.48 + wag),
                   control1: CGPoint(x: -0.55, y: -0.18 + wag * 0.3),
                   control2: CGPoint(x: -0.75, y: -0.40 + wag * 0.8))
        p.addQuadCurve(to: CGPoint(x: -0.62, y: wag * 0.4),
                       control: CGPoint(x: -0.78, y: -0.05 + wag * 0.7))
        p.addCurve(to: CGPoint(x: -0.72, y: 0.30 + wag),
                   control1: CGPoint(x: -0.52, y: 0.08 + wag * 0.6),
                   control2: CGPoint(x: -0.66, y: 0.26 + wag * 0.8))
        p.addQuadCurve(to: CGPoint(x: -0.38, y: 0.05),
                       control: CGPoint(x: -0.52, y: 0.16 + wag * 0.4))
        p.closeSubpath()
        return p
    }

    /// The pectoral fin on the near flank; `flap` trails the tail wag.
    private static func pectoralFin(flap: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0.16, y: 0.04))
        p.addQuadCurve(to: CGPoint(x: -0.04, y: 0.20 + flap),
                       control: CGPoint(x: 0.02, y: 0.10 + flap * 0.6))
        p.addQuadCurve(to: CGPoint(x: 0.10, y: 0.18),
                       control: CGPoint(x: 0.04, y: 0.22 + flap * 0.5))
        p.closeSubpath()
        return p
    }

    /// The clownfish's deeper, rounder body.
    private static let clownfishBody: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.48, y: -0.04))
        p.addCurve(to: CGPoint(x: 0.08, y: -0.46),
                   control1: CGPoint(x: 0.42, y: -0.32),
                   control2: CGPoint(x: 0.26, y: -0.48))
        p.addCurve(to: CGPoint(x: -0.36, y: -0.14),
                   control1: CGPoint(x: -0.14, y: -0.44),
                   control2: CGPoint(x: -0.30, y: -0.22))
        p.addQuadCurve(to: CGPoint(x: -0.36, y: 0.14),
                       control: CGPoint(x: -0.42, y: 0))
        p.addCurve(to: CGPoint(x: 0.10, y: 0.32),
                   control1: CGPoint(x: -0.22, y: 0.28),
                   control2: CGPoint(x: -0.04, y: 0.40))
        p.addCurve(to: CGPoint(x: 0.48, y: -0.04),
                   control1: CGPoint(x: 0.28, y: 0.26),
                   control2: CGPoint(x: 0.44, y: 0.10))
        p.closeSubpath()
        return p
    }()

    /// The shark's blade: pointed snout, flat belly.
    private static let sharkBody: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.56, y: -0.02))
        p.addQuadCurve(to: CGPoint(x: 0.05, y: -0.26), control: CGPoint(x: 0.42, y: -0.24))
        p.addQuadCurve(to: CGPoint(x: -0.44, y: -0.06), control: CGPoint(x: -0.22, y: -0.20))
        p.addQuadCurve(to: CGPoint(x: -0.44, y: 0.06), control: CGPoint(x: -0.47, y: 0))
        p.addQuadCurve(to: CGPoint(x: 0.10, y: 0.18), control: CGPoint(x: -0.12, y: 0.16))
        p.addQuadCurve(to: CGPoint(x: 0.56, y: -0.02), control: CGPoint(x: 0.40, y: 0.12))
        p.closeSubpath()
        return p
    }()

    /// The shark's tall dorsal triangle.
    private static let sharkDorsal: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.08, y: -0.24))
        p.addLine(to: CGPoint(x: -0.06, y: -0.62))
        p.addQuadCurve(to: CGPoint(x: -0.22, y: -0.22), control: CGPoint(x: -0.14, y: -0.55))
        p.closeSubpath()
        return p
    }()

    /// The angelfish's tall disc.
    private static let angelfishBody: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.44, y: -0.02))
        p.addQuadCurve(to: CGPoint(x: 0.05, y: -0.55), control: CGPoint(x: 0.34, y: -0.50))
        p.addQuadCurve(to: CGPoint(x: -0.32, y: -0.08), control: CGPoint(x: -0.14, y: -0.52))
        p.addQuadCurve(to: CGPoint(x: -0.32, y: 0.08), control: CGPoint(x: -0.36, y: 0))
        p.addQuadCurve(to: CGPoint(x: 0.05, y: 0.55), control: CGPoint(x: -0.14, y: 0.52))
        p.addQuadCurve(to: CGPoint(x: 0.44, y: -0.02), control: CGPoint(x: 0.34, y: 0.46))
        p.closeSubpath()
        return p
    }()

    /// The angelfish's long swept fins, top & bottom.
    private static let angelfishDorsal: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.18, y: -0.40))
        p.addQuadCurve(to: CGPoint(x: -0.05, y: -0.88), control: CGPoint(x: 0.10, y: -0.72))
        p.addQuadCurve(to: CGPoint(x: -0.18, y: -0.30), control: CGPoint(x: -0.14, y: -0.70))
        p.closeSubpath()
        return p
    }()

    private static let angelfishAnal: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.18, y: 0.40))
        p.addQuadCurve(to: CGPoint(x: -0.05, y: 0.88), control: CGPoint(x: 0.10, y: 0.72))
        p.addQuadCurve(to: CGPoint(x: -0.18, y: 0.30), control: CGPoint(x: -0.14, y: 0.70))
        p.closeSubpath()
        return p
    }()

    /// The angelfish's two thin ventral streamers.
    private static let angelfishStreamers: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.08, y: 0.50))
        p.addQuadCurve(to: CGPoint(x: -0.02, y: 0.95), control: CGPoint(x: 0.04, y: 0.76))
        p.addQuadCurve(to: CGPoint(x: 0.02, y: 0.48), control: CGPoint(x: 0.02, y: 0.80))
        p.closeSubpath()
        p.move(to: CGPoint(x: 0.16, y: 0.46))
        p.addQuadCurve(to: CGPoint(x: 0.08, y: 0.90), control: CGPoint(x: 0.14, y: 0.72))
        p.addQuadCurve(to: CGPoint(x: 0.10, y: 0.44), control: CGPoint(x: 0.12, y: 0.76))
        p.closeSubpath()
        return p
    }()

    /// The puffer: nearly a circle.
    private static let pufferBody: Path = {
        var p = Path()
        p.addEllipse(in: CGRect(x: -0.42, y: -0.46, width: 0.90, height: 0.92))
        return p
    }()

    /// The puffer's little dorsal nub.
    private static let pufferDorsal: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.05, y: -0.42))
        p.addQuadCurve(to: CGPoint(x: -0.05, y: -0.58), control: CGPoint(x: 0.04, y: -0.55))
        p.addQuadCurve(to: CGPoint(x: -0.12, y: -0.40), control: CGPoint(x: -0.10, y: -0.52))
        p.closeSubpath()
        return p
    }()

    /// The puffer's spikes: triangles ringing the body, clear of the
    /// tail root.
    private static let pufferSpikes: Path = {
        var p = Path()
        for i in 0..<12 {
            let a = Double(i) / 12 * .pi * 2
            let ex = cos(a) * 0.44, ey = sin(a) * 0.45
            guard ex > -0.28 || abs(ey) > 0.2 else { continue }
            let px = -sin(a), py = cos(a)
            p.move(to: CGPoint(x: ex + px * 0.035, y: ey + py * 0.035))
            p.addLine(to: CGPoint(x: ex + cos(a) * 0.10, y: ey + sin(a) * 0.11))
            p.addLine(to: CGPoint(x: ex - px * 0.035, y: ey - py * 0.035))
            p.closeSubpath()
        }
        return p
    }()

    /// The betta's flowing ventral veil.
    private static let bettaVeil: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.0, y: 0.20))
        p.addCurve(to: CGPoint(x: -0.62, y: 0.60),
                   control1: CGPoint(x: -0.20, y: 0.34),
                   control2: CGPoint(x: -0.50, y: 0.58))
        p.addQuadCurve(to: CGPoint(x: -0.34, y: 0.18), control: CGPoint(x: -0.58, y: 0.40))
        p.addQuadCurve(to: CGPoint(x: 0.0, y: 0.20), control: CGPoint(x: -0.20, y: 0.24))
        p.closeSubpath()
        return p
    }()

    /// The seahorse stands upright: snout at the top right, a crown,
    /// a belly, and the tail curling under.
    private static let seahorseBody: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.46, y: -0.36))
        p.addQuadCurve(to: CGPoint(x: 0.30, y: -0.30), control: CGPoint(x: 0.40, y: -0.28))
        p.addQuadCurve(to: CGPoint(x: 0.16, y: -0.46), control: CGPoint(x: 0.20, y: -0.42))
        p.addCurve(to: CGPoint(x: -0.02, y: 0.10),
                   control1: CGPoint(x: 0.10, y: -0.38),
                   control2: CGPoint(x: -0.06, y: -0.10))
        p.addCurve(to: CGPoint(x: 0.26, y: 0.34),
                   control1: CGPoint(x: -0.10, y: 0.24),
                   control2: CGPoint(x: 0.10, y: 0.38))
        p.addQuadCurve(to: CGPoint(x: 0.34, y: 0.22), control: CGPoint(x: 0.34, y: 0.32))
        p.addQuadCurve(to: CGPoint(x: 0.22, y: 0.26), control: CGPoint(x: 0.30, y: 0.18))
        p.addCurve(to: CGPoint(x: 0.16, y: -0.02),
                   control1: CGPoint(x: 0.12, y: 0.18),
                   control2: CGPoint(x: 0.22, y: 0.08))
        p.addQuadCurve(to: CGPoint(x: 0.30, y: -0.24), control: CGPoint(x: 0.10, y: -0.14))
        p.closeSubpath()
        return p
    }()

    /// The seahorse's fluttering back fin.
    private static let seahorseFin: Path = {
        var p = Path()
        p.move(to: CGPoint(x: -0.02, y: -0.14))
        p.addQuadCurve(to: CGPoint(x: -0.24, y: -0.02), control: CGPoint(x: -0.16, y: -0.16))
        p.addQuadCurve(to: CGPoint(x: -0.02, y: 0.06), control: CGPoint(x: -0.18, y: 0.04))
        p.closeSubpath()
        return p
    }()

    /// Every species' kit, built once.
    private static let arts: [FishSpecies: SpeciesArt] = {
        let fin: (Double) -> Path = { pectoralFin(flap: $0) }
        var arts: [FishSpecies: SpeciesArt] = [:]
        arts[.minnow] = SpeciesArt(
            body: minnowBody, dorsal: minnowDorsal, anal: minnowAnal,
            extras: [], gill: minnowGill, stripe: minnowStripe, stripeWidth: 0.05,
            eye: CGPoint(x: 0.30, y: -0.11), eyeR: 0.052,
            tail: { fanTail(wag: $0) }, pectoral: fin)
        arts[.tetra] = SpeciesArt(
            body: minnowBody, dorsal: minnowDorsal, anal: minnowAnal,
            extras: [], gill: minnowGill, stripe: minnowStripe, stripeWidth: 0.10,
            eye: CGPoint(x: 0.30, y: -0.10), eyeR: 0.060,
            tail: { fanTail(wag: $0, span: 0.26, reach: 0.62) }, pectoral: fin)
        arts[.tang] = SpeciesArt(
            body: minnowBody, dorsal: minnowDorsal, anal: minnowAnal,
            extras: [], gill: minnowGill, stripe: nil, stripeWidth: 0.05,
            eye: CGPoint(x: 0.30, y: -0.11), eyeR: 0.052,
            tail: { fanTail(wag: $0, span: 0.30, reach: 0.66) }, pectoral: fin)
        arts[.clownfish] = SpeciesArt(
            body: clownfishBody, dorsal: minnowDorsal, anal: minnowAnal,
            extras: [], gill: minnowGill, stripe: nil, stripeWidth: 0.05,
            eye: CGPoint(x: 0.32, y: -0.14), eyeR: 0.055,
            tail: { fanTail(wag: $0, span: 0.28, reach: 0.62) }, pectoral: fin)
        arts[.betta] = SpeciesArt(
            body: minnowBody, dorsal: minnowDorsal, anal: nil,
            extras: [bettaVeil], gill: minnowGill, stripe: nil, stripeWidth: 0.05,
            eye: CGPoint(x: 0.30, y: -0.10), eyeR: 0.052,
            tail: { fanTail(wag: $0, span: 0.48, reach: 0.88) }, pectoral: fin)
        arts[.shark] = SpeciesArt(
            body: sharkBody, dorsal: sharkDorsal, anal: nil,
            extras: [], gill: nil, stripe: nil, stripeWidth: 0.05,
            eye: CGPoint(x: 0.38, y: -0.06), eyeR: 0.045,
            tail: { lunateTail(wag: $0) }, pectoral: fin)
        arts[.angelfish] = SpeciesArt(
            body: angelfishBody, dorsal: angelfishDorsal, anal: angelfishAnal,
            extras: [angelfishStreamers], gill: nil, stripe: nil, stripeWidth: 0.05,
            eye: CGPoint(x: 0.28, y: -0.16), eyeR: 0.050,
            tail: { fanTail(wag: $0, span: 0.20, reach: 0.58) }, pectoral: fin)
        arts[.puffer] = SpeciesArt(
            body: pufferBody, dorsal: pufferDorsal, anal: nil,
            extras: [pufferSpikes], gill: nil, stripe: nil, stripeWidth: 0.05,
            eye: CGPoint(x: 0.28, y: -0.16), eyeR: 0.075,
            tail: { fanTail(wag: $0, span: 0.18, reach: 0.58) }, pectoral: fin)
        arts[.seahorse] = SpeciesArt(
            body: seahorseBody, dorsal: nil, anal: nil,
            extras: [seahorseFin], gill: nil, stripe: nil, stripeWidth: 0.05,
            eye: CGPoint(x: 0.30, y: -0.36), eyeR: 0.050,
            tail: nil, pectoral: nil)
        return arts
    }()

    private static func art(for species: FishSpecies) -> SpeciesArt {
        // Every case is in the table; the minnow is the safety net.
        arts[species] ?? arts[.minnow]!
    }

    /// The species' marking, clipped to the body silhouette.
    private func drawPattern(_ pattern: FishSpecies.Pattern, over body: Path,
                             light: Color, dark: Color, into f: inout GraphicsContext) {
        switch pattern {
        case .plain:
            break
        case .bars:
            // Three white bars, thin-edged, clownfish-style.
            var b = f
            b.clip(to: body)
            for bx in [0.30, 0.02, -0.26] {
                let bar = CGRect(x: bx - 0.055, y: -0.6, width: 0.11, height: 1.2)
                let pill = Path(roundedRect: bar, cornerRadius: 0.05)
                b.fill(pill, with: .color(.white.opacity(0.85)))
                b.stroke(pill, with: .color(dark.opacity(0.5)), lineWidth: 0.02)
            }
        case .spots:
            var b = f
            b.clip(to: body)
            let spots: [(x: Double, y: Double, r: Double)] = [
                (0.30, -0.18, 0.045), (0.10, -0.30, 0.050), (0.16, 0.08, 0.040),
                (-0.06, -0.14, 0.055), (-0.10, 0.16, 0.045), (-0.26, 0.00, 0.050),
                (0.34, 0.10, 0.035),
            ]
            for spot in spots {
                b.fill(Path(ellipseIn: CGRect(x: spot.x - spot.r, y: spot.y - spot.r,
                                              width: spot.r * 2, height: spot.r * 2)),
                       with: .color(dark.opacity(0.40)))
            }
        case .band:
            // A bold dark sweep over the rear third & a pale flash at
            // the tail root.
            var b = f
            b.clip(to: body)
            var band = Path()
            band.move(to: CGPoint(x: -0.08, y: -0.6))
            band.addQuadCurve(to: CGPoint(x: -0.16, y: 0.6), control: CGPoint(x: -0.30, y: 0))
            band.addLine(to: CGPoint(x: -0.50, y: 0.6))
            band.addLine(to: CGPoint(x: -0.50, y: -0.6))
            band.closeSubpath()
            b.fill(band, with: .color(dark.opacity(0.45)))
            var flash = Path()
            flash.move(to: CGPoint(x: -0.34, y: -0.6))
            flash.addLine(to: CGPoint(x: -0.50, y: -0.6))
            flash.addLine(to: CGPoint(x: -0.50, y: 0.6))
            flash.addLine(to: CGPoint(x: -0.36, y: 0.6))
            flash.addQuadCurve(to: CGPoint(x: -0.34, y: -0.6), control: CGPoint(x: -0.44, y: 0))
            flash.closeSubpath()
            b.fill(flash, with: .color(light.opacity(0.5)))
        }
    }

    private func drawFish(canvas: inout GraphicsContext, size: CGSize, t: Double, now: Date,
                          fish: Fish, layout l: Layout,
                          parent: (fish: Fish, layout: Layout)?, showLabels: Bool) {
        let art = Self.art(for: fish.species)
        let h = AquariumModel.stableHash(fish.id)
        let phase = Double((h >> 43) & 0xFF) / 0xFF * .pi * 2
        // Fry ride at their school's depth, a little shallower.
        let lane = fish.isFry ? (parent?.fish.lane ?? fish.lane) * 0.85 : fish.lane
        let length = 46.0 * l.scale * fish.species.sizeScale
            * (fish.isFry ? AquariumModel.fryScale : 1)
        let height = length * fish.species.aspect

        // Depth: deeper lanes dim & wash toward the water colour.
        let base: NSColor = fish.state == .sinking
            ? .secondaryLabelColor
            : ProviderStyle.style(for: fish.providerID).nsAccent
        let bodyColor = Color(nsColor: base.blended(withFraction: lane * 0.42, of: Self.waterNS) ?? base)
        let lightColor = Color(nsColor: base.blended(withFraction: 0.55, of: .white) ?? base)
        let darkColor = Color(nsColor: base.blended(withFraction: 0.38, of: .black) ?? base)

        // Recent session activity quickens the tail; a lagging beat in
        // the pitch gives the head the classic follow-the-tail sway.
        // Reduce Motion stills both — the fish glides, poses stay.
        let recency = fish.lastUpdate.map { now.timeIntervalSince($0) } ?? .infinity
        let vigor = 1 + 1.15 * exp(-max(0, recency) / 9)
        let beat = t * (3.0 + fish.speed * 24) * vigor + phase
        let wag = reduceMotion ? 0 : sin(beat) * 0.22 * l.wag * (1 + l.turn * 0.3)
        let sway = reduceMotion ? 0 : sin(beat - 0.8) * 0.045 * l.wag

        var f = canvas
        f.opacity = l.opacity * (1 - lane * 0.28)
        f.translateBy(x: l.x, y: l.y)
        // Rotate before the body scale so the pitch is rigid (no shear)
        // and `pitch * facing` keeps "nose down" the same for both
        // facings.
        if l.pitch + sway != 0 { f.rotate(by: .radians((l.pitch + sway) * l.facing)) }
        f.scaleBy(x: l.facing * l.thin * length, y: height)

        // Fins & tail go down first, behind the body silhouette.
        if let tail = art.tail {
            f.fill(tail(wag), with: .color(bodyColor.opacity(0.7)))
        }
        for extra in art.extras {
            f.fill(extra, with: .color(darkColor.opacity(0.45)))
        }
        if let dorsal = art.dorsal {
            f.fill(dorsal, with: .color(bodyColor.opacity(0.85)))
        }
        if let anal = art.anal {
            f.fill(anal, with: .color(bodyColor.opacity(0.8)))
        }
        f.fill(art.body, with: .color(bodyColor))
        drawPattern(fish.species.pattern, over: art.body,
                    light: lightColor, dark: darkColor, into: &f)
        // Volume: light from above, shade along the belly.
        f.fill(art.body, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.30), .clear]),
            startPoint: CGPoint(x: 0, y: -0.5), endPoint: CGPoint(x: 0, y: 0.05)))
        f.fill(art.body, with: .linearGradient(
            Gradient(colors: [.clear, .black.opacity(0.20)]),
            startPoint: CGPoint(x: 0, y: 0.05), endPoint: CGPoint(x: 0, y: 0.42)))
        if let pectoral = art.pectoral {
            f.fill(pectoral(wag * 0.45), with: .color(lightColor.opacity(0.5)))
        }
        if let stripe = art.stripe {
            f.stroke(stripe, with: .color(lightColor.opacity(0.55)), lineWidth: art.stripeWidth)
        }
        if let gill = art.gill {
            f.stroke(gill, with: .color(darkColor.opacity(0.6)), lineWidth: 0.04)
        }

        // The eye stays round by compensating the body's aspect.
        let aspect = length / height
        func eyeCircle(_ cx: Double, _ cy: Double, _ r: Double) -> Path {
            Path(ellipseIn: CGRect(x: cx - r, y: cy - r * aspect,
                                   width: r * 2, height: r * 2 * aspect))
        }
        let dead = fish.state == .sinking
        f.fill(eyeCircle(art.eye.x, art.eye.y, art.eyeR),
               with: .color(.white.opacity(dead ? 0.5 : 0.95)))
        f.fill(eyeCircle(art.eye.x + art.eyeR * 0.29, art.eye.y, art.eyeR * 0.58),
               with: .color(.black.opacity(0.8)))
        if !dead {
            f.fill(eyeCircle(art.eye.x + art.eyeR * 0.48, art.eye.y - art.eyeR * 0.48, art.eyeR * 0.23),
                   with: .color(.white.opacity(0.9)))
        }

        // An ask comes up for air: a small trail climbs from where the
        // rise began, and a bubble rides overhead growing till it pops.
        // Fry don't get one — a worker's ask surfaces on its parent.
        if fish.state == .surfacing, !fish.isFry {
            let since = now.timeIntervalSince(fish.stateSince)
            for k in 0..<3 {
                let birth = 0.15 + Double(k) * 0.42
                let age = since - birth
                guard age > 0, age < 2.6 else { continue }
                let release = smooth(clamp01(birth / 1.15))
                let startY = l.riseFrom + (24 - l.riseFrom) * release
                let r = 1.4 + Double(k) * 0.5
                let bx = l.x - l.facing * 6 + Double(k - 1) * 4 + sin(age * 3 + Double(k) * 2.1) * 4
                let by = startY - 4 - age * 30
                guard by > 3 else { continue }
                var b = canvas
                b.opacity = l.opacity * (1 - age / 2.6) * 0.5
                b.stroke(Path(ellipseIn: CGRect(x: bx - r, y: by - r, width: r * 2, height: r * 2)),
                         with: .color(.white), lineWidth: 0.7)
            }
            let rise = frac(t * 0.45 + phase / (.pi * 2))
            let bx = l.x + l.facing * 6 + sin(t * 3 + phase) * 2
            let by = l.y - height * 0.5 - 8 - rise * 20
            let br = 2.6 + rise * 1.2
            var b = canvas
            b.opacity = l.opacity * (1 - rise) * 0.9
            b.stroke(Path(ellipseIn: CGRect(x: bx - br, y: by - br, width: br * 2, height: br * 2)),
                     with: .color(.white), lineWidth: 0.9)
        }

        if showLabels, !fish.isFry {
            var lc = canvas
            lc.opacity = l.opacity * (fish.state == .sinking ? 0.5 : 0.9)
            let resolved = lc.resolve(
                Text(fish.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.95)))
            let textSize = resolved.measure(in: CGSize(width: size.width, height: 40))
            let chipX = min(max(l.x, textSize.width / 2 + 14), size.width - textSize.width / 2 - 14)
            let chipY = min(l.y + height / 2 + 12, size.height - 14)
            let chip = CGRect(x: chipX - textSize.width / 2 - 8,
                              y: chipY - textSize.height / 2 - 3.5,
                              width: textSize.width + 16, height: textSize.height + 7)
            let pill = Path(roundedRect: chip, cornerRadius: chip.height / 2)
            lc.fill(pill, with: .color(Color(red: 0.01, green: 0.05, blue: 0.10).opacity(0.55)))
            lc.stroke(pill, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
            lc.draw(resolved, at: CGPoint(x: chipX, y: chipY), anchor: .center)
        }
    }

    /// The empty tank still gets the full water & decor; a dimmed
    /// minnow silhouette drifts in place over it.
    private func drawEmpty(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let art = Self.art(for: .minnow)
        var ec = canvas
        let drift = reduceMotion ? 0 : sin(t * 0.55) * 3
        ec.translateBy(x: size.width / 2, y: size.height / 2 - 12 + drift)
        ec.scaleBy(x: 60, y: 26)
        ec.opacity = 0.07
        if let tail = art.tail {
            ec.fill(tail(reduceMotion ? 0 : sin(t * 0.55 + 1) * 0.1), with: .color(.white))
        }
        if let dorsal = art.dorsal {
            ec.fill(dorsal, with: .color(.white))
        }
        ec.fill(art.body, with: .color(.white))
        // The eye reads as a hole in the silhouette.
        ec.opacity = 0.35
        ec.fill(Path(ellipseIn: CGRect(x: 0.30 - 0.05, y: -0.11 - 0.115,
                                       width: 0.10, height: 0.23)),
                with: .color(Color(red: 0.10, green: 0.30, blue: 0.48)))
        canvas.draw(
            Text("Nothing swimming yet")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.45)),
            at: CGPoint(x: size.width / 2, y: size.height / 2 + 36))
    }

    private func frac(_ x: Double) -> Double {
        x - x.rounded(.down)
    }

    private func clamp01(_ x: Double) -> Double {
        min(1, max(0, x))
    }

    private func smooth(_ x: Double) -> Double {
        let c = clamp01(x)
        return c * c * (3 - 2 * c)
    }
}
