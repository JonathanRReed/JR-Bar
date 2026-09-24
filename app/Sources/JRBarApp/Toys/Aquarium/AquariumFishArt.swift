import JRBarCore
import SwiftUI

/// The cartoon fish kit (docs/TOYS.md): plump rounded bodies with
/// real volume — countershaded, lit from the surface, glossy on top —
/// big friendly eyes with a coloured iris and two catchlights, soft
/// translucent fins with rays, a mouth that smiles when fed and makes
/// a small "o" when hungry. Everything is a unit-space `Path` — nose
/// toward +x, body centred near the origin, roughly x −0.5…0.5 — so
/// the caller scales to the fish's drawn length, flips x for
/// left-facing, and rotates for pitch without the paths knowing. No
/// image assets anywhere.
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
        var dark: Color      // markings, the shaded back
        var outline: Color   // the silhouette's edge
    }

    /// A species' own markings, drawn over the body on top of its
    /// `FishSpecies.Pattern` — what makes a tetra a tetra.
    enum Marking: Sendable {
        case none
        /// A dotted lateral line along the flank.
        case lateralLine
        /// A glowing neon stripe from the eye to the tail root.
        case neon
        /// Three soft dark bands down the disc.
        case angelBands
        /// Gill slits behind the eye and a crisp white underside.
        case sharkGills
        /// An iridescent sheen across the flank.
        case iridescent
        /// Ridged segments down the trunk and tail.
        case seahorseRings
        /// Rosy cheeks under the eye.
        case blush
    }

    /// One fin: its shape, where its rays spring from and which way
    /// they fan, and how many.
    struct Fin: Sendable {
        var path: Path
        var root: CGPoint
        var tip: CGPoint
        var rays: Int = 5
        /// A dark margin along the edge — the clownfish's trim.
        var trim: Bool = false
    }

    /// One species' silhouette kit.
    struct Art: Sendable {
        var body: Path
        /// A pale belly patch clipped inside the body, when the
        /// silhouette leaves room for one.
        var belly: Path?
        /// Fins behind the body (veils, spines, the far pectoral).
        var extras: [Fin]
        /// The tail, rebuilt per frame off the wag phase.
        var tail: (@Sendable (Double) -> Fin)?
        var dorsal: Fin?
        var anal: Fin?
        /// The near-side fin, rebuilt off the flap phase.
        var pectoral: (@Sendable (Double) -> Fin)?
        /// Where the eye sits and how big it is — big, per the brief.
        var eye: CGPoint
        var eyeR: Double
        /// The mouth anchor: the nose-side point it draws around.
        var mouth: CGPoint
        /// Where a hat sits on the head.
        var hatAnchor: CGPoint
        /// The gill cover's curve behind the eye; nil draws none.
        var gill: Path? = nil
        var marking: Marking = .none
        /// Where the upper-front gloss sits and how wide it runs.
        var gloss: CGRect = CGRect(x: -0.06, y: -0.26, width: 0.42, height: 0.11)
    }

    // MARK: Shared shapes

    /// A plump teardrop body: rounded nose at +x, full belly, tapering
    /// tail root at −x. `fullness` fattens the mid-body; `brow` lifts
    /// the forehead.
    private static func teardrop(fullness: Double = 1, brow: Double = 0) -> Path {
        let h = 0.30 * fullness
        var p = Path()
        p.move(to: CGPoint(x: 0.50, y: 0.00))
        p.addCurve(to: CGPoint(x: 0.08, y: -h),
                   control1: CGPoint(x: 0.47, y: -h * (0.78 + brow)),
                   control2: CGPoint(x: 0.28, y: -h * (1.04 + brow * 0.5)))
        p.addCurve(to: CGPoint(x: -0.36, y: -0.07),
                   control1: CGPoint(x: -0.13, y: -h * 0.98),
                   control2: CGPoint(x: -0.30, y: -0.17))
        p.addQuadCurve(to: CGPoint(x: -0.36, y: 0.07),
                       control: CGPoint(x: -0.39, y: 0))
        p.addCurve(to: CGPoint(x: 0.08, y: h * 0.86),
                   control1: CGPoint(x: -0.16, y: h * 0.88),
                   control2: CGPoint(x: -0.03, y: h * 1.04))
        p.addCurve(to: CGPoint(x: 0.50, y: 0.00),
                   control1: CGPoint(x: 0.30, y: h * 0.74),
                   control2: CGPoint(x: 0.47, y: h * 0.36))
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

    /// The gill cover: a soft crescent just behind the eye.
    private static func gillArc(behind eye: CGPoint, r: Double, drop: Double = 0.22) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: eye.x - r * 1.5, y: eye.y - r * 1.4))
        p.addQuadCurve(to: CGPoint(x: eye.x - r * 1.2, y: eye.y + drop),
                       control: CGPoint(x: eye.x - r * 3.0, y: eye.y + drop * 0.35))
        return p
    }

    /// A round fan tail with a soft two-lobed edge: peduncle at −0.34.
    /// `wag` swings the tips; `span`/`reach` size it.
    private static func fanTail(wag: Double, span: Double = 0.30, reach: Double = 0.70) -> Fin {
        var p = Path()
        p.move(to: CGPoint(x: -0.33, y: -0.07))
        p.addCurve(to: CGPoint(x: -reach, y: -span + wag),
                   control1: CGPoint(x: -0.48, y: -0.20 + wag * 0.4),
                   control2: CGPoint(x: -reach + 0.04, y: -span * 0.92 + wag * 0.8))
        p.addQuadCurve(to: CGPoint(x: -reach + 0.10, y: wag * 0.7),
                       control: CGPoint(x: -reach - 0.02, y: -span * 0.25 + wag * 0.8))
        p.addQuadCurve(to: CGPoint(x: -reach, y: span + wag),
                       control: CGPoint(x: -reach - 0.02, y: span * 0.25 + wag * 0.8))
        p.addCurve(to: CGPoint(x: -0.33, y: 0.07),
                   control1: CGPoint(x: -reach + 0.04, y: span * 0.92 + wag * 0.8),
                   control2: CGPoint(x: -0.48, y: 0.20 + wag * 0.4))
        p.closeSubpath()
        return Fin(path: p, root: CGPoint(x: -0.30, y: 0),
                   tip: CGPoint(x: -reach, y: wag), rays: 7)
    }

    /// A swept, rounded dorsal fin along the back.
    private static func dorsalFin(root0: Double, root1: Double, apex: CGPoint,
                                  base: Double = -0.24) -> Fin {
        var p = Path()
        p.move(to: CGPoint(x: root0, y: base))
        p.addCurve(to: apex,
                   control1: CGPoint(x: root0 - 0.02, y: base - 0.14),
                   control2: CGPoint(x: apex.x + 0.10, y: apex.y - 0.02))
        p.addQuadCurve(to: CGPoint(x: root1, y: base + 0.05),
                       control: CGPoint(x: (root1 + apex.x) / 2 - 0.05, y: apex.y + 0.12))
        p.closeSubpath()
        return Fin(path: p, root: CGPoint(x: (root0 + root1) / 2, y: base + 0.08),
                   tip: apex, rays: 5)
    }

    /// A small anal fin under the rear belly.
    private static func analFin(root0: Double, root1: Double, apex: CGPoint,
                                base: Double = 0.20) -> Fin {
        var p = Path()
        p.move(to: CGPoint(x: root0, y: base))
        p.addCurve(to: apex,
                   control1: CGPoint(x: root0 - 0.02, y: base + 0.10),
                   control2: CGPoint(x: apex.x + 0.08, y: apex.y))
        p.addQuadCurve(to: CGPoint(x: root1, y: base - 0.04),
                       control: CGPoint(x: (root1 + apex.x) / 2 - 0.03, y: apex.y - 0.08))
        p.closeSubpath()
        return Fin(path: p, root: CGPoint(x: (root0 + root1) / 2, y: base - 0.06),
                   tip: apex, rays: 4)
    }

    /// The near-side pectoral fin; `flap` follows the wag a beat late.
    private static func pectoralFin(flap: Double, at root: CGPoint = CGPoint(x: 0.14, y: 0.07),
                                    size: Double = 1) -> Fin {
        var p = Path()
        p.move(to: root)
        p.addCurve(to: CGPoint(x: root.x - 0.21 * size, y: root.y + (0.17 + flap) * size),
                   control1: CGPoint(x: root.x - 0.06 * size, y: root.y + 0.02),
                   control2: CGPoint(x: root.x - 0.19 * size, y: root.y + (0.08 + flap * 0.6) * size))
        p.addQuadCurve(to: CGPoint(x: root.x - 0.02 * size, y: root.y + 0.12 * size),
                       control: CGPoint(x: root.x - 0.10 * size, y: root.y + (0.22 + flap * 0.5) * size))
        p.closeSubpath()
        return Fin(path: p, root: root,
                   tip: CGPoint(x: root.x - 0.20 * size, y: root.y + (0.17 + flap) * size), rays: 4)
    }

    /// A filled ribbon along `spine`, `widths` wide at each point — a
    /// seahorse's trunk and curled tail in one outline.
    private static func ribbon(_ spine: [CGPoint], widths: [Double]) -> Path {
        guard spine.count >= 2, widths.count == spine.count else { return Path() }
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for i in spine.indices {
            let a = spine[max(0, i - 1)], b = spine[min(spine.count - 1, i + 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(0.0001, (dx * dx + dy * dy).squareRoot())
            let nx = -dy / len, ny = dx / len
            let w = widths[i] / 2
            left.append(CGPoint(x: spine[i].x + nx * w, y: spine[i].y + ny * w))
            right.append(CGPoint(x: spine[i].x - nx * w, y: spine[i].y - ny * w))
        }
        var p = Path()
        p.move(to: left[0])
        for i in 1..<left.count {
            let mid = CGPoint(x: (left[i - 1].x + left[i].x) / 2, y: (left[i - 1].y + left[i].y) / 2)
            p.addQuadCurve(to: mid, control: left[i - 1])
        }
        p.addLine(to: left[left.count - 1])
        // A rounded cap at the tail's tip.
        p.addQuadCurve(to: right[right.count - 1],
                       control: CGPoint(x: spine[spine.count - 1].x * 2 - (left[left.count - 1].x + right[right.count - 1].x) / 2,
                                        y: spine[spine.count - 1].y * 2 - (left[left.count - 1].y + right[right.count - 1].y) / 2))
        for i in stride(from: right.count - 2, through: 0, by: -1) {
            let mid = CGPoint(x: (right[i + 1].x + right[i].x) / 2, y: (right[i + 1].y + right[i].y) / 2)
            p.addQuadCurve(to: mid, control: right[i + 1])
        }
        p.addLine(to: right[0])
        p.closeSubpath()
        return p
    }

    // MARK: Species kits

    /// The shark's crescent tail: long upper lobe, short lower.
    private static func lunateTail(wag: Double) -> Fin {
        var p = Path()
        p.move(to: CGPoint(x: -0.38, y: -0.05))
        p.addCurve(to: CGPoint(x: -0.84, y: -0.50 + wag),
                   control1: CGPoint(x: -0.56, y: -0.16 + wag * 0.3),
                   control2: CGPoint(x: -0.74, y: -0.40 + wag * 0.8))
        p.addQuadCurve(to: CGPoint(x: -0.62, y: wag * 0.4),
                       control: CGPoint(x: -0.74, y: -0.12 + wag * 0.7))
        p.addCurve(to: CGPoint(x: -0.72, y: 0.30 + wag),
                   control1: CGPoint(x: -0.64, y: 0.10 + wag * 0.6),
                   control2: CGPoint(x: -0.68, y: 0.22 + wag * 0.8))
        p.addQuadCurve(to: CGPoint(x: -0.38, y: 0.05),
                       control: CGPoint(x: -0.50, y: 0.12 + wag * 0.4))
        p.closeSubpath()
        return Fin(path: p, root: CGPoint(x: -0.36, y: 0),
                   tip: CGPoint(x: -0.80, y: -0.30 + wag), rays: 6)
    }

    /// The betta's veil: a huge soft fan that ripples at its edge.
    private static func veilTail(wag: Double) -> Fin {
        var p = Path()
        p.move(to: CGPoint(x: -0.33, y: -0.08))
        p.addCurve(to: CGPoint(x: -0.86, y: -0.62 + wag),
                   control1: CGPoint(x: -0.46, y: -0.34 + wag * 0.4),
                   control2: CGPoint(x: -0.70, y: -0.62 + wag * 0.8))
        // The ruffled trailing edge, top to bottom.
        let lobes = 5
        for k in 0..<lobes {
            let y0 = -0.62 + Double(k) / Double(lobes) * 1.24
            let y1 = -0.62 + Double(k + 1) / Double(lobes) * 1.24
            let bulge = -0.98 - 0.04 * sin(Double(k) * 1.7)
            p.addQuadCurve(to: CGPoint(x: -0.86 - 0.05 * sin(Double(k + 1) * 2.1), y: y1 + wag),
                           control: CGPoint(x: bulge, y: (y0 + y1) / 2 + wag))
        }
        p.addCurve(to: CGPoint(x: -0.33, y: 0.08),
                   control1: CGPoint(x: -0.70, y: 0.62 + wag * 0.8),
                   control2: CGPoint(x: -0.46, y: 0.34 + wag * 0.4))
        p.closeSubpath()
        return Fin(path: p, root: CGPoint(x: -0.30, y: 0),
                   tip: CGPoint(x: -0.95, y: wag), rays: 11)
    }

    private static let kits: [FishSpecies: Art] = {
        var kits: [FishSpecies: Art] = [:]

        // Minnow: the plain plump fish, a dotted line down its flank.
        kits[.minnow] = Art(
            body: teardrop(fullness: 0.92),
            belly: bellyPatch(x: 0.08, y: 0.15, w: 0.30, h: 0.16),
            extras: [],
            tail: { fanTail(wag: $0, span: 0.27, reach: 0.64) },
            dorsal: dorsalFin(root0: 0.10, root1: -0.20, apex: CGPoint(x: -0.12, y: -0.50)),
            anal: analFin(root0: -0.08, root1: -0.26, apex: CGPoint(x: -0.26, y: 0.34)),
            pectoral: { pectoralFin(flap: $0) },
            eye: CGPoint(x: 0.29, y: -0.08), eyeR: 0.092,
            mouth: CGPoint(x: 0.47, y: 0.06),
            hatAnchor: CGPoint(x: 0.22, y: -0.25),
            gill: gillArc(behind: CGPoint(x: 0.29, y: -0.08), r: 0.092),
            marking: .lateralLine)

        // Tetra: small, slim and shiny — the neon stripe is its name.
        kits[.tetra] = Art(
            body: teardrop(fullness: 0.84),
            belly: bellyPatch(x: 0.06, y: 0.14, w: 0.28, h: 0.13),
            extras: [],
            tail: { fanTail(wag: $0, span: 0.26, reach: 0.60) },
            dorsal: dorsalFin(root0: 0.06, root1: -0.16, apex: CGPoint(x: -0.12, y: -0.48)),
            anal: analFin(root0: -0.02, root1: -0.24, apex: CGPoint(x: -0.24, y: 0.34)),
            pectoral: { pectoralFin(flap: $0, size: 0.85) },
            eye: CGPoint(x: 0.29, y: -0.07), eyeR: 0.105,
            mouth: CGPoint(x: 0.47, y: 0.05),
            hatAnchor: CGPoint(x: 0.22, y: -0.23),
            gill: gillArc(behind: CGPoint(x: 0.29, y: -0.07), r: 0.105, drop: 0.18),
            marking: .neon)

        // Tang: a tall oval with a long fin along its back and belly;
        // the tail-end band is its pattern.
        let tangBody: Path = {
            var p = Path()
            p.move(to: CGPoint(x: 0.50, y: 0.04))
            p.addCurve(to: CGPoint(x: 0.10, y: -0.36),
                       control1: CGPoint(x: 0.48, y: -0.22),
                       control2: CGPoint(x: 0.32, y: -0.37))
            p.addCurve(to: CGPoint(x: -0.36, y: -0.07),
                       control1: CGPoint(x: -0.14, y: -0.35),
                       control2: CGPoint(x: -0.30, y: -0.20))
            p.addQuadCurve(to: CGPoint(x: -0.36, y: 0.07), control: CGPoint(x: -0.39, y: 0))
            p.addCurve(to: CGPoint(x: 0.10, y: 0.33),
                       control1: CGPoint(x: -0.30, y: 0.20),
                       control2: CGPoint(x: -0.12, y: 0.34))
            p.addCurve(to: CGPoint(x: 0.50, y: 0.04),
                       control1: CGPoint(x: 0.32, y: 0.32),
                       control2: CGPoint(x: 0.47, y: 0.22))
            p.closeSubpath()
            return p
        }()
        kits[.tang] = Art(
            body: tangBody,
            belly: bellyPatch(x: 0.10, y: 0.18, w: 0.28, h: 0.17),
            extras: [],
            tail: { fanTail(wag: $0, span: 0.30, reach: 0.62) },
            dorsal: dorsalFin(root0: 0.24, root1: -0.30, apex: CGPoint(x: -0.12, y: -0.52),
                              base: -0.30),
            anal: analFin(root0: 0.06, root1: -0.30, apex: CGPoint(x: -0.18, y: 0.46),
                          base: 0.26),
            pectoral: { pectoralFin(flap: $0) },
            eye: CGPoint(x: 0.30, y: -0.12), eyeR: 0.090,
            mouth: CGPoint(x: 0.48, y: 0.08),
            hatAnchor: CGPoint(x: 0.22, y: -0.33),
            gill: gillArc(behind: CGPoint(x: 0.30, y: -0.12), r: 0.090, drop: 0.26))

        // Clownfish: the roundest body of the lot, bold bars, every fin
        // trimmed dark.
        kits[.clownfish] = Art(
            body: teardrop(fullness: 1.18, brow: 0.08),
            belly: bellyPatch(x: 0.06, y: 0.20, w: 0.30, h: 0.20),
            extras: [],
            tail: {
                var tail = fanTail(wag: $0, span: 0.27, reach: 0.60)
                tail.trim = true
                return tail
            },
            dorsal: {
                var fin = dorsalFin(root0: 0.16, root1: -0.22, apex: CGPoint(x: -0.08, y: -0.54),
                                    base: -0.28)
                fin.trim = true
                return fin
            }(),
            anal: {
                var fin = analFin(root0: -0.04, root1: -0.26, apex: CGPoint(x: -0.24, y: 0.40),
                                  base: 0.24)
                fin.trim = true
                return fin
            }(),
            pectoral: {
                var fin = pectoralFin(flap: $0, size: 1.05)
                fin.trim = true
                return fin
            },
            eye: CGPoint(x: 0.30, y: -0.10), eyeR: 0.094,
            mouth: CGPoint(x: 0.47, y: 0.07),
            hatAnchor: CGPoint(x: 0.21, y: -0.31),
            gill: nil,
            marking: .blush)

        // Betta: a small body under huge flowing veils.
        let bettaVeil: Fin = {
            var p = Path()
            p.move(to: CGPoint(x: 0.04, y: 0.20))
            p.addCurve(to: CGPoint(x: -0.62, y: 0.74),
                       control1: CGPoint(x: -0.16, y: 0.40),
                       control2: CGPoint(x: -0.44, y: 0.72))
            p.addQuadCurve(to: CGPoint(x: -0.50, y: 0.54), control: CGPoint(x: -0.62, y: 0.62))
            p.addQuadCurve(to: CGPoint(x: -0.34, y: 0.14), control: CGPoint(x: -0.46, y: 0.30))
            p.addQuadCurve(to: CGPoint(x: 0.04, y: 0.20), control: CGPoint(x: -0.16, y: 0.26))
            p.closeSubpath()
            return Fin(path: p, root: CGPoint(x: -0.10, y: 0.18),
                       tip: CGPoint(x: -0.60, y: 0.72), rays: 8)
        }()
        let bettaDorsal: Fin = {
            var p = Path()
            p.move(to: CGPoint(x: 0.06, y: -0.25))
            p.addCurve(to: CGPoint(x: -0.52, y: -0.62),
                       control1: CGPoint(x: -0.06, y: -0.52),
                       control2: CGPoint(x: -0.34, y: -0.66))
            p.addQuadCurve(to: CGPoint(x: -0.32, y: -0.12), control: CGPoint(x: -0.48, y: -0.30))
            p.closeSubpath()
            return Fin(path: p, root: CGPoint(x: -0.12, y: -0.22),
                       tip: CGPoint(x: -0.50, y: -0.60), rays: 7)
        }()
        kits[.betta] = Art(
            body: teardrop(fullness: 0.98),
            belly: bellyPatch(x: 0.08, y: 0.17, w: 0.28, h: 0.16),
            extras: [bettaVeil],
            tail: { veilTail(wag: $0) },
            dorsal: bettaDorsal,
            anal: nil,
            pectoral: { pectoralFin(flap: $0) },
            eye: CGPoint(x: 0.30, y: -0.09), eyeR: 0.088,
            mouth: CGPoint(x: 0.47, y: 0.06),
            hatAnchor: CGPoint(x: 0.20, y: -0.27),
            gill: gillArc(behind: CGPoint(x: 0.30, y: -0.09), r: 0.088),
            marking: .iridescent)

        // Shark: a sleek blade with a pointed snout, a crisp white
        // belly and gill slits — still round-eyed and friendly.
        let sharkBody: Path = {
            var p = Path()
            p.move(to: CGPoint(x: 0.56, y: 0.02))
            p.addCurve(to: CGPoint(x: 0.06, y: -0.30),
                       control1: CGPoint(x: 0.48, y: -0.16),
                       control2: CGPoint(x: 0.28, y: -0.31))
            p.addCurve(to: CGPoint(x: -0.44, y: -0.06),
                       control1: CGPoint(x: -0.18, y: -0.28),
                       control2: CGPoint(x: -0.36, y: -0.14))
            p.addQuadCurve(to: CGPoint(x: -0.44, y: 0.06), control: CGPoint(x: -0.47, y: 0))
            p.addCurve(to: CGPoint(x: 0.10, y: 0.22),
                       control1: CGPoint(x: -0.20, y: 0.18),
                       control2: CGPoint(x: -0.06, y: 0.25))
            p.addCurve(to: CGPoint(x: 0.56, y: 0.02),
                       control1: CGPoint(x: 0.34, y: 0.19),
                       control2: CGPoint(x: 0.52, y: 0.10))
            p.closeSubpath()
            return p
        }()
        let sharkDorsal: Fin = {
            var p = Path()
            p.move(to: CGPoint(x: 0.08, y: -0.28))
            p.addCurve(to: CGPoint(x: -0.16, y: -0.74),
                       control1: CGPoint(x: 0.04, y: -0.46),
                       control2: CGPoint(x: -0.06, y: -0.66))
            p.addQuadCurve(to: CGPoint(x: -0.24, y: -0.22), control: CGPoint(x: -0.14, y: -0.40))
            p.closeSubpath()
            return Fin(path: p, root: CGPoint(x: -0.08, y: -0.24),
                       tip: CGPoint(x: -0.16, y: -0.72), rays: 0)
        }()
        let sharkPectoral: @Sendable (Double) -> Fin = { flap in
            var p = Path()
            p.move(to: CGPoint(x: 0.20, y: 0.10))
            p.addCurve(to: CGPoint(x: -0.12, y: 0.44 + flap * 0.6),
                       control1: CGPoint(x: 0.12, y: 0.22),
                       control2: CGPoint(x: -0.02, y: 0.36 + flap * 0.4))
            p.addQuadCurve(to: CGPoint(x: 0.04, y: 0.16), control: CGPoint(x: -0.02, y: 0.26))
            p.closeSubpath()
            return Fin(path: p, root: CGPoint(x: 0.10, y: 0.14),
                       tip: CGPoint(x: -0.10, y: 0.42), rays: 0)
        }
        kits[.shark] = Art(
            body: sharkBody,
            belly: bellyPatch(x: 0.10, y: 0.14, w: 0.40, h: 0.16),
            extras: [],
            tail: { lunateTail(wag: $0) },
            dorsal: sharkDorsal,
            anal: analFin(root0: -0.20, root1: -0.32, apex: CGPoint(x: -0.34, y: 0.26), base: 0.12),
            pectoral: sharkPectoral,
            eye: CGPoint(x: 0.34, y: -0.08), eyeR: 0.074,
            mouth: CGPoint(x: 0.50, y: 0.09),
            hatAnchor: CGPoint(x: 0.24, y: -0.26),
            gill: nil,
            marking: .sharkGills,
            gloss: CGRect(x: -0.14, y: -0.25, width: 0.52, height: 0.09))

        // Angelfish: a tall disc under long swept sails.
        let angelBody: Path = {
            var p = Path()
            p.move(to: CGPoint(x: 0.50, y: 0.02))
            p.addCurve(to: CGPoint(x: 0.04, y: -0.42),
                       control1: CGPoint(x: 0.46, y: -0.24),
                       control2: CGPoint(x: 0.30, y: -0.43))
            p.addCurve(to: CGPoint(x: -0.34, y: -0.08),
                       control1: CGPoint(x: -0.20, y: -0.41),
                       control2: CGPoint(x: -0.32, y: -0.26))
            p.addQuadCurve(to: CGPoint(x: -0.34, y: 0.08), control: CGPoint(x: -0.37, y: 0))
            p.addCurve(to: CGPoint(x: 0.04, y: 0.42),
                       control1: CGPoint(x: -0.32, y: 0.26),
                       control2: CGPoint(x: -0.20, y: 0.41))
            p.addCurve(to: CGPoint(x: 0.50, y: 0.02),
                       control1: CGPoint(x: 0.30, y: 0.43),
                       control2: CGPoint(x: 0.46, y: 0.24))
            p.closeSubpath()
            return p
        }()
        let angelDorsal: Fin = {
            var p = Path()
            p.move(to: CGPoint(x: 0.14, y: -0.38))
            p.addCurve(to: CGPoint(x: -0.40, y: -0.88),
                       control1: CGPoint(x: 0.06, y: -0.64),
                       control2: CGPoint(x: -0.18, y: -0.84))
            p.addQuadCurve(to: CGPoint(x: -0.28, y: -0.22), control: CGPoint(x: -0.28, y: -0.48))
            p.closeSubpath()
            return Fin(path: p, root: CGPoint(x: -0.06, y: -0.32),
                       tip: CGPoint(x: -0.40, y: -0.86), rays: 7)
        }()
        let angelAnal: Fin = {
            var p = Path()
            p.move(to: CGPoint(x: 0.14, y: 0.38))
            p.addCurve(to: CGPoint(x: -0.40, y: 0.88),
                       control1: CGPoint(x: 0.06, y: 0.64),
                       control2: CGPoint(x: -0.18, y: 0.84))
            p.addQuadCurve(to: CGPoint(x: -0.28, y: 0.22), control: CGPoint(x: -0.28, y: 0.48))
            p.closeSubpath()
            return Fin(path: p, root: CGPoint(x: -0.06, y: 0.32),
                       tip: CGPoint(x: -0.40, y: 0.86), rays: 7)
        }()
        let angelStreamers: Fin = {
            // The two long ventral threads that trail under the disc.
            var p = Path()
            p.move(to: CGPoint(x: 0.18, y: 0.30))
            p.addCurve(to: CGPoint(x: -0.20, y: 0.86),
                       control1: CGPoint(x: 0.12, y: 0.52),
                       control2: CGPoint(x: -0.04, y: 0.76))
            p.addQuadCurve(to: CGPoint(x: 0.12, y: 0.32), control: CGPoint(x: 0.02, y: 0.60))
            p.closeSubpath()
            return Fin(path: p, root: CGPoint(x: 0.14, y: 0.32),
                       tip: CGPoint(x: -0.20, y: 0.86), rays: 0)
        }()
        kits[.angelfish] = Art(
            body: angelBody,
            belly: bellyPatch(x: 0.10, y: 0.22, w: 0.26, h: 0.18),
            extras: [angelStreamers],
            tail: { fanTail(wag: $0, span: 0.24, reach: 0.58) },
            dorsal: angelDorsal,
            anal: angelAnal,
            pectoral: { pectoralFin(flap: $0, at: CGPoint(x: 0.12, y: 0.04), size: 0.9) },
            eye: CGPoint(x: 0.27, y: -0.12), eyeR: 0.082,
            mouth: CGPoint(x: 0.46, y: 0.03),
            hatAnchor: CGPoint(x: 0.16, y: -0.38),
            gill: gillArc(behind: CGPoint(x: 0.27, y: -0.12), r: 0.082, drop: 0.26),
            marking: .angelBands,
            gloss: CGRect(x: -0.10, y: -0.34, width: 0.42, height: 0.13))

        // Puffer: a round, spiny little ball with big eyes.
        let pufferBody: Path = {
            var p = Path()
            p.addEllipse(in: CGRect(x: -0.38, y: -0.44, width: 0.86, height: 0.88))
            return p
        }()
        let pufferSpikes: Fin = {
            var p = Path()
            let count = 18
            for i in 0..<count {
                let a = Double(i) / Double(count) * .pi * 2 + 0.17
                let cx = 0.05, cy = 0.0
                let ex = cx + cos(a) * 0.42, ey = cy + sin(a) * 0.43
                // No spines on the face or at the tail root.
                guard cos(a) < 0.78, cos(a) > -0.86 || abs(sin(a)) > 0.34 else { continue }
                let px = -sin(a), py = cos(a)
                p.move(to: CGPoint(x: ex + px * 0.035, y: ey + py * 0.035))
                p.addLine(to: CGPoint(x: ex + cos(a) * 0.10, y: ey + sin(a) * 0.10))
                p.addLine(to: CGPoint(x: ex - px * 0.035, y: ey - py * 0.035))
                p.closeSubpath()
            }
            return Fin(path: p, root: CGPoint(x: 0.05, y: 0), tip: CGPoint(x: 0.5, y: 0), rays: 0)
        }()
        kits[.puffer] = Art(
            body: pufferBody,
            belly: bellyPatch(x: 0.06, y: 0.20, w: 0.34, h: 0.24),
            extras: [pufferSpikes],
            tail: { fanTail(wag: $0, span: 0.20, reach: 0.60) },
            dorsal: dorsalFin(root0: 0.00, root1: -0.18, apex: CGPoint(x: -0.16, y: -0.58),
                              base: -0.40),
            anal: analFin(root0: -0.06, root1: -0.22, apex: CGPoint(x: -0.20, y: 0.54), base: 0.38),
            pectoral: { pectoralFin(flap: $0, at: CGPoint(x: 0.10, y: 0.06), size: 0.9) },
            eye: CGPoint(x: 0.25, y: -0.13), eyeR: 0.11,
            mouth: CGPoint(x: 0.46, y: 0.08),
            hatAnchor: CGPoint(x: 0.10, y: -0.40),
            gill: nil,
            marking: .blush,
            gloss: CGRect(x: -0.14, y: -0.36, width: 0.46, height: 0.16))

        // Seahorse: upright, a long snout, a crown and a curled tail.
        let seahorseTrunk = ribbon(
            [CGPoint(x: 0.16, y: -0.30), CGPoint(x: 0.08, y: -0.16), CGPoint(x: 0.08, y: 0.00),
             CGPoint(x: 0.12, y: 0.12), CGPoint(x: 0.08, y: 0.24), CGPoint(x: -0.02, y: 0.32),
             CGPoint(x: -0.10, y: 0.40), CGPoint(x: -0.08, y: 0.48), CGPoint(x: 0.00, y: 0.51),
             CGPoint(x: 0.06, y: 0.46), CGPoint(x: 0.04, y: 0.41)],
            widths: [0.22, 0.26, 0.30, 0.28, 0.20, 0.14, 0.11, 0.09, 0.07, 0.055, 0.04])
        let seahorseHead: Path = {
            var p = Path()
            p.addEllipse(in: CGRect(x: 0.08, y: -0.45, width: 0.26, height: 0.22))
            // The snout: a tube to a little flared mouth.
            p.move(to: CGPoint(x: 0.26, y: -0.39))
            p.addQuadCurve(to: CGPoint(x: 0.50, y: -0.37), control: CGPoint(x: 0.38, y: -0.40))
            p.addQuadCurve(to: CGPoint(x: 0.50, y: -0.29), control: CGPoint(x: 0.53, y: -0.33))
            p.addQuadCurve(to: CGPoint(x: 0.26, y: -0.29), control: CGPoint(x: 0.38, y: -0.31))
            p.closeSubpath()
            return p
        }()
        let seahorseCrown: Path = {
            var p = Path()
            for (x, h) in [(0.13, 0.08), (0.18, 0.10), (0.23, 0.07)] as [(Double, Double)] {
                p.move(to: CGPoint(x: x - 0.03, y: -0.42))
                p.addQuadCurve(to: CGPoint(x: x, y: -0.43 - h), control: CGPoint(x: x - 0.02, y: -0.44 - h * 0.5))
                p.addQuadCurve(to: CGPoint(x: x + 0.03, y: -0.42), control: CGPoint(x: x + 0.02, y: -0.44 - h * 0.5))
                p.closeSubpath()
            }
            return p
        }()
        var seahorseBody = seahorseTrunk
        seahorseBody.addPath(seahorseHead)
        seahorseBody.addPath(seahorseCrown)
        kits[.seahorse] = Art(
            body: seahorseBody,
            belly: bellyPatch(x: 0.16, y: 0.06, w: 0.10, h: 0.18),
            extras: [],
            tail: nil,
            dorsal: nil,
            anal: nil,
            // The seahorse's one working fin: the little fan on its
            // back, fluttering with the swim.
            pectoral: { flap in
                var p = Path()
                p.move(to: CGPoint(x: -0.03, y: -0.10))
                p.addCurve(to: CGPoint(x: -0.06, y: 0.12),
                           control1: CGPoint(x: -0.20 - flap * 0.4, y: -0.10),
                           control2: CGPoint(x: -0.22 - flap * 0.4, y: 0.10))
                p.closeSubpath()
                return Fin(path: p, root: CGPoint(x: -0.02, y: 0.01),
                           tip: CGPoint(x: -0.20 - flap * 0.4, y: 0.0), rays: 6)
            },
            eye: CGPoint(x: 0.22, y: -0.35), eyeR: 0.07,
            mouth: CGPoint(x: 0.50, y: -0.33),
            hatAnchor: CGPoint(x: 0.17, y: -0.47),
            gill: nil,
            marking: .seahorseRings,
            gloss: CGRect(x: 0.02, y: -0.20, width: 0.12, height: 0.26))

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
                     patternSeed: UInt64, aspectComp: Double = 1,
                     variant: AquariumVariant? = nil) {
        let art = art(for: species)

        // Fins behind the body — soft and translucent, so they read as
        // fins rather than more body.
        if let tail = art.tail { drawFin(tail(wag), palette: palette, into: &f) }
        for extra in art.extras { drawFin(extra, palette: palette, into: &f) }
        if let dorsal = art.dorsal { drawFin(dorsal, palette: palette, into: &f) }
        if let anal = art.anal { drawFin(anal, palette: palette, into: &f) }

        // The silhouette's edge goes down first, twice as wide as it
        // shows: the body fills over its inner half, so compound
        // bodies (the seahorse) keep one clean outline.
        f.stroke(art.body, with: .color(palette.outline.opacity(0.92)),
                 style: StrokeStyle(lineWidth: 0.058, lineJoin: .round))
        drawBody(art, species: species, palette: palette, into: &f,
                 seed: patternSeed, variant: variant)

        if let pectoral = art.pectoral {
            drawFin(pectoral(flap), palette: palette, into: &f, near: true)
        }

        drawEye(into: &f, art: art, palette: palette,
                blink: blink, dead: dead, comp: aspectComp)
        if species != .seahorse || mouth != .plain {
            drawMouth(into: &f, at: art.mouth, kind: mouth, palette: palette)
        }
    }

    /// The body's paint, back to front: the base colour, the shaded
    /// back and pale underside, the belly, the pattern and marking,
    /// the scales, the volume, the gloss and a thin rim of light.
    private static func drawBody(_ art: Art, species: FishSpecies, palette: Palette,
                                 into f: inout GraphicsContext, seed: UInt64,
                                 variant: AquariumVariant?) {
        let body = art.body
        f.fill(body, with: .color(palette.body))
        var b = f
        b.clip(to: body)
        let bounds = body.boundingRect
        // Countershading: a darker back, a paler underside.
        b.fill(body, with: .linearGradient(
            Gradient(stops: [
                .init(color: palette.dark.opacity(0.62), location: 0),
                .init(color: palette.dark.opacity(0), location: 0.46),
                .init(color: palette.light.opacity(0), location: 0.56),
                .init(color: palette.light.opacity(0.55), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: bounds.minY),
            endPoint: CGPoint(x: 0, y: bounds.maxY)))
        if let belly = art.belly {
            b.fill(belly, with: .linearGradient(
                Gradient(colors: [palette.light.opacity(0.1), palette.light.opacity(0.85)]),
                startPoint: CGPoint(x: 0, y: belly.boundingRect.minY),
                endPoint: CGPoint(x: 0, y: belly.boundingRect.maxY)))
        }
        drawPattern(species.pattern, palette: palette, into: &b, seed: seed)
        drawMarking(art.marking, art: art, palette: palette, into: &b)
        if let variant { drawVariant(variant, palette: palette, into: &b) }
        drawScales(bounds: bounds, palette: palette, into: &b)
        // Volume: the flanks fall off toward the edge and the tail.
        b.fill(body, with: .radialGradient(
            Gradient(stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0), location: 0.55),
                .init(color: .black.opacity(0.26), location: 1),
            ]),
            center: CGPoint(x: bounds.midX + bounds.width * 0.12, y: bounds.midY - bounds.height * 0.08),
            startRadius: 0, endRadius: max(bounds.width, bounds.height) * 0.62))
        // The gill cover.
        if let gill = art.gill {
            b.stroke(gill, with: .color(palette.dark.opacity(0.42)),
                     style: StrokeStyle(lineWidth: 0.02, lineCap: .round))
            b.stroke(gill.offsetBy(dx: 0.018, dy: 0), with: .color(palette.light.opacity(0.28)),
                     style: StrokeStyle(lineWidth: 0.012, lineCap: .round))
        }
        // The gloss: the surface's light caught on the upper front.
        let g = art.gloss
        b.fill(Path(ellipseIn: g), with: .radialGradient(
            Gradient(colors: [.white.opacity(0.62), .white.opacity(0)]),
            center: CGPoint(x: g.midX + g.width * 0.12, y: g.midY),
            startRadius: 0, endRadius: g.width * 0.5))
        // A thin rim of light along the back.
        b.stroke(body, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.42), .white.opacity(0)]),
            startPoint: CGPoint(x: 0, y: bounds.minY),
            endPoint: CGPoint(x: 0, y: bounds.minY + bounds.height * 0.45)),
            lineWidth: 0.05)
    }

    /// One fin: a soft gradient from the root to a pale translucent
    /// edge, fine rays fanning from the root, and a thin edge line.
    private static func drawFin(_ fin: Fin, palette: Palette,
                                into f: inout GraphicsContext, near: Bool = false) {
        let path = fin.path
        f.fill(path, with: .linearGradient(
            Gradient(stops: [
                .init(color: palette.body.opacity(near ? 0.95 : 0.86), location: 0),
                .init(color: palette.body.opacity(near ? 0.70 : 0.55), location: 0.5),
                .init(color: palette.light.opacity(near ? 0.55 : 0.34), location: 1),
            ]),
            startPoint: fin.root, endPoint: fin.tip))
        if fin.rays > 0 {
            var r = f
            r.clip(to: path)
            let dx = fin.tip.x - fin.root.x, dy = fin.tip.y - fin.root.y
            let reach = (dx * dx + dy * dy).squareRoot() * 1.6
            let heading = atan2(dy, dx)
            var rays = Path()
            for k in 0..<fin.rays {
                let spread = fin.rays == 1 ? 0 : (Double(k) / Double(fin.rays - 1) - 0.5) * 1.9
                let a = heading + spread
                rays.move(to: fin.root)
                rays.addLine(to: CGPoint(x: fin.root.x + cos(a) * reach, y: fin.root.y + sin(a) * reach))
            }
            r.stroke(rays, with: .color(palette.dark.opacity(0.30)), lineWidth: 0.011)
        }
        if fin.trim {
            var t = f
            t.clip(to: path)
            t.stroke(path, with: .color(palette.outline.opacity(0.85)), lineWidth: 0.06)
        }
        f.stroke(path, with: .color(palette.outline.opacity(near ? 0.55 : 0.5)),
                 style: StrokeStyle(lineWidth: near ? 0.02 : 0.022, lineJoin: .round))
    }

    /// Faint overlapping scales on the rear two thirds of the flank,
    /// fading out toward the head.
    private static func drawScales(bounds: CGRect, palette: Palette,
                                   into b: inout GraphicsContext) {
        var scales = Path()
        let r = 0.05
        var row = 0
        var y = bounds.minY + 0.06
        while y < bounds.maxY - 0.04 {
            var x = -0.38 + (row % 2 == 0 ? 0 : r)
            while x < 0.22 {
                scales.move(to: CGPoint(x: x + r * cos(.pi * 0.62), y: y - r * sin(.pi * 0.62)))
                scales.addArc(center: CGPoint(x: x, y: y), radius: r,
                              startAngle: .radians(-.pi * 0.62), endAngle: .radians(.pi * 0.62),
                              clockwise: false)
                x += r * 2
            }
            y += r * 1.3
            row += 1
        }
        b.stroke(scales, with: .linearGradient(
            Gradient(colors: [palette.dark.opacity(0.16), palette.dark.opacity(0)]),
            startPoint: CGPoint(x: -0.36, y: 0), endPoint: CGPoint(x: 0.18, y: 0)),
            lineWidth: 0.010)
    }

    /// The species' own markings, over the pattern.
    private static func drawMarking(_ marking: Marking, art: Art, palette: Palette,
                                    into b: inout GraphicsContext) {
        switch marking {
        case .none:
            break
        case .lateralLine:
            var line = Path()
            line.move(to: CGPoint(x: art.eye.x - 0.12, y: art.eye.y + 0.04))
            line.addQuadCurve(to: CGPoint(x: -0.36, y: 0.02), control: CGPoint(x: -0.02, y: -0.04))
            b.stroke(line, with: .color(palette.dark.opacity(0.40)),
                     style: StrokeStyle(lineWidth: 0.018, lineCap: .round, dash: [0.001, 0.035]))
        case .neon:
            var stripe = Path()
            stripe.move(to: CGPoint(x: art.eye.x - 0.04, y: art.eye.y + 0.02))
            stripe.addQuadCurve(to: CGPoint(x: -0.38, y: -0.01), control: CGPoint(x: -0.02, y: -0.05))
            var glow = b
            glow.blendMode = .plusLighter
            glow.stroke(stripe, with: .color(palette.light.opacity(0.55)),
                        style: StrokeStyle(lineWidth: 0.10, lineCap: .round))
            glow.stroke(stripe, with: .color(.white.opacity(0.75)),
                        style: StrokeStyle(lineWidth: 0.03, lineCap: .round))
        case .angelBands:
            for (x, w) in [(0.24, 0.05), (0.02, 0.07), (-0.20, 0.06)] as [(Double, Double)] {
                var band = Path()
                band.move(to: CGPoint(x: x + 0.02, y: -0.6))
                band.addQuadCurve(to: CGPoint(x: x - 0.02, y: 0.6), control: CGPoint(x: x - 0.06, y: 0))
                b.stroke(band, with: .color(palette.dark.opacity(0.42)),
                         style: StrokeStyle(lineWidth: w, lineCap: .round))
            }
        case .sharkGills:
            var gills = Path()
            for k in 0..<3 {
                let x = art.eye.x - 0.14 - Double(k) * 0.045
                gills.move(to: CGPoint(x: x + 0.01, y: -0.06))
                gills.addQuadCurve(to: CGPoint(x: x, y: 0.10), control: CGPoint(x: x - 0.025, y: 0.02))
            }
            b.stroke(gills, with: .color(palette.dark.opacity(0.55)),
                     style: StrokeStyle(lineWidth: 0.014, lineCap: .round))
        case .iridescent:
            var sheen = b
            sheen.blendMode = .plusLighter
            sheen.fill(Path(CGRect(x: -0.5, y: -0.5, width: 1, height: 1)), with: .linearGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0.2),
                    .init(color: Color(red: 0.45, green: 0.85, blue: 1.0).opacity(0.22), location: 0.45),
                    .init(color: Color(red: 0.95, green: 0.55, blue: 1.0).opacity(0.18), location: 0.6),
                    .init(color: .clear, location: 0.8),
                ]),
                startPoint: CGPoint(x: -0.4, y: -0.3), endPoint: CGPoint(x: 0.3, y: 0.3)))
        case .seahorseRings:
            var rings = Path()
            for k in 0..<7 {
                let y = -0.18 + Double(k) * 0.075
                let x = 0.10 - max(0, Double(k) - 3.5) * 0.04
                rings.move(to: CGPoint(x: x - 0.16, y: y - 0.02))
                rings.addQuadCurve(to: CGPoint(x: x + 0.16, y: y - 0.02), control: CGPoint(x: x, y: y + 0.035))
            }
            b.stroke(rings, with: .color(palette.dark.opacity(0.38)), lineWidth: 0.014)
        case .blush:
            let c = CGPoint(x: art.eye.x - 0.02, y: art.eye.y + art.eyeR * 2.0)
            b.fill(Path(ellipseIn: CGRect(x: c.x - 0.055, y: c.y - 0.03, width: 0.11, height: 0.06)),
                   with: .radialGradient(
                    Gradient(colors: [Color(red: 1.0, green: 0.45, blue: 0.50).opacity(0.45), .clear]),
                    center: c, startRadius: 0, endRadius: 0.055))
        }
    }

    /// An earned mark (`AquariumVariant`), clipped to the body like a
    /// pattern and drawn over it — small and pale, so it reads as a
    /// distinction rather than a costume.
    private static func drawVariant(_ variant: AquariumVariant, palette: Palette,
                                    into b: inout GraphicsContext) {
        switch variant {
        case .tide:
            // One pale wave from gill to tail root along the flank.
            var stripe = Path()
            stripe.move(to: CGPoint(x: 0.34, y: -0.02))
            stripe.addCurve(to: CGPoint(x: -0.46, y: 0.02),
                            control1: CGPoint(x: 0.10, y: -0.16),
                            control2: CGPoint(x: -0.18, y: 0.14))
            b.stroke(stripe, with: .color(palette.light.opacity(0.8)),
                     style: StrokeStyle(lineWidth: 0.07, lineCap: .round))
            b.stroke(stripe, with: .color(.white.opacity(0.35)),
                     style: StrokeStyle(lineWidth: 0.025, lineCap: .round))
        case .starry:
            // Six specks across the back: a school's worth of stars.
            let specks: [(Double, Double, Double)] = [
                (0.22, -0.26, 0.030), (0.06, -0.33, 0.024), (-0.08, -0.24, 0.028),
                (-0.20, -0.30, 0.022), (0.14, -0.14, 0.020), (-0.30, -0.16, 0.024),
            ]
            for (x, y, r) in specks {
                b.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                       with: .color(.white.opacity(0.9)))
            }
        }
    }

    /// The species' marking, clipped to the body silhouette.
    private static func drawPattern(_ pattern: FishSpecies.Pattern, palette: Palette,
                                    into b: inout GraphicsContext, seed: UInt64) {
        switch pattern {
        case .plain:
            break
        case .bars:
            // Three bold white bars with dark edges, clownfish-style.
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
                b.stroke(bar, with: .color(palette.outline.opacity(0.9)), lineWidth: 0.05)
                b.fill(bar, with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.9), Color(white: 0.93).opacity(0.97)]),
                    startPoint: CGPoint(x: 0, y: -0.4), endPoint: CGPoint(x: 0, y: 0.4)))
            }
        case .spots:
            let spots: [(x: Double, y: Double, r: Double)] = [
                (0.28, -0.20, 0.045), (0.08, -0.30, 0.05), (0.14, 0.10, 0.04),
                (-0.08, -0.12, 0.055), (-0.12, 0.18, 0.045), (-0.26, 0.02, 0.05),
                (0.32, 0.14, 0.035), (-0.02, -0.34, 0.035), (-0.22, -0.26, 0.04),
            ]
            for spot in spots {
                b.fill(Path(ellipseIn: CGRect(x: spot.x - spot.r, y: spot.y - spot.r,
                                              width: spot.r * 2, height: spot.r * 2)),
                       with: .color(palette.dark.opacity(0.5)))
            }
        case .band:
            // A bold dark sweep over the tail end with a pale flash at
            // the root — the tang's calling card.
            var band = Path()
            band.move(to: CGPoint(x: -0.06, y: -0.6))
            band.addQuadCurve(to: CGPoint(x: -0.12, y: 0.6),
                              control: CGPoint(x: -0.30, y: 0))
            band.addLine(to: CGPoint(x: -0.50, y: 0.6))
            band.addLine(to: CGPoint(x: -0.50, y: -0.6))
            band.closeSubpath()
            b.fill(band, with: .color(palette.outline.opacity(0.62)))
            var flash = Path()
            flash.move(to: CGPoint(x: -0.25, y: -0.6))
            flash.addLine(to: CGPoint(x: -0.50, y: -0.6))
            flash.addLine(to: CGPoint(x: -0.50, y: 0.6))
            flash.addLine(to: CGPoint(x: -0.27, y: 0.6))
            flash.addQuadCurve(to: CGPoint(x: -0.25, y: -0.6),
                               control: CGPoint(x: -0.36, y: 0))
            flash.closeSubpath()
            b.fill(flash, with: .color(Color(red: 1.0, green: 0.84, blue: 0.28).opacity(0.9)))
        }
    }

    /// The big friendly eye: a soft socket, a white that shades toward
    /// its lower edge, a coloured iris, a deep pupil and two
    /// catchlights — and a lid that slides down on `blink`. Drawn as a
    /// circle in a space the caller may have sheared, so the radius is
    /// compensated on y by the body's aspect handled at call site.
    private static func drawEye(into f: inout GraphicsContext, art: Art,
                                palette: Palette, blink: Double, dead: Bool,
                                comp: Double) {
        func circle(_ cx: Double, _ cy: Double, _ r: Double) -> Path {
            Path(ellipseIn: CGRect(x: cx - r, y: cy - r * comp,
                                   width: r * 2, height: r * 2 * comp))
        }
        let e = art.eye, r = art.eyeR
        if dead {
            // A sinking fish: the classic cartoon X.
            var x1 = Path()
            let rr = r * 0.8
            x1.move(to: CGPoint(x: e.x - rr, y: e.y - rr * comp))
            x1.addLine(to: CGPoint(x: e.x + rr, y: e.y + rr * comp))
            x1.move(to: CGPoint(x: e.x + rr, y: e.y - rr * comp))
            x1.addLine(to: CGPoint(x: e.x - rr, y: e.y + rr * comp))
            f.stroke(x1, with: .color(palette.outline.opacity(0.8)),
                     style: StrokeStyle(lineWidth: 0.035, lineCap: .round))
            return
        }
        // The socket: a soft shadow ring that seats the eye in the head.
        f.fill(circle(e.x - r * 0.04, e.y + r * 0.06, r * 1.28),
               with: .radialGradient(Gradient(colors: [palette.dark.opacity(0.45), palette.dark.opacity(0)]),
                                     center: CGPoint(x: e.x, y: e.y), startRadius: r * 0.9,
                                     endRadius: r * 1.3))
        let white = circle(e.x, e.y, r)
        f.fill(white, with: .radialGradient(
            Gradient(colors: [.white, Color(red: 0.86, green: 0.90, blue: 0.94)]),
            center: CGPoint(x: e.x + r * 0.2, y: e.y - r * 0.3 * comp),
            startRadius: 0, endRadius: r * 1.2))
        var inner = f
        inner.clip(to: white)
        // The iris looks forward, where the fish is going.
        let ix = e.x + r * 0.24, iy = e.y + r * 0.02
        let irisR = r * 0.68
        inner.fill(circle(ix, iy, irisR), with: .radialGradient(
            Gradient(colors: [palette.light, palette.body, palette.outline]),
            center: CGPoint(x: ix, y: iy + irisR * 0.3 * comp),
            startRadius: 0, endRadius: irisR * 1.05))
        inner.fill(circle(ix + r * 0.04, iy, irisR * 0.60),
                   with: .color(Color(red: 0.03, green: 0.04, blue: 0.07)))
        // The upper lid's shadow across the top of the white.
        inner.fill(Path(CGRect(x: e.x - r, y: e.y - r * comp, width: r * 2, height: r * 0.5 * comp)),
                   with: .linearGradient(Gradient(colors: [palette.dark.opacity(0.35), .clear]),
                                         startPoint: CGPoint(x: 0, y: e.y - r * comp),
                                         endPoint: CGPoint(x: 0, y: e.y - r * 0.45 * comp)))
        // Catchlights: a big one high and forward, a small one low.
        inner.fill(circle(ix + r * 0.18, iy - r * 0.30, r * 0.26), with: .color(.white.opacity(0.97)))
        inner.fill(circle(ix - r * 0.26, iy + r * 0.30, r * 0.11), with: .color(.white.opacity(0.75)))
        f.stroke(white, with: .color(palette.outline.opacity(0.85)), lineWidth: 0.022)
        if blink > 0.01 {
            // The lid: a body-coloured cap sliding over the eye.
            var lid = f
            lid.clip(to: circle(e.x, e.y, r + 0.012))
            let cover = r * 2 * blink * comp
            lid.fill(Path(CGRect(x: e.x - r - 0.02, y: e.y - r * comp - 0.02,
                                 width: r * 2 + 0.04, height: cover + 0.02)),
                     with: .color(palette.body))
            lid.stroke(Path(ellipseIn: CGRect(
                x: e.x - r, y: e.y - r * comp + cover - r * 0.2 * comp,
                width: r * 2, height: r * 0.4 * comp)),
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
            m.move(to: CGPoint(x: p.x - 0.01, y: p.y - 0.05))
            m.addQuadCurve(to: CGPoint(x: p.x - 0.14, y: p.y - 0.02),
                           control: CGPoint(x: p.x - 0.05, y: p.y + 0.06))
            m.addQuadCurve(to: CGPoint(x: p.x - 0.01, y: p.y - 0.05),
                           control: CGPoint(x: p.x - 0.07, y: p.y + 0.01))
            f.fill(m, with: .color(Color(red: 0.55, green: 0.12, blue: 0.16).opacity(0.85)))
            f.stroke(m, with: .color(palette.outline),
                     style: StrokeStyle(lineWidth: 0.026, lineCap: .round, lineJoin: .round))
        case .hungry:
            let r = 0.042
            let o = Path(ellipseIn: CGRect(x: p.x - 0.03 - r, y: p.y - 0.02 - r,
                                           width: r * 2, height: r * 2))
            f.fill(o, with: .color(Color(red: 0.35, green: 0.06, blue: 0.10).opacity(0.85)))
            f.stroke(o, with: .color(palette.outline), lineWidth: 0.024)
        case .plain:
            var m = Path()
            m.move(to: CGPoint(x: p.x - 0.01, y: p.y - 0.02))
            m.addQuadCurve(to: CGPoint(x: p.x - 0.11, y: p.y - 0.005),
                           control: CGPoint(x: p.x - 0.05, y: p.y + 0.025))
            f.stroke(m, with: .color(palette.outline.opacity(0.85)),
                     style: StrokeStyle(lineWidth: 0.024, lineCap: .round))
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
