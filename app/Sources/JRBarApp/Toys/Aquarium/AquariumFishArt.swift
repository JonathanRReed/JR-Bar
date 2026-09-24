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
        /// water.
        init(accent: NSColor, depth: Double = 0, floor: NSColor) {
            let washed = (accent.blended(withFraction: depth * 0.30, of: .gray) ?? accent)
                .blended(withFraction: depth * 0.45, of: floor) ?? accent
            let navy = NSColor(srgbRed: 0.03, green: 0.07, blue: 0.19, alpha: 1)
            let ink = NSColor(srgbRed: 0.02, green: 0.03, blue: 0.08, alpha: 1)
            let sky = NSColor(srgbRed: 0.86, green: 0.97, blue: 1.0, alpha: 1)
            self.init(
                body: Color(nsColor: washed),
                light: Color(nsColor: washed.blended(withFraction: 0.58, of: .white) ?? washed),
                dark: Color(nsColor: washed.blended(withFraction: 0.42, of: navy) ?? washed),
                outline: Color(nsColor: washed.blended(withFraction: 0.74, of: ink) ?? ink),
                glow: Color(nsColor: washed.blended(withFraction: 0.72, of: sky) ?? sky))
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
        /// An iridescent sweep over the fin — the betta's veils.
        var sheen = false
    }

    /// A paint layer clipped to the body: bars, bands, stripes, spots.
    struct Mark: Sendable {
        enum Tone: Sendable { case body, light, dark, outline, white, neonRed }
        enum Style: Sendable {
            case fill(Tone, Double)
            /// An even-odd fill: the tang's palette with its pale window.
            case evenOdd(Tone, Double)
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
                    trim: Bool = false, tint: Color? = nil, sheen: Bool = false) -> Fin {
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
            let end = along(u)
            // Past the edge a touch — the clip trims it clean.
            let over = CGPoint(x: end.x + (end.x - start.x) * 0.12, y: end.y + (end.y - start.y) * 0.12)
            let mid = lerp(start, over, 0.5)
            let bow = CGPoint(x: mid.x - (over.y - start.y) * 0.06, y: mid.y + (over.x - start.x) * 0.06)
            rays.move(to: start)
            rays.addQuadCurve(to: over, control: bow)
        }
        var tip = pivot
        var reach = 0.0
        for p in edge.map(\.p) {
            let d = hypot(p.x - pivot.x, p.y - pivot.y)
            if d > reach { reach = d; tip = p }
        }
        return Fin(path: path, rays: rays, pivot: pivot, tip: tip, reach: max(0.01, reach),
                   motion: motion, layer: layer, trim: trim, tint: tint, sheen: sheen)
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
    static func outlineWidth(_ pointSize: Double) -> Double {
        min(1.9, max(0.95, 0.72 + pointSize * 0.0085)) / max(1, pointSize)
    }

    /// Draw one fish at the origin of `f` — already translated, rotated,
    /// flipped & scaled to unit space by the caller. `blink` is 0 open
    /// …1 shut. `dead` (a sinking fish) crosses the eye out.
    /// `pointSize` is the fish's drawn length, so the outline keeps one
    /// weight and the fine detail drops out where it would only be
    /// noise. `aspectComp` un-shears the eye for a caller that scales
    /// y by more or less than x.
    static func draw(into f: inout GraphicsContext, species: FishSpecies,
                     palette: Palette, swim: Swim = .still,
                     mouth: MouthKind, blink: Double, dead: Bool,
                     patternSeed: UInt64, aspectComp: Double = 1,
                     pointSize: Double = 60,
                     variant: AquariumVariant? = nil) {
        let art = art(for: species)
        let pose = Pose(art: art, swim: swim)
        let lw = outlineWidth(pointSize)
        let detailed = pointSize >= 38

        // Fins behind the body — soft and translucent, so they read as
        // fins rather than more body.
        for fin in art.fins where fin.layer == .far {
            drawFin(fin, pose: pose, palette: palette, into: &f, lw: lw, detailed: detailed)
        }
        for fin in art.fins where fin.layer == .behind {
            drawFin(fin, pose: pose, palette: palette, into: &f, lw: lw, detailed: detailed)
        }

        let body = pose.body(art.body)
        // The silhouette's edge goes down first, twice as wide as it
        // shows: the body fills over its inner half, so compound
        // bodies (the seahorse) keep one clean outline.
        f.stroke(body, with: .color(palette.outline),
                 style: StrokeStyle(lineWidth: lw * 2, lineJoin: .round))
        drawBody(body, art: art, pose: pose, palette: palette, into: &f,
                 lw: lw, detailed: detailed, seed: patternSeed, variant: variant)

        for fin in art.fins where fin.layer == .near {
            // The fin's soft shadow on the flank under it.
            var shade = f
            shade.clip(to: body)
            shade.fill(pose.fin(fin.path, fin).offsetBy(dx: -0.012, dy: 0.022),
                       with: .color(palette.dark.opacity(0.35)))
            drawFin(fin, pose: pose, palette: palette, into: &f, lw: lw, detailed: detailed)
        }

        drawFace(art: art, species: species, swim: swim, palette: palette, into: &f,
                 mouth: mouth, blink: blink, dead: dead, lw: lw, comp: aspectComp)
    }

    /// The body's paint, back to front: the countershaded base, the
    /// markings, the scales, the volume, the top light and gloss, a
    /// cool rim of light off the surface and the gill cover.
    private static func drawBody(_ body: Path, art: Art, pose: Pose, palette: Palette,
                                 into f: inout GraphicsContext, lw: Double, detailed: Bool,
                                 seed: UInt64, variant: AquariumVariant?) {
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
            paintMark(mark, path: pose.body(mark.path), palette: palette, into: &b, lw: lw)
        }
        if let variant { drawVariant(variant, art: art, pose: pose, palette: palette, into: &b) }
        // Volume: the flanks turn away from the light toward the edge,
        // deepest along the belly and the tail.
        let extent = max(r.width, r.height)
        b.fill(body, with: .radialGradient(
            Gradient(stops: [
                .init(color: palette.dark.opacity(0), location: 0),
                .init(color: palette.dark.opacity(0), location: 0.52),
                .init(color: palette.dark.opacity(0.42), location: 1),
            ]),
            center: CGPoint(x: r.midX + r.width * 0.14, y: r.midY - r.height * 0.16),
            startRadius: 0, endRadius: extent * 0.60))
        // The top light: the surface's glow spread soft along the back.
        b.fill(Path(ellipseIn: CGRect(x: r.minX + r.width * 0.16, y: r.minY - r.height * 0.10,
                                      width: r.width * 0.72, height: r.height * 0.52)),
               with: .radialGradient(
                Gradient(colors: [palette.glow.opacity(0.34), palette.glow.opacity(0)]),
                center: CGPoint(x: r.midX + r.width * 0.10, y: r.minY + r.height * 0.12),
                startRadius: 0, endRadius: r.width * 0.36))
        // The gloss: a crisp catch of light on the brow.
        let g = art.gloss
        b.fill(Path(ellipseIn: g), with: .radialGradient(
            Gradient(colors: [.white.opacity(0.70), .white.opacity(0)]),
            center: CGPoint(x: g.midX + g.width * 0.1, y: g.midY),
            startRadius: 0, endRadius: g.width * 0.5))
        // A rim of cool light along the back, where the surface sits.
        b.stroke(body, with: .linearGradient(
            Gradient(colors: [palette.glow.opacity(0.85), palette.glow.opacity(0)]),
            startPoint: CGPoint(x: 0, y: r.minY),
            endPoint: CGPoint(x: 0, y: r.minY + r.height * 0.42)),
            lineWidth: lw * 2.6)
        // Bounce light off the sand along the belly's edge.
        b.stroke(body, with: .linearGradient(
            Gradient(colors: [palette.light.opacity(0), palette.light.opacity(0.35)]),
            startPoint: CGPoint(x: 0, y: r.maxY - r.height * 0.30),
            endPoint: CGPoint(x: 0, y: r.maxY)),
            lineWidth: lw * 2.2)
        if let gill = art.gill {
            b.stroke(gill, with: .color(palette.dark.opacity(0.55)),
                     style: StrokeStyle(lineWidth: lw * 0.9, lineCap: .round))
            b.stroke(gill.offsetBy(dx: lw * 1.1, dy: 0), with: .color(palette.light.opacity(0.35)),
                     style: StrokeStyle(lineWidth: lw * 0.7, lineCap: .round))
        }
    }

    private static func color(_ tone: Mark.Tone, _ palette: Palette) -> Color {
        switch tone {
        case .body: return palette.body
        case .light: return palette.light
        case .dark: return palette.dark
        case .outline: return palette.outline
        case .white: return Color(red: 0.99, green: 0.99, blue: 0.97)
        case .neonRed: return Color(red: 0.93, green: 0.20, blue: 0.30)
        }
    }

    private static func paintMark(_ mark: Mark, path: Path, palette: Palette,
                                  into b: inout GraphicsContext, lw: Double) {
        switch mark.style {
        case .fill(let tone, let opacity):
            b.fill(path, with: .color(color(tone, palette).opacity(opacity)))
        case .evenOdd(let tone, let opacity):
            b.fill(path, with: .color(color(tone, palette).opacity(opacity)),
                   style: FillStyle(eoFill: true))
        case .stroke(let tone, let width, let opacity):
            b.stroke(path, with: .color(color(tone, palette).opacity(opacity)),
                     style: StrokeStyle(lineWidth: width, lineCap: .round))
        case .dots(let tone, let width, let gap, let opacity):
            b.stroke(path, with: .color(color(tone, palette).opacity(opacity)),
                     style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [0.0001, gap]))
        case .bar(let edge):
            b.stroke(path, with: .color(palette.outline.opacity(0.95)), lineWidth: edge + lw * 1.2)
            let r = path.boundingRect
            b.fill(path, with: .linearGradient(
                Gradient(colors: [.white, Color(red: 0.90, green: 0.93, blue: 0.97)]),
                startPoint: CGPoint(x: 0, y: r.minY), endPoint: CGPoint(x: 0, y: r.maxY)))
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

    /// One fin: a soft gradient from the root to a pale translucent
    /// edge, fine rays fanning from the root, and a thin edge line.
    private static func drawFin(_ fin: Fin, pose: Pose, palette: Palette,
                                into f: inout GraphicsContext, lw: Double, detailed: Bool) {
        let path = pose.fin(fin.path, fin)
        let root = pose.finPoint(fin.pivot, fin)
        let tip = pose.finPoint(fin.tip, fin)
        if fin.solid {
            // Spines are body, not membrane: lit tips, a full outline.
            f.stroke(path, with: .color(palette.outline), style: StrokeStyle(lineWidth: lw * 2, lineJoin: .round))
            f.fill(path, with: .radialGradient(Gradient(colors: [palette.body, palette.light]),
                                               center: root, startRadius: fin.reach * 0.8,
                                               endRadius: fin.reach * 1.05))
            return
        }
        let base = fin.tint ?? palette.body
        let far = fin.layer == .far
        let near = fin.layer == .near
        f.fill(path, with: .linearGradient(
            Gradient(stops: [
                .init(color: (far ? palette.dark : base).opacity(near ? 0.97 : 0.92), location: 0),
                .init(color: base.opacity(near ? 0.82 : 0.68), location: 0.5),
                .init(color: (fin.tint ?? palette.light).opacity(near ? 0.66 : 0.46), location: 1),
            ]),
            startPoint: root, endPoint: tip))
        if detailed || fin.trim || fin.sheen {
            var r = f
            r.clip(to: path)
            if fin.sheen {
                var sheen = r
                sheen.blendMode = .plusLighter
                sheen.fill(path, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .clear, location: 0.1),
                        .init(color: Color(red: 0.35, green: 0.80, blue: 1.0).opacity(0.28), location: 0.45),
                        .init(color: Color(red: 1.0, green: 0.45, blue: 0.85).opacity(0.24), location: 0.8),
                        .init(color: .clear, location: 1),
                    ]),
                    startPoint: root, endPoint: tip))
            }
            if detailed {
                r.stroke(pose.fin(fin.rays, fin), with: .color(palette.dark.opacity(far ? 0.22 : 0.34)),
                         lineWidth: lw * 0.55)
            }
            if fin.trim {
                r.stroke(path, with: .color(palette.outline.opacity(0.9)), lineWidth: lw * 3.4)
            }
        }
        f.stroke(path, with: .color(palette.outline.opacity(near ? 0.8 : 0.5)),
                 style: StrokeStyle(lineWidth: lw * (near ? 0.9 : 0.7), lineJoin: .round))
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
                                 blink: Double, dead: Bool, lw: Double, comp: Double) {
        let thin = max(0.12, min(1, swim.thin))
        let turn = min(1, max(0, (0.9 - thin) / 0.6))
        let spread = art.eyeSpread * (1 - thin * thin).squareRoot() / thin * turn
        // Round on screen: the eye widens back against the squash.
        let sx = (0.55 + 0.45 * thin) / thin * turn + (1 - turn)
        if turn > 0.05 {
            // The far eye, peeking over the brow as the head comes round.
            var far = f
            far.opacity = turn
            drawEye(into: &far, at: CGPoint(x: art.eye.x - spread, y: art.eye.y), r: art.eyeR * 0.94,
                    palette: palette, mood: mouth, blink: blink, dead: dead, lw: lw, sx: sx, sy: comp)
        }
        drawEye(into: &f, at: CGPoint(x: art.eye.x + spread, y: art.eye.y), r: art.eyeR,
                palette: palette, mood: mouth, blink: blink, dead: dead, lw: lw, sx: sx, sy: comp)
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

    /// The big friendly eye: a soft socket, a white that shades toward
    /// its lower edge, a coloured iris lit from below, a deep pupil,
    /// two catchlights, and lids that carry the mood — relaxed, a
    /// happy squint after a meal, a worried slant when hungry — and
    /// slide shut on `blink`. `sx`/`sy` stretch the circle back
    /// against the caller's squash.
    private static func drawEye(into f: inout GraphicsContext, at e: CGPoint, r: Double,
                                palette: Palette, mood: MouthKind, blink: Double, dead: Bool,
                                lw: Double, sx: Double, sy: Double) {
        func oval(_ cx: Double, _ cy: Double, _ rr: Double) -> Path {
            Path(ellipseIn: CGRect(x: cx - rr * sx, y: cy - rr * sy,
                                   width: rr * 2 * sx, height: rr * 2 * sy))
        }
        if dead {
            // A sinking fish: the classic cartoon X.
            var x = Path()
            let rr = r * 0.78
            x.move(to: CGPoint(x: e.x - rr * sx, y: e.y - rr * sy))
            x.addLine(to: CGPoint(x: e.x + rr * sx, y: e.y + rr * sy))
            x.move(to: CGPoint(x: e.x + rr * sx, y: e.y - rr * sy))
            x.addLine(to: CGPoint(x: e.x - rr * sx, y: e.y + rr * sy))
            f.stroke(x, with: .color(palette.outline.opacity(0.85)),
                     style: StrokeStyle(lineWidth: lw * 1.6, lineCap: .round))
            return
        }
        // The socket: a soft shadow ring that seats the eye in the head.
        f.fill(oval(e.x - r * 0.03, e.y + r * 0.08, r * 1.3), with: .radialGradient(
            Gradient(colors: [palette.dark.opacity(0.3), palette.dark.opacity(0)]),
            center: CGPoint(x: e.x, y: e.y + r * 0.08 * sy), startRadius: r * 0.9, endRadius: r * 1.3))
        let white = oval(e.x, e.y, r)
        f.fill(white, with: .radialGradient(
            Gradient(colors: [.white, Color(red: 0.84, green: 0.89, blue: 0.95)]),
            center: CGPoint(x: e.x + r * 0.2 * sx, y: e.y - r * 0.3 * sy),
            startRadius: 0, endRadius: r * 1.25))
        var inner = f
        inner.clip(to: white)
        // The iris looks forward, where the fish is going; a hungry
        // fish's pupils go wide.
        let ix = e.x + r * 0.24 * sx, iy = e.y + r * 0.04 * sy
        let irisR = r * (mood == .hungry ? 0.74 : 0.68)
        inner.fill(oval(ix, iy, irisR), with: .radialGradient(
            Gradient(stops: [
                .init(color: palette.light, location: 0),
                .init(color: palette.body, location: 0.55),
                .init(color: palette.outline, location: 1),
            ]),
            center: CGPoint(x: ix, y: iy + irisR * 0.45 * sy),
            startRadius: 0, endRadius: irisR * 1.15))
        inner.fill(oval(ix + r * 0.03 * sx, iy, irisR * (mood == .hungry ? 0.66 : 0.58)),
                   with: .color(Color(red: 0.02, green: 0.03, blue: 0.07)))
        // The upper lid's shadow across the top of the white.
        inner.fill(Path(CGRect(x: e.x - r * sx, y: e.y - r * sy, width: r * 2 * sx, height: r * 0.7 * sy)),
                   with: .linearGradient(Gradient(colors: [palette.dark.opacity(0.30), .clear]),
                                         startPoint: CGPoint(x: 0, y: e.y - r * sy),
                                         endPoint: CGPoint(x: 0, y: e.y - r * 0.3 * sy)))
        // Catchlights: a big soft one high and forward, a sharp dot low.
        inner.fill(oval(ix + r * 0.16 * sx, iy - r * 0.30 * sy, r * 0.27), with: .color(.white.opacity(0.97)))
        inner.fill(oval(ix - r * 0.26 * sx, iy + r * 0.30 * sy, r * 0.10), with: .color(.white.opacity(0.8)))
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
        let top = e.y - r * sy
        let span = r * 2 * sy
        if upper > 0.01 {
            // The lid's edge bows down: a curve from back to front.
            let yb = top + span * min(1, upper + slant * 0.5)
            let yf = top + span * max(0, upper - slant * 0.5)
            let sag = r * 0.35 * sy * (1 - upper * 0.8)
            var cap = Path()
            cap.move(to: CGPoint(x: e.x - r * 1.2 * sx, y: top - r))
            cap.addLine(to: CGPoint(x: e.x - r * 1.2 * sx, y: yb))
            cap.addQuadCurve(to: CGPoint(x: e.x + r * 1.2 * sx, y: yf),
                             control: CGPoint(x: e.x, y: (yb + yf) / 2 + sag))
            cap.addLine(to: CGPoint(x: e.x + r * 1.2 * sx, y: top - r))
            cap.closeSubpath()
            lid.fill(cap, with: .linearGradient(Gradient(colors: [palette.light, palette.body]),
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
            let bottom = e.y + r * sy
            let yl = bottom - span * lower
            var arch = Path()
            arch.move(to: CGPoint(x: e.x - r * 1.2 * sx, y: yl + r * 0.55 * sy))
            arch.addQuadCurve(to: CGPoint(x: e.x + r * 1.2 * sx, y: yl + r * 0.55 * sy),
                              control: CGPoint(x: e.x, y: yl - r * 0.55 * sy))
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
