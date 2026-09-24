import JRBarCore
import SwiftUI

/// The species kits: each silhouette drawn at its true proportions in
/// unit space, nose toward +x. Built once; the swim pose bends copies.
extension CartoonFish {
    static let kits: [FishSpecies: Art] = [
        .minnow: minnowKit(),
        .tetra: tetraKit(),
        .clownfish: clownfishKit(),
        .tang: tangKit(),
        .angelfish: angelfishKit(),
        .betta: bettaKit(),
        .puffer: pufferKit(),
        .shark: sharkKit(),
        .seahorse: seahorseKit(),
    ].mapValues(finished)

    /// The kit made ready: marks that never reach the bending tail are
    /// told so, and the collar is found — just behind the gill on a
    /// swimmer, across the neck under the head on an upright one.
    private static func finished(_ art: Art) -> Art {
        var art = art
        // Every path the swim bends is held as a CoreGraphics path, so
        // bending one each frame reads it without converting it first.
        art.body = Path(art.body.cgPath)
        for i in art.marks.indices {
            art.marks[i].path = Path(art.marks[i].path.cgPath)
            art.marks[i].flexes = art.marks[i].path.boundingRect.minX < art.flexPivot
        }
        for i in art.fins.indices {
            art.fins[i].path = Path(art.fins[i].path.cgPath)
            art.fins[i].rays = Path(art.fins[i].rays.cgPath)
        }
        art.flank = Path(art.flank.cgPath)
        let b = art.bounds
        var inside: [CGPoint] = []
        if art.upright {
            let y = art.eye.y + art.eyeR * 2.6
            for x in stride(from: b.minX, through: b.maxX, by: 0.004)
            where art.body.contains(CGPoint(x: x, y: y)) {
                inside.append(CGPoint(x: x, y: y))
            }
        } else {
            let x = art.eye.x - art.eyeR * 2.3
            for y in stride(from: b.minY, through: b.maxY, by: 0.004)
            where art.body.contains(CGPoint(x: x, y: y)) {
                inside.append(CGPoint(x: x, y: y))
            }
        }
        if let first = inside.first, let last = inside.last {
            art.collar = (first, last)
        }
        return art
    }

    /// The union of a kit's body and fins, for shadows and tags.
    private static func extent(_ body: Path, _ fins: [Fin]) -> CGRect {
        fins.reduce(body.boundingRect) { $0.union($1.path.boundingRect) }
    }

    private static func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    private static func line(_ knots: [Knot]) -> Path { spline(knots, closed: false) }

    /// The gill cover: a soft crescent just behind the eye.
    private static func gillArc(x: Double, top: Double, bottom: Double, bow: Double = 0.07) -> Path {
        var p = Path()
        p.move(to: pt(x, top))
        p.addQuadCurve(to: pt(x + 0.005, bottom), control: pt(x - bow, (top + bottom) / 2))
        return p
    }

    private static func dot(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    // MARK: Minnow

    /// The plain plump fish, a dotted line down its flank.
    private static func minnowKit() -> Art {
        let body = spline([k(0.50, 0.03), k(0.44, -0.09), k(0.28, -0.185), k(0.04, -0.205),
                           k(-0.18, -0.155), k(-0.33, -0.075), k(-0.39, 0), k(-0.33, 0.07),
                           k(-0.18, 0.13), k(0.04, 0.185), k(0.28, 0.165), k(0.44, 0.10)])
        let fins = [
            fin(pt(0.19, 0.05), pt(0.16, 0.10), edge: [k(0.10, 0.03), corner(0.03, 0.08), k(0.08, 0.14)],
                rays: 3, motion: .paddle(0.5), layer: .far),
            fin(pt(-0.34, -0.05), pt(-0.34, 0.05),
                edge: [k(-0.46, -0.13), corner(-0.66, -0.26), k(-0.60, -0.11), corner(-0.55, 0),
                       k(-0.60, 0.11), corner(-0.66, 0.26), k(-0.46, 0.13)],
                rays: 8, motion: .tail),
            fin(pt(0.10, -0.195), pt(-0.20, -0.145),
                edge: [k(0.04, -0.31), corner(-0.06, -0.36), k(-0.16, -0.27), k(-0.23, -0.17)],
                rays: 5, motion: .ripple(0.5)),
            fin(pt(-0.08, 0.175), pt(-0.28, 0.10),
                edge: [k(-0.14, 0.27), corner(-0.25, 0.28), k(-0.31, 0.15)],
                rays: 4, motion: .ripple(0.5)),
            fin(pt(0.14, 0.17), pt(0.06, 0.185), edge: [corner(0.02, 0.29), k(0.08, 0.25)],
                rays: 3, motion: .ripple(0.4)),
            fin(pt(0.19, 0.04), pt(0.17, 0.11),
                edge: [k(0.10, 0.04), k(0.02, 0.10), corner(0.0, 0.155), k(0.09, 0.16)],
                rays: 4, motion: .paddle(0.6), layer: .near),
        ]
        let flank = line([k(0.16, -0.025), k(-0.05, -0.03), k(-0.36, 0.005)])
        return Art(
            body: body, bounds: body.boundingRect, fins: fins,
            marks: [Mark(path: flank, style: .dots(.dark, width: 0.022, gap: 0.045, opacity: 0.5))],
            eye: pt(0.29, -0.055), eyeR: 0.088, eyeSpread: 0.07,
            mouth: pt(0.49, 0.055),
            hatAnchor: pt(0.25, -0.185), hatScale: 0.9, hatTilt: 0.12,
            chin: pt(0.30, 0.16),
            gill: gillArc(x: 0.17, top: -0.13, bottom: 0.11),
            flank: flank, flexPivot: 0.10, tailRootX: -0.36,
            gloss: CGRect(x: 0.18, y: -0.17, width: 0.20, height: 0.06),
            scales: scaleTexture(bounds: body.boundingRect),
            extent: extent(body, fins))
    }

    // MARK: Tetra

    /// Small, slim and shiny — the neon stripe is its name, over a
    /// red lower flank.
    private static func tetraKit() -> Art {
        let body = spline([k(0.50, 0.02), k(0.43, -0.075), k(0.26, -0.145), k(0.02, -0.16),
                           k(-0.18, -0.12), k(-0.32, -0.06), k(-0.38, 0), k(-0.32, 0.055),
                           k(-0.16, 0.105), k(0.06, 0.145), k(0.30, 0.125), k(0.44, 0.065)])
        let fins = [
            fin(pt(0.19, 0.04), pt(0.17, 0.08), edge: [k(0.11, 0.03), corner(0.05, 0.07), k(0.09, 0.11)],
                rays: 3, motion: .paddle(0.6), layer: .far),
            fin(pt(-0.34, -0.045), pt(-0.34, 0.045),
                edge: [k(-0.44, -0.11), corner(-0.62, -0.22), k(-0.55, -0.08), corner(-0.51, 0),
                       k(-0.55, 0.08), corner(-0.62, 0.22), k(-0.44, 0.11)],
                rays: 7, motion: .tail),
            fin(pt(0.04, -0.155), pt(-0.10, -0.14),
                edge: [k(0.0, -0.26), corner(-0.06, -0.31), k(-0.13, -0.20)],
                rays: 4, motion: .ripple(0.5)),
            // The adipose: the tiny fin behind the dorsal every tetra has.
            fin(pt(-0.22, -0.105), pt(-0.29, -0.075), edge: [k(-0.27, -0.15)],
                rays: 0, motion: .fixed),
            fin(pt(-0.02, 0.145), pt(-0.27, 0.07),
                edge: [k(-0.06, 0.23), k(-0.18, 0.22), corner(-0.28, 0.19), k(-0.31, 0.10)],
                rays: 5, motion: .ripple(0.4)),
            fin(pt(0.14, 0.135), pt(0.08, 0.145), edge: [corner(0.04, 0.23), k(0.09, 0.2)],
                rays: 2, motion: .ripple(0.4)),
            fin(pt(0.19, 0.035), pt(0.17, 0.09),
                edge: [k(0.11, 0.03), k(0.04, 0.08), corner(0.02, 0.125), k(0.10, 0.125)],
                rays: 3, motion: .paddle(0.7), layer: .near),
        ]
        let stripe = line([k(0.22, -0.045), k(0.0, -0.05), k(-0.20, -0.035), k(-0.37, -0.01)])
        let red = spline([k(0.24, 0.07), k(0.02, 0.012), corner(-0.44, 0.0),
                          corner(-0.44, 0.3), corner(0.10, 0.3)])
        return Art(
            body: body, bounds: body.boundingRect, fins: fins,
            marks: [Mark(path: red, style: .fill(.neonRed, 0.72)),
                    Mark(path: stripe, style: .neon(width: 0.032))],
            eye: pt(0.31, -0.035), eyeR: 0.095, eyeSpread: 0.07,
            mouth: pt(0.49, 0.04), mouthScale: 0.85,
            hatAnchor: pt(0.27, -0.14), hatScale: 0.78, hatTilt: 0.14,
            chin: pt(0.32, 0.115),
            gill: gillArc(x: 0.19, top: -0.10, bottom: 0.09, bow: 0.05),
            flank: stripe, flexPivot: 0.08, tailRootX: -0.34,
            gloss: CGRect(x: 0.18, y: -0.135, width: 0.18, height: 0.05),
            scales: scaleTexture(bounds: body.boundingRect, r: 0.04),
            extent: extent(body, fins))
    }

    // MARK: Clownfish

    /// The roundest body of the lot: three bold white bars edged in
    /// black, every fin trimmed dark, a notched dorsal.
    private static func clownfishKit() -> Art {
        let body = spline([k(0.50, 0.04), k(0.45, -0.10), k(0.32, -0.225), k(0.10, -0.28),
                           k(-0.12, -0.245), k(-0.28, -0.15), k(-0.37, -0.065), k(-0.40, 0),
                           k(-0.37, 0.065), k(-0.28, 0.15), k(-0.10, 0.235), k(0.12, 0.26),
                           k(0.34, 0.195), k(0.46, 0.11)])
        let fins = [
            fin(pt(0.20, 0.05), pt(0.17, 0.12), edge: [k(0.11, 0.04), k(0.04, 0.09), k(0.06, 0.16)],
                rays: 4, motion: .paddle(0.5), layer: .far, trim: true),
            fin(pt(-0.36, -0.06), pt(-0.36, 0.06),
                edge: [k(-0.46, -0.16), k(-0.58, -0.21), k(-0.66, -0.13), k(-0.68, 0),
                       k(-0.66, 0.13), k(-0.58, 0.21), k(-0.46, 0.16)],
                rays: 8, motion: .tail, trim: true),
            fin(pt(0.22, -0.24), pt(-0.30, -0.14),
                edge: [k(0.16, -0.33), k(0.07, -0.365), k(-0.02, -0.335), k(-0.10, -0.39),
                       k(-0.22, -0.38), k(-0.32, -0.26), k(-0.36, -0.17)],
                rays: 8, motion: .ripple(0.4), trim: true),
            fin(pt(-0.06, 0.24), pt(-0.30, 0.14),
                edge: [k(-0.10, 0.35), k(-0.22, 0.355), k(-0.33, 0.24), k(-0.36, 0.16)],
                rays: 5, motion: .ripple(0.4), trim: true),
            fin(pt(0.16, 0.24), pt(0.06, 0.255), edge: [k(0.10, 0.35), corner(0.02, 0.36), k(0.03, 0.30)],
                rays: 3, motion: .ripple(0.4), trim: true),
            fin(pt(0.20, 0.03), pt(0.17, 0.12),
                edge: [k(0.11, 0.02), k(0.02, 0.07), k(-0.01, 0.14), k(0.04, 0.19), k(0.12, 0.17)],
                rays: 5, motion: .paddle(0.6), layer: .near, trim: true),
        ]
        let head = spline([k(0.24, -0.42), k(0.18, -0.12), k(0.18, 0.10), k(0.24, 0.42),
                           k(0.15, 0.42), k(0.11, 0.10), k(0.11, -0.12), k(0.15, -0.42)])
        let middle = spline([k(-0.03, -0.42), k(-0.01, -0.15), k(0.05, 0.02), k(-0.01, 0.18),
                             k(-0.04, 0.42), k(-0.12, 0.42), k(-0.09, 0.18), k(-0.04, 0.02),
                             k(-0.09, -0.15), k(-0.11, -0.42)])
        let tail = spline([k(-0.28, -0.32), k(-0.295, 0), k(-0.28, 0.32),
                           k(-0.345, 0.32), k(-0.355, 0), k(-0.345, -0.32)])
        let cheek = Path(ellipseIn: CGRect(x: 0.22, y: 0.03, width: 0.11, height: 0.06))
        return Art(
            body: body, bounds: body.boundingRect, fins: fins,
            marks: [Mark(path: head, style: .bar(edge: 0.022)),
                    Mark(path: middle, style: .bar(edge: 0.022)),
                    Mark(path: tail, style: .bar(edge: 0.022)),
                    Mark(path: cheek, style: .blush)],
            eye: pt(0.30, -0.075), eyeR: 0.092, eyeSpread: 0.08,
            mouth: pt(0.49, 0.075),
            hatAnchor: pt(0.26, -0.245), hatScale: 1.0, hatTilt: 0.18,
            chin: pt(0.30, 0.21),
            gill: nil,
            flank: line([k(0.20, 0.02), k(-0.05, 0.0), k(-0.38, 0.0)]),
            flexPivot: 0.05, tailRootX: -0.37,
            gloss: CGRect(x: 0.20, y: -0.25, width: 0.20, height: 0.07),
            scales: scaleTexture(bounds: body.boundingRect),
            extent: extent(body, fins))
    }

    // MARK: Tang

    /// A tall oval with a long fin along its back and belly, the deep
    /// sweep of its palette marking and a bright yellow tail.
    private static func tangKit() -> Art {
        let yellow = Color(red: 1.0, green: 0.80, blue: 0.22)
        let body = spline([k(0.50, 0.08), k(0.47, -0.04), k(0.36, -0.20), k(0.16, -0.315),
                           k(-0.08, -0.31), k(-0.26, -0.20), k(-0.36, -0.085), k(-0.40, 0),
                           k(-0.36, 0.075), k(-0.26, 0.18), k(-0.06, 0.28), k(0.16, 0.285),
                           k(0.36, 0.21), k(0.46, 0.14)])
        let fins = [
            fin(pt(0.20, 0.06), pt(0.17, 0.13), edge: [k(0.11, 0.05), corner(0.03, 0.10), k(0.07, 0.16)],
                rays: 3, motion: .paddle(0.5), layer: .far, tint: yellow),
            fin(pt(-0.37, -0.05), pt(-0.37, 0.05),
                edge: [k(-0.47, -0.13), corner(-0.64, -0.23), k(-0.585, -0.10), k(-0.57, 0),
                       k(-0.585, 0.10), corner(-0.64, 0.23), k(-0.47, 0.13)],
                rays: 8, motion: .tail, tint: yellow),
            fin(pt(0.28, -0.25), pt(-0.34, -0.10),
                edge: [k(0.20, -0.35), k(0.02, -0.41), k(-0.18, -0.39), k(-0.32, -0.28), k(-0.39, -0.14)],
                rays: 10, motion: .ripple(0.35)),
            fin(pt(0.12, 0.28), pt(-0.34, 0.09),
                edge: [k(0.02, 0.37), k(-0.16, 0.38), k(-0.30, 0.27), k(-0.38, 0.12)],
                rays: 8, motion: .ripple(0.35)),
            fin(pt(0.20, 0.26), pt(0.12, 0.28), edge: [corner(0.10, 0.38), k(0.15, 0.34)],
                rays: 2, motion: .ripple(0.4)),
            fin(pt(0.21, 0.05), pt(0.18, 0.13),
                edge: [k(0.12, 0.04), k(0.03, 0.09), corner(0.01, 0.15), k(0.10, 0.17)],
                rays: 4, motion: .paddle(0.6), layer: .near, tint: yellow),
        ]
        // The palette: a dark sweep from the eye along the back and down
        // to the tail, hooking forward along the lower flank.
        let palette = spline([k(0.40, -0.10), k(0.33, -0.19), k(0.16, -0.27), k(-0.06, -0.28),
                              k(-0.26, -0.19), corner(-0.41, -0.07), corner(-0.41, 0.08),
                              k(-0.26, 0.13), k(-0.08, 0.12), k(0.06, 0.085), k(0.10, 0.05),
                              k(0.03, 0.04), k(-0.12, 0.055), k(-0.25, 0.0), k(-0.22, -0.15),
                              k(-0.10, -0.21), k(0.06, -0.20), k(0.18, -0.12), k(0.24, 0.0),
                              k(0.35, 0.01)])
        return Art(
            body: body, bounds: body.boundingRect, fins: fins,
            marks: [Mark(path: palette, style: .fill(.outline, 0.88))],
            eye: pt(0.30, -0.07), eyeR: 0.088, eyeSpread: 0.08,
            mouth: pt(0.495, 0.10), mouthScale: 0.9,
            hatAnchor: pt(0.24, -0.285), hatScale: 1.0, hatTilt: 0.28,
            chin: pt(0.33, 0.22),
            gill: gillArc(x: 0.17, top: -0.16, bottom: 0.14, bow: 0.08),
            flank: line([k(0.18, 0.02), k(-0.06, 0.03), k(-0.38, 0.0)]),
            flexPivot: 0.0, tailRootX: -0.38,
            gloss: CGRect(x: 0.20, y: -0.27, width: 0.20, height: 0.07),
            scales: scaleTexture(bounds: body.boundingRect),
            extent: extent(body, fins))
    }

    // MARK: Angelfish

    /// A tall disc under long swept sails, ventral threads trailing
    /// beneath and three soft bands down the body.
    private static func angelfishKit() -> Art {
        let body = spline([k(0.50, -0.005), k(0.44, -0.075), k(0.32, -0.21), k(0.14, -0.33),
                           k(-0.06, -0.32), k(-0.22, -0.21), k(-0.33, -0.08), k(-0.37, 0),
                           k(-0.33, 0.08), k(-0.22, 0.21), k(-0.04, 0.33), k(0.16, 0.32),
                           k(0.33, 0.19), k(0.45, 0.065)])
        let fins = [
            fin(pt(0.22, 0.27), pt(0.16, 0.30),
                edge: [k(0.16, 0.44), k(0.06, 0.60), corner(-0.04, 0.74), k(0.05, 0.56), k(0.12, 0.42)],
                rays: 0, motion: .ripple(0.5), layer: .far),
            fin(pt(-0.35, -0.05), pt(-0.35, 0.05),
                edge: [k(-0.46, -0.16), corner(-0.76, -0.34), k(-0.63, -0.15), k(-0.61, 0),
                       k(-0.63, 0.15), corner(-0.76, 0.34), k(-0.46, 0.16)],
                rays: 9, motion: .tail),
            fin(pt(0.16, -0.33), pt(-0.28, -0.13),
                edge: [k(0.07, -0.48), k(-0.07, -0.62), corner(-0.30, -0.78), k(-0.26, -0.55),
                       k(-0.29, -0.35), k(-0.34, -0.18)],
                rays: 9, motion: .ripple(0.25)),
            fin(pt(0.14, 0.33), pt(-0.28, 0.13),
                edge: [k(0.06, 0.50), k(-0.08, 0.66), corner(-0.30, 0.82), k(-0.26, 0.57),
                       k(-0.29, 0.37), k(-0.34, 0.19)],
                rays: 9, motion: .ripple(0.25)),
            fin(pt(0.24, 0.26), pt(0.18, 0.29),
                edge: [k(0.20, 0.44), k(0.12, 0.62), corner(0.02, 0.78), k(0.10, 0.58), k(0.15, 0.42)],
                rays: 0, motion: .ripple(0.5)),
            fin(pt(0.19, 0.02), pt(0.17, 0.09),
                edge: [k(0.10, 0.02), k(0.03, 0.07), corner(0.01, 0.13), k(0.09, 0.14)],
                rays: 4, motion: .paddle(0.6), layer: .near),
        ]
        let bands = [
            Mark(path: line([k(0.34, -0.42), k(0.29, 0), k(0.32, 0.42)]),
                 style: .stroke(.outline, width: 0.06, opacity: 0.55)),
            Mark(path: line([k(0.07, -0.46), k(0.02, 0), k(0.06, 0.46)]),
                 style: .stroke(.outline, width: 0.09, opacity: 0.55)),
            Mark(path: line([k(-0.19, -0.46), k(-0.23, 0), k(-0.19, 0.46)]),
                 style: .stroke(.outline, width: 0.07, opacity: 0.5)),
        ]
        return Art(
            body: body, bounds: body.boundingRect, fins: fins, marks: bands,
            eye: pt(0.29, -0.085), eyeR: 0.088, eyeSpread: 0.075,
            mouth: pt(0.495, 0.01), mouthScale: 0.85,
            hatAnchor: pt(0.24, -0.265), hatScale: 0.95, hatTilt: 0.4,
            chin: pt(0.33, 0.17),
            gill: gillArc(x: 0.16, top: -0.18, bottom: 0.15, bow: 0.08),
            flank: line([k(0.18, 0.0), k(-0.06, 0.0), k(-0.35, 0.0)]),
            flexPivot: -0.12, tailRootX: -0.35,
            gloss: CGRect(x: 0.16, y: -0.29, width: 0.20, height: 0.08),
            scales: scaleTexture(bounds: body.boundingRect),
            extent: extent(body, fins))
    }

    // MARK: Betta

    /// A slim body under huge flowing veils that ripple at the edge.
    private static func bettaKit() -> Art {
        let body = spline([k(0.50, 0.02), k(0.43, -0.065), k(0.26, -0.135), k(0.02, -0.15),
                           k(-0.18, -0.115), k(-0.30, -0.07), k(-0.34, 0), k(-0.30, 0.065),
                           k(-0.16, 0.11), k(0.06, 0.15), k(0.30, 0.13), k(0.44, 0.07)])
        // The veil: a wide fan with a softly ruffled trailing edge.
        var veil: [Knot] = [k(-0.40, -0.20)]
        let lobes = 13
        for i in 0..<lobes {
            let u = Double(i) / Double(lobes - 1)
            let a = -1.30 + 2.60 * u
            let r = 0.56 + 0.05 * cos(a * 1.4) + (i % 2 == 0 ? 0.03 : -0.02)
            veil.append(k(-0.29 - r * cos(a), r * sin(a) * 0.98))
        }
        veil.append(k(-0.40, 0.20))
        let fins = [
            fin(pt(0.22, 0.03), pt(0.20, 0.07), edge: [k(0.14, 0.02), corner(0.08, 0.06), k(0.12, 0.09)],
                rays: 3, motion: .paddle(0.6), layer: .far),
            fin(pt(0.22, 0.12), pt(0.16, 0.14), edge: [k(0.16, 0.28), corner(0.06, 0.44), k(0.12, 0.26)],
                rays: 0, motion: .ripple(0.6), layer: .far),
            fin(pt(-0.29, -0.07), pt(-0.29, 0.07), edge: veil,
                rays: 13, motion: .tail),
            fin(pt(0.02, -0.15), pt(-0.28, -0.075),
                edge: [k(-0.04, -0.28), k(-0.18, -0.40), k(-0.36, -0.44), k(-0.50, -0.38),
                       k(-0.46, -0.24), k(-0.36, -0.12)],
                rays: 8, motion: .ripple(0.45)),
            fin(pt(0.16, 0.14), pt(-0.28, 0.07),
                edge: [k(0.08, 0.30), k(-0.06, 0.46), k(-0.26, 0.54), k(-0.46, 0.48),
                       k(-0.44, 0.30), k(-0.36, 0.14)],
                rays: 10, motion: .ripple(0.45)),
            fin(pt(0.26, 0.12), pt(0.20, 0.14), edge: [k(0.22, 0.28), corner(0.12, 0.46), k(0.17, 0.27)],
                rays: 0, motion: .ripple(0.6)),
            fin(pt(0.22, 0.02), pt(0.20, 0.08),
                edge: [k(0.14, 0.02), k(0.07, 0.06), corner(0.05, 0.10), k(0.13, 0.11)],
                rays: 3, motion: .paddle(0.7), layer: .near),
        ]
        return Art(
            body: body, bounds: body.boundingRect, fins: fins,
            marks: [Mark(path: Path(body.boundingRect), style: .sheen)],
            eye: pt(0.32, -0.035), eyeR: 0.082, eyeSpread: 0.065,
            mouth: pt(0.49, 0.03), mouthScale: 0.85,
            hatAnchor: pt(0.29, -0.125), hatScale: 0.8, hatTilt: 0.18,
            chin: pt(0.33, 0.12),
            gill: gillArc(x: 0.20, top: -0.09, bottom: 0.10, bow: 0.05),
            flank: line([k(0.18, -0.01), k(-0.05, -0.01), k(-0.33, 0.0)]),
            flexPivot: 0.08, tailRootX: -0.30,
            gloss: CGRect(x: 0.20, y: -0.13, width: 0.18, height: 0.05),
            scales: scaleTexture(bounds: body.boundingRect, r: 0.04),
            extent: extent(body, fins),
            iridescent: true)
    }

    // MARK: Puffer

    /// A round, spiny little ball with big eyes, a spotted back, a
    /// cream belly and fins too small for the job.
    private static func pufferKit() -> Art {
        let body = spline([k(0.475, 0.05), k(0.44, -0.12), k(0.31, -0.29), k(0.09, -0.385),
                           k(-0.13, -0.37), k(-0.30, -0.25), k(-0.385, -0.08), k(-0.38, 0.07),
                           k(-0.31, 0.22), k(-0.15, 0.335), k(0.06, 0.375), k(0.28, 0.31),
                           k(0.42, 0.19)])
        // Soft spines around the back and belly — none on the face or
        // at the tail root.
        var spines = Path()
        for i in 0..<22 {
            let a = Double(i) / 22 * .pi * 2 + 0.14
            let ca = cos(a), sa = sin(a)
            guard ca < 0.5, ca > -0.8 || abs(sa) > 0.45 else { continue }
            let base = pt(0.04 + ca * 0.405, sa * 0.37)
            let px = -sa, py = ca
            spines.move(to: pt(base.x + px * 0.03, base.y + py * 0.03))
            spines.addQuadCurve(to: pt(base.x + ca * 0.085, base.y + sa * 0.085),
                                control: pt(base.x + ca * 0.03 + px * 0.012, base.y + sa * 0.03 + py * 0.012))
            spines.addQuadCurve(to: pt(base.x - px * 0.03, base.y - py * 0.03),
                                control: pt(base.x + ca * 0.03 - px * 0.012, base.y + sa * 0.03 - py * 0.012))
            spines.closeSubpath()
        }
        let spineFin = Fin(path: spines, rays: Path(), pivot: pt(0.04, 0), tip: pt(0.04, -0.46),
                           reach: 0.46, motion: .fixed, layer: .behind, solid: true)
        let fins = [
            spineFin,
            fin(pt(-0.36, -0.07), pt(-0.36, 0.07),
                edge: [k(-0.46, -0.15), k(-0.56, -0.15), k(-0.60, 0), k(-0.56, 0.15), k(-0.46, 0.15)],
                rays: 6, motion: .tail),
            fin(pt(-0.14, -0.36), pt(-0.27, -0.26), edge: [k(-0.18, -0.46), corner(-0.28, -0.46), k(-0.31, -0.34)],
                rays: 3, motion: .ripple(0.7)),
            fin(pt(-0.14, 0.345), pt(-0.27, 0.24), edge: [k(-0.18, 0.44), corner(-0.28, 0.43), k(-0.31, 0.31)],
                rays: 3, motion: .ripple(0.7)),
            fin(pt(0.03, 0.06), pt(0.01, 0.15),
                edge: [k(-0.05, 0.05), corner(-0.14, 0.08), k(-0.12, 0.16), k(-0.04, 0.19)],
                rays: 4, motion: .paddle(0.9), layer: .near),
        ]
        let belly = spline([k(0.44, 0.12), k(0.22, 0.17), k(-0.04, 0.18), k(-0.30, 0.10),
                            corner(-0.42, 0.10), corner(-0.42, 0.45), corner(0.5, 0.45)])
        var spots = Path()
        for (x, y, r) in [(0.10, -0.29, 0.034), (-0.06, -0.31, 0.04), (-0.21, -0.23, 0.036),
                          (0.00, -0.19, 0.028), (-0.14, -0.11, 0.034), (-0.29, -0.07, 0.03),
                          (0.18, -0.22, 0.024), (-0.30, 0.05, 0.026), (-0.02, -0.06, 0.022)]
                as [(Double, Double, Double)] {
            spots.addPath(dot(x, y, r))
        }
        let cheek = Path(ellipseIn: CGRect(x: 0.20, y: 0.0, width: 0.14, height: 0.08))
        return Art(
            body: body, bounds: body.boundingRect, fins: fins,
            marks: [Mark(path: belly, style: .fill(.light, 0.85)),
                    Mark(path: spots, style: .fill(.dark, 0.6)),
                    Mark(path: cheek, style: .blush)],
            eye: pt(0.25, -0.14), eyeR: 0.11, eyeSpread: 0.10,
            mouth: pt(0.475, 0.07), mouthScale: 0.8,
            hatAnchor: pt(0.12, -0.38), hatScale: 1.05, hatTilt: 0.12,
            chin: pt(0.30, 0.29),
            gill: nil,
            flank: line([k(0.14, -0.02), k(-0.10, 0.0), k(-0.38, 0.0)]),
            flexPivot: -0.15, tailRootX: -0.36,
            gloss: CGRect(x: 0.04, y: -0.36, width: 0.26, height: 0.10),
            scales: nil,
            extent: extent(body, fins))
    }

    // MARK: Shark

    /// A sleek blade with a pointed snout, a tall dorsal, a crisp white
    /// belly and gill slits — still round-eyed and friendly.
    private static func sharkKit() -> Art {
        let body = spline([k(0.52, 0.025), k(0.46, -0.055), k(0.28, -0.12), k(0.04, -0.145),
                           k(-0.20, -0.11), k(-0.36, -0.055), k(-0.44, -0.02), k(-0.46, 0),
                           k(-0.44, 0.02), k(-0.32, 0.05), k(-0.08, 0.11), k(0.18, 0.125),
                           k(0.38, 0.10), k(0.49, 0.06)])
        let fins = [
            fin(pt(0.20, 0.07), pt(0.12, 0.09), edge: [k(0.13, 0.15), corner(0.02, 0.26), k(0.06, 0.15)],
                rays: 0, motion: .paddle(0.3), layer: .far),
            fin(pt(-0.43, -0.025), pt(-0.43, 0.025),
                edge: [k(-0.52, -0.10), k(-0.64, -0.22), corner(-0.78, -0.34), k(-0.70, -0.17),
                       k(-0.62, -0.04), k(-0.63, 0.06), corner(-0.68, 0.17), k(-0.56, 0.08)],
                rays: 0, motion: .tail),
            fin(pt(0.14, -0.14), pt(-0.10, -0.135),
                edge: [k(0.10, -0.24), k(0.04, -0.34), corner(-0.04, -0.43), k(-0.05, -0.30),
                       k(-0.08, -0.20), k(-0.12, -0.155)],
                rays: 0, motion: .ripple(0.15)),
            fin(pt(-0.27, -0.085), pt(-0.34, -0.06), edge: [corner(-0.35, -0.135)],
                rays: 0, motion: .fixed),
            fin(pt(-0.16, 0.085), pt(-0.24, 0.07), edge: [corner(-0.28, 0.15)],
                rays: 0, motion: .fixed),
            fin(pt(-0.31, 0.05), pt(-0.36, 0.035), edge: [corner(-0.38, 0.09)],
                rays: 0, motion: .fixed),
            fin(pt(0.22, 0.075), pt(0.13, 0.105),
                edge: [k(0.14, 0.18), k(0.06, 0.27), corner(-0.02, 0.33), k(0.03, 0.22), k(0.07, 0.14)],
                rays: 0, motion: .paddle(0.35), layer: .near),
        ]
        let belly = spline([k(0.53, 0.03), k(0.36, 0.035), k(0.10, 0.045), k(-0.16, 0.035),
                            k(-0.40, 0.005), corner(-0.48, 0), corner(-0.48, 0.2), corner(0.55, 0.2)])
        var gills = Path()
        for x in [0.225, 0.19, 0.155] {
            gills.move(to: pt(x + 0.008, -0.05))
            gills.addQuadCurve(to: pt(x - 0.004, 0.06), control: pt(x - 0.02, 0.005))
        }
        return Art(
            body: body, bounds: body.boundingRect, fins: fins,
            marks: [Mark(path: belly, style: .fill(.white, 0.9)),
                    Mark(path: gills, style: .stroke(.dark, width: 0.013, opacity: 0.65))],
            eye: pt(0.35, -0.04), eyeR: 0.058, eyeSpread: 0.06,
            mouth: pt(0.45, 0.075),
            hatAnchor: pt(0.30, -0.11), hatScale: 0.85, hatTilt: 0.16,
            chin: pt(0.33, 0.105),
            gill: nil,
            flank: line([k(0.24, 0.0), k(-0.05, -0.01), k(-0.44, 0.0)]),
            flexPivot: 0.10, tailRootX: -0.43,
            gloss: CGRect(x: 0.24, y: -0.125, width: 0.22, height: 0.05),
            scales: nil,
            extent: extent(body, fins))
    }

    // MARK: Seahorse

    /// Upright: a long snout, a little coronet, a pot belly, a curled
    /// tail and the one busy fin on its back.
    private static func seahorseKit() -> Art {
        let spine = [pt(0.18, -0.33), pt(0.12, -0.25), pt(0.09, -0.15), pt(0.11, -0.03), pt(0.145, 0.08),
                     pt(0.11, 0.19), pt(0.02, 0.28), pt(-0.07, 0.36), pt(-0.10, 0.45),
                     pt(-0.05, 0.52), pt(0.03, 0.53), pt(0.07, 0.48), pt(0.04, 0.43)]
        let widths = [0.16, 0.19, 0.25, 0.30, 0.30, 0.24, 0.17, 0.13, 0.10, 0.085, 0.07, 0.055, 0.045]
        // Trunk, head, snout and coronet merged into one silhouette, so
        // where they overlap the body stays solid instead of the parts'
        // opposing windings punching a hole beside the eye.
        var body = ribbon(spine, widths: widths)
            .union(Path(ellipseIn: CGRect(x: 0.08, y: -0.455, width: 0.26, height: 0.21)))
            .union(spline([k(0.27, -0.40), k(0.40, -0.395), corner(0.50, -0.41),
                           corner(0.51, -0.325), k(0.40, -0.325), k(0.27, -0.31)]))
        for (x, h) in [(0.14, 0.06), (0.19, 0.08), (0.24, 0.055)] as [(Double, Double)] {
            body = body.union(spline([corner(x - 0.035, -0.42), k(x - 0.012, -0.43 - h * 0.6),
                                      corner(x, -0.43 - h), k(x + 0.012, -0.43 - h * 0.6),
                                      corner(x + 0.035, -0.42)]))
        }
        // Rings across the trunk, square to the spine.
        var rings = Path()
        for i in 2..<(spine.count - 3) {
            let a = spine[i - 1], b = spine[i + 1], c = spine[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(0.0001, (dx * dx + dy * dy).squareRoot())
            let nx = -dy / len, ny = dx / len
            let w = widths[i] * 0.55
            rings.move(to: pt(c.x - nx * w, c.y - ny * w))
            rings.addQuadCurve(to: pt(c.x + nx * w, c.y + ny * w),
                               control: pt(c.x + dx / len * 0.03, c.y + dy / len * 0.03))
        }
        var specks = Path()
        for (x, y, r) in [(0.16, -0.12, 0.014), (0.06, 0.02, 0.012), (0.18, 0.10, 0.013),
                          (0.10, -0.36, 0.012), (0.05, 0.22, 0.011)] as [(Double, Double, Double)] {
            specks.addPath(dot(x, y, r))
        }
        let fins = [
            fin(pt(-0.02, -0.10), pt(-0.01, 0.12),
                edge: [k(-0.11, -0.10), k(-0.19, 0.0), k(-0.17, 0.08), k(-0.10, 0.13)],
                rays: 7, motion: .ripple(1.6)),
            fin(pt(0.145, -0.28), pt(0.135, -0.235),
                edge: [k(0.10, -0.305), k(0.06, -0.29), k(0.045, -0.255), k(0.07, -0.225), k(0.11, -0.218)],
                rays: 4, motion: .paddle(1.2), layer: .near),
        ]
        return Art(
            body: body, bounds: body.boundingRect, fins: fins,
            marks: [Mark(path: Path(ellipseIn: CGRect(x: 0.10, y: -0.20, width: 0.17, height: 0.40)),
                         style: .fill(.light, 0.38)),
                    Mark(path: rings, style: .stroke(.dark, width: 0.013, opacity: 0.45)),
                    Mark(path: specks, style: .fill(.white, 0.6))],
            eye: pt(0.20, -0.365), eyeR: 0.068, eyeSpread: 0.06,
            mouth: pt(0.505, -0.365), mouthScale: 0.7,
            hatAnchor: pt(0.19, -0.48), hatScale: 0.85, hatTilt: 0.05,
            chin: pt(0.22, -0.265),
            gill: nil,
            flank: line([k(0.10, -0.15), k(0.125, 0.0), k(0.10, 0.19), k(0.0, 0.30)]),
            flexPivot: -2, tailRootX: -2.5,
            gloss: CGRect(x: 0.12, y: -0.44, width: 0.12, height: 0.06),
            scales: nil,
            extent: extent(body, fins),
            upright: true)
    }
}
