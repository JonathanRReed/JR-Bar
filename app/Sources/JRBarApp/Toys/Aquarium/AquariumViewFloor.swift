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

    /// One seeded grain of sand, in unit space.
    private struct Speck {
        var x, y, r: Double
        var light: Bool
    }

    /// ~110 grains scattered over the bed, seeded once. The hash goes
    /// through the same murmur-style finalizer `decorSet` uses —
    /// FNV-1a's low bits cluster on sequential tags and would lay the
    /// grains out in rows.
    private static let sandSpeckles: [Speck] = (0..<150).map { i in
        var h = AquariumModel.stableHash("speck-\(i)")
        h ^= h >> 33
        h &*= 0xff51afd7ed558ccd
        h ^= h >> 33
        return Speck(x: Double(h & 0xFFFF) / 0xFFFF,
                     y: Double((h >> 16) & 0xFFFF) / 0xFFFF,
                     r: 0.6 + Double((h >> 32) & 0xF) / 0xF * 1.3,
                     light: (h >> 48) & 1 == 0)
    }

    /// The floor's palette per substrate (docs/TOYS.md shop): classic
    /// tan, white's bright aragonite, black's basalt gravel — the
    /// grains, crest and ripples all follow.
    var sandTones: (backA: Color, backB: Color, frontA: Color,
                            frontB: Color, frontC: Color, crest: Color,
                            rim: Color, ripple: Color,
                            speckLight: Color, speckDark: Color) {
        switch substrateKey {
        case "white":
            return (Color(red: 0.46, green: 0.45, blue: 0.42),
                    Color(red: 0.18, green: 0.19, blue: 0.22),
                    Color(red: 0.97, green: 0.95, blue: 0.88),
                    Color(red: 0.82, green: 0.79, blue: 0.68),
                    Color(red: 0.48, green: 0.44, blue: 0.34),
                    Color(red: 1.0, green: 1.0, blue: 0.94),
                    Color(red: 1.0, green: 0.98, blue: 0.86),
                    Color(red: 0.50, green: 0.45, blue: 0.34),
                    Color(red: 1.0, green: 0.99, blue: 0.94),
                    Color(red: 0.42, green: 0.38, blue: 0.30))
        case "black":
            return (Color(red: 0.10, green: 0.11, blue: 0.14),
                    Color(red: 0.02, green: 0.02, blue: 0.04),
                    Color(red: 0.22, green: 0.23, blue: 0.28),
                    Color(red: 0.12, green: 0.13, blue: 0.16),
                    Color(red: 0.04, green: 0.04, blue: 0.05),
                    Color(red: 0.62, green: 0.65, blue: 0.72),
                    Color(red: 0.52, green: 0.55, blue: 0.62),
                    Color(red: 0.03, green: 0.03, blue: 0.04),
                    Color(red: 0.60, green: 0.63, blue: 0.70),
                    Color(red: 0.01, green: 0.01, blue: 0.02))
        default:
            return (Color(red: 0.23, green: 0.22, blue: 0.18),
                    Color(red: 0.06, green: 0.07, blue: 0.11),
                    Color(red: 0.72, green: 0.62, blue: 0.42),
                    Color(red: 0.46, green: 0.37, blue: 0.23),
                    Color(red: 0.15, green: 0.12, blue: 0.08),
                    Color(red: 0.98, green: 0.88, blue: 0.60),
                    Color(red: 0.88, green: 0.78, blue: 0.56),
                    Color(red: 0.20, green: 0.15, blue: 0.09),
                    Color(red: 0.82, green: 0.72, blue: 0.50),
                    Color(red: 0.10, green: 0.08, blue: 0.05))
        }
    }

    /// The floor: a darker back dune (the far end of the bed) with a
    /// shadowed seam above it, the lit front dune, and a scatter of
    /// seeded grains.
    func drawSand(canvas: inout GraphicsContext, size: CGSize) {
        let sand = sandTones
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
            Gradient(colors: [sand.backA, sand.backB]),
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
                .init(color: sand.frontA, location: 0),
                .init(color: sand.frontB, location: 0.5),
                .init(color: sand.frontC, location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: sandTop(atX: size.width / 2, in: size)),
            endPoint: CGPoint(x: 0, y: size.height)))
        // The crest catches the god rays: a broad soft glow under a
        // thin bright edge, so the dune tops read lit from above.
        var crestGlow = canvas
        crestGlow.blendMode = .plusLighter
        crestGlow.stroke(rim,
                         with: .color(sand.crest.opacity(0.14)),
                         style: StrokeStyle(lineWidth: 9, lineCap: .round))
        canvas.stroke(rim, with: .color(sand.rim.opacity(0.45)),
                      lineWidth: 1.2)
        // Wind-ripple contours: faint strokes paralleling the crest a
        // little way down the face — what makes a bar of colour read
        // as piled sand.
        for i in 0..<3 {
            let off = 13.0 + Double(i) * 15
            var ripple = Path()
            ripple.move(to: CGPoint(x: 0, y: sandTop(atX: 0, in: size) + off))
            var rx = 0.0
            while rx <= size.width {
                let u = rx / max(1, size.width)
                ripple.addLine(to: CGPoint(
                    x: rx,
                    y: sandTop(atX: rx, in: size) + off
                        + 2.4 * sin(u * .pi * 6.2 + Double(i) * 2.1 + Self.dunePhase2)))
                rx += 8
            }
            canvas.stroke(ripple,
                          with: .color(sand.ripple
                                        .opacity(0.10 - Double(i) * 0.03)),
                          style: StrokeStyle(lineWidth: 1.6 - Double(i) * 0.4, lineCap: .round))
        }

        // Grain scale & contrast per substrate: basalt gravel is
        // chunky and high-contrast, aragonite fine and bright, the
        // classic tan somewhere between.
        let grainScale = substrateKey == "black" ? 2.1
            : substrateKey == "white" ? 0.9 : 1.0
        let grainAlpha = substrateKey == "black" ? 1.6 : 1.0
        for speck in Self.sandSpeckles {
            let sx = speck.x * size.width
            let top = sandTop(atX: sx, in: size)
            let sy = top + 2 + speck.y * max(0, size.height - top - 3)
            let r = speck.r * grainScale
            canvas.fill(Path(ellipseIn: CGRect(x: sx - r, y: sy - r * 0.7,
                                               width: r * 2, height: r * 1.4)),
                        with: .color(speck.light
                                     ? sand.speckLight.opacity(min(1, 0.20 * grainAlpha))
                                     : sand.speckDark.opacity(min(1, 0.25 * grainAlpha))))
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

    /// The glass itself: the far edges of the tank fall away, darkness
    /// pools along the bottom, and a faint reflection streaks the
    /// top-left corner — the pane you look through.
    func drawGlass(canvas: inout GraphicsContext, size: CGSize) {
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
    func drawPlankton(canvas: inout GraphicsContext, size: CGSize, t: Double,
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
            // The dark themes' motes are bioluminescent — cyan/teal
            // pulses instead of dust catching light.
            let moteColor = isDarkTheme
                ? (((h >> 50) & 1) == 0
                   ? Color(red: 0.30, green: 0.95, blue: 0.85)
                   : Color(red: 0.25, green: 0.70, blue: 0.95))
                : .white
            canvas.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(
                            Gradient(colors: [moteColor.opacity(alpha * twinkle
                                                                * (isDarkTheme ? 1.6 : 1)),
                                              .clear]),
                            center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
        }
        // Deeper still in the dark themes: the lantern-fish glimmers —
        // a handful of distant dots blinking on their own slow clocks.
        if isDarkTheme && !front {
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
                g.fill(Path(ellipseIn: CGRect(x: lx - lr, y: ly - lr,
                                              width: lr * 2, height: lr * 2)),
                       with: .radialGradient(
                           Gradient(colors: [Color(red: 0.60, green: 0.95,
                                                   blue: 0.90)
                                               .opacity(0.55), .clear]),
                           center: CGPoint(x: lx, y: ly), startRadius: 0,
                           endRadius: lr * 3))
            }
        }
    }

    /// Ambient bubbles — half streaming off the chest, half seeded at
    /// random spots in the sand — each with a rim, a faint body and a
    /// glint. They wobble up from the bed and pop just under the
    /// surface. The seed goes through `scatter` so the rise phases
    /// don't fall into an evenly spaced ladder.
    func drawBubbles(canvas: inout GraphicsContext, size: CGSize, t: Double, density: Double) {
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
            // Each bubble staggers its own amount at its own rate.
            let wobble = 2.5 + Double((h >> 48) & 0xF) / 0xF * 8.5
            let x = x0 * size.width
                + (reduceMotion ? 0 : sin(t * (0.9 + speed * 6) + phase) * wobble)
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
}
