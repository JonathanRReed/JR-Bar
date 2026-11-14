import AppKit
import JRBarCore
import SwiftUI

/// The fish kit (docs/TOYS.md): one illustrated style for every
/// species, lit by the tank and not inked. No outline carries a fish:
/// its volume is a four-stop body gradient, a pale crescent of surface
/// light along the back, a warm bounce off the sand under the belly and
/// one soft catch of light on the brow. Each species wears its own coat
/// (`CartoonFish.coat(for:)`), fins are translucent and thin toward the
/// water, and the eyes are dark and bright enough to carry the mood.
/// Everything is a unit-space `Path` drawn at true proportions, nose
/// toward +x, body centred near the origin, roughly x −0.5…0.5, so the
/// caller scales both axes by the fish's length, flips x for
/// left-facing and rotates for pitch without the paths knowing. No
/// image assets anywhere.
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

    /// The colours one fish is painted in: its species' coat
    /// (docs/TOYS.md) as the tank's water and light leave it.
    struct Palette: Sendable {
        /// The flank.
        var body: Color
        /// The back, where the surface lights it.
        var light: Color
        /// The shaded lower flank and the soft markings.
        var dark: Color
        /// Ink: the lines of the face and the thin edge that keeps a
        /// small fish crisp. Never a cartoon outline, unless the tank's
        /// own `ink` asks for one.
        var outline: Color
        /// The light the surface lays along every top edge; gold on a
        /// fish whose run just finished.
        var glow: Color
        /// The underside.
        var belly: Color
        /// Plain fin membranes.
        var fin: Color
        /// The fins that carry the species' second colour.
        var accent: Color
        /// The bold markings.
        var mark: Color
        /// The water at the fish's depth; fins thin toward it.
        var fog: Color
        /// How strongly the sand throws warm light back under the belly:
        /// about a quarter by day, nothing at night.
        var bounce: Double
        /// The tank's cartoon ink (Arcade 1): the edge draws heavier.
        var ink: Double = 0

        /// The tank's recipe: `coat` washed toward `floor` as the fish
        /// swims `depth` (0 shallow … 1 deep) down the column, hue as
        /// well as brightness, with a touch of grey on top, so a deep
        /// fish reads watery rather than just dim. Plain sRGB colours,
        /// so a frame resolves them for free.
        ///
        /// The water's style tunes it: `haze` scales the depth wash (the
        /// Arcade tank keeps a deep fish nearly as bright as a shallow
        /// one), `vivid` pushes the colour's saturation, and `ink`
        /// darkens the edge and makes it draw heavier. `hue` turns the
        /// coat a few degrees so two fish of one species differ, `look`
        /// drains a failed fish, `night` (0 day … 1 night) cools the rim
        /// and puts the sand's bounce out, and `gold` turns the rim gold.
        init(coat: Coat, depth: Double = 0, floor: NSColor,
             haze: Double = 1, vivid: Double = 0, ink: Double = 0,
             look: Look = .natural, hue: Double = 0, night: Double = 0, gold: Bool = false) {
            let fl = Self.rgb(floor)
            var coat = coat
            if hue != 0 {
                coat.base = CartoonFish.hueTurned(coat.base, degrees: hue)
                coat.light = CartoonFish.hueTurned(coat.light, degrees: hue)
                coat.dark = CartoonFish.hueTurned(coat.dark, degrees: hue)
                coat.belly = CartoonFish.hueTurned(coat.belly, degrees: hue * 0.5)
                coat.fin = CartoonFish.hueTurned(coat.fin, degrees: hue)
            }
            if look == .drained {
                coat = coat.map {
                    CartoonFish.mix(CartoonFish.desaturated($0, 0.82), (0.42, 0.48, 0.53), 0.25)
                }
            }
            let grey = (0.5, 0.5, 0.5)
            let wash: (CartoonFish.RGB) -> CartoonFish.RGB = { c in
                let hazed = CartoonFish.mix(CartoonFish.mix(c, grey, depth * 0.30 * haze), fl, depth * 0.45 * haze)
                return Self.saturate(hazed, by: 1 + vivid)
            }
            let fogRGB = CartoonFish.mix(fl, (0.10, 0.44, 0.62), 0.55)
            // At night the fish sink a quarter of the way into the dark
            // water with everything else, so the tank reads as one night.
            let nightRGB = CartoonFish.mix(fl, (0.04, 0.10, 0.22), 0.5)
            let c = coat.map { CartoonFish.mix(wash($0), nightRGB, night * 0.25) }
            let rim: CartoonFish.RGB = gold
                ? (1.0, 0.88, 0.54)
                : CartoonFish.mix((0.914, 1.0, 0.984), (0.725, 0.827, 1.0), night)
            body = Self.color(c.base)
            light = Self.color(c.light)
            dark = Self.color(c.dark)
            outline = Self.color(CartoonFish.mix(c.dark, (0.04, 0.10, 0.18), 0.55 + 0.30 * ink))
            glow = Self.color(CartoonFish.mix(rim, fogRGB, depth * 0.35 * haze))
            belly = Self.color(c.belly)
            fin = Self.color(c.fin)
            accent = Self.color(c.accent)
            mark = Self.color(c.mark)
            fog = Self.color(fogRGB)
            bounce = look == .drained ? 0 : 0.28 * (1 - night)
            self.ink = ink
        }

        /// A coat grown from one colour: the proofs' hand-painted fish.
        init(accent: NSColor, depth: Double = 0, floor: NSColor,
             haze: Double = 1, vivid: Double = 0, ink: Double = 0) {
            self.init(coat: .mono(Self.rgb(accent)), depth: depth, floor: floor,
                      haze: haze, vivid: vivid, ink: ink)
        }

        /// A colour pushed away from its own grey by `factor` (1 keeps
        /// it), clamped to the displayable range.
        private static func saturate(_ c: CartoonFish.RGB, by factor: Double) -> CartoonFish.RGB {
            guard factor != 1 else { return c }
            let l = 0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2
            func push(_ v: Double) -> Double { min(1, max(0, l + (v - l) * factor)) }
            return (push(c.0), push(c.1), push(c.2))
        }

        private static func rgb(_ c: NSColor) -> CartoonFish.RGB {
            // A colour with no sRGB form (a pattern, say) swims grey.
            guard let s = c.usingColorSpace(.sRGB) else { return (0.5, 0.5, 0.5) }
            return (Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent))
        }

        private static func color(_ c: CartoonFish.RGB) -> Color {
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
        /// Through a turn, how far the head is turned beyond the body's
        /// middle, radians (`AquariumTurn.Pose.lead`): ahead while it
        /// comes round, behind while it opens out. 0 draws the kit as is.
        var lead: Double = 0

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
        /// Painted in the coat's second colour: the tang's yellow tail,
        /// the angelfish's sails.
        var accent = false
        /// Opaque, body-coloured — the puffer's spines.
        var solid = false
    }

    /// A paint layer clipped to the body: bars, bands, stripes, spots.
    struct Mark: Sendable {
        /// `light` is the belly's colour, `dark` the shaded flank and
        /// `outline` the coat's bold marking colour.
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
                    trim: Bool = false, accent: Bool = false) -> Fin {
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
                   motion: motion, layer: layer, trim: trim, accent: accent)
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

    /// Draw one fish at the origin of `f`, already translated, rotated,
    /// flipped & scaled to unit space by the caller. `blink` is 0 open
    /// …1 shut. `dead` (a sinking fish) closes the eye and puts out the
    /// species' own lights: no neon, no shimmer, no blush. `pointSize`
    /// is the fish's drawn length, so the edge and the rim keep one
    /// weight and the fine detail drops out where it would only be
    /// noise.
    static func draw(into f: inout GraphicsContext, species: FishSpecies,
                     palette: Palette, swim: Swim = .still,
                     mouth: MouthKind, blink: Double, dead: Bool,
                     pointSize: Double = 60,
                     variant: AquariumVariant? = nil,
                     gaze: CGVector? = nil) {
        let art = art(for: species)
        let pose = Pose(art: art, swim: swim)
        let lw = outlineWidth(pointSize, ink: palette.ink)
        let detailed = pointSize >= 38
        let vivid = !dead

        drawFinsBehind(art: art, pose: pose, palette: palette, into: &f, lw: lw,
                       rim: rimWidth(pointSize), detailed: detailed, vivid: vivid)

        let body = pose.body(art.body)
        var near: [(fin: Fin, path: Path)] = []
        for fin in art.fins where fin.layer == .near {
            near.append((fin, pose.fin(fin.path, fin)))
        }
        drawBody(body, art: art, pose: pose, palette: palette, into: &f,
                 lw: lw, rim: rimWidth(pointSize), detailed: detailed, vivid: vivid,
                 variant: variant, shadows: near.map(\.path))
        // The edge: a thin line a shade darker than the flank. It is not
        // an outline; it keeps the silhouette crisp against the water at
        // 24 pt. A tank drawn in cartoon ink thickens it into one.
        f.stroke(body, with: .color(palette.outline.opacity(edgeOpacity(palette.ink))),
                 style: StrokeStyle(lineWidth: lw * 0.75, lineJoin: .round))
        for (fin, path) in near {
            // The near pectoral: its own lit membrane, rays and edge.
            let base = fin.accent && vivid ? palette.accent : palette.fin.mix(with: palette.light, by: 0.25)
            if fin.trim {
                f.stroke(path, with: .color(palette.outline.opacity(0.7)),
                         style: StrokeStyle(lineWidth: lw * 1.8, lineJoin: .round))
            }
            f.fill(path, with: .linearGradient(
                Gradient(stops: [
                    .init(color: base.opacity(0.95), location: 0),
                    .init(color: base.opacity(0.70), location: 1),
                ]),
                startPoint: pose.finPoint(fin.pivot, fin), endPoint: pose.finPoint(fin.tip, fin)))
            if detailed {
                f.stroke(pose.fin(fin.rays, fin), with: .color(palette.dark.opacity(0.22)), lineWidth: lw * 0.5)
            }
            if !fin.trim {
                f.stroke(path, with: .color(palette.dark.opacity(0.35 + 0.4 * palette.ink)),
                         style: StrokeStyle(lineWidth: lw * 0.6, lineJoin: .round))
            }
        }

        drawFace(art: art, species: species, swim: swim, palette: palette, into: &f,
                 mouth: mouth, blink: blink, dead: dead, lw: lw, detailed: detailed, gaze: gaze)
    }

    /// How solid the body's thin edge draws: half there on a lit fish,
    /// full in a tank drawn in cartoon ink.
    static func edgeOpacity(_ ink: Double) -> Double { min(1, 0.5 + 0.5 * ink) }

    /// The width of the rim of surface light, in unit space: about a
    /// point and a half on a tank-sized fish, wider on a big one.
    static func rimWidth(_ pointSize: Double) -> Double {
        max(1.4, pointSize * 0.028) / max(1, pointSize)
    }

    /// The part of `path` that `path` moved by `dy` leaves uncovered, as
    /// an even-odd shape to fill inside a clip to `path`: a crescent
    /// along the top edge for a positive `dy`, along the bottom for a
    /// negative one. The cheapest volume there is.
    static func crescent(of path: Path, in bounds: CGRect, dy: Double) -> Path {
        var p = Path()
        p.addRect(bounds.insetBy(dx: -0.1 - abs(dy), dy: -0.1 - abs(dy)))
        p.addPath(path.offsetBy(dx: 0, dy: dy))
        return p
    }

    /// The fins behind the body, soft and translucent so they read as
    /// fins rather than more body. Every plain membrane shares one
    /// radial wash, dense by the body and thinning toward the water at
    /// the edges, and all the rims, rays and edges go down in one pass
    /// each, so a fish's fins cost a handful of fills however many it
    /// has. A fin in the coat's second colour (the tang's yellow)
    /// paints its own while the fish is `vivid`; spines are solid.
    private static func drawFinsBehind(art: Art, pose: Pose, palette: Palette,
                                       into f: inout GraphicsContext, lw: Double, rim: Double,
                                       detailed: Bool, vivid: Bool) {
        var far = Path()
        var membrane = Path()
        var lit = Path()
        var trims = Path()
        var rays = Path()
        var edges = Path()
        var tinted: [(fin: Fin, path: Path)] = []
        for fin in art.fins where fin.layer != .near {
            let path = pose.fin(fin.path, fin)
            if fin.solid {
                // Spines are body, not membrane: lit tips, a thin edge.
                f.fill(path, with: .radialGradient(Gradient(colors: [palette.body, palette.light]),
                                                   center: fin.pivot, startRadius: fin.reach * 0.8,
                                                   endRadius: fin.reach * 1.05))
                f.stroke(path, with: .color(palette.outline.opacity(edgeOpacity(palette.ink))),
                         style: StrokeStyle(lineWidth: lw * 0.7, lineJoin: .round))
                continue
            }
            if fin.layer == .far {
                far.addPath(path)
            } else if fin.accent, vivid {
                tinted.append((fin, path))
                lit.addPath(path)
            } else {
                membrane.addPath(path)
                lit.addPath(path)
            }
            if fin.trim { trims.addPath(path) } else { edges.addPath(path) }
            if detailed { rays.addPath(pose.fin(fin.rays, fin)) }
        }
        f.fill(far, with: .color(palette.dark.opacity(0.6)))
        f.stroke(trims, with: .color(palette.outline.opacity(0.7)),
                 style: StrokeStyle(lineWidth: lw * 1.8, lineJoin: .round))
        let centre = CGPoint(x: art.bounds.midX, y: art.bounds.midY)
        let e = art.extent
        let reach = max(hypot(e.minX - centre.x, e.minY - centre.y), hypot(e.minX - centre.x, e.maxY - centre.y),
                        hypot(e.maxX - centre.x, e.minY - centre.y))
        let inner = min(art.bounds.width, art.bounds.height) * 0.4
        // A veil keeps its colour right out to the edge, the richest
        // part of a betta, where a plain fin thins toward the water.
        let veil = art.iridescent && vivid
        let thin = palette.fin.mix(with: palette.fog, by: 0.25)
        f.fill(membrane, with: .radialGradient(
            Gradient(stops: [
                .init(color: palette.fin.opacity(0.88), location: 0),
                .init(color: palette.fin.opacity(veil ? 0.82 : 0.74), location: 0.45),
                .init(color: veil ? palette.fin.opacity(0.62) : thin.opacity(0.48), location: 1),
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
            f.fill(path, with: .linearGradient(
                Gradient(stops: [
                    .init(color: palette.accent.opacity(0.92), location: 0),
                    .init(color: palette.accent.mix(with: palette.fog, by: 0.25).opacity(0.55), location: 1),
                ]),
                startPoint: pose.finPoint(fin.pivot, fin), endPoint: pose.finPoint(fin.tip, fin)))
        }
        // The surface's light along every fin's top edge, in one fill.
        if !lit.isEmpty {
            var top = f
            top.clip(to: lit)
            top.fill(crescent(of: lit, in: e, dy: rim * 1.4), with: .color(palette.glow.opacity(0.25)),
                     style: FillStyle(eoFill: true))
        }
        f.stroke(rays, with: .color(palette.dark.opacity(0.18)), lineWidth: lw * 0.5)
        f.stroke(edges, with: .color(palette.dark.opacity(0.28 + 0.5 * palette.ink)),
                 style: StrokeStyle(lineWidth: lw * 0.6, lineJoin: .round))
    }

    /// The body's paint, back to front: the four-stop light that is its
    /// volume, the markings and scales, the sand's warm bounce under
    /// the belly, a crescent of surface light along the back with a
    /// softer one behind it, a shade crescent along the belly's edge,
    /// one soft catch of light on the brow, the near fins' shadows and
    /// the gill cover. One clip to the silhouette carries all of it.
    private static func drawBody(_ body: Path, art: Art, pose: Pose, palette: Palette,
                                 into f: inout GraphicsContext, lw: Double, rim: Double,
                                 detailed: Bool, vivid: Bool, variant: AquariumVariant?,
                                 shadows: [Path]) {
        let r = art.bounds
        let top = CGPoint(x: 0, y: r.minY), bottom = CGPoint(x: 0, y: r.maxY)
        f.fill(body, with: .linearGradient(
            Gradient(stops: [
                .init(color: palette.light, location: 0),
                .init(color: palette.body, location: 0.34),
                .init(color: palette.body.mix(with: palette.dark, by: 0.35), location: 0.66),
                .init(color: palette.belly, location: 1),
            ]),
            startPoint: top, endPoint: bottom))
        var b = f
        b.clip(to: body)
        if detailed, let rest = art.scales {
            let scales = pose.warps ? pose.body(rest) : rest
            b.stroke(scales, with: .linearGradient(
                Gradient(colors: [palette.dark.opacity(0.12), palette.dark.opacity(0)]),
                startPoint: CGPoint(x: r.minX, y: 0),
                endPoint: CGPoint(x: r.minX + r.width * 0.72, y: 0)),
                lineWidth: lw * 0.5)
        }
        for mark in art.marks {
            paintMark(mark, path: mark.flexes || pose.warps ? pose.body(mark.path) : mark.path,
                      palette: palette, into: &b, lw: lw, vivid: vivid)
        }
        if let variant { drawVariant(variant, art: art, pose: pose, palette: palette, into: &b) }
        // The sand's light, thrown back up under every fish.
        if palette.bounce > 0 {
            let warm = sandBounce
            b.fill(body, with: .linearGradient(
                Gradient(stops: [
                    .init(color: warm.opacity(0), location: 0.75),
                    .init(color: warm.opacity(palette.bounce), location: 1),
                ]),
                startPoint: top, endPoint: bottom))
        }
        // The rim: where the surface's light lands on the back, crisp at
        // the edge and soft behind it, and the belly's edge turning away.
        b.fill(crescent(of: body, in: r, dy: rim * 2.25), with: .color(palette.glow.opacity(0.22)),
               style: FillStyle(eoFill: true))
        b.fill(crescent(of: body, in: r, dy: rim), with: .color(palette.glow.opacity(0.9)),
               style: FillStyle(eoFill: true))
        b.fill(crescent(of: body, in: r, dy: -rim), with: .color(palette.dark.opacity(0.45)),
               style: FillStyle(eoFill: true))
        // One soft catch of light on the brow.
        let rest = art.gloss.insetBy(dx: -art.gloss.width * 0.12, dy: -art.gloss.height * 0.45)
        let g = pose.warps ? warped(rest, pose) : rest
        b.fill(Path(ellipseIn: g), with: .radialGradient(
            Gradient(colors: [.white.opacity(0.42), .white.opacity(0)]),
            center: CGPoint(x: g.midX + g.width * 0.1, y: g.midY),
            startRadius: 0, endRadius: g.width * 0.5))
        // The near fins' soft shadows on the flank under them.
        if !shadows.isEmpty {
            var shade = Path()
            for shadow in shadows { shade.addPath(shadow.offsetBy(dx: -0.012, dy: 0.022)) }
            b.fill(shade, with: .color(palette.dark.opacity(0.22)))
        }
        if let rest = art.gill {
            let gill = pose.warps ? pose.body(rest) : rest
            b.stroke(gill, with: .color(palette.dark.opacity(0.38)),
                     style: StrokeStyle(lineWidth: lw * 0.8, lineCap: .round))
        }
    }

    /// `rect` carried along the length by the turn's head lead.
    private static func warped(_ rect: CGRect, _ pose: Pose) -> CGRect {
        let minX = pose.warpX(rect.minX), maxX = pose.warpX(rect.maxX)
        return CGRect(x: minX, y: rect.minY, width: max(0.001, maxX - minX), height: rect.height)
    }

    private static func color(_ tone: Mark.Tone, _ palette: Palette, vivid: Bool) -> Color {
        switch tone {
        case .light: return palette.belly
        case .dark: return palette.dark
        case .outline: return palette.mark
        case .white: return barWhite
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
            b.stroke(path, with: .color(palette.mark.opacity(0.85)), lineWidth: edge + lw * 0.6)
            let r = path.boundingRect
            b.fill(path, with: .linearGradient(
                Gradient(colors: [barWhite, barShade]),
                startPoint: CGPoint(x: 0, y: r.minY), endPoint: CGPoint(x: 0, y: r.maxY)))
        case .neon(let width) where !vivid:
            b.stroke(path, with: .color(palette.belly.opacity(0.6)),
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
            b.stroke(stripe, with: .color(palette.belly.opacity(0.85)),
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
                let c = CGPoint(x: pose.warpX(r.minX + r.width * u), y: r.minY + r.height * v)
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
    /// squashing with the body. When the head leads the turn, the face
    /// turns with the head, not the middle, and rides the warp with it.
    private static func drawFace(art: Art, species: FishSpecies, swim: Swim, palette: Palette,
                                 into f: inout GraphicsContext, mouth: MouthKind,
                                 blink: Double, dead: Bool, lw: Double, detailed: Bool,
                                 gaze: CGVector? = nil) {
        let place = facePlacement(art: art, swim: swim)
        let face = place.face
        if face.turn > 0.05 {
            // The far eye, peeking over the brow as the head comes round.
            var far = f
            far.opacity = face.far
            drawEye(into: &far, at: place.farEye, r: art.eyeR * 0.94,
                    palette: palette, mood: mouth, blink: blink, dead: dead, lw: lw, detailed: false,
                    sx: place.sx, gaze: gaze)
        }
        drawEye(into: &f, at: place.nearEye, r: art.eyeR,
                palette: palette, mood: mouth, blink: blink, dead: dead, lw: lw, detailed: detailed,
                sx: place.sx, gaze: gaze)
        if !dead, species != .seahorse || mouth != .plain {
            var m = f
            if face.turn > 0.05 {
                // Face-on the mouth sits centred under the eyes.
                m.translateBy(x: -face.spread * 0.2, y: 0)
            }
            drawMouth(into: &m, at: place.mouth, kind: mouth, palette: palette, lw: lw,
                      s: art.mouthScale)
        }
    }

    /// Where the face sits this frame, in the kit's unit space: the turn
    /// read off the head's own yaw, both eyes and the mouth carried by
    /// the head lead, and how much wider to draw an eye so it stays round
    /// against the caller's squash (the body's middle). Wear anchors on
    /// the same numbers, so glasses stay on the eyes through a turn.
    static func facePlacement(art: Art, swim: Swim)
        -> (face: (turn: Double, spread: Double, sx: Double, far: Double),
            nearEye: CGPoint, farEye: CGPoint, mouth: CGPoint, sx: Double) {
        let lead = CartoonFish.HeadLead(art: art, thin: swim.thin, lead: swim.lead)
        let face = faceTurn(art: art, thin: lead?.headThin ?? swim.thin)
        let warp: (Double) -> Double = { x in lead?.x(x) ?? x }
        var sx = face.sx
        if lead != nil {
            // The eye ovals aren't warped, so they widen back against the
            // middle's squash, turned by the head's.
            let mid = max(0.12, min(1, swim.thin))
            sx = (0.55 + 0.45 * mid) / mid * face.turn + (1 - face.turn)
        }
        // Nearly head-on the eyes part further than a squashed side view
        // is wide — more so while the head leads, turned further round
        // than the middle: each eye stops at the silhouette, bulging at
        // it, never floating off the head (a puffer is short enough for
        // both to).
        let inset = art.eyeR * sx * 0.9
        let near = min(warp(art.eye.x + face.spread), warp(art.bounds.maxX) - inset)
        let far = max(warp(art.eye.x - face.spread), warp(art.bounds.minX) + inset)
        return (face,
                CGPoint(x: max(near, far), y: art.eye.y),
                CGPoint(x: far, y: art.eye.y),
                CGPoint(x: warp(art.mouth.x), y: art.mouth.y),
                sx)
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

    /// The eye: a soft socket, a cool white, one dark iris looking
    /// where the fish is going and a catchlight, with lids that carry
    /// the mood (relaxed, a happy squint after a meal, a worried slant
    /// when hungry) and slide shut on `blink`. Smaller and darker than a
    /// sticker's eye, so the fish reads as a character. `sx` widens the
    /// circle back against a turn's squash.
    static func drawEye(into f: inout GraphicsContext, at e: CGPoint, r: Double,
                                palette: Palette, mood: MouthKind, blink: Double, dead: Bool,
                                lw: Double, detailed: Bool, sx: Double, gaze: CGVector? = nil) {
        func oval(_ cx: Double, _ cy: Double, _ rr: Double) -> Path {
            Path(ellipseIn: CGRect(x: cx - rr * sx, y: cy - rr,
                                   width: rr * 2 * sx, height: rr * 2))
        }
        // The socket seats the eye in the head.
        f.fill(oval(e.x, e.y, r * 1.18), with: .color(palette.dark.opacity(0.25)))
        if dead {
            // A failed run's fish: the eye shut, drooping at its outer
            // end. Sad, not dead.
            var shut = Path()
            shut.move(to: CGPoint(x: e.x - r * 0.85 * sx, y: e.y - r * 0.10))
            shut.addQuadCurve(to: CGPoint(x: e.x + r * 0.85 * sx, y: e.y + r * 0.05),
                              control: CGPoint(x: e.x, y: e.y + r * 0.62))
            f.stroke(shut, with: .color(palette.outline.opacity(0.85)),
                     style: StrokeStyle(lineWidth: max(lw * 1.4, r * 0.26), lineCap: .round))
            return
        }
        // The white, shaded under the brow at the top and cool at the
        // bottom edge.
        let white = oval(e.x, e.y, r)
        let cool = eyeWhite
        f.fill(white, with: .linearGradient(
            Gradient(stops: [
                .init(color: palette.dark.mix(with: cool, by: 0.62), location: 0),
                .init(color: cool, location: 0.34),
                .init(color: cool, location: 0.72),
                .init(color: eyeShade, location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: e.y - r), endPoint: CGPoint(x: 0, y: e.y + r)))
        // Everything inside the white sits well inside it, so nothing
        // here needs a clip. The iris looks forward, where the fish is
        // going; a hungry fish's goes wide.
        // A fish that has noticed the pointer looks at it: `gaze` is the
        // way to it in the kit's own space, at most one long.
        let lookX = gaze.map { 0.24 * $0.dx } ?? 0.22
        let lookY = gaze.map { 0.24 * $0.dy } ?? 0.03
        let ix = e.x + r * lookX * sx, iy = e.y + r * lookY
        let irisR = r * (mood == .hungry ? 0.76 : 0.70)
        f.fill(oval(ix, iy, irisR), with: .color(iris))
        // Catchlights: one high and forward, and on a fish big enough to
        // show it, a sharp dot low.
        var glints = oval(ix + r * 0.14 * sx, iy - r * 0.30, r * 0.24)
        if detailed { glints.addPath(oval(ix - r * 0.24 * sx, iy + r * 0.30, r * 0.09)) }
        f.fill(glints, with: .color(.white.opacity(0.95)))
        f.stroke(white, with: .color(palette.outline.opacity(0.45 + 0.45 * palette.ink)), lineWidth: lw * 0.6)

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
            lid.stroke(edge, with: .color(palette.outline.opacity(0.85)), lineWidth: lw * 1.1)
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
            lid.stroke(arch, with: .color(palette.outline.opacity(0.85)), lineWidth: lw * 1.1)
        }
    }

    /// The mouth: a smile just after eating, a small "o" when hungry,
    /// a soft upturned curve otherwise. `s` sizes it to the face.
    static func drawMouth(into f: inout GraphicsContext, at p: CGPoint,
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
            f.fill(o, with: .color(palette.belly))
            f.stroke(o, with: .color(palette.outline), lineWidth: lw * 1.0)
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
