import AppKit
import JRBarCore
import SwiftUI

/// The tank (docs/TOYS.md): one `TimelineView` + `Canvas`. Fish
/// positions are integrated from each `Fish`'s constants and the frame
/// clock, so `toy.fish` only has to change when the session set does,
/// and the timeline pauses while the window is covered.
struct AquariumView: View {
    /// A fixed scene for the snapshot renderer (JRBarAppTests): the
    /// tank drawn without a toy. The app only ever uses `init(toy:)`.
    struct Fixture {
        var fish: [Fish]
        var showLabels = true
        var density: Double = 1
        var paused = false
    }

    private let toy: AquariumToy?
    private let fixture: Fixture?

    init(toy: AquariumToy) {
        self.toy = toy
        self.fixture = nil
    }

    init(fixture: Fixture) {
        self.toy = nil
        self.fixture = fixture
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Read the observable surface in `body` so the card's tracked
        // reads stay honest even while the timeline is paused.
        let fish = toy?.fish ?? fixture?.fish ?? []
        let showLabels = toy?.store?.state.aquarium.showLabels ?? fixture?.showLabels ?? true
        let density = max(0.1, toy?.store?.state.aquarium.density ?? fixture?.density ?? 1)
        let paused = toy?.windowOccluded ?? fixture?.paused ?? false
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
            let t = context.date.timeIntervalSince1970
            let mains = mainsByID(fish)
            // Deep lanes draw first: the near fish swim over them.
            let ordered = fish.sorted { depth(of: $0, mains: mains) > depth(of: $1, mains: mains) }
            let empty = fish.isEmpty || fish.allSatisfy { $0.isRetired(at: context.date) }
            Canvas { canvas, size in
                drawWater(canvas: &canvas, size: size)
                drawGodRays(canvas: &canvas, size: size, t: t)
                drawSand(canvas: &canvas, size: size)
                // The empty-tank caption's capsule: decor keeps clear
                // of it, and it draws last, over the sand.
                let caption = empty ? captionLayout(canvas: &canvas, size: size) : nil
                drawDecor(canvas: &canvas, size: size, t: t, density: density,
                          front: false, keepClear: caption?.rect)
                drawJellyfish(canvas: &canvas, size: size, t: t, resident: empty)
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
                drawDecor(canvas: &canvas, size: size, t: t, density: density,
                          front: true, keepClear: caption?.rect)
                drawPlankton(canvas: &canvas, size: size, t: t, density: density, front: true)
                // The surface draws over everything: a surfacing fish
                // reads as under the waterline, not pasted on top.
                drawSurface(canvas: &canvas, size: size, t: t)
                drawGlass(canvas: &canvas, size: size)
                if let caption {
                    drawEmpty(canvas: &canvas, size: size, caption: caption)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.02, green: 0.07, blue: 0.25))
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

    /// The column of water itself: a many-stop gradient from the bright
    /// green-teal surface down to a deep indigo floor, a warm glow
    /// where the light comes in, and a faint cool counter-glow low on
    /// the right so the far side never goes dead flat.
    private func drawWater(canvas: inout GraphicsContext, size: CGSize) {
        canvas.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(red: 0.46, green: 0.79, blue: 0.72), location: 0),
                    .init(color: Color(red: 0.28, green: 0.64, blue: 0.64), location: 0.12),
                    .init(color: Color(red: 0.12, green: 0.45, blue: 0.58), location: 0.34),
                    .init(color: Color(red: 0.06, green: 0.28, blue: 0.50), location: 0.58),
                    .init(color: Color(red: 0.03, green: 0.15, blue: 0.39), location: 0.80),
                    .init(color: Color(red: 0.02, green: 0.07, blue: 0.25), location: 1),
                ]),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height)))
        var glow = canvas
        glow.blendMode = .plusLighter
        glow.fill(Path(CGRect(origin: .zero, size: size)),
                  with: .radialGradient(
                      Gradient(colors: [Color(red: 0.95, green: 0.88, blue: 0.66).opacity(0.22), .clear]),
                      center: CGPoint(x: size.width * 0.36, y: -size.height * 0.10),
                      startRadius: 0, endRadius: size.width * 0.62))
        glow.fill(Path(CGRect(origin: .zero, size: size)),
                  with: .radialGradient(
                      Gradient(colors: [Color(red: 0.20, green: 0.50, blue: 0.62).opacity(0.10), .clear]),
                      center: CGPoint(x: size.width * 0.88, y: size.height * 0.55),
                      startRadius: 0, endRadius: size.width * 0.5))
    }

    /// Soft light shafts leaning down from the surface. Each ray is its
    /// own layer: a gradient across the beam gives the soft edges and a
    /// masking gradient fades it with depth, so there are no hard
    /// polygon sides. They breathe & sway a couple of degrees; Reduce
    /// Motion holds them still.
    private func drawGodRays(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let rayColor = Color(red: 0.86, green: 0.97, blue: 0.93)
        for i in 0..<5 {
            let h = AquariumModel.stableHash("ray-\(i)")
            let jitter = Double(h & 0xFF) / 0xFF
            let phase = Double((h >> 8) & 0xFF) / 0xFF * .pi * 2
            let speed = 0.05 + Double((h >> 16) & 0xFF) / 0xFF * 0.05
            let anchorX = size.width * (0.08 + 0.21 * Double(i) + jitter * 0.07)
            let halfW = 16 + Double((h >> 24) & 0xFF) / 0xFF * 30
            let lean = 0.20 + jitter * 0.18
            let sway = reduceMotion ? 0 : sin(t * speed + phase) * 0.035
            let breathe = reduceMotion ? 0.55 : 0.42 + 0.38 * sin(t * 0.08 + phase * 1.7)
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
                        .init(color: rayColor.opacity(0.05 * breathe), location: core - 0.28),
                        .init(color: rayColor.opacity(0.13 * breathe), location: core),
                        .init(color: rayColor.opacity(0.05 * breathe), location: core + 0.28),
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

    /// The water's surface: a soft bright band just under the glass,
    /// three wandering caustic bands (wide, low-contrast strokes), and
    /// the thin bright meniscus line on top.
    private func drawSurface(canvas: inout GraphicsContext, size: CGSize, t: Double) {
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
            let drift = reduceMotion ? 0 : t * (0.45 + Double(r) * 0.16)
            var wave = Path()
            wave.move(to: CGPoint(x: 0, y: y0))
            var x = 0.0
            while x <= size.width {
                let y = y0 + sin(x * 0.045 + drift + Double(r) * 2.3) * amp
                    + sin(x * 0.011 - drift * 0.6) * amp * 0.5
                wave.addLine(to: CGPoint(x: x, y: y))
                x += 8
            }
            let shimmer = reduceMotion ? 0.6 : 0.55 + 0.45 * sin(t * 0.6 + Double(r) * 2.1)
            canvas.stroke(wave,
                          with: .color(.white.opacity((0.075 - Double(r) * 0.018) * shimmer)),
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

    // MARK: Floor

    /// Seeded phases for the dune profile — fixed across launches.
    private static let dunePhase1 =
        Double(AquariumModel.stableHash("dune-p1") & 0xFFFF) / 0xFFFF * .pi * 2
    private static let dunePhase2 =
        Double(AquariumModel.stableHash("dune-p2") & 0xFFFF) / 0xFFFF * .pi * 2

    /// The dune crest the whole floor agrees on — closed form, so a
    /// chest, a fish shadow or a kelp root can sit exactly on the sand
    /// at any x. The bed stands ~11–13% of the tank tall: a real floor,
    /// not a sliver.
    private func sandTop(atX x: Double, in size: CGSize) -> Double {
        let u = x / max(1, size.width)
        return size.height
            - (78 + 5 * sin(u * .pi * 2.6 + Self.dunePhase1)
               + 4 * sin(u * .pi * 5.4 + Self.dunePhase2))
    }

    /// The back dune's crest, a layer higher on screen: the bed
    /// running away from the glass. A good stone's throw behind the
    /// front crest so the two dunes read as separate layers.
    private func backDuneTop(atX x: Double, in size: CGSize) -> Double {
        let u = x / max(1, size.width)
        return sandTop(atX: x, in: size) - 30 - 8 * sin(u * .pi * 3.4 + Self.dunePhase2 * 1.7)
    }

    /// One seeded grain of sand, in unit space.
    private struct Speck {
        var x, y, r: Double
        var light: Bool
    }

    /// ~110 grains scattered over the bed, seeded once. The hash goes
    /// through the same murmur-style finalizer `decorSet` uses —
    /// FNV-1a's low bits cluster on sequential tags and would lay the
    /// grains out in rows.
    private static let sandSpeckles: [Speck] = (0..<110).map { i in
        var h = AquariumModel.stableHash("speck-\(i)")
        h ^= h >> 33
        h &*= 0xff51afd7ed558ccd
        h ^= h >> 33
        return Speck(x: Double(h & 0xFFFF) / 0xFFFF,
                     y: Double((h >> 16) & 0xFFFF) / 0xFFFF,
                     r: 0.6 + Double((h >> 32) & 0xF) / 0xF * 1.3,
                     light: (h >> 48) & 1 == 0)
    }

    /// The floor: a darker back dune (the far end of the bed) with a
    /// shadowed seam above it, the lit front dune, and a scatter of
    /// seeded grains.
    private func drawSand(canvas: inout GraphicsContext, size: CGSize) {
        var back = Path()
        back.move(to: CGPoint(x: 0, y: backDuneTop(atX: 0, in: size)))
        var x = 0.0
        while x <= size.width {
            back.addLine(to: CGPoint(x: x, y: backDuneTop(atX: x, in: size)))
            x += 8
        }
        back.addLine(to: CGPoint(x: size.width, y: size.height))
        back.addLine(to: CGPoint(x: 0, y: size.height))
        back.closeSubpath()
        canvas.fill(back, with: .linearGradient(
            Gradient(colors: [Color(red: 0.23, green: 0.22, blue: 0.18),
                              Color(red: 0.06, green: 0.07, blue: 0.11)]),
            startPoint: CGPoint(x: 0, y: backDuneTop(atX: size.width / 2, in: size)),
            endPoint: CGPoint(x: 0, y: size.height)))

        // The dark band where the far end of the bed meets the back
        // wall of the tank — fakes the water depth behind the dunes.
        var seam = Path()
        seam.move(to: CGPoint(x: 0, y: backDuneTop(atX: 0, in: size) - 30))
        x = 0.0
        while x <= size.width {
            seam.addLine(to: CGPoint(x: x, y: backDuneTop(atX: x, in: size) - 30))
            x += 8
        }
        x = size.width
        while x >= 0 {
            seam.addLine(to: CGPoint(x: x, y: backDuneTop(atX: x, in: size)))
            x -= 8
        }
        seam.closeSubpath()
        canvas.fill(seam, with: .linearGradient(
            Gradient(colors: [.clear, .black.opacity(0.32)]),
            startPoint: CGPoint(x: 0, y: backDuneTop(atX: size.width / 2, in: size) - 30),
            endPoint: CGPoint(x: 0, y: backDuneTop(atX: size.width / 2, in: size))))

        var front = Path()
        var rim = Path()
        front.move(to: CGPoint(x: 0, y: sandTop(atX: 0, in: size)))
        rim.move(to: CGPoint(x: 0, y: sandTop(atX: 0, in: size)))
        x = 0.0
        while x <= size.width {
            front.addLine(to: CGPoint(x: x, y: sandTop(atX: x, in: size)))
            rim.addLine(to: CGPoint(x: x, y: sandTop(atX: x, in: size)))
            x += 6
        }
        front.addLine(to: CGPoint(x: size.width, y: size.height))
        front.addLine(to: CGPoint(x: 0, y: size.height))
        front.closeSubpath()
        canvas.fill(front, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.66, green: 0.56, blue: 0.38), location: 0),
                .init(color: Color(red: 0.44, green: 0.35, blue: 0.22), location: 0.5),
                .init(color: Color(red: 0.15, green: 0.12, blue: 0.08), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: sandTop(atX: size.width / 2, in: size)),
            endPoint: CGPoint(x: 0, y: size.height)))
        canvas.stroke(rim, with: .color(Color(red: 0.84, green: 0.74, blue: 0.52).opacity(0.4)),
                      lineWidth: 1.2)

        for speck in Self.sandSpeckles {
            let sx = speck.x * size.width
            let top = sandTop(atX: sx, in: size)
            let sy = top + 2 + speck.y * max(0, size.height - top - 3)
            canvas.fill(Path(ellipseIn: CGRect(x: sx - speck.r, y: sy - speck.r * 0.7,
                                               width: speck.r * 2, height: speck.r * 1.4)),
                        with: .color(speck.light
                                     ? Color(red: 0.82, green: 0.72, blue: 0.50).opacity(0.20)
                                     : Color(red: 0.10, green: 0.08, blue: 0.05).opacity(0.25)))
        }
    }

    /// A soft elliptical shadow pooled on the sand — the gradient is
    /// drawn in a scaled context so it fades on every side.
    private func groundShadow(canvas: inout GraphicsContext, x: Double, y: Double,
                              halfW: Double, halfH: Double = 4.5, alpha: Double) {
        var s = canvas
        s.translateBy(x: x, y: y)
        s.scaleBy(x: halfW, y: halfH)
        s.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
               with: .radialGradient(
                   Gradient(colors: [.black.opacity(alpha), .clear]),
                   center: .zero, startRadius: 0, endRadius: 1))
    }

    /// The glass itself: the far edges of the tank fall away, darkness
    /// pools along the bottom, and a faint reflection streaks the
    /// top-left corner — the pane you look through.
    private func drawGlass(canvas: inout GraphicsContext, size: CGSize) {
        let radius = max(size.width, size.height)
        canvas.fill(Path(CGRect(origin: .zero, size: size)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: .clear, location: 0.45),
                            .init(color: .black.opacity(0.30), location: 1),
                        ]),
                        center: CGPoint(x: size.width * 0.5, y: size.height * 0.42),
                        startRadius: radius * 0.30, endRadius: radius * 0.78))
        canvas.fill(Path(CGRect(x: 0, y: size.height * 0.72,
                                width: size.width, height: size.height * 0.28)),
                    with: .linearGradient(
                        Gradient(colors: [.clear, .black.opacity(0.22)]),
                        startPoint: CGPoint(x: 0, y: size.height * 0.72),
                        endPoint: CGPoint(x: 0, y: size.height)))
        var g = canvas
        g.blendMode = .plusLighter
        g.translateBy(x: size.width * 0.14, y: size.height * 0.10)
        g.rotate(by: .radians(-0.55))
        g.fill(Path(roundedRect: CGRect(x: -size.width * 0.30, y: -18,
                                        width: size.width * 0.60, height: 36),
                    cornerRadius: 18),
               with: .linearGradient(
                   Gradient(stops: [
                       .init(color: .clear, location: 0),
                       .init(color: .white.opacity(0.055), location: 0.5),
                       .init(color: .clear, location: 1),
                   ]),
                   startPoint: CGPoint(x: 0, y: -18), endPoint: CGPoint(x: 0, y: 18)))
    }

    /// Slow flecks drifting with the water as soft glowing motes, in
    /// two depth layers — the near ones are bigger, brighter & a touch
    /// faster. `density` scales the count; Reduce Motion stills them.
    /// The seed goes through `scatter` (a murmur-style scramble):
    /// FNV-1a's low bits cluster on sequential tags, which used to
    /// park the motes in visible rows.
    private func drawPlankton(canvas: inout GraphicsContext, size: CGSize, t: Double,
                              density: Double, front: Bool) {
        let tt = reduceMotion ? 0.0 : t
        let count = Int((44 * density).rounded())
        for i in 0..<count {
            let h = scatter(AquariumModel.stableHash("plankton-field"), i)
            let isFront = (h >> 56) & 1 == 1
            guard isFront == front else { continue }
            let x0 = Double(h & 0xFFFF) / 0xFFFF
            let y0 = Double((h >> 16) & 0xFFFF) / 0xFFFF
            let phase = Double((h >> 32) & 0xFF) / 0xFF * .pi * 2
            let drift = (h >> 40) & 1 == 0 ? 1.0 : -1.0
            // Near layer 1.6–3 px, far layer 1–2.2 px.
            let r = 1.0 + Double((h >> 44) & 0xFF) / 0xFF * (front ? 2.0 : 1.2)
            let x = frac(x0 + drift * tt * (front ? 0.010 : 0.005)
                         + 0.018 * sin(tt * 0.20 + phase)) * size.width
            // Stay in the water column, off the bed.
            let y = (0.12 + frac(y0 + 0.018 * sin(tt * 0.26 + phase)) * 0.68) * size.height
            let twinkle = reduceMotion ? 0.8 : 0.55 + 0.45 * sin(t * 0.6 + phase)
            let alpha = (front ? 0.16 : 0.07)
                + Double((h >> 48) & 0xFF) / 0xFF * (front ? 0.20 : 0.11)
            canvas.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(
                            Gradient(colors: [.white.opacity(alpha * twinkle), .clear]),
                            center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
        }
    }

    /// Ambient bubbles — half streaming off the chest, half seeded at
    /// random spots in the sand — each with a rim, a faint body and a
    /// glint. They wobble up from the bed and pop just under the
    /// surface. The seed goes through `scatter` so the rise phases
    /// don't fall into an evenly spaced ladder.
    private func drawBubbles(canvas: inout GraphicsContext, size: CGSize, t: Double, density: Double) {
        let count = Int((9 * density).rounded())
        let chestX = Self.decor.first(where: { $0.kind == .chest })?.x ?? 0.5
        for i in 0..<count {
            let h = scatter(AquariumModel.stableHash("bubble-seed"), i)
            let nearChest = (h >> 52) & 1 == 0
            let x0 = nearChest
                ? chestX + (Double((h >> 54) & 0xFF) / 0xFF - 0.5) * 0.10
                : Double(h & 0xFFFF) / 0xFFFF
            let phase = Double((h >> 16) & 0xFF) / 0xFF * .pi * 2
            let speed = 0.04 + Double((h >> 24) & 0xFF) / 0xFF * 0.09
            let r = 1.2 + Double((h >> 32) & 0xFF) / 0xFF * 3.4
            let rise = frac(Double((h >> 40) & 0xFF) / 0xFF + (reduceMotion ? 0 : t) * speed)
            if rise > 0.97 { continue }
            // Each bubble staggers its own amount at its own rate.
            let wobble = 2.5 + Double((h >> 48) & 0xF) / 0xF * 8.5
            let x = x0 * size.width
                + (reduceMotion ? 0 : sin(t * (0.9 + speed * 6) + phase) * wobble)
            let floorY = sandTop(atX: x, in: size) - 3
            let y = floorY - rise * (floorY - 8)
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            canvas.fill(Path(ellipseIn: rect),
                        with: .radialGradient(
                            Gradient(colors: [.white.opacity(0.14), .clear]),
                            center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
            canvas.stroke(Path(ellipseIn: rect),
                          with: .color(.white.opacity(0.38)), lineWidth: 0.8)
            canvas.fill(Path(ellipseIn: CGRect(x: x - r * 0.45, y: y - r * 0.55,
                                               width: r * 0.35, height: r * 0.35)),
                        with: .color(.white.opacity(0.6)))
        }
    }

    // MARK: Decor

    /// The seeded layout, built once — the tank never rearranges.
    private static let decor = AquariumModel.decorSet()

    /// The bed is ~12% of the tank now; the dressing grows with it —
    /// roughly twice the original footprint.
    private static let decorBoost = 2.0

    /// The seeded dressing (docs/TOYS.md): kelp, rocks, corals, sea
    /// grass, shells, a starfish, a bottle & a treasure chest, laid
    /// out by `AquariumModel.decorSet` so the tank looks the same
    /// every launch. `density` decides how much of the set shows —
    /// the signature pieces come first, so a sparse tank keeps them.
    /// `front` splits the set at depth 0.6: near pieces draw over the
    /// fish as foreground parallax. `keepClear` (the empty-tank
    /// caption's capsule) culls any piece rooted inside it — nothing
    /// sits under the plaque.
    private func drawDecor(canvas: inout GraphicsContext, size: CGSize, t: Double,
                           density: Double, front: Bool, keepClear: CGRect? = nil) {
        let shown = Int((Double(Self.decor.count) * min(1, density)).rounded(.up))
        // The capsule sits on the sand face below the dune line; the
        // zone reaches up over the dune face behind it so nothing is
        // rooted inside the plaque's footprint either.
        let clearZone = keepClear?.insetBy(dx: -10, dy: -34)
        for piece in Self.decor.prefix(shown) where (piece.depth > 0.6) == front {
            if let clearZone,
               clearZone.contains(CGPoint(x: piece.x * size.width,
                                          y: decorBaseY(piece, in: size))) {
                continue
            }
            switch piece.kind {
            case .kelp: drawKelp(canvas: &canvas, size: size, t: t, piece: piece)
            case .rock: drawRocks(canvas: &canvas, size: size, piece: piece)
            case .coral: drawCoral(canvas: &canvas, size: size, piece: piece)
            case .grass: drawGrass(canvas: &canvas, size: size, t: t, piece: piece)
            case .shell: drawShell(canvas: &canvas, size: size, piece: piece)
            case .bottle: drawBottle(canvas: &canvas, size: size, piece: piece)
            case .starfish: drawStarfish(canvas: &canvas, size: size, piece: piece)
            case .chest: drawChest(canvas: &canvas, size: size, t: t, piece: piece)
            }
        }
    }

    /// Where a piece stands: on the dune line under it, with a couple
    /// of pixels of sink so nothing floats over the sand.
    private func decorBaseY(_ piece: TankDecor, in size: CGSize) -> Double {
        sandTop(atX: piece.x * size.width, in: size) + 2
    }

    /// Per-item hash scramble: folds an index into a piece's bits so
    /// every frond/blade/branch of one piece varies independently.
    private func scatter(_ bits: UInt64, _ k: Int) -> UInt64 {
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
    /// at these sizes.
    private func ribbon(from p0: CGPoint, c1: CGPoint, c2: CGPoint, to p1: CGPoint,
                        width w0: Double, litLeft: Bool = true,
                        steps: Int = 9) -> (fill: Path, midrib: Path, edge: Path) {
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
            let hw = w0 / 2 * (1 - u) + 0.35
            mid.append(CGPoint(x: px, y: py))
            left.append(CGPoint(x: px + nx * hw, y: py + ny * hw))
            right.append(CGPoint(x: px - nx * hw, y: py - ny * hw))
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

    /// One kelp cluster: 3–5 broad ribbons fanning from a root, each
    /// ~14–22 px wide at the base and tapering to a point, bending in
    /// a slow S as it sways, midrib and lit edge picked out. Deep
    /// clusters melt toward the water colour; near-glass ones draw as
    /// wider, darker teal silhouettes over the fish — translucent, so
    /// they stay plants, not slabs. Reduce Motion freezes the sway.
    private func drawKelp(canvas: inout GraphicsContext, size: CGSize, t: Double, piece: TankDecor) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = decorBaseY(piece, in: size)
        let front = piece.depth > 0.6
        let fronds = 3 + Int(scatter(b, 90) % 3)
        let wash = 1 - piece.depth
        let widthScale = size.width / 1024
        for k in 0..<fronds {
            let fb = scatter(b, k)
            let phase = Double(fb & 0xFF) / 0xFF * .pi * 2
            // Heights vary inside the cluster; the tallest fronds
            // reach ~45% of the tank.
            let hgt = min(size.height * (0.18 + Double((fb >> 8) & 0xFF) / 0xFF * 0.30)
                          * (0.8 + piece.scale * 0.25),
                          size.height * (front ? 0.52 : 0.45))
            let spread = (Double(k) - Double(fronds - 1) / 2) * 15 * piece.scale
            let lean = (Double((fb >> 16) & 0xFF) / 0xFF - 0.5) * 34 + spread
            let sway = reduceMotion ? 0
                : sin(t * (0.24 + Double((fb >> 24) & 0xFF) / 0xFF * 0.20) + phase)
                  * (7 + hgt * 0.05)
            let w0 = (14 + Double((fb >> 32) & 0xFF) / 0xFF * 8) * widthScale
                * (0.7 + piece.scale * 0.3) * (front ? 1.25 : 1.0)

            let root = CGPoint(x: baseX + spread * 0.6, y: baseY)
            let tip = CGPoint(x: baseX + lean + sway, y: baseY - hgt)
            // A gentle S: the lower third of the blade bows one side
            // of the root→tip chord, the upper third the other.
            let drift = lean + sway
            let chLen = max(1, (drift * drift + hgt * hgt).squareRoot())
            let sAmp = hgt * (0.07 + (reduceMotion ? 0 : 0.025 * sin(t * 0.4 + phase)))
            let perpX = hgt / chLen * sAmp
            let perpY = drift / chLen * sAmp
            let c1 = CGPoint(x: root.x + drift * 0.33 - perpX,
                             y: baseY - hgt * 0.33 - perpY)
            let c2 = CGPoint(x: root.x + drift * 0.68 + perpX,
                             y: baseY - hgt * 0.68 + perpY)
            let rib = ribbon(from: root, c1: c1, c2: c2, to: tip,
                             width: w0, litLeft: drift < 0, steps: 12)

            let body: Color
            let ribColor: Color
            let edgeColor: Color
            if front {
                // Foreground: a wide glass-side frond sliding over the
                // fish — deep teal and translucent, not a black slab.
                body = Color(red: 0.02, green: 0.16, blue: 0.19).opacity(0.55)
                ribColor = Color(red: 0.01, green: 0.08, blue: 0.10).opacity(0.5)
                edgeColor = Color(red: 0.36, green: 0.62, blue: 0.58).opacity(0.32)
            } else {
                let green = Self.waterNS.blended(
                    withFraction: 1 - wash * 0.55,
                    of: NSColor(srgbRed: 0.10, green: 0.40, blue: 0.22, alpha: 1))
                    ?? Self.waterNS
                body = Color(nsColor: green).opacity(0.80 - wash * 0.25)
                ribColor = Color(red: 0.02, green: 0.14, blue: 0.10).opacity(0.5)
                edgeColor = Color(red: 0.55, green: 0.85, blue: 0.60)
                    .opacity(0.30 * (1 - wash * 0.5))
            }
            canvas.fill(rib.fill, with: .color(body))
            canvas.stroke(rib.midrib, with: .color(ribColor),
                          style: StrokeStyle(lineWidth: max(1.2, w0 * 0.11), lineCap: .round))
            canvas.stroke(rib.edge, with: .color(edgeColor),
                          style: StrokeStyle(lineWidth: max(1.0, w0 * 0.06), lineCap: .round))
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
        // The grooves: same dome shrunk, stroked into the shade.
        for g in [0.72, 0.48, 0.26] as [Double] {
            let gr = r * g
            var groove = Path()
            groove.move(to: CGPoint(x: baseX - gr, y: baseY))
            groove.addCurve(to: CGPoint(x: baseX + gr, y: baseY),
                            control1: CGPoint(x: baseX - gr, y: baseY - gr * 1.15),
                            control2: CGPoint(x: baseX + gr, y: baseY - gr * 1.15))
            canvas.stroke(groove, with: .color(dark.opacity(0.55 - wash * 0.2)),
                          style: StrokeStyle(lineWidth: max(0.8, r * 0.08), lineCap: .round))
        }
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
        c.fill(Path(roundedRect: CGRect(x: -0.42, y: -0.18, width: 0.5, height: 0.07),
                    cornerRadius: 0.035),
               with: .color(.white.opacity(0.16)))
        // A lip of sand over the low corner buries it.
        canvas.fill(Path(ellipseIn: CGRect(x: baseX - s * 0.6, y: baseY - 3,
                                           width: s * 1.1, height: 5)),
                    with: .color(Color(red: 0.48, green: 0.40, blue: 0.27).opacity(0.9)))
    }

    /// A five-pointed star resting on the sand, with a rim, a raised
    /// centre and a row of bumps down each arm.
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
        let x = piece.x * size.width
        let y = decorBaseY(piece, in: size)
        let s = 16 * piece.scale * Self.decorBoost
        groundShadow(canvas: &canvas, x: x, y: y + 1.5,
                     halfW: s * 0.6, halfH: 3.5, alpha: 0.26)
        var c = canvas
        c.translateBy(x: x, y: y - s * 0.18)
        c.rotate(by: .radians(Double(piece.bits & 0xFF) / 0xFF * .pi * 2))
        c.scaleBy(x: s, y: s)
        c.fill(Self.starPath,
               with: .color(Color(red: 0.90, green: 0.55, blue: 0.35).opacity(0.9)))
        c.stroke(Self.starPath,
                 with: .color(Color(red: 0.55, green: 0.28, blue: 0.14).opacity(0.6)),
                 lineWidth: 0.05)
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
    /// under it — and every few seconds it burps a single bubble, the
    /// tank's smallest joke.
    private func drawChest(canvas: inout GraphicsContext, size: CGSize, t: Double, piece: TankDecor) {
        let w = 40 * piece.scale * Self.decorBoost
        let h = 26 * piece.scale * Self.decorBoost
        let x = piece.x * size.width
        let y = decorBaseY(piece, in: size) + 2
        let wood = Color(red: 0.40, green: 0.28, blue: 0.15)
        let woodDark = Color(red: 0.24, green: 0.16, blue: 0.08)
        let brass = Color(red: 0.78, green: 0.62, blue: 0.30)

        groundShadow(canvas: &canvas, x: x, y: y + 1, halfW: w * 0.62, halfH: 5, alpha: 0.32)

        // Body planks.
        let body = CGRect(x: x - w / 2, y: y - h * 0.60, width: w, height: h * 0.60)
        canvas.fill(Path(roundedRect: body, cornerRadius: 5),
                    with: .linearGradient(
                        Gradient(colors: [wood, woodDark]),
                        startPoint: CGPoint(x: x, y: y - h * 0.60),
                        endPoint: CGPoint(x: x, y: y)))
        for seam in [-0.17, 0.17] as [Double] {
            canvas.fill(Path(CGRect(x: x + w * seam - 1.0, y: y - h * 0.58,
                                    width: 2, height: h * 0.56)),
                        with: .color(woodDark.opacity(0.6)))
        }

        // The domed lid, a shade lighter than the body.
        var lid = Path()
        lid.move(to: CGPoint(x: x - w / 2 - 2.5, y: y - h * 0.58))
        lid.addQuadCurve(to: CGPoint(x: x + w / 2 + 2.5, y: y - h * 0.58),
                         control: CGPoint(x: x, y: y - h * 1.22))
        lid.closeSubpath()
        canvas.fill(lid, with: .linearGradient(
            Gradient(colors: [Color(red: 0.52, green: 0.36, blue: 0.19), wood]),
            startPoint: CGPoint(x: x, y: y - h), endPoint: CGPoint(x: x, y: y - h * 0.58)))
        canvas.stroke(lid, with: .color(.black.opacity(0.3)), lineWidth: 1.2)
        // The lid's lit crest.
        var crest = Path()
        crest.move(to: CGPoint(x: x - w * 0.28, y: y - h * 0.94))
        crest.addQuadCurve(to: CGPoint(x: x + w * 0.28, y: y - h * 0.94),
                           control: CGPoint(x: x, y: y - h * 1.14))
        canvas.stroke(crest, with: .color(Color(red: 0.9, green: 0.75, blue: 0.5).opacity(0.4)),
                      lineWidth: 2)

        // Brass bands over the lid & body, and the latch.
        for bandX in [-0.30, 0.30] as [Double] {
            let bx = x + w * bandX
            canvas.fill(Path(CGRect(x: bx - 2.6, y: y - h * 0.60, width: 5.2, height: h * 0.60)),
                        with: .color(brass.opacity(0.75)))
            var band = Path()
            band.move(to: CGPoint(x: bx - 2.6, y: y - h * 0.58))
            band.addQuadCurve(to: CGPoint(x: bx + 2.6, y: y - h * 0.58),
                              control: CGPoint(x: bx, y: y - h * (0.58 + 0.64 * (1 - abs(bandX) * 2.2))))
            canvas.stroke(band, with: .color(brass.opacity(0.75)), lineWidth: 5.2)
        }
        let latch = CGRect(x: x - 4, y: y - h * 0.72, width: 8, height: h * 0.20)
        canvas.fill(Path(roundedRect: latch, cornerRadius: 1.6),
                    with: .color(brass.opacity(0.85)))
        canvas.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: y - h * 0.66, width: 3.2, height: 4)),
                    with: .color(woodDark.opacity(0.9)))

        guard !reduceMotion else { return }
        let period = 6 + Double(piece.bits & 0xFF) / 0xFF * 5
        let rise = frac(t / period + Double((piece.bits >> 8) & 0xFF) / 0xFF)
        guard rise < 0.6 else { return }
        let br = 2.0 + rise * 2.5
        let by = y - h - rise * size.height * 0.35
        canvas.stroke(Path(ellipseIn: CGRect(x: x - br, y: by - br, width: br * 2, height: br * 2)),
                      with: .color(.white.opacity(0.5 * (1 - rise / 0.6))), lineWidth: 0.8)
    }

    // MARK: Ambient life

    /// A jellyfish pulses through the mid-water every ~40 s — or, when
    /// the tank is empty (`resident`), stays on as the standing guest
    /// on a slow figure-eight, so a quiet tank still has one living
    /// thing in it. A translucent bell over four trailing tentacles.
    /// Reduce Motion parks it mid-tank, unpulsed.
    private func drawJellyfish(canvas: inout GraphicsContext, size: CGSize, t: Double,
                               resident: Bool) {
        let x: Double
        let y: Double
        let pulse: Double
        let alpha: Double
        if resident {
            if reduceMotion {
                x = size.width * 0.5
                y = size.height * 0.30
                pulse = 0
            } else {
                x = size.width * (0.5 + 0.17 * sin(t * 0.11))
                y = size.height * (0.30 + 0.05 * sin(t * 0.23 + 1.3))
                pulse = sin(t * 1.9) * 0.10
            }
            alpha = 0.62
        } else {
            let progress: Double
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
            x = size.width * (1.08 - 1.24 * progress)
            y = size.height * (0.30 + 0.10 * sin(progress * .pi * 2 + 1))
        }
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
            Gradient(stops: [
                .init(color: Color(red: 0.97, green: 0.84, blue: 0.93).opacity(0.95), location: 0),
                .init(color: Color(red: 0.90, green: 0.72, blue: 0.85).opacity(0.45), location: 0.7),
                .init(color: Color(red: 0.85, green: 0.65, blue: 0.80).opacity(0.15), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: -0.5), endPoint: CGPoint(x: 0, y: 0.3)))
        // A rim of light along the bell's lower lip.
        var lip = Path()
        lip.move(to: CGPoint(x: -0.5, y: 0.12))
        lip.addQuadCurve(to: CGPoint(x: 0.5, y: 0.12), control: CGPoint(x: 0, y: 0.30))
        j.stroke(lip, with: .color(Color(red: 0.98, green: 0.88, blue: 0.95).opacity(0.5)),
                 lineWidth: 0.04)
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
        // It inches along the dune crest, not the glass bottom.
        let y = sandTop(atX: x, in: size) - 1
        var s = canvas
        s.opacity = 0.85
        s.translateBy(x: x, y: y)
        s.scaleBy(x: 25, y: 19)
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
        // Keep the deepest lane clear of the raised bed (the highest
        // dune crest is ~92 pt up) with room for a belly under it.
        let bottom = size.height - 108.0
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
            // It comes to rest on the dune under it, not the glass.
            let floorY = sandTop(atX: frozen.x, in: size) - 12
            l.y = min(laneY + (floorY - laneY) * eased, floorY) + rock * 4
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

        // Depth: deeper lanes dim & wash toward the water colour, with
        // a slight extra blue cast on top of the desaturation.
        let base: NSColor = fish.state == .sinking
            ? .secondaryLabelColor
            : ProviderStyle.style(for: fish.providerID).nsAccent
        let washed = base.blended(withFraction: lane * 0.42, of: Self.waterNS) ?? base
        let bodyColor = Color(nsColor: washed)
        let lightColor = Color(nsColor: washed.blended(withFraction: 0.55, of: .white) ?? washed)
        let darkColor = Color(nsColor: washed.blended(withFraction: 0.38, of: .black) ?? washed)

        // Recent session activity quickens the tail; a lagging beat in
        // the pitch gives the head the classic follow-the-tail sway.
        // Reduce Motion stills both — the fish glides, poses stay.
        let recency = fish.lastUpdate.map { now.timeIntervalSince($0) } ?? .infinity
        let vigor = 1 + 1.15 * exp(-max(0, recency) / 9)
        let beat = t * (3.0 + fish.speed * 24) * vigor + phase
        let wag = reduceMotion ? 0 : sin(beat) * 0.22 * l.wag * (1 + l.turn * 0.3)
        let sway = reduceMotion ? 0 : sin(beat - 0.8) * 0.045 * l.wag

        // A low fish pools a soft shadow on the sand under it; the
        // pool fades out as it climbs.
        if fish.state != .leaving {
            let floorY = sandTop(atX: l.x, in: size) + 3
            let clearance = floorY - (l.y + height * 0.5)
            if clearance < 90 {
                groundShadow(canvas: &canvas, x: l.x, y: floorY,
                             halfW: length * 0.48, halfH: 4.5,
                             alpha: 0.30 * clamp01(1 - max(0, clearance) / 90) * l.opacity)
            }
        }

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
        // The body is one countershaded gradient: saturated back,
        // washing to a pale belly, with a blue cast deep down.
        f.fill(art.body, with: .linearGradient(
            Gradient(stops: [
                .init(color: darkColor.opacity(0.9), location: 0),
                .init(color: bodyColor, location: 0.35),
                .init(color: bodyColor, location: 0.62),
                .init(color: lightColor.opacity(0.95), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: -0.55), endPoint: CGPoint(x: 0, y: 0.48)))
        if lane > 0.05 {
            f.fill(art.body,
                   with: .color(Color(red: 0.05, green: 0.20, blue: 0.50).opacity(lane * 0.16)))
        }
        drawPattern(fish.species.pattern, over: art.body,
                    light: lightColor, dark: darkColor, into: &f)
        // Volume: a soft sheen along the back.
        f.fill(art.body, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.26), .clear]),
            startPoint: CGPoint(x: 0, y: -0.5), endPoint: CGPoint(x: 0, y: 0.02)))
        // A thin darker outline keeps the silhouette crisp.
        f.stroke(art.body, with: .color(darkColor.opacity(0.55)), lineWidth: 0.035)
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

    /// The empty-tank caption, resolved & measured once per frame so
    /// the decor pass can keep clear of it: a small translucent
    /// capsule pinned to the bottom-left with a 16 pt margin, like a
    /// gallery plaque set on the sand.
    private func captionLayout(canvas: inout GraphicsContext, size: CGSize)
        -> (text: GraphicsContext.ResolvedText, rect: CGRect) {
        let resolved = canvas.resolve(
            Text("Quiet water — fish arrive when agents start")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62)))
        let textSize = resolved.measure(in: CGSize(width: size.width - 64, height: 40))
        let rect = CGRect(x: 16, y: size.height - 16 - textSize.height - 12,
                          width: textSize.width + 22, height: textSize.height + 12)
        return (resolved, rect)
    }

    /// A quiet tank is still a dressed tank — the jellyfish stays on
    /// as the resident and the caption capsule sits low on the left.
    private func drawEmpty(canvas: inout GraphicsContext, size: CGSize,
                           caption: (text: GraphicsContext.ResolvedText, rect: CGRect)) {
        let pill = Path(roundedRect: caption.rect, cornerRadius: caption.rect.height / 2)
        canvas.fill(pill,
                    with: .color(Color(red: 0.02, green: 0.07, blue: 0.13).opacity(0.55)))
        canvas.stroke(pill, with: .color(.white.opacity(0.10)), lineWidth: 0.75)
        canvas.draw(caption.text,
                    at: CGPoint(x: caption.rect.midX, y: caption.rect.midY),
                    anchor: .center)
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
