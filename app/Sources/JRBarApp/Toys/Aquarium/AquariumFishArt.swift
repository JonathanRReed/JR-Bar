import JRBarCore
import SwiftUI

/// The chunky cartoon fish kit (docs/TOYS.md): fat rounded bodies,
/// bold dark outlines, big eyes with catchlights, a mouth that smiles
/// when fed and makes a small "o" when hungry, translucent fins.
/// Everything is a unit-space `Path` — nose toward +x, body centred
/// near the origin, roughly x −0.5…0.5 — so the caller scales to the
/// fish's drawn length, flips x for left-facing, and rotates for
/// pitch without the paths knowing. No image assets anywhere.
enum CartoonFish {
    /// What the fish is saying with its mouth.
    enum MouthKind: Equatable, Sendable {
        /// Just ate: a big open smile.
        case smile
        /// Starving: a small round "o".
        case hungry
        /// Cruising: a soft neutral curve.
        case plain
    }

    /// The colours a species is painted in — the provider's accent
    /// keeps the fish's identity (docs/TOYS.md).
    struct Palette: Sendable {
        var body: Color      // provider accent, depth-washed
        var light: Color     // pale belly / fin light
        var dark: Color      // markings
        var outline: Color   // bold dark outline
    }

    /// One species' silhouette kit.
    struct Art: Sendable {
        var body: Path
        /// A pale belly patch clipped inside the body, when the
        /// silhouette leaves room for one.
        var belly: Path?
        /// Trailing shapes under the body (spikes, veils, streamers).
        var extras: [Path]
        /// The tail, rebuilt per frame off the wag phase.
        var tail: (@Sendable (Double) -> Path)?
        var dorsal: Path?
        var anal: Path?
        /// The near-side fin, rebuilt off the flap phase.
        var pectoral: (@Sendable (Double) -> Path)?
        /// Where the eye sits and how big it is — big, per the brief.
        var eye: CGPoint
        var eyeR: Double
        /// The mouth anchor: the nose-side point it draws around.
        var mouth: CGPoint
        /// Where a hat sits on the head.
        var hatAnchor: CGPoint
    }

    // MARK: Shared shapes

    /// A fat teardrop body: rounded nose at +x, full belly, tapering
    /// tail root at −x. `fullness` fattens the mid-body.
    private static func teardrop(fullness: Double = 1) -> Path {
        let h = 0.30 * fullness
        var p = Path()
        p.move(to: CGPoint(x: 0.50, y: -0.01))
        p.addCurve(to: CGPoint(x: 0.06, y: -h),
                   control1: CGPoint(x: 0.42, y: -h * 0.9),
                   control2: CGPoint(x: 0.22, y: -h * 1.05))
        p.addCurve(to: CGPoint(x: -0.36, y: -0.07),
                   control1: CGPoint(x: -0.14, y: -h * 1.02),
                   control2: CGPoint(x: -0.30, y: -0.16))
        p.addQuadCurve(to: CGPoint(x: -0.36, y: 0.07),
                       control: CGPoint(x: -0.40, y: 0))
        p.addCurve(to: CGPoint(x: 0.08, y: h * 0.82),
                   control1: CGPoint(x: -0.16, y: h * 0.85),
                   control2: CGPoint(x: -0.02, y: h * 1.02))
        p.addCurve(to: CGPoint(x: 0.50, y: -0.01),
                   control1: CGPoint(x: 0.30, y: h * 0.72),
                   control2: CGPoint(x: 0.44, y: h * 0.30))
        p.closeSubpath()
        return p
    }

    /// A soft belly oval sitting in the lower half of a body.
    private static func bellyPatch(x: Double, y: Double, w: Double, h: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: x - w, y: y))
        p.addQuadCurve(to: CGPoint(x: x + w, y: y + h * 0.1),
                       control: CGPoint(x: x, y: y + h))
        p.addQuadCurve(to: CGPoint(x: x - w, y: y),
                       control: CGPoint(x: x, y: y - h * 0.55))
        p.closeSubpath()
        return p
    }

    /// A round fan tail: peduncle at −0.34, notched trailing edge.
    /// `wag` swings the tips; `span`/`reach` size it.
    private static func fanTail(wag: Double, span: Double = 0.30, reach: Double = 0.70) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: -0.34, y: -0.07))
        p.addCurve(to: CGPoint(x: -reach, y: -span + wag),
                   control1: CGPoint(x: -0.50, y: -0.22 + wag * 0.4),
                   control2: CGPoint(x: -0.64, y: -span + wag * 0.8))
        p.addQuadCurve(to: CGPoint(x: -0.56, y: wag * 0.5),
                       control: CGPoint(x: -0.70, y: -0.02 + wag * 0.8))
        p.addCurve(to: CGPoint(x: -reach, y: span + wag),
                   control1: CGPoint(x: -0.50, y: 0.12 + wag * 0.6),
                   control2: CGPoint(x: -0.64, y: span + wag * 0.8))
        p.addQuadCurve(to: CGPoint(x: -0.34, y: 0.07),
                       control: CGPoint(x: -0.50, y: 0.22 + wag * 0.4))
        p.closeSubpath()
        return p
    }

    /// A triangle-ish dorsal fin along the back.
    private static func dorsalFin(root0: Double, root1: Double, apex: CGPoint) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: root0, y: -0.24))
        p.addQuadCurve(to: apex, control: CGPoint(x: (root0 + apex.x) / 2 + 0.04, y: apex.y - 0.04))
        p.addQuadCurve(to: CGPoint(x: root1, y: -0.20),
                       control: CGPoint(x: (root1 + apex.x) / 2 - 0.02, y: apex.y + 0.02))
        p.closeSubpath()
        return p
    }

    /// The near-side pectoral fin; `flap` follows the wag a beat late.
    private static func pectoralFin(flap: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0.14, y: 0.06))
        p.addQuadCurve(to: CGPoint(x: -0.06, y: 0.24 + flap),
                       control: CGPoint(x: 0.02, y: 0.12 + flap * 0.6))
        p.addQuadCurve(to: CGPoint(x: 0.10, y: 0.20),
                       control: CGPoint(x: 0.02, y: 0.26 + flap * 0.5))
        p.closeSubpath()
        return p
    }

    // MARK: Species kits

    /// The shark's crescent tail: long upper lobe, short lower.
    private static func lunateTail(wag: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: -0.36, y: -0.05))
        p.addCurve(to: CGPoint(x: -0.82, y: -0.46 + wag),
                   control1: CGPoint(x: -0.54, y: -0.18 + wag * 0.3),
                   control2: CGPoint(x: -0.72, y: -0.38 + wag * 0.8))
        p.addQuadCurve(to: CGPoint(x: -0.60, y: wag * 0.4),
                       control: CGPoint(x: -0.76, y: -0.05 + wag * 0.7))
        p.addCurve(to: CGPoint(x: -0.70, y: 0.28 + wag),
                   control1: CGPoint(x: -0.50, y: 0.08 + wag * 0.6),
                   control2: CGPoint(x: -0.64, y: 0.24 + wag * 0.8))
        p.addQuadCurve(to: CGPoint(x: -0.36, y: 0.05),
                   control: CGPoint(x: -0.50, y: 0.15 + wag * 0.4))
        p.closeSubpath()
        return p
    }

    private static let kits: [FishSpecies: Art] = {
        var kits: [FishSpecies: Art] = [:]

        // Minnow: the plain fat fish.
        kits[.minnow] = Art(
            body: teardrop(fullness: 0.9),
            belly: bellyPatch(x: 0.10, y: 0.16, w: 0.26, h: 0.16),
            extras: [],
            tail: { fanTail(wag: $0, span: 0.26, reach: 0.62) },
            dorsal: dorsalFin(root0: 0.10, root1: -0.18, apex: CGPoint(x: -0.02, y: -0.52)),
            anal: nil,
            pectoral: { pectoralFin(flap: $0) },
            eye: CGPoint(x: 0.30, y: -0.08), eyeR: 0.085,
            mouth: CGPoint(x: 0.46, y: 0.06),
            hatAnchor: CGPoint(x: 0.22, y: -0.24))

        // Tetra: same fat teardrop, smaller & shinier — the stripe is
        // drawn by the pattern pass.
        kits[.tetra] = Art(
            body: teardrop(fullness: 0.8),
            belly: bellyPatch(x: 0.10, y: 0.14, w: 0.24, h: 0.13),
            extras: [],
            tail: { fanTail(wag: $0, span: 0.24, reach: 0.58) },
            dorsal: dorsalFin(root0: 0.10, root1: -0.16, apex: CGPoint(x: -0.02, y: -0.46)),
            anal: nil,
            pectoral: { pectoralFin(flap: $0) },
            eye: CGPoint(x: 0.30, y: -0.07), eyeR: 0.095,
            mouth: CGPoint(x: 0.46, y: 0.05),
            hatAnchor: CGPoint(x: 0.22, y: -0.22))

        // Tang: chunkier oval, the tail-end band is its pattern.
        kits[.tang] = Art(
            body: teardrop(fullness: 1.05),
            belly: bellyPatch(x: 0.10, y: 0.18, w: 0.26, h: 0.17),
            extras: [],
            tail: { fanTail(wag: $0, span: 0.28, reach: 0.62) },
            dorsal: dorsalFin(root0: 0.14, root1: -0.22, apex: CGPoint(x: -0.04, y: -0.52)),
            anal: nil,
            pectoral: { pectoralFin(flap: $0) },
            eye: CGPoint(x: 0.30, y: -0.10), eyeR: 0.085,
            mouth: CGPoint(x: 0.46, y: 0.06),
            hatAnchor: CGPoint(x: 0.22, y: -0.28))

        // Clownfish: the roundest mid-body of the teardrops, bold bars.
        kits[.clownfish] = Art(
            body: teardrop(fullness: 1.2),
            belly: bellyPatch(x: 0.08, y: 0.20, w: 0.28, h: 0.20),
            extras: [],
            tail: { fanTail(wag: $0, span: 0.26, reach: 0.58) },
            dorsal: dorsalFin(root0: 0.16, root1: -0.20, apex: CGPoint(x: -0.02, y: -0.52)),
            anal: nil,
            pectoral: { pectoralFin(flap: $0) },
            eye: CGPoint(x: 0.31, y: -0.10), eyeR: 0.088,
            mouth: CGPoint(x: 0.47, y: 0.07),
            hatAnchor: CGPoint(x: 0.22, y: -0.30))

        // Betta: an oval under a flowing tail & ventral veil.
        let bettaVeil: Path = {
            var p = Path()
            p.move(to: CGPoint(x: 0.02, y: 0.20))
            p.addCurve(to: CGPoint(x: -0.66, y: 0.66),
                       control1: CGPoint(x: -0.22, y: 0.36),
                       control2: CGPoint(x: -0.54, y: 0.62))
            p.addQuadCurve(to: CGPoint(x: -0.36, y: 0.16),
                           control: CGPoint(x: -0.62, y: 0.44))
            p.addQuadCurve(to: CGPoint(x: 0.02, y: 0.20),
                           control: CGPoint(x: -0.20, y: 0.24))
            p.closeSubpath()
            return p
        }()
        kits[.betta] = Art(
            body: teardrop(fullness: 1.0),
            belly: bellyPatch(x: 0.10, y: 0.18, w: 0.26, h: 0.16),
            extras: [bettaVeil],
            tail: { fanTail(wag: $0, span: 0.50, reach: 0.88) },
            dorsal: dorsalFin(root0: 0.12, root1: -0.24, apex: CGPoint(x: -0.06, y: -0.50)),
            anal: nil,
            pectoral: { pectoralFin(flap: $0) },
            eye: CGPoint(x: 0.30, y: -0.09), eyeR: 0.082,
            mouth: CGPoint(x: 0.46, y: 0.06),
            hatAnchor: CGPoint(x: 0.20, y: -0.26))

        // Shark: a fat blade — still chunky, still cute.
        let sharkBody: Path = {
            var p = Path()
            p.move(to: CGPoint(x: 0.54, y: -0.02))
            p.addCurve(to: CGPoint(x: 0.04, y: -0.30),
                       control1: CGPoint(x: 0.42, y: -0.22),
                       control2: CGPoint(x: 0.24, y: -0.33))
            p.addCurve(to: CGPoint(x: -0.42, y: -0.07),
                       control1: CGPoint(x: -0.20, y: -0.27),
                       control2: CGPoint(x: -0.36, y: -0.15))
            p.addQuadCurve(to: CGPoint(x: -0.42, y: 0.07),
                           control: CGPoint(x: -0.46, y: 0))
            p.addCurve(to: CGPoint(x: 0.10, y: 0.22),
                       control1: CGPoint(x: -0.18, y: 0.20),
                       control2: CGPoint(x: -0.04, y: 0.26))
            p.addCurve(to: CGPoint(x: 0.54, y: -0.02),
                       control1: CGPoint(x: 0.32, y: 0.18),
                       control2: CGPoint(x: 0.48, y: 0.08))
            p.closeSubpath()
            return p
        }()
        kits[.shark] = Art(
            body: sharkBody,
            belly: bellyPatch(x: 0.12, y: 0.16, w: 0.30, h: 0.14),
            extras: [],
            tail: { lunateTail(wag: $0) },
            dorsal: dorsalFin(root0: 0.06, root1: -0.24, apex: CGPoint(x: -0.10, y: -0.66)),
            anal: nil,
            pectoral: { pectoralFin(flap: $0 * 0.7) },
            eye: CGPoint(x: 0.36, y: -0.07), eyeR: 0.070,
            mouth: CGPoint(x: 0.50, y: 0.08),
            hatAnchor: CGPoint(x: 0.24, y: -0.26))

        // Angelfish: a tall disc on long fins.
        let angelBody: Path = {
            var p = Path()
            p.addEllipse(in: CGRect(x: -0.30, y: -0.44, width: 0.78, height: 0.88))
            return p
        }()
        let angelDorsal: Path = {
            var p = Path()
            p.move(to: CGPoint(x: 0.12, y: -0.36))
            p.addQuadCurve(to: CGPoint(x: -0.10, y: -0.80),
                           control: CGPoint(x: 0.06, y: -0.64))
            p.addQuadCurve(to: CGPoint(x: -0.22, y: -0.30),
                           control: CGPoint(x: -0.16, y: -0.60))
            p.closeSubpath()
            return p
        }()
        let angelAnal: Path = {
            var p = Path()
            p.move(to: CGPoint(x: 0.12, y: 0.36))
            p.addQuadCurve(to: CGPoint(x: -0.10, y: 0.80),
                           control: CGPoint(x: 0.06, y: 0.64))
            p.addQuadCurve(to: CGPoint(x: -0.22, y: 0.30),
                           control: CGPoint(x: -0.16, y: 0.60))
            p.closeSubpath()
            return p
        }()
        kits[.angelfish] = Art(
            body: angelBody,
            belly: bellyPatch(x: 0.10, y: 0.22, w: 0.24, h: 0.18),
            extras: [],
            tail: { fanTail(wag: $0, span: 0.20, reach: 0.56) },
            dorsal: angelDorsal,
            anal: angelAnal,
            pectoral: { pectoralFin(flap: $0) },
            eye: CGPoint(x: 0.28, y: -0.14), eyeR: 0.078,
            mouth: CGPoint(x: 0.44, y: 0.02),
            hatAnchor: CGPoint(x: 0.16, y: -0.38))

        // Puffer: a near-circle with spikes & spots.
        let pufferBody: Path = {
            var p = Path()
            p.addEllipse(in: CGRect(x: -0.38, y: -0.44, width: 0.86, height: 0.88))
            return p
        }()
        let pufferSpikes: Path = {
            var p = Path()
            for i in 0..<10 {
                let a = Double(i) / 10 * .pi * 2 + 0.3
                let ex = cos(a) * 0.44, ey = sin(a) * 0.44
                guard ex > -0.24 || abs(ey) > 0.24 else { continue }
                let px = -sin(a), py = cos(a)
                p.move(to: CGPoint(x: ex + px * 0.045, y: ey + py * 0.045))
                p.addLine(to: CGPoint(x: ex + cos(a) * 0.11, y: ey + sin(a) * 0.11))
                p.addLine(to: CGPoint(x: ex - px * 0.045, y: ey - py * 0.045))
                p.closeSubpath()
            }
            return p
        }()
        kits[.puffer] = Art(
            body: pufferBody,
            belly: bellyPatch(x: 0.06, y: 0.22, w: 0.30, h: 0.20),
            extras: [pufferSpikes],
            tail: { fanTail(wag: $0, span: 0.18, reach: 0.56) },
            dorsal: dorsalFin(root0: 0.04, root1: -0.14, apex: CGPoint(x: -0.04, y: -0.58)),
            anal: nil,
            pectoral: { pectoralFin(flap: $0) },
            eye: CGPoint(x: 0.24, y: -0.14), eyeR: 0.095,
            mouth: CGPoint(x: 0.42, y: 0.04),
            hatAnchor: CGPoint(x: 0.10, y: -0.40))

        // Seahorse: upright, curled tail, little crown bumps.
        let seahorseBody: Path = {
            var p = Path()
            p.move(to: CGPoint(x: 0.46, y: -0.34))
            p.addQuadCurve(to: CGPoint(x: 0.30, y: -0.28),
                           control: CGPoint(x: 0.40, y: -0.26))
            p.addQuadCurve(to: CGPoint(x: 0.14, y: -0.44),
                           control: CGPoint(x: 0.20, y: -0.40))
            p.addCurve(to: CGPoint(x: -0.02, y: 0.12),
                   control1: CGPoint(x: 0.08, y: -0.36),
                   control2: CGPoint(x: -0.08, y: -0.08))
            p.addCurve(to: CGPoint(x: 0.26, y: 0.36),
                   control1: CGPoint(x: -0.10, y: 0.26),
                   control2: CGPoint(x: 0.10, y: 0.40))
            p.addQuadCurve(to: CGPoint(x: 0.34, y: 0.24),
                           control: CGPoint(x: 0.34, y: 0.34))
            p.addQuadCurve(to: CGPoint(x: 0.22, y: 0.28),
                           control: CGPoint(x: 0.30, y: 0.20))
            p.addCurve(to: CGPoint(x: 0.16, y: 0.00),
                   control1: CGPoint(x: 0.12, y: 0.20),
                   control2: CGPoint(x: 0.22, y: 0.10))
            p.addQuadCurve(to: CGPoint(x: 0.30, y: -0.22),
                           control: CGPoint(x: 0.10, y: -0.12))
            p.closeSubpath()
            return p
        }()
        let seahorseFin: Path = {
            var p = Path()
            p.move(to: CGPoint(x: -0.02, y: -0.12))
            p.addQuadCurve(to: CGPoint(x: -0.26, y: 0.00),
                           control: CGPoint(x: -0.18, y: -0.14))
            p.addQuadCurve(to: CGPoint(x: -0.02, y: 0.08),
                           control: CGPoint(x: -0.20, y: 0.06))
            p.closeSubpath()
            return p
        }()
        kits[.seahorse] = Art(
            body: seahorseBody,
            belly: bellyPatch(x: 0.14, y: 0.14, w: 0.14, h: 0.16),
            extras: [seahorseFin],
            tail: nil,
            dorsal: nil,
            anal: nil,
            pectoral: nil,
            eye: CGPoint(x: 0.28, y: -0.34), eyeR: 0.075,
            mouth: CGPoint(x: 0.46, y: -0.32),
            hatAnchor: CGPoint(x: 0.18, y: -0.46))

        return kits
    }()

    static func art(for species: FishSpecies) -> Art {
        kits[species] ?? kits[.minnow]!
    }

    // MARK: Draw

    /// Draw one fish at the origin of `f` — already translated, rotated,
    /// flipped & scaled to unit space by the caller. `blink` is 0 open
    /// …1 shut. `dead` (a sinking fish) crosses the eye out.
    /// `aspectComp` un-shears the eye: the caller's non-uniform scale
    /// (length × height) would stretch the eye's circle, so the eye's
    /// y-radii pre-multiply by it — pass `drawnLength / drawnHeight`.
    static func draw(into f: inout GraphicsContext, species: FishSpecies,
                     palette: Palette, wag: Double, flap: Double,
                     mouth: MouthKind, blink: Double, dead: Bool,
                     patternSeed: UInt64, aspectComp: Double = 1) {
        let art = art(for: species)

        // Fins & extras behind the body silhouette — translucent, so
        // they read as fins rather than more body.
        if let tail = art.tail {
            let tailPath = tail(wag)
            f.fill(tailPath, with: .color(palette.body.opacity(0.55)))
            f.stroke(tailPath, with: .color(palette.outline.opacity(0.7)),
                     lineWidth: 0.035)
        }
        for extra in art.extras {
            f.fill(extra, with: .color(palette.body.opacity(0.5)))
            f.stroke(extra, with: .color(palette.outline.opacity(0.6)),
                     lineWidth: 0.03)
        }
        if let dorsal = art.dorsal {
            f.fill(dorsal, with: .color(palette.body.opacity(0.6)))
            f.fill(dorsal, with: .color(palette.light.opacity(0.25)))
            f.stroke(dorsal, with: .color(palette.outline.opacity(0.7)),
                     lineWidth: 0.03)
        }
        if let anal = art.anal {
            f.fill(anal, with: .color(palette.body.opacity(0.55)))
            f.stroke(anal, with: .color(palette.outline.opacity(0.6)),
                     lineWidth: 0.03)
        }

        // The body: a flat cheerful fill plus a pale belly, then the
        // bold outline the cartoon look lives on.
        f.fill(art.body, with: .color(palette.body))
        if let belly = art.belly {
            var b = f
            b.clip(to: art.body)
            b.fill(belly, with: .color(palette.light.opacity(0.75)))
        }
        drawPattern(species.pattern, over: art.body,
                    palette: palette, into: &f, seed: patternSeed)
        // A soft top sheen keeps the flat fill from reading pasted.
        f.fill(art.body, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.22), .clear]),
            startPoint: CGPoint(x: 0, y: -0.5), endPoint: CGPoint(x: 0, y: 0.05)))
        f.stroke(art.body, with: .color(palette.outline), lineWidth: 0.045)

        if let pectoral = art.pectoral {
            let fin = pectoral(flap)
            f.fill(fin, with: .color(palette.light.opacity(0.55)))
            f.stroke(fin, with: .color(palette.outline.opacity(0.7)),
                     lineWidth: 0.03)
        }

        drawEye(into: &f, art: art, palette: palette,
                blink: blink, dead: dead, comp: aspectComp)
        drawMouth(into: &f, at: art.mouth, kind: mouth, palette: palette)
    }

    /// The species' marking, clipped to the body silhouette.
    private static func drawPattern(_ pattern: FishSpecies.Pattern, over body: Path,
                                    palette: Palette, into f: inout GraphicsContext,
                                    seed: UInt64) {
        switch pattern {
        case .plain:
            break
        case .bars:
            // Three bold white bars with dark edges, clownfish-style.
            var b = f
            b.clip(to: body)
            for (bx, bow) in [(0.30, -0.06), (0.02, -0.01), (-0.24, 0.06)]
                    as [(Double, Double)] {
                var bar = Path()
                bar.move(to: CGPoint(x: bx - 0.055, y: -0.6))
                bar.addQuadCurve(to: CGPoint(x: bx - 0.055, y: 0.6),
                                 control: CGPoint(x: bx - 0.16 + bow, y: 0))
                bar.addLine(to: CGPoint(x: bx + 0.065, y: 0.6))
                bar.addQuadCurve(to: CGPoint(x: bx + 0.065, y: -0.6),
                                 control: CGPoint(x: bx - 0.04 + bow, y: 0))
                bar.closeSubpath()
                b.fill(bar, with: .color(.white.opacity(0.92)))
                b.stroke(bar, with: .color(palette.outline.opacity(0.8)),
                         lineWidth: 0.025)
            }
        case .spots:
            var b = f
            b.clip(to: body)
            let spots: [(x: Double, y: Double, r: Double)] = [
                (0.28, -0.20, 0.05), (0.08, -0.30, 0.055), (0.14, 0.10, 0.045),
                (-0.08, -0.12, 0.06), (-0.12, 0.18, 0.05), (-0.26, 0.02, 0.055),
                (0.32, 0.14, 0.04),
            ]
            for spot in spots {
                b.fill(Path(ellipseIn: CGRect(x: spot.x - spot.r, y: spot.y - spot.r,
                                              width: spot.r * 2, height: spot.r * 2)),
                       with: .color(palette.dark.opacity(0.45)))
            }
        case .band:
            // A bold dark sweep over the tail end with a pale flash at
            // the root — the tang's calling card.
            var b = f
            b.clip(to: body)
            var band = Path()
            band.move(to: CGPoint(x: -0.10, y: -0.6))
            band.addQuadCurve(to: CGPoint(x: -0.16, y: 0.6),
                              control: CGPoint(x: -0.30, y: 0))
            band.addLine(to: CGPoint(x: -0.50, y: 0.6))
            band.addLine(to: CGPoint(x: -0.50, y: -0.6))
            band.closeSubpath()
            b.fill(band, with: .color(palette.dark.opacity(0.5)))
            var flash = Path()
            flash.move(to: CGPoint(x: -0.34, y: -0.6))
            flash.addLine(to: CGPoint(x: -0.50, y: -0.6))
            flash.addLine(to: CGPoint(x: -0.50, y: 0.6))
            flash.addLine(to: CGPoint(x: -0.36, y: 0.6))
            flash.addQuadCurve(to: CGPoint(x: -0.34, y: -0.6),
                             control: CGPoint(x: -0.44, y: 0))
            flash.closeSubpath()
            b.fill(flash, with: .color(palette.light.opacity(0.5)))
        }
    }

    /// The big cartoon eye: a white disc, a fat dark pupil, a bright
    /// catchlight — and a lid that slides down on `blink`. Drawn as a
    /// circle in a space the caller may have sheared, so the radius is
    /// compensated on y by the body's aspect handled at call site.
    private static func drawEye(into f: inout GraphicsContext, art: Art,
                                palette: Palette, blink: Double, dead: Bool,
                                comp: Double) {
        func circle(_ cx: Double, _ cy: Double, _ r: Double) -> Path {
            Path(ellipseIn: CGRect(x: cx - r, y: cy - r * comp,
                                   width: r * 2, height: r * 2 * comp))
        }
        if dead {
            // A sinking fish: the classic cartoon X.
            var x1 = Path()
            let r = art.eyeR * 0.8
            x1.move(to: CGPoint(x: art.eye.x - r, y: art.eye.y - r * comp))
            x1.addLine(to: CGPoint(x: art.eye.x + r, y: art.eye.y + r * comp))
            x1.move(to: CGPoint(x: art.eye.x + r, y: art.eye.y - r * comp))
            x1.addLine(to: CGPoint(x: art.eye.x - r, y: art.eye.y + r * comp))
            f.stroke(x1, with: .color(palette.outline.opacity(0.8)),
                     lineWidth: 0.035)
            return
        }
        f.fill(circle(art.eye.x, art.eye.y, art.eyeR),
               with: .color(.white.opacity(0.96)))
        f.stroke(circle(art.eye.x, art.eye.y, art.eyeR),
                 with: .color(palette.outline.opacity(0.8)), lineWidth: 0.025)
        let pupilR = art.eyeR * 0.55
        f.fill(circle(art.eye.x + art.eyeR * 0.22, art.eye.y, pupilR),
               with: .color(palette.outline))
        // Catchlight high-forward, a faint counter-glint low-back.
        f.fill(circle(art.eye.x + art.eyeR * 0.42, art.eye.y - art.eyeR * 0.42,
                      art.eyeR * 0.26),
               with: .color(.white.opacity(0.95)))
        if blink > 0.01 {
            // The lid: a body-coloured cap sliding over the eye.
            var lid = f
            lid.clip(to: circle(art.eye.x, art.eye.y, art.eyeR + 0.01))
            let cover = art.eyeR * 2 * blink * comp
            lid.fill(Path(CGRect(x: art.eye.x - art.eyeR - 0.02,
                                 y: art.eye.y - art.eyeR * comp - 0.02,
                                 width: art.eyeR * 2 + 0.04,
                                 height: cover + 0.02)),
                     with: .color(palette.body))
            lid.stroke(Path(ellipseIn: CGRect(
                x: art.eye.x - art.eyeR,
                y: art.eye.y - art.eyeR * comp + cover - art.eyeR * 0.2 * comp,
                width: art.eyeR * 2, height: art.eyeR * 0.4 * comp)),
                with: .color(palette.outline.opacity(0.7)), lineWidth: 0.02)
        }
    }

    /// The mouth: a smile just after eating, a small "o" when hungry,
    /// a soft curve otherwise.
    private static func drawMouth(into f: inout GraphicsContext, at p: CGPoint,
                                  kind: MouthKind, palette: Palette) {
        switch kind {
        case .smile:
            var m = Path()
            m.move(to: CGPoint(x: p.x - 0.02, y: p.y - 0.05))
            m.addQuadCurve(to: CGPoint(x: p.x - 0.14, y: p.y - 0.02),
                           control: CGPoint(x: p.x - 0.06, y: p.y + 0.05))
            f.stroke(m, with: .color(palette.outline),
                     style: StrokeStyle(lineWidth: 0.038, lineCap: .round))
        case .hungry:
            let r = 0.045
            f.stroke(Path(ellipseIn: CGRect(x: p.x - 0.03 - r, y: p.y - 0.02 - r,
                                            width: r * 2, height: r * 2)),
                     with: .color(palette.outline), lineWidth: 0.03)
            f.fill(Path(ellipseIn: CGRect(x: p.x - 0.03 - r * 0.5, y: p.y - 0.02 - r * 0.5,
                                          width: r, height: r)),
                   with: .color(palette.outline.opacity(0.55)))
        case .plain:
            var m = Path()
            m.move(to: CGPoint(x: p.x - 0.01, y: p.y - 0.02))
            m.addQuadCurve(to: CGPoint(x: p.x - 0.12, y: p.y - 0.01),
                           control: CGPoint(x: p.x - 0.06, y: p.y + 0.02))
            f.stroke(m, with: .color(palette.outline.opacity(0.85)),
                     style: StrokeStyle(lineWidth: 0.032, lineCap: .round))
        }
    }

    // MARK: Hats

    /// A purchased hat drawn at the fish's `hatAnchor`, in the same
    /// unit space — it rides the pitch and the flip with the body.
    static func drawHat(_ item: ShopItem, into f: inout GraphicsContext,
                        at anchor: CGPoint) {
        switch item {
        case .hatBeanie:
            var dome = Path()
            dome.move(to: CGPoint(x: anchor.x - 0.13, y: anchor.y))
            dome.addQuadCurve(to: CGPoint(x: anchor.x + 0.13, y: anchor.y),
                              control: CGPoint(x: anchor.x, y: anchor.y - 0.20))
            dome.closeSubpath()
            f.fill(dome, with: .color(Color(red: 0.75, green: 0.22, blue: 0.28)))
            f.stroke(dome, with: .color(Color(red: 0.40, green: 0.10, blue: 0.14)),
                     lineWidth: 0.025)
            let brim = Path(roundedRect: CGRect(x: anchor.x - 0.15, y: anchor.y - 0.03,
                                                width: 0.30, height: 0.07),
                            cornerRadius: 0.03)
            f.fill(brim, with: .color(Color(red: 0.55, green: 0.14, blue: 0.18)))
            f.fill(Path(ellipseIn: CGRect(x: anchor.x - 0.035, y: anchor.y - 0.225,
                                          width: 0.07, height: 0.07)),
                   with: .color(.white))
        case .hatParty:
            var cone = Path()
            cone.move(to: CGPoint(x: anchor.x - 0.11, y: anchor.y))
            cone.addLine(to: CGPoint(x: anchor.x + 0.02, y: anchor.y - 0.26))
            cone.addLine(to: CGPoint(x: anchor.x + 0.11, y: anchor.y))
            cone.closeSubpath()
            f.fill(cone, with: .color(Color(red: 0.35, green: 0.60, blue: 0.95)))
            f.stroke(cone, with: .color(Color(red: 0.16, green: 0.30, blue: 0.60)),
                     lineWidth: 0.025)
            // Stripes.
            for i in 0..<2 {
                let y = anchor.y - 0.07 - Double(i) * 0.08
                let w = 0.10 - Double(i) * 0.035
                var s = Path()
                s.move(to: CGPoint(x: anchor.x - w, y: y))
                s.addLine(to: CGPoint(x: anchor.x + w, y: y))
                f.stroke(s, with: .color(.white.opacity(0.8)), lineWidth: 0.02)
            }
            f.fill(Path(ellipseIn: CGRect(x: anchor.x + 0.02 - 0.035, y: anchor.y - 0.30,
                                          width: 0.07, height: 0.07)),
                   with: .color(Color(red: 0.95, green: 0.75, blue: 0.25)))
        case .hatCrown:
            var band = Path()
            band.move(to: CGPoint(x: anchor.x - 0.12, y: anchor.y))
            band.addLine(to: CGPoint(x: anchor.x - 0.12, y: anchor.y - 0.10))
            band.addLine(to: CGPoint(x: anchor.x - 0.06, y: anchor.y - 0.05))
            band.addLine(to: CGPoint(x: anchor.x, y: anchor.y - 0.14))
            band.addLine(to: CGPoint(x: anchor.x + 0.06, y: anchor.y - 0.05))
            band.addLine(to: CGPoint(x: anchor.x + 0.12, y: anchor.y - 0.10))
            band.addLine(to: CGPoint(x: anchor.x + 0.12, y: anchor.y))
            band.closeSubpath()
            f.fill(band, with: .color(Color(red: 0.95, green: 0.75, blue: 0.20)))
            f.stroke(band, with: .color(Color(red: 0.55, green: 0.38, blue: 0.05)),
                     lineWidth: 0.025)
            f.fill(Path(ellipseIn: CGRect(x: anchor.x - 0.02, y: anchor.y - 0.055,
                                          width: 0.04, height: 0.04)),
                   with: .color(Color(red: 0.80, green: 0.20, blue: 0.30)))
        default:
            break
        }
    }

    // MARK: Accessories

    /// A purchased accessory drawn in the second wearable slot (docs/
    /// TOYS.md): eyewear anchors on the `Art`'s eye, headwear on its
    /// `hatAnchor` (the view skips a hat while headwear wins the
    /// slot), the bow tie sits under the chin and the scarf wraps the
    /// neck. Same unit space as `drawHat` — the body's flip, pitch and
    /// squash carry it.
    static func drawAccessory(_ item: ShopItem, into f: inout GraphicsContext,
                              art: Art, trail: Double = 0) {
        switch item {
        case .sunglasses:
            // Two dark lenses over the eye with a bridge; the far lens
            // hides behind the head's roundness.
            let lens = Path(roundedRect: CGRect(x: art.eye.x - art.eyeR * 1.5,
                                                y: art.eye.y - art.eyeR * 1.3,
                                                width: art.eyeR * 3.0,
                                                height: art.eyeR * 2.4),
                            cornerRadius: art.eyeR * 0.7)
            f.fill(lens, with: .color(Color(red: 0.06, green: 0.07, blue: 0.10)
                                     .opacity(0.92)))
            f.stroke(lens, with: .color(.black.opacity(0.6)), lineWidth: 0.018)
            var temple = Path()
            temple.move(to: CGPoint(x: art.eye.x - art.eyeR * 1.5,
                                    y: art.eye.y - art.eyeR * 0.4))
            temple.addLine(to: CGPoint(x: art.eye.x - 0.20,
                                       y: art.eye.y - art.eyeR * 0.9))
            f.stroke(temple, with: .color(.black.opacity(0.6)), lineWidth: 0.02)
            // A glint off the lens.
            f.fill(Path(ellipseIn: CGRect(x: art.eye.x - art.eyeR * 0.9,
                                          y: art.eye.y - art.eyeR * 1.0,
                                          width: art.eyeR * 0.8,
                                          height: art.eyeR * 0.35)),
                   with: .color(.white.opacity(0.35)))
        case .monocle:
            // A gold ring on the eye, a chain dropping to a pocket.
            let ring = Path(ellipseIn: CGRect(x: art.eye.x - art.eyeR * 1.7,
                                              y: art.eye.y - art.eyeR * 1.7,
                                              width: art.eyeR * 3.4,
                                              height: art.eyeR * 3.4))
            f.fill(ring, with: .color(.white.opacity(0.14)))
            f.stroke(ring, with: .color(Color(red: 0.85, green: 0.70, blue: 0.30)),
                     lineWidth: 0.028)
            var chain = Path()
            chain.move(to: CGPoint(x: art.eye.x + art.eyeR * 1.2,
                                   y: art.eye.y + art.eyeR * 1.5))
            chain.addQuadCurve(
                to: CGPoint(x: art.eye.x - 0.02, y: art.eye.y + 0.30),
                control: CGPoint(x: art.eye.x + 0.10, y: art.eye.y + 0.26))
            f.stroke(chain, with: .color(Color(red: 0.75, green: 0.60, blue: 0.26)),
                     lineWidth: 0.015)
        case .topHat:
            let a = art.hatAnchor
            // Brim, tall crown, band.
            let brim = Path(roundedRect: CGRect(x: a.x - 0.17, y: a.y - 0.045,
                                                width: 0.34, height: 0.06),
                            cornerRadius: 0.03)
            f.fill(brim, with: .color(Color(red: 0.10, green: 0.10, blue: 0.14)))
            let crown = Path(roundedRect: CGRect(x: a.x - 0.11, y: a.y - 0.32,
                                                 width: 0.22, height: 0.30),
                             cornerRadius: 0.02)
            f.fill(crown, with: .color(Color(red: 0.12, green: 0.12, blue: 0.17)))
            f.stroke(crown, with: .color(.black.opacity(0.55)), lineWidth: 0.02)
            f.fill(Path(CGRect(x: a.x - 0.11, y: a.y - 0.10, width: 0.22, height: 0.05)),
                   with: .color(Color(red: 0.62, green: 0.16, blue: 0.22)))
            // The crown's soft sheen.
            f.fill(Path(CGRect(x: a.x - 0.075, y: a.y - 0.30, width: 0.035, height: 0.26)),
                   with: .color(.white.opacity(0.10)))
        case .headphones:
            let a = art.hatAnchor
            // A band arcing over the head with a cup on the near ear.
            var band = Path()
            band.move(to: CGPoint(x: a.x + 0.10, y: a.y + 0.05))
            band.addQuadCurve(to: CGPoint(x: a.x - 0.12, y: a.y + 0.02),
                              control: CGPoint(x: a.x - 0.02, y: a.y - 0.24))
            f.stroke(band, with: .color(Color(red: 0.16, green: 0.17, blue: 0.22)),
                     style: StrokeStyle(lineWidth: 0.045, lineCap: .round))
            f.stroke(band, with: .color(Color(red: 0.30, green: 0.32, blue: 0.40)),
                     style: StrokeStyle(lineWidth: 0.02, lineCap: .round))
            let cup = Path(roundedRect: CGRect(x: a.x - 0.16, y: a.y - 0.02,
                                               width: 0.09, height: 0.16),
                           cornerRadius: 0.04)
            f.fill(cup, with: .color(Color(red: 0.14, green: 0.15, blue: 0.20)))
            f.stroke(cup, with: .color(Color(red: 0.36, green: 0.55, blue: 0.85)),
                     lineWidth: 0.018)
        case .bowTie:
            // Under the chin: two triangles knot-to-cheek.
            let knot = CGPoint(x: art.mouth.x - 0.10, y: art.mouth.y + 0.10)
            var bow = Path()
            bow.move(to: knot)
            bow.addLine(to: CGPoint(x: knot.x - 0.10, y: knot.y - 0.07))
            bow.addLine(to: CGPoint(x: knot.x - 0.10, y: knot.y + 0.07))
            bow.closeSubpath()
            bow.move(to: knot)
            bow.addLine(to: CGPoint(x: knot.x + 0.10, y: knot.y - 0.07))
            bow.addLine(to: CGPoint(x: knot.x + 0.10, y: knot.y + 0.07))
            bow.closeSubpath()
            f.fill(bow, with: .color(Color(red: 0.72, green: 0.18, blue: 0.24)))
            f.stroke(bow, with: .color(Color(red: 0.40, green: 0.08, blue: 0.12)),
                     lineWidth: 0.018)
            f.fill(Path(roundedRect: CGRect(x: knot.x - 0.028, y: knot.y - 0.035,
                                            width: 0.056, height: 0.07),
                            cornerRadius: 0.02),
                   with: .color(Color(red: 0.55, green: 0.12, blue: 0.18)))
        case .scarf:
            // A wrap around the neck with a tail trailing behind.
            let neck = CGPoint(x: 0.16, y: 0.02)
            var wrap = Path()
            wrap.move(to: CGPoint(x: neck.x - 0.05, y: neck.y - 0.22))
            wrap.addQuadCurve(to: CGPoint(x: neck.x - 0.02, y: neck.y + 0.24),
                              control: CGPoint(x: neck.x - 0.13, y: neck.y + 0.02))
            f.stroke(wrap, with: .color(Color(red: 0.80, green: 0.30, blue: 0.14)),
                     style: StrokeStyle(lineWidth: 0.10, lineCap: .round))
            // The trailing end, lifted by the swim.
            var tail = Path()
            tail.move(to: CGPoint(x: neck.x - 0.04, y: neck.y + 0.12))
            tail.addQuadCurve(
                to: CGPoint(x: neck.x - 0.34, y: neck.y + 0.16 - trail * 0.10),
                control: CGPoint(x: neck.x - 0.18, y: neck.y + 0.20 - trail * 0.06))
            f.stroke(tail, with: .color(Color(red: 0.80, green: 0.30, blue: 0.14)),
                     style: StrokeStyle(lineWidth: 0.08, lineCap: .round))
            // Fringe.
            for k in 0..<3 {
                var fr = Path()
                let fx = neck.x - 0.34
                let fy = neck.y + 0.16 - trail * 0.10
                fr.move(to: CGPoint(x: fx, y: fy))
                fr.addLine(to: CGPoint(x: fx - 0.05, y: fy + Double(k - 1) * 0.035))
                f.stroke(fr, with: .color(Color(red: 0.55, green: 0.16, blue: 0.08)),
                         lineWidth: 0.015)
            }
        case .tinyLaptop:
            // A clamshell under the pectoral fin, its screen glowing.
            var lap = f
            lap.translateBy(x: 0.16, y: 0.16)
            lap.rotate(by: .radians(-0.25))
            let base = Path(roundedRect: CGRect(x: -0.09, y: 0, width: 0.20, height: 0.05),
                            cornerRadius: 0.015)
            lap.fill(base, with: .color(Color(red: 0.55, green: 0.57, blue: 0.62)))
            var screen = lap
            screen.blendMode = .plusLighter
            screen.fill(Path(roundedRect: CGRect(x: -0.09, y: -0.13, width: 0.17, height: 0.13),
                             cornerRadius: 0.015),
                        with: .linearGradient(
                            Gradient(colors: [Color(red: 0.55, green: 0.85, blue: 0.95),
                                              Color(red: 0.30, green: 0.55, blue: 0.80)]),
                            startPoint: CGPoint(x: 0, y: -0.13),
                            endPoint: CGPoint(x: 0, y: 0)))
            lap.stroke(Path(roundedRect: CGRect(x: -0.09, y: -0.13, width: 0.17, height: 0.13),
                            cornerRadius: 0.015),
                       with: .color(Color(red: 0.35, green: 0.37, blue: 0.42)),
                       lineWidth: 0.015)
        default:
            break
        }
    }
}
