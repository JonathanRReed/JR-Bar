import AppKit
import SwiftUI

/// The tank's shared materials: one light (high and to the left, from
/// the surface), one way of seating a thing on the sand, so the shop's
/// stone, clay, wood and brass all read as one illustrated set with the
/// fish. Every helper paints into the caller's context, in its units.
enum TankPaint {
    /// A small seeded generator — decor texture must land in the same
    /// place every frame and every launch.
    struct Seeded {
        private var state: UInt64

        init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

        /// The next value in 0…1.
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }

        mutating func next(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next() }
    }

    /// A lit solid: `lit` where the surface light lands (upper left),
    /// `base` across the middle, `shade` in the lower right, a band of
    /// ambient shadow along the foot, a thin rim of light on the upper
    /// edge and a soft outline.
    static func solid(_ c: inout GraphicsContext, _ path: Path,
                      lit: Color, base: Color, shade: Color,
                      outline: Color = .black.opacity(0.38), lineWidth: Double = 1,
                      rim: Double = 0.30) {
        let r = path.boundingRect
        c.fill(path, with: .linearGradient(
            Gradient(stops: [
                .init(color: lit, location: 0),
                .init(color: base, location: 0.45),
                .init(color: shade, location: 1),
            ]),
            startPoint: CGPoint(x: r.minX + r.width * 0.15, y: r.minY),
            endPoint: CGPoint(x: r.maxX - r.width * 0.10, y: r.maxY)))
        var inner = c
        inner.clip(to: path)
        inner.fill(Path(r), with: .linearGradient(
            Gradient(colors: [.black.opacity(0), .black.opacity(0.28)]),
            startPoint: CGPoint(x: 0, y: r.maxY - r.height * 0.32),
            endPoint: CGPoint(x: 0, y: r.maxY)))
        if rim > 0 {
            inner.stroke(path, with: .linearGradient(
                Gradient(colors: [.white.opacity(rim), .white.opacity(0)]),
                startPoint: CGPoint(x: r.minX, y: r.minY),
                endPoint: CGPoint(x: r.midX, y: r.midY)),
                lineWidth: lineWidth * 2.4)
        }
        c.stroke(path, with: .color(outline), style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
    }

    /// A round solid lit the same way — a cylinder's or a bowl's
    /// sideways falloff: bright a third of the way in from the left,
    /// dark at both edges.
    static func cylinder(_ c: inout GraphicsContext, _ path: Path,
                         lit: Color, base: Color, shade: Color,
                         outline: Color = .black.opacity(0.38), lineWidth: Double = 1) {
        let r = path.boundingRect
        c.fill(path, with: .linearGradient(
            Gradient(stops: [
                .init(color: shade, location: 0),
                .init(color: lit, location: 0.32),
                .init(color: base, location: 0.62),
                .init(color: shade, location: 1),
            ]),
            startPoint: CGPoint(x: r.minX, y: 0), endPoint: CGPoint(x: r.maxX, y: 0)))
        var inner = c
        inner.clip(to: path)
        inner.fill(Path(r), with: .linearGradient(
            Gradient(colors: [.black.opacity(0), .black.opacity(0.24)]),
            startPoint: CGPoint(x: 0, y: r.maxY - r.height * 0.25),
            endPoint: CGPoint(x: 0, y: r.maxY)))
        c.stroke(path, with: .color(outline), style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
    }

    /// Stone or clay grain: seeded pits and flecks, clipped to `path`.
    static func speckle(_ c: inout GraphicsContext, _ path: Path, seed: UInt64,
                        count: Int, size: Double,
                        dark: Color = .black.opacity(0.22), light: Color = .white.opacity(0.14)) {
        var inner = c
        inner.clip(to: path)
        let r = path.boundingRect
        var rng = Seeded(seed)
        var pits = Path()
        var flecks = Path()
        for k in 0..<count {
            let x = rng.next(r.minX, r.maxX)
            let y = rng.next(r.minY, r.maxY)
            let d = size * rng.next(0.5, 1.4)
            let dot = CGRect(x: x - d / 2, y: y - d * 0.35, width: d, height: d * 0.7)
            if k % 3 == 0 { flecks.addEllipse(in: dot) } else { pits.addEllipse(in: dot) }
        }
        inner.fill(pits, with: .color(dark))
        inner.fill(flecks, with: .color(light))
    }

    /// Masonry: horizontal courses with staggered joints across `rect`,
    /// clipped to `path` — each joint a dark line with a pale lip under
    /// it, so the blocks stand proud.
    static func courses(_ c: inout GraphicsContext, _ path: Path, rect: CGRect,
                        rowHeight: Double, blockWidth: Double, lineWidth: Double,
                        seed: UInt64) {
        var inner = c
        inner.clip(to: path)
        var joints = Path()
        var rng = Seeded(seed)
        var row = 0
        var y = rect.maxY - rowHeight
        while y > rect.minY {
            joints.move(to: CGPoint(x: rect.minX, y: y))
            joints.addLine(to: CGPoint(x: rect.maxX, y: y))
            var x = rect.minX + (row % 2 == 0 ? blockWidth * 0.5 : blockWidth) + rng.next(-2, 2) * lineWidth
            while x < rect.maxX {
                joints.move(to: CGPoint(x: x, y: y))
                joints.addLine(to: CGPoint(x: x, y: min(rect.maxY, y + rowHeight)))
                x += blockWidth * rng.next(0.8, 1.2)
            }
            y -= rowHeight
            row += 1
        }
        inner.stroke(joints.offsetBy(dx: lineWidth * 0.5, dy: lineWidth * 0.7),
                     with: .color(.white.opacity(0.16)), lineWidth: lineWidth * 0.8)
        inner.stroke(joints, with: .color(.black.opacity(0.30)), lineWidth: lineWidth)
    }

    /// Moss and algae creeping up from a foot line: soft green tufts,
    /// darker at the root, a lit fleck on each crown. `clip` keeps it
    /// on the thing it grows on.
    static func moss(_ c: inout GraphicsContext, clip: Path?, from x0: Double, to x1: Double,
                     y: Double, height: Double, seed: UInt64, fade: Double = 1) {
        var m = c
        if let clip { m.clip(to: clip) }
        var rng = Seeded(seed)
        var tufts = Path()
        var crowns = Path()
        let step = max(0.5, height * 0.55)
        var x = x0
        while x < x1 {
            // Patches, not a hedge: some stretches stay bare.
            if rng.next() < 0.3 {
                x += step * rng.next(1.0, 2.2)
                continue
            }
            let h = height * rng.next(0.25, 1.0)
            let w = step * rng.next(0.8, 1.5)
            tufts.addEllipse(in: CGRect(x: x - w / 2, y: y - h, width: w, height: h * 1.4))
            if rng.next() > 0.6 {
                crowns.addEllipse(in: CGRect(x: x - w * 0.18, y: y - h * 0.92, width: w * 0.36, height: h * 0.28))
            }
            x += step * rng.next(0.55, 1.0)
        }
        m.fill(tufts, with: .linearGradient(
            Gradient(colors: [Color(red: 0.30, green: 0.48, blue: 0.22).opacity(0.75 * fade),
                              Color(red: 0.08, green: 0.20, blue: 0.10).opacity(0.9 * fade)]),
            startPoint: CGPoint(x: 0, y: y - height), endPoint: CGPoint(x: 0, y: y + height * 0.3)))
        m.fill(crowns, with: .color(Color(red: 0.62, green: 0.78, blue: 0.40).opacity(0.45 * fade)))
    }

    /// Wood grain: long wavering lines along the plank's length.
    static func grain(_ c: inout GraphicsContext, _ path: Path, from p0: CGPoint, to p1: CGPoint,
                      spacing: Double, width: Double, seed: UInt64, color: Color) {
        var inner = c
        inner.clip(to: path)
        let r = path.boundingRect
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let len = max(0.001, (dx * dx + dy * dy).squareRoot())
        let nx = -dy / len, ny = dx / len
        let reach = max(r.width, r.height)
        var rng = Seeded(seed)
        var lines = Path()
        var off = -reach
        while off < reach {
            let wob = rng.next(-0.6, 0.6) * spacing
            let a = CGPoint(x: p0.x + nx * off - dx * 0.2, y: p0.y + ny * off - dy * 0.2)
            let b = CGPoint(x: p1.x + nx * off + dx * 0.2, y: p1.y + ny * off + dy * 0.2)
            lines.move(to: a)
            lines.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2 + nx * wob,
                                                       y: (a.y + b.y) / 2 + ny * wob))
            off += spacing * rng.next(0.7, 1.3)
        }
        inner.stroke(lines, with: .color(color), lineWidth: width)
    }

    /// A warm glow — a window, a lamp, a crater — added onto the water.
    static func glow(_ c: inout GraphicsContext, at p: CGPoint, radius: Double, color: Color) {
        var g = c
        g.blendMode = .plusLighter
        g.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
               with: .radialGradient(Gradient(colors: [color, color.opacity(0)]),
                                     center: p, startRadius: 0, endRadius: radius))
    }

    /// How far decor sinks into the water's colour: a little by
    /// night, more in the dark themes, so a lit castle never reads as a
    /// sticker on the abyss. Light sources (windows, lamps, glows) are
    /// never toned — they are what the dark is for.
    struct Tone {
        var wash: Double
        var toward: NSColor

        static let none = Tone(wash: 0, toward: .black)

        func callAsFunction(_ color: Color) -> Color {
            guard wash > 0.001 else { return color }
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
            let alpha = ns.alphaComponent
            let mixed = ns.withAlphaComponent(1).blended(withFraction: wash, of: toward) ?? ns
            return Color(nsColor: mixed).opacity(alpha)
        }
    }
}
