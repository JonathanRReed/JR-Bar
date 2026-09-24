import AppKit
import JRBarCore
import SwiftUI

/// The fish kit (docs/TOYS.md): one illustrated style for every
/// species — a crisp outline tinted from the fish's own colour,
/// countershaded bodies lit from the surface with a soft top light
/// and a cool rim, translucent fins whose rays ripple with the swim,
/// and big glossy eyes that carry the mood. Everything is a unit-space
/// `Path` drawn at true proportions — nose toward +x, body centred
/// near the origin, roughly x −0.5…0.5 — so the caller scales both
/// axes by the fish's length, flips x for left-facing and rotates for
/// pitch without the paths knowing. No image assets anywhere.
enum CartoonFish {
    /// What the fish is saying with its mouth.
    enum MouthKind: Equatable, Sendable {
        /// Just ate: a big open smile and happy, squinting eyes.
        case smile
        /// Starving: a small round "o" under worried lids.
        case hungry
        /// Cruising: a soft upturned curve.
        case plain
    }

    /// The colours a species is painted in — the provider's accent
    /// keeps the fish's identity (docs/TOYS.md).
    struct Palette: Sendable {
        var body: Color      // provider accent, depth-washed
        var light: Color     // pale belly / fin light
        var dark: Color      // markings, the shaded back
        var outline: Color   // the silhouette's edge
        /// The cool light the surface rims the back with.
        var glow: Color
        /// The tank's cartoon ink (Arcade 1): the outline draws heavier.
        var ink: Double = 0

        init(body: Color, light: Color, dark: Color, outline: Color, glow: Color? = nil) {
            self.body = body
            self.light = light
            self.dark = dark
            self.outline = outline
            self.glow = glow ?? light
        }

        /// The tank's recipe: `accent` washed toward `floor` as the
        /// fish swims `depth` (0 shallow … 1 deep) down the column —
        /// hue as well as brightness, with a touch of grey on top, so
        /// a deep fish reads watery rather than just dim. Shadows cool
        /// toward navy instead of black, the way light falls off in
        /// water. Plain sRGB colours, so a frame resolves them for free.
        ///
        /// The water's style tunes it: `haze` scales the depth wash (the
        /// Arcade tank keeps a deep fish nearly as bright as a shallow
        /// one), `vivid` pushes the colour's saturation, and `ink`
        /// darkens the outline and makes it draw heavier.
        init(accent: NSColor, depth: Double = 0, floor: NSColor,
             haze: Double = 1, vivid: Double = 0, ink: Double = 0) {
            let a = Self.rgb(accent), fl = Self.rgb(floor)
            let grey = (0.5, 0.5, 0.5)
            let hazed = Self.mix(Self.mix(a, grey, depth * 0.30 * haze), fl, depth * 0.45 * haze)
            let washed = Self.saturate(hazed, by: 1 + vivid)
            self.init(
                body: Self.color(washed),
                light: Self.color(Self.mix(washed, (1, 1, 1), 0.58)),
                dark: Self.color(Self.mix(washed, (0.03, 0.07, 0.19), 0.42)),
                outline: Self.color(Self.mix(washed, (0.02, 0.03, 0.08), 0.74 + 0.18 * ink)),
                glow: Self.color(Self.mix(washed, (0.86, 0.97, 1.0), 0.72)))
            self.ink = ink
        }

        /// A colour pushed away from its own grey by `factor` (1 keeps
        /// it), clamped to the displayable range.
        private static func saturate(_ c: RGB, by factor: Double) -> RGB {
            guard factor != 1 else { return c }
            let l = 0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2
            func push(_ v: Double) -> Double { min(1, max(0, l + (v - l) * factor)) }
            return (push(c.0), push(c.1), push(c.2))
        }

        private typealias RGB = (Double, Double, Double)

        private static func rgb(_ c: NSColor) -> RGB {
            // A colour with no sRGB form (a pattern, say) swims grey.
            guard let s = c.usingColorSpace(.sRGB) else { return (0.5, 0.5, 0.5) }
            return (Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent))
        }

        private static func mix(_ a: RGB, _ b: RGB, _ u: Double) -> RGB {
            (a.0 + (b.0 - a.0) * u, a.1 + (b.1 - a.1) * u, a.2 + (b.2 - a.2) * u)
        }

        private static func color(_ c: RGB) -> Color {
            Color(.sRGB, red: c.0, green: c.1, blue: c.2)
        }
    }

    /// Where the fish is in its swim this frame.
    struct Swim: Sendable {
        /// The tail beat's phase in radians; the caller advances it
        /// faster the faster the fish swims.
        var phase: Double = 0
        /// How hard the tail beats: 0 holds still, ~0.3 is a brisk swim.
        var amplitude: Double = 0
        /// 1 side-on, falling toward 0 as a wall turn brings the face
        /// round to the glass; the caller squashes x by the same.
        var thin: Double = 1

        /// A fish holding perfectly still — the Reduce Motion pose.
        static let still = Swim()
    }

    // MARK: Kit types

    /// A point on an outline; a `corner` stops the curve rounding
    /// through it, for fin tips and forks.
    struct Knot: Sendable {
        var p: CGPoint
        var corner = false
    }

    /// One fin: its rest shape and rays, where it hinges, and how it
    /// moves.
    struct Fin: Sendable {
        enum Motion: Sendable {
            /// The tail: swings on the beat, foreshortens at the ends
            /// of the stroke and rides the body's flex.
            case tail
            /// Dorsal, anal and ventral fins: a wave travels out along
            /// them, `k` strong.
            case ripple(Double)
            /// Pectorals: a paddle about the root, `k` strong.
            case paddle(Double)
            /// Moves only with the body's flex.
            case fixed
        }

        /// Which side of the body the fin draws on.
        enum Layer: Sendable {
            /// The far side, seen through the water behind the body.
            case far
            /// Behind the body on the near side.
            case behind
            /// Over the body — the near pectoral.
            case near
        }

        var path: Path
        var rays: Path
        /// The root's midpoint: what the fin swings about.
        var pivot: CGPoint
        /// The farthest edge point; the fin's gradient runs pivot → tip.
        var tip: CGPoint
        var reach: Double
        var motion: Motion
        var layer: Layer
        /// A dark margin along the edge — the clownfish's trim.
        var trim = false
        /// A colour of its own — the tang's yellow tail.
        var tint: Color?
        /// Opaque, body-coloured — the puffer's spines.
        var solid = false
    }

    /// A paint layer clipped to the body: bars, bands, stripes, spots.
    struct Mark: Sendable {
        enum Tone: Sendable { case light, dark, outline, white, neonRed }
        enum Style: Sendable {
            case fill(Tone, Double)
            case stroke(Tone, width: Double, opacity: Double)
            /// A dotted line — the lateral line.
            case dots(Tone, width: Double, gap: Double, opacity: Double)
            /// A white bar with a dark edge — the clownfish's bars.
            case bar(edge: Double)
            /// A glowing line — the tetra's neon.
            case neon(width: Double)
            /// An iridescent sweep laid over the flank.
            case sheen
            /// A soft rosy cheek.
            case blush
        }

        var path: Path
        var style: Style
        /// Reaches back into the bending tail, so the swim must bend
        /// it too; a mark on the head stays put for free.
        var flexes = true
    }

    /// One species' silhouette kit.
    struct Art: Sendable {
        var body: Path
        var bounds: CGRect
        var fins: [Fin]
        var marks: [Mark]
        /// Where the eye sits and how big it is — big, per the brief.
        var eye: CGPoint
        var eyeR: Double
        /// Half the gap between the eyes, for the face-on turn.
        var eyeSpread: Double
        /// The mouth anchor: the nose-side point it draws around.
        var mouth: CGPoint
        var mouthScale: Double = 1
        /// Where a hat sits on the head, how big and how tipped.
        var hatAnchor: CGPoint
        var hatScale: Double = 1
        var hatTilt: Double = 0
        /// Under the chin, where a bow tie knots.
        var chin: CGPoint
        /// The gill cover's curve behind the eye; nil draws none.
        var gill: Path?
        /// The mid-flank line from the gill to the tail root — the
        /// tide stripe follows it.
        var flank: Path
        /// The body bends behind `flexPivot` down to `tailRootX`.
        var flexPivot: Double
        var tailRootX: Double
        /// The body's upper-front, where the gloss catches.
        var gloss: CGRect
        /// Faint overlapping scales, cached once.
        var scales: Path?
        /// Everything drawn, fins included — shadows and tags measure it.
        var extent: CGRect
        /// Stands upright (the seahorse): the pale side is the front,
        /// not the underside.
        var upright = false
        /// Where a scarf wraps: the collar's top and bottom edge,
        /// found once from the silhouette.
        var collar: (top: CGPoint, bottom: CGPoint) = (.zero, .zero)
        /// Fins that shimmer cyan to rose toward the edge — the betta's.
        var iridescent = false
    }

    // MARK: Shape builders

    static func k(_ x: Double, _ y: Double) -> Knot { Knot(p: CGPoint(x: x, y: y)) }
    static func corner(_ x: Double, _ y: Double) -> Knot { Knot(p: CGPoint(x: x, y: y), corner: true) }

    /// A smooth Catmull–Rom outline through `knots`, cornered where a
    /// knot asks.
    static func spline(_ knots: [Knot], closed: Bool = true) -> Path {
        var path = Path()
        let n = knots.count
        guard n >= 2 else { return path }
        path.move(to: knots[0].p)
        let segments = closed ? n : n - 1
        for i in 0..<segments {
            let a = knots[i], b = knots[(i + 1) % n]
            let before = closed || i > 0 ? knots[(i - 1 + n) % n].p : a.p
            let after = closed || i + 2 < n ? knots[(i + 2) % n].p : b.p
            let c1 = a.corner
                ? lerp(a.p, b.p, 1.0 / 3)
                : CGPoint(x: a.p.x + (b.p.x - before.x) / 6, y: a.p.y + (b.p.y - before.y) / 6)
            let c2 = b.corner
                ? lerp(b.p, a.p, 1.0 / 3)
                : CGPoint(x: b.p.x - (after.x - a.p.x) / 6, y: b.p.y - (after.y - a.p.y) / 6)
            path.addCurve(to: b.p, control1: c1, control2: c2)
        }
        if closed { path.closeSubpath() }
        return path
    }

    static func lerp(_ a: CGPoint, _ b: CGPoint, _ u: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
    }

    /// A fin springing from the body between `a` (front) and `b`
    /// (back) out round `edge`; `rays` fan from the root to the edge.
    static func fin(_ a: CGPoint, _ b: CGPoint, edge: [Knot], rays count: Int,
                    motion: Fin.Motion, layer: Fin.Layer = .behind,
                    trim: Bool = false, tint: Color? = nil) -> Fin {
        let path = spline([Knot(p: a, corner: true)] + edge + [Knot(p: b, corner: true)])
        let pivot = lerp(a, b, 0.5)
        // The edge as a polyline, measured, so the rays land evenly.
        let rim = [a] + edge.map(\.p) + [b]
        var lengths: [Double] = [0]
        for i in 1..<rim.count {
            let dx = rim[i].x - rim[i - 1].x, dy = rim[i].y - rim[i - 1].y
            lengths.append(lengths[i - 1] + (dx * dx + dy * dy).squareRoot())
        }
        func along(_ u: Double) -> CGPoint {
            let target = u * (lengths.last ?? 0)
            for i in 1..<rim.count where lengths[i] >= target {
                let span = max(0.0001, lengths[i] - lengths[i - 1])
                return lerp(rim[i - 1], rim[i], (target - lengths[i - 1]) / span)
            }
            return b
        }
        var rays = Path()
        for i in 0..<count {
            let u = (Double(i) + 1) / (Double(count) + 1)
            let start = lerp(a, b, 0.15 + 0.7 * u)
            // Just short of the edge, so no clip is needed to keep the
            // rays inside the membrane.
            let end = lerp(start, along(u), 0.96)
            let mid = lerp(start, end, 0.5)
            let bow = CGPoint(x: mid.x - (end.y - start.y) * 0.04, y: mid.y + (end.x - start.x) * 0.04)
            rays.move(to: start)
            rays.addQuadCurve(to: end, control: bow)
        }
        var tip = pivot
        var reach = 0.0
        for p in edge.map(\.p) {
            let d = hypot(p.x - pivot.x, p.y - pivot.y)
            if d > reach { reach = d; tip = p }
        }
        return Fin(path: path, rays: rays, pivot: pivot, tip: tip, reach: max(0.01, reach),
                   motion: motion, layer: layer, trim: trim, tint: tint)
    }

    /// A filled ribbon along `spine`, `widths` wide at each point — a
    /// seahorse's trunk and curled tail in one outline.
    static func ribbon(_ spine: [CGPoint], widths: [Double]) -> Path {
        guard spine.count >= 2, widths.count == spine.count else { return Path() }
        var left: [Knot] = []
        var right: [Knot] = []
        for i in spine.indices {
            let a = spine[max(0, i - 1)], b = spine[min(spine.count - 1, i + 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(0.0001, (dx * dx + dy * dy).squareRoot())
            let nx = -dy / len, ny = dx / len
            let w = widths[i] / 2
            left.append(k(spine[i].x + nx * w, spine[i].y + ny * w))
            right.append(k(spine[i].x - nx * w, spine[i].y - ny * w))
        }
        // Round cap at the tail's tip.
        let last = spine[spine.count - 1], prev = spine[spine.count - 2]
        let dx = last.x - prev.x, dy = last.y - prev.y
        let len = max(0.0001, (dx * dx + dy * dy).squareRoot())
        let capR = widths[widths.count - 1] * 0.5
        let cap = k(last.x + dx / len * capR, last.y + dy / len * capR)
        return spline(left + [cap] + right.reversed())
    }

    /// Faint overlapping scales across `bounds`, rear two thirds.
    static func scaleTexture(bounds: CGRect, r: Double = 0.045) -> Path {
        var scales = Path()
        var row = 0
        var y = bounds.minY + r
        while y < bounds.maxY {
            var x = bounds.minX + (row % 2 == 0 ? 0 : r)
            while x < bounds.minX + bounds.width * 0.72 {
                scales.move(to: CGPoint(x: x + r * cos(.pi * 0.64), y: y - r * sin(.pi * 0.64)))
                scales.addArc(center: CGPoint(x: x, y: y), radius: r,
                              startAngle: .radians(-.pi * 0.64), endAngle: .radians(.pi * 0.64),
                              clockwise: false)
                x += r * 2
            }
            y += r * 1.25
            row += 1
        }
        return scales
    }

    static func art(for species: FishSpecies) -> Art {
        kits[species] ?? kits[.minnow]!
    }

    // MARK: Draw

    /// The outline's weight in unit space for a fish `pointSize` long:
    /// about 1.2 pt on a tank-sized fish, never hairline, never heavy.
    /// A tank's cartoon `ink` (Arcade 1) thickens it by up to 60 %.
    static func outlineWidth(_ pointSize: Double, ink: Double = 0) -> Double {
        min(1.9, max(0.95, 0.72 + pointSize * 0.0085)) * (1 + 0.6 * ink) / max(1, pointSize)
    }

    /// Draw one fish at the origin of `f` — already translated, rotated,
    /// flipped & scaled to unit space by the caller. `blink` is 0 open
    /// …1 shut. `dead` (a sinking fish) crosses the eye out and drains
    /// the species' own colours — no neon, no yellow tail, no blush.
    /// `pointSize` is the fish's drawn length, so the outline keeps one
    /// weight and the fine detail drops out where it would only be
    /// noise.
    static func draw(into f: inout GraphicsContext, species: FishSpecies,
                     palette: Palette, swim: Swim = .still,
                     mouth: MouthKind, blink: Double, dead: Bool,
                     pointSize: Double = 60,
                     variant: AquariumVariant? = nil) {
        let art = art(for: species)
        let pose = Pose(art: art, swim: swim)
        let lw = outlineWidth(pointSize, ink: palette.ink)
        let detailed = pointSize >= 38
        let vivid = !dead

        drawFinsBehind(art: art, pose: pose, palette: palette, into: &f, lw: lw,
                       detailed: detailed, vivid: vivid)

        let body = pose.body(art.body)
        // The silhouette's edge goes down first, twice as wide as it
        // shows: the body fills over its inner half, so the outline
        // hugs the fill with no seam between them.
        f.stroke(body, with: .color(palette.outline),
                 style: StrokeStyle(lineWidth: lw * 2, lineJoin: .round))
        var near: [(fin: Fin, path: Path)] = []
        for fin in art.fins where fin.layer == .near {
            near.append((fin, pose.fin(fin.path, fin)))
        }
        drawBody(body, art: art, pose: pose, palette: palette, into: &f,
                 lw: lw, detailed: detailed, vivid: vivid, variant: variant,
                 shadows: near.map(\.path))
        for (fin, path) in near {
            // The near pectoral: its own lit membrane, rays and edge.
            let tint = vivid ? fin.tint : nil
            let base = tint ?? palette.body
            if fin.trim {
                f.stroke(path, with: .color(palette.outline.opacity(0.95)),
                         style: StrokeStyle(lineWidth: lw * 3.2, lineJoin: .round))
            }
            f.fill(path, with: .linearGradient(
                Gradient(stops: [
                    .init(color: base.opacity(0.97), location: 0),
                    .init(color: base.opacity(0.82), location: 0.5),
                    .init(color: (tint ?? palette.light).opacity(0.66), location: 1),
                ]),
                startPoint: pose.finPoint(fin.pivot, fin), endPoint: pose.finPoint(fin.tip, fin)))
            if detailed {
                f.stroke(pose.fin(fin.rays, fin), with: .color(palette.dark.opacity(0.34)), lineWidth: lw * 0.55)
            }
            if !fin.trim {
                f.stroke(path, with: .color(palette.outline.opacity(0.8)),
                         style: StrokeStyle(lineWidth: lw * 0.9, lineJoin: .round))
            }
        }

        drawFace(art: art, species: species, swim: swim, palette: palette, into: &f,
                 mouth: mouth, blink: blink, dead: dead, lw: lw, detailed: detailed)
    }

    /// The fins behind the body, soft and translucent so they read as
    /// fins rather than more body. Every plain membrane shares one
    /// radial wash — dense by the body, glassy out at the edges — and
    /// all the rays and edges go down in one stroke each, so a fish's
    /// fins cost a handful of fills however many it has. A tinted fin
    /// (the tang's yellow) paints its own while the fish is `vivid`;
    /// spines are solid.
    private static func drawFinsBehind(art: Art, pose: Pose, palette: Palette,
                                       into f: inout GraphicsContext, lw: Double, detailed: Bool,
                                       vivid: Bool) {
        var far = Path()
        var membrane = Path()
        var trims = Path()
        var rays = Path()
        var edges = Path()
        var tinted: [(fin: Fin, path: Path)] = []
        for fin in art.fins where fin.layer != .near {
            let path = pose.fin(fin.path, fin)
            if fin.solid {
                // Spines are body, not membrane: lit tips, a full outline.
                f.stroke(path, with: .color(palette.outline), style: StrokeStyle(lineWidth: lw * 2, lineJoin: .round))
                f.fill(path, with: .radialGradient(Gradient(colors: [palette.body, palette.light]),
                                                   center: fin.pivot, startRadius: fin.reach * 0.8,
                                                   endRadius: fin.reach * 1.05))
                continue
            }
            if fin.layer == .far {
                far.addPath(path)
            } else if fin.tint != nil, vivid {
                tinted.append((fin, path))
            } else {
                membrane.addPath(path)
            }
            if fin.trim { trims.addPath(path) } else { edges.addPath(path) }
            if detailed { rays.addPath(pose.fin(fin.rays, fin)) }
        }
        f.fill(far, with: .color(palette.dark.opacity(0.75)))
        f.stroke(trims, with: .color(palette.outline.opacity(0.95)),
                 style: StrokeStyle(lineWidth: lw * 3.2, lineJoin: .round))
        let centre = CGPoint(x: art.bounds.midX, y: art.bounds.midY)
        let e = art.extent
        let reach = max(hypot(e.minX - centre.x, e.minY - centre.y), hypot(e.minX - centre.x, e.maxY - centre.y),
                        hypot(e.maxX - centre.x, e.minY - centre.y))
        let inner = min(art.bounds.width, art.bounds.height) * 0.4
        // A veil keeps its colour right out to the edge — the richest
        // part of a betta — where a plain fin thins to glass.
        let veil = art.iridescent && vivid
        f.fill(membrane, with: .radialGradient(
            Gradient(stops: [
                .init(color: palette.body.opacity(0.94), location: 0),
                .init(color: palette.body.opacity(veil ? 0.82 : 0.70), location: 0.45),
                .init(color: veil ? palette.body.opacity(0.62) : palette.light.opacity(0.42), location: 1),
            ]),
            center: centre, startRadius: inner, endRadius: reach * 0.9))
        if veil {
            // The shimmer: a cool sheen through a rosy blush toward the
            // veils' edges, light enough to keep the fish's own colour.
            var sheen = f
            sheen.blendMode = .plusLighter
            sheen.fill(membrane, with: .radialGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0.15),
                    .init(color: Color(red: 0.30, green: 0.70, blue: 1.0).opacity(0.18), location: 0.5),
                    .init(color: Color(red: 1.0, green: 0.40, blue: 0.80).opacity(0.16), location: 0.82),
                    .init(color: .clear, location: 1),
                ]),
                center: centre, startRadius: inner, endRadius: reach * 0.9))
        }
        for (fin, path) in tinted {
            let tint = fin.tint ?? palette.body
            f.fill(path, with: .linearGradient(
                Gradient(stops: [
                    .init(color: tint.opacity(0.94), location: 0),
                    .init(color: tint.opacity(0.72), location: 0.5),
                    .init(color: tint.opacity(0.5), location: 1),
                ]),
                startPoint: pose.finPoint(fin.pivot, fin), endPoint: pose.finPoint(fin.tip, fin)))
        }
        f.stroke(rays, with: .color(palette.dark.opacity(0.32)), lineWidth: lw * 0.55)
        f.stroke(edges, with: .color(palette.outline.opacity(0.5)),
                 style: StrokeStyle(lineWidth: lw * 0.7, lineJoin: .round))
    }

    /// The body's paint, back to front: the countershaded base, the
    /// markings and scales, one pass of volume that lifts the back
    /// toward the surface and darkens the flanks as they turn away, a
    /// gloss on the brow, the near fins' soft shadows, a cool rim of
    /// light along the back with a bounce under the belly, and the
    /// gill cover. One clip to the silhouette carries all of it.
    private static func drawBody(_ body: Path, art: Art, pose: Pose, palette: Palette,
                                 into f: inout GraphicsContext, lw: Double, detailed: Bool,
                                 vivid: Bool, variant: AquariumVariant?, shadows: [Path]) {
        let r = art.bounds
        // Countershading: a deep back, the true colour across the
        // flank and a pale underside — for an upright seahorse, the
        // back is behind it and the pale side in front.
        f.fill(body, with: .linearGradient(
            Gradient(stops: [
                .init(color: palette.dark, location: 0),
                .init(color: palette.body, location: 0.36),
                .init(color: palette.body, location: 0.58),
                .init(color: art.upright ? palette.body : palette.light, location: 0.96),
            ]),
            startPoint: art.upright ? CGPoint(x: r.minX, y: 0) : CGPoint(x: 0, y: r.minY),
            endPoint: art.upright ? CGPoint(x: r.maxX, y: 0) : CGPoint(x: 0, y: r.maxY)))
        var b = f
        b.clip(to: body)
        if detailed, let scales = art.scales {
            b.stroke(scales, with: .linearGradient(
                Gradient(colors: [palette.dark.opacity(0.16), palette.dark.opacity(0)]),
                startPoint: CGPoint(x: r.minX, y: 0),
                endPoint: CGPoint(x: r.minX + r.width * 0.72, y: 0)),
                lineWidth: lw * 0.55)
        }
        for mark in art.marks {
            paintMark(mark, path: mark.flexes ? pose.body(mark.path) : mark.path,
                      palette: palette, into: &b, lw: lw, vivid: vivid)
        }
        if let variant { drawVariant(variant, art: art, pose: pose, palette: palette, into: &b) }
        // Volume and the top light in one pass: the surface's glow soft
        // along the back, the flanks turning away from it toward the
        // edge, deepest along the belly and the tail.
        let extent = max(r.width, r.height)
        b.fill(body, with: .radialGradient(
            Gradient(stops: [
                .init(color: palette.glow.opacity(0.32), location: 0),
                .init(color: palette.glow.opacity(0), location: 0.34),
                .init(color: palette.dark.opacity(0), location: 0.55),
                .init(color: palette.dark.opacity(0.42), location: 1),
            ]),
            center: CGPoint(x: r.midX + r.width * 0.12, y: r.midY - r.height * 0.24),
            startRadius: 0, endRadius: extent * 0.62))
        // The gloss: a crisp catch of light on the brow.
        let g = art.gloss
        b.fill(Path(ellipseIn: g), with: .radialGradient(
            Gradient(colors: [.white.opacity(0.70), .white.opacity(0)]),
            center: CGPoint(x: g.midX + g.width * 0.1, y: g.midY),
            startRadius: 0, endRadius: g.width * 0.5))
        // The near fins' soft shadows on the flank under them.
        if !shadows.isEmpty {
            var shade = Path()
            for shadow in shadows { shade.addPath(shadow.offsetBy(dx: -0.012, dy: 0.022)) }
            b.fill(shade, with: .color(palette.dark.opacity(0.35)))
        }
        // A rim of cool light along the back, where the surface sits,
        // and bounce light off the sand along the belly's edge.
        b.stroke(body, with: .linearGradient(
            Gradient(stops: [
                .init(color: palette.glow.opacity(0.85), location: 0),
                .init(color: palette.glow.opacity(0), location: 0.42),
                .init(color: palette.light.opacity(0), location: 0.70),
                .init(color: palette.light.opacity(0.35), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: r.minY), endPoint: CGPoint(x: 0, y: r.maxY)),
            lineWidth: lw * 2.4)
        if let gill = art.gill {
            b.stroke(gill, with: .color(palette.dark.opacity(0.55)),
                     style: StrokeStyle(lineWidth: lw * 0.9, lineCap: .round))
            if detailed {
                b.stroke(gill.offsetBy(dx: lw * 1.1, dy: 0), with: .color(palette.light.opacity(0.35)),
                         style: StrokeStyle(lineWidth: lw * 0.7, lineCap: .round))
            }
        }
    }

    private static func color(_ tone: Mark.Tone, _ palette: Palette, vivid: Bool) -> Color {
        switch tone {
        case .light: return palette.light
        case .dark: return palette.dark
        case .outline: return palette.outline
        case .white: return Color(red: 0.99, green: 0.99, blue: 0.97)
        case .neonRed: return vivid ? Color(red: 0.93, green: 0.20, blue: 0.30) : palette.dark
        }
    }

    /// One marking. A fish that isn't `vivid` keeps its pattern but
    /// loses the colours of its own: the neon goes out, the shimmer
    /// and the blush fade away.
    private static func paintMark(_ mark: Mark, path: Path, palette: Palette,
                                  into b: inout GraphicsContext, lw: Double, vivid: Bool) {
        switch mark.style {
        case .fill(let tone, let opacity):
            b.fill(path, with: .color(color(tone, palette, vivid: vivid).opacity(opacity)))
        case .stroke(let tone, let width, let opacity):
            b.stroke(path, with: .color(color(tone, palette, vivid: vivid).opacity(opacity)),
                     style: StrokeStyle(lineWidth: width, lineCap: .round))
        case .dots(let tone, let width, let gap, let opacity):
            b.stroke(path, with: .color(color(tone, palette, vivid: vivid).opacity(opacity)),
                     style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [0.0001, gap]))
        case .bar(let edge):
            b.stroke(path, with: .color(palette.outline.opacity(0.95)), lineWidth: edge + lw * 1.2)
            let r = path.boundingRect
            b.fill(path, with: .linearGradient(
                Gradient(colors: [.white, Color(red: 0.90, green: 0.93, blue: 0.97)]),
                startPoint: CGPoint(x: 0, y: r.minY), endPoint: CGPoint(x: 0, y: r.maxY)))
        case .neon(let width) where !vivid:
            b.stroke(path, with: .color(palette.light.opacity(0.6)),
                     style: StrokeStyle(lineWidth: width, lineCap: .round))
        case .sheen where !vivid, .blush where !vivid:
            break
        case .neon(let width):
            var glow = b
            glow.blendMode = .plusLighter
            glow.stroke(path, with: .color(Color(red: 0.30, green: 0.85, blue: 1.0).opacity(0.55)),
                        style: StrokeStyle(lineWidth: width * 2.2, lineCap: .round))
            glow.stroke(path, with: .color(Color(red: 0.55, green: 0.95, blue: 1.0).opacity(0.9)),
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
            glow.stroke(path, with: .color(.white.opacity(0.85)),
                        style: StrokeStyle(lineWidth: width * 0.35, lineCap: .round))
        case .sheen:
            var sheen = b
            sheen.blendMode = .plusLighter
            let r = path.boundingRect
            sheen.fill(path, with: .linearGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0.15),
                    .init(color: Color(red: 0.40, green: 0.85, blue: 1.0).opacity(0.30), location: 0.42),
                    .init(color: Color(red: 0.95, green: 0.50, blue: 1.0).opacity(0.24), location: 0.62),
                    .init(color: .clear, location: 0.85),
                ]),
                startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)))
        case .blush:
            let r = path.boundingRect
            b.fill(path, with: .radialGradient(
                Gradient(colors: [Color(red: 1.0, green: 0.42, blue: 0.50).opacity(0.50), .clear]),
                center: CGPoint(x: r.midX, y: r.midY), startRadius: 0, endRadius: r.width * 0.5))
        }
    }

    /// An earned mark (`AquariumVariant`), clipped to the body like a
    /// pattern and drawn over it — small and pale, so it reads as a
    /// distinction rather than a costume.
    private static func drawVariant(_ variant: AquariumVariant, art: Art, pose: Pose,
                                    palette: Palette, into b: inout GraphicsContext) {
        let r = art.bounds
        switch variant {
        case .tide:
            // One pale wave from gill to tail root along the flank.
            let stripe = pose.body(art.flank)
            let w = r.height * 0.16
            b.stroke(stripe, with: .color(palette.light.opacity(0.85)),
                     style: StrokeStyle(lineWidth: w, lineCap: .round))
            b.stroke(stripe, with: .color(.white.opacity(0.45)),
                     style: StrokeStyle(lineWidth: w * 0.35, lineCap: .round))
        case .starry:
            // Six specks across the back: a school's worth of stars.
            let specks: [(Double, Double, Double)] = [
                (0.70, 0.18, 0.050), (0.52, 0.10, 0.040), (0.36, 0.22, 0.046),
                (0.22, 0.14, 0.036), (0.60, 0.34, 0.034), (0.12, 0.30, 0.040),
            ]
            var sparkle = b
            sparkle.blendMode = .plusLighter
            for (u, v, s) in specks {
                let c = CGPoint(x: r.minX + r.width * u, y: r.minY + r.height * v)
                let d = s * max(r.width, r.height) * 0.5
                sparkle.fill(Path(ellipseIn: CGRect(x: c.x - d * 2, y: c.y - d * 2, width: d * 4, height: d * 4)),
                             with: .radialGradient(Gradient(colors: [.white.opacity(0.35), .clear]),
                                                   center: c, startRadius: 0, endRadius: d * 2))
                b.fill(Path(ellipseIn: CGRect(x: c.x - d, y: c.y - d, width: d * 2, height: d * 2)),
                       with: .color(.white.opacity(0.95)))
            }
        }
    }

    // MARK: Face

    /// The eyes and mouth. Through a wall turn the face comes round to
    /// the glass: both eyes show, and they stay round instead of
    /// squashing with the body.
    private static func drawFace(art: Art, species: FishSpecies, swim: Swim, palette: Palette,
                                 into f: inout GraphicsContext, mouth: MouthKind,
                                 blink: Double, dead: Bool, lw: Double, detailed: Bool) {
        let face = faceTurn(art: art, thin: swim.thin)
        let turn = face.turn, spread = face.spread, sx = face.sx
        if turn > 0.05 {
            // The far eye, peeking over the brow as the head comes round.
            var far = f
            far.opacity = face.far
            drawEye(into: &far, at: CGPoint(x: art.eye.x - spread, y: art.eye.y), r: art.eyeR * 0.94,
                    palette: palette, mood: mouth, blink: blink, dead: dead, lw: lw, detailed: false,
                    sx: sx)
        }
        drawEye(into: &f, at: CGPoint(x: art.eye.x + spread, y: art.eye.y), r: art.eyeR,
                palette: palette, mood: mouth, blink: blink, dead: dead, lw: lw, detailed: detailed,
                sx: sx)
        if !dead, species != .seahorse || mouth != .plain {
            var m = f
            if turn > 0.05 {
                // Face-on the mouth sits centred under the eyes.
                m.translateBy(x: -spread * 0.2, y: 0)
            }
            drawMouth(into: &m, at: art.mouth, kind: mouth, palette: palette, lw: lw,
                      s: art.mouthScale)
        }
    }

    /// How far a turn has brought the face round to the glass: `turn`
    /// 0 side-on … 1 face-on, how far the eyes part from where they sit
    /// side-on (unit space, before the caller's squash), how much
    /// wider to draw an eye so it stays round on screen, and how solid
    /// the far eye (and anything worn over it) shows — solid by half
    /// way, so a fish holding a half turn at the glass never looks at
    /// you through a ghost of an eye.
    static func faceTurn(art: Art, thin: Double)
        -> (turn: Double, spread: Double, sx: Double, far: Double) {
        let thin = max(0.12, min(1, thin))
        let turn = min(1, max(0, (0.9 - thin) / 0.6))
        let spread = art.eyeSpread * (1 - thin * thin).squareRoot() / thin * turn
        let sx = (0.55 + 0.45 * thin) / thin * turn + (1 - turn)
        return (turn, spread, sx, min(1, turn * 2.2))
    }

    /// The big friendly eye: a soft socket, a white that shades toward
    /// its lower edge, a coloured iris lit from below, a deep pupil,
    /// two catchlights, and lids that carry the mood — relaxed, a
    /// happy squint after a meal, a worried slant when hungry — and
    /// slide shut on `blink`. `sx` widens the circle back
    /// against a turn's squash.
    private static func drawEye(into f: inout GraphicsContext, at e: CGPoint, r: Double,
                                palette: Palette, mood: MouthKind, blink: Double, dead: Bool,
                                lw: Double, detailed: Bool, sx: Double) {
        func oval(_ cx: Double, _ cy: Double, _ rr: Double) -> Path {
            Path(ellipseIn: CGRect(x: cx - rr * sx, y: cy - rr,
                                   width: rr * 2 * sx, height: rr * 2))
        }
        if dead {
            // A sinking fish: the classic cartoon X.
            var x = Path()
            let rr = r * 0.78
            x.move(to: CGPoint(x: e.x - rr * sx, y: e.y - rr))
            x.addLine(to: CGPoint(x: e.x + rr * sx, y: e.y + rr))
            x.move(to: CGPoint(x: e.x + rr * sx, y: e.y - rr))
            x.addLine(to: CGPoint(x: e.x - rr * sx, y: e.y + rr))
            f.stroke(x, with: .color(palette.outline.opacity(0.85)),
                     style: StrokeStyle(lineWidth: lw * 1.6, lineCap: .round))
            return
        }
        if detailed {
            // The socket: a soft shadow ring that seats the eye in the head.
            f.fill(oval(e.x - r * 0.03, e.y + r * 0.08, r * 1.3), with: .radialGradient(
                Gradient(colors: [palette.dark.opacity(0.3), palette.dark.opacity(0)]),
                center: CGPoint(x: e.x, y: e.y + r * 0.08), startRadius: r * 0.9, endRadius: r * 1.3))
        }
        // The white, shaded under the brow at the top and cool at the
        // bottom edge.
        let white = oval(e.x, e.y, r)
        f.fill(white, with: .linearGradient(
            Gradient(stops: [
                .init(color: palette.dark.mix(with: .white, by: 0.55), location: 0),
                .init(color: .white, location: 0.36),
                .init(color: .white, location: 0.7),
                .init(color: Color(red: 0.84, green: 0.89, blue: 0.95), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: e.y - r), endPoint: CGPoint(x: 0, y: e.y + r)))
        // Everything inside the white sits well inside it, so nothing
        // here needs a clip.
        // The iris looks forward, where the fish is going; a hungry
        // fish's pupils go wide.
        let ix = e.x + r * 0.24 * sx, iy = e.y + r * 0.04
        let irisR = r * (mood == .hungry ? 0.74 : 0.68)
        f.fill(oval(ix, iy, irisR), with: .radialGradient(
            Gradient(stops: [
                .init(color: palette.light, location: 0),
                .init(color: palette.body, location: 0.55),
                .init(color: palette.outline, location: 1),
            ]),
            center: CGPoint(x: ix, y: iy + irisR * 0.45),
            startRadius: 0, endRadius: irisR * 1.15))
        f.fill(oval(ix + r * 0.03 * sx, iy, irisR * (mood == .hungry ? 0.66 : 0.58)),
                   with: .color(Color(red: 0.02, green: 0.03, blue: 0.07)))
        // Catchlights: a big one high and forward, a sharp dot low.
        var glints = oval(ix + r * 0.16 * sx, iy - r * 0.30, r * 0.27)
        glints.addPath(oval(ix - r * 0.26 * sx, iy + r * 0.30, r * 0.10))
        f.fill(glints, with: .color(.white.opacity(0.95)))
        f.stroke(white, with: .color(palette.outline.opacity(0.9)), lineWidth: lw * 0.95)

        // The lids. `upper` is how far the top lid has come down (0…1
        // of the eye's height), `slant` tips it lower at the back.
        var upper = 0.0
        var slant = 0.0
        var lower = 0.0
        switch mood {
        case .plain: break
        case .smile:
            lower = 0.34
        case .hungry:
            upper = 0.10
            slant = 0.34
        }
        upper = max(upper, blink)
        lower = lower * (1 - blink)
        var lid = f
        lid.clip(to: oval(e.x, e.y, r + lw * 0.5))
        let top = e.y - r
        let span = r * 2
        if upper > 0.01 {
            // The lid's edge bows down: a curve from back to front.
            let yb = top + span * min(1, upper + slant * 0.5)
            let yf = top + span * max(0, upper - slant * 0.5)
            let sag = r * 0.35 * (1 - upper * 0.8)
            var cap = Path()
            cap.move(to: CGPoint(x: e.x - r * 1.2 * sx, y: top - r))
            cap.addLine(to: CGPoint(x: e.x - r * 1.2 * sx, y: yb))
            cap.addQuadCurve(to: CGPoint(x: e.x + r * 1.2 * sx, y: yf),
                             control: CGPoint(x: e.x, y: (yb + yf) / 2 + sag))
            cap.addLine(to: CGPoint(x: e.x + r * 1.2 * sx, y: top - r))
            cap.closeSubpath()
            lid.fill(cap, with: .linearGradient(Gradient(colors: [palette.body, palette.body.mix(with: palette.dark, by: 0.25)]),
                                                startPoint: CGPoint(x: 0, y: top),
                                                endPoint: CGPoint(x: 0, y: max(yb, yf))))
            var edge = Path()
            edge.move(to: CGPoint(x: e.x - r * 1.2 * sx, y: yb))
            edge.addQuadCurve(to: CGPoint(x: e.x + r * 1.2 * sx, y: yf),
                              control: CGPoint(x: e.x, y: (yb + yf) / 2 + sag))
            lid.stroke(edge, with: .color(palette.outline), lineWidth: lw * 1.3)
        }
        if lower > 0.01 {
            // The happy squint: the cheek pushes the lower lid up.
            let bottom = e.y + r
            let yl = bottom - span * lower
            var arch = Path()
            arch.move(to: CGPoint(x: e.x - r * 1.2 * sx, y: yl + r * 0.55))
            arch.addQuadCurve(to: CGPoint(x: e.x + r * 1.2 * sx, y: yl + r * 0.55),
                              control: CGPoint(x: e.x, y: yl - r * 0.55))
            var cheek = arch
            cheek.addLine(to: CGPoint(x: e.x + r * 1.2 * sx, y: bottom + r))
            cheek.addLine(to: CGPoint(x: e.x - r * 1.2 * sx, y: bottom + r))
            cheek.closeSubpath()
            lid.fill(cheek, with: .color(palette.body))
            lid.stroke(arch, with: .color(palette.outline), lineWidth: lw * 1.2)
        }
    }

    /// The mouth: a smile just after eating, a small "o" when hungry,
    /// a soft upturned curve otherwise. `s` sizes it to the face.
    private static func drawMouth(into f: inout GraphicsContext, at p: CGPoint,
                                  kind: MouthKind, palette: Palette, lw: Double, s: Double) {
        let throat = Color(red: 0.36, green: 0.06, blue: 0.12)
        switch kind {
        case .smile:
            // A wide open grin, a tongue at the bottom, a dimple at the
            // back corner.
            var m = Path()
            m.move(to: CGPoint(x: p.x, y: p.y - 0.04 * s))
            m.addQuadCurve(to: CGPoint(x: p.x - 0.15 * s, y: p.y - 0.035 * s),
                           control: CGPoint(x: p.x - 0.075 * s, y: p.y - 0.015 * s))
            m.addQuadCurve(to: CGPoint(x: p.x, y: p.y - 0.04 * s),
                           control: CGPoint(x: p.x - 0.05 * s, y: p.y + 0.10 * s))
            m.closeSubpath()
            f.fill(m, with: .color(throat))
            var tongue = f
            tongue.clip(to: m)
            tongue.fill(Path(ellipseIn: CGRect(x: p.x - 0.09 * s, y: p.y + 0.01 * s,
                                               width: 0.08 * s, height: 0.06 * s)),
                        with: .color(Color(red: 1.0, green: 0.46, blue: 0.52)))
            f.stroke(m, with: .color(palette.outline),
                     style: StrokeStyle(lineWidth: lw * 1.3, lineCap: .round, lineJoin: .round))
            var dimple = Path()
            dimple.move(to: CGPoint(x: p.x - 0.165 * s, y: p.y - 0.06 * s))
            dimple.addQuadCurve(to: CGPoint(x: p.x - 0.16 * s, y: p.y - 0.01 * s),
                                control: CGPoint(x: p.x - 0.18 * s, y: p.y - 0.035 * s))
            f.stroke(dimple, with: .color(palette.outline.opacity(0.8)),
                     style: StrokeStyle(lineWidth: lw * 0.9, lineCap: .round))
        case .hungry:
            // A small round "o", lips pursed for food.
            let r = 0.046 * s
            let c = CGPoint(x: p.x - 0.045 * s, y: p.y)
            let o = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r * 1.1, width: r * 2, height: r * 2.2))
            f.fill(o, with: .color(palette.light))
            f.stroke(o, with: .color(palette.outline), lineWidth: lw * 1.2)
            let inside = Path(ellipseIn: CGRect(x: c.x - r * 0.58, y: c.y - r * 0.7,
                                                width: r * 1.16, height: r * 1.4))
            f.fill(inside, with: .color(throat))
        case .plain:
            var m = Path()
            m.move(to: CGPoint(x: p.x - 0.005 * s, y: p.y - 0.02 * s))
            m.addQuadCurve(to: CGPoint(x: p.x - 0.10 * s, y: p.y - 0.018 * s),
                           control: CGPoint(x: p.x - 0.045 * s, y: p.y + 0.035 * s))
            f.stroke(m, with: .color(palette.outline),
                     style: StrokeStyle(lineWidth: lw * 1.15, lineCap: .round))
        }
    }
}
