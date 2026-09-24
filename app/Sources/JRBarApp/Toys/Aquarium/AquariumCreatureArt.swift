import JRBarCore
import SwiftUI

/// The creatures' shared paint: one light, high and to the left from
/// the surface, so the pets, the wearables and the fish read as one
/// illustrated set. Every helper paints into the caller's context, in
/// its units.
enum CreaturePaint {
    /// A lit solid: `lit` where the surface light lands, `base` across
    /// the middle, `shade` underneath, a band of shadow along the foot,
    /// a cool rim of light on the upper edge and a crisp outline.
    static func solid(_ c: inout GraphicsContext, _ path: Path,
                      lit: Color, base: Color, shade: Color,
                      outline: Color, lineWidth: Double, rim: Double = 0.45) {
        let r = path.boundingRect
        c.stroke(path, with: .color(outline), style: StrokeStyle(lineWidth: lineWidth * 2, lineJoin: .round))
        c.fill(path, with: .linearGradient(
            Gradient(stops: [
                .init(color: lit, location: 0),
                .init(color: base, location: 0.45),
                .init(color: shade, location: 1),
            ]),
            startPoint: CGPoint(x: r.minX + r.width * 0.2, y: r.minY),
            endPoint: CGPoint(x: r.maxX - r.width * 0.1, y: r.maxY)))
        var inner = c
        inner.clip(to: path)
        if rim > 0 {
            inner.stroke(path, with: .linearGradient(
                Gradient(colors: [.white.opacity(rim), .white.opacity(0)]),
                startPoint: CGPoint(x: r.minX, y: r.minY),
                endPoint: CGPoint(x: r.minX + r.width * 0.3, y: r.minY + r.height * 0.5)),
                lineWidth: lineWidth * 2.4)
        }
    }

    /// A glossy highlight: a soft white oval in `rect`.
    static func gloss(_ c: inout GraphicsContext, _ rect: CGRect, opacity: Double = 0.6) {
        c.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [.white.opacity(opacity), .white.opacity(0)]),
            center: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
            endRadius: max(rect.width, rect.height) * 0.5))
    }

    /// A little lit ball: a pompom, a crown's pearl, a bead.
    static func pompom(_ c: inout GraphicsContext, at p: CGPoint, r: Double,
                       lineWidth: Double, tint: Color, outline: Color) {
        let ball = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        c.stroke(ball, with: .color(outline), lineWidth: lineWidth * 1.6)
        c.fill(ball, with: .radialGradient(
            Gradient(colors: [.white, tint, tint.opacity(0.75)]),
            center: CGPoint(x: p.x - r * 0.35, y: p.y - r * 0.35), startRadius: 0, endRadius: r * 1.4))
    }

    /// A faceted gem with a sparkle.
    static func gem(_ c: inout GraphicsContext, at p: CGPoint, r: Double,
                    tint: Color, lineWidth: Double) {
        var stone = Path()
        stone.move(to: CGPoint(x: p.x, y: p.y - r))
        stone.addLine(to: CGPoint(x: p.x + r * 0.85, y: p.y))
        stone.addLine(to: CGPoint(x: p.x, y: p.y + r))
        stone.addLine(to: CGPoint(x: p.x - r * 0.85, y: p.y))
        stone.closeSubpath()
        c.fill(stone, with: .linearGradient(Gradient(colors: [.white, tint, tint.opacity(0.7)]),
                                            startPoint: CGPoint(x: p.x - r, y: p.y - r),
                                            endPoint: CGPoint(x: p.x + r, y: p.y + r)))
        c.stroke(stone, with: .color(.black.opacity(0.45)), lineWidth: lineWidth * 0.8)
    }
}

extension CreaturePaint {
    /// A pet's glossy eye: a white, a big dark iris, two catchlights
    /// and a crisp rim — the fish's eye, scaled down for the pets.
    static func eye(_ c: inout GraphicsContext, at p: CGPoint, r: Double,
                    iris: Color, outline: Color, lineWidth: Double, look: Double = 0.25) {
        let white = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        c.fill(white, with: .radialGradient(
            Gradient(colors: [.white, Color(red: 0.84, green: 0.88, blue: 0.93)]),
            center: CGPoint(x: p.x + r * 0.2, y: p.y - r * 0.3), startRadius: 0, endRadius: r * 1.2))
        var inner = c
        inner.clip(to: white)
        let ic = CGPoint(x: p.x + r * look, y: p.y + r * 0.05)
        let ir = r * 0.74
        inner.fill(Path(ellipseIn: CGRect(x: ic.x - ir, y: ic.y - ir, width: ir * 2, height: ir * 2)),
                   with: .radialGradient(Gradient(colors: [iris.opacity(0.7), iris, outline]),
                                         center: CGPoint(x: ic.x, y: ic.y + ir * 0.4),
                                         startRadius: 0, endRadius: ir * 1.1))
        let pr = ir * 0.58
        inner.fill(Path(ellipseIn: CGRect(x: ic.x - pr, y: ic.y - pr, width: pr * 2, height: pr * 2)),
                   with: .color(Color(red: 0.02, green: 0.03, blue: 0.06)))
        let hr = r * 0.3
        inner.fill(Path(ellipseIn: CGRect(x: ic.x + r * 0.1 - hr, y: ic.y - r * 0.32 - hr,
                                          width: hr * 2, height: hr * 2)), with: .color(.white))
        inner.fill(Path(ellipseIn: CGRect(x: ic.x - r * 0.32, y: ic.y + r * 0.2,
                                          width: r * 0.2, height: r * 0.2)), with: .color(.white.opacity(0.8)))
        c.stroke(white, with: .color(outline), lineWidth: lineWidth)
    }
}

/// The shop's pets, each drawn at the origin facing +x in points, in
/// the fish's style: one light from the surface, crisp outlines,
/// glossy eyes. The tank's pet passes place them and pick the pose.
enum PetArt {
    // MARK: Sea turtle

    private static let turtleInk = Color(red: 0.10, green: 0.13, blue: 0.07)
    private static let skinLit = Color(red: 0.78, green: 0.88, blue: 0.64)
    private static let skin = Color(red: 0.47, green: 0.62, blue: 0.40)
    private static let skinShade = Color(red: 0.22, green: 0.33, blue: 0.20)

    private static let turtleShell: Path = CartoonFish.spline([
        CartoonFish.corner(-26, 5), CartoonFish.k(-23, -7), CartoonFish.k(-11, -15.5),
        CartoonFish.k(4, -17), CartoonFish.k(17, -12.5), CartoonFish.k(25.5, -3),
        CartoonFish.corner(27, 4.5), CartoonFish.k(1, 8.5),
    ])

    /// The shell's plates: three along the spine, four down the flank.
    private static let turtleScutes: [Path] = {
        func plate(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ tilt: Double) -> Path {
            var p = Path()
            for v in 0..<6 {
                let a = Double(v) / 6 * .pi * 2 + .pi / 6
                let pt = CGPoint(x: cx + cos(a) * rx + sin(a) * tilt, y: cy + sin(a) * ry)
                if v == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
            return p
        }
        return [plate(-12, -8.5, 6.2, 5.2, 0.6), plate(0.5, -11, 6.4, 5.4, 0), plate(13, -7.5, 6.0, 5.0, -0.6),
                plate(-19, 0, 5.2, 4.2, 0.5), plate(-7, -0.5, 5.6, 4.4, 0.2),
                plate(5.5, -0.5, 5.6, 4.4, -0.2), plate(17.5, 0, 5.0, 4.2, -0.5)]
    }()

    /// A sea turtle mid-glide: front flippers sweep on `flap` (−1…1).
    static func seaTurtle(_ c: inout GraphicsContext, flap: Double) {
        let lw = 0.9
        func paddle(_ root: CGPoint, _ tip: CGPoint, width: Double) -> Path {
            let dx = tip.x - root.x, dy = tip.y - root.y
            let len = max(0.01, hypot(dx, dy))
            let nx = -dy / len, ny = dx / len
            return CartoonFish.spline([
                CartoonFish.k(root.x + nx * width * 0.5, root.y + ny * width * 0.5),
                CartoonFish.k(root.x + dx * 0.55 + nx * width * 0.62, root.y + dy * 0.55 + ny * width * 0.62),
                CartoonFish.corner(tip.x, tip.y),
                CartoonFish.k(root.x + dx * 0.5 - nx * width * 0.35, root.y + dy * 0.5 - ny * width * 0.35),
                CartoonFish.k(root.x - nx * width * 0.5, root.y - ny * width * 0.5),
            ])
        }
        // The far flippers, deeper in shadow, behind the shell.
        let farFront = paddle(CGPoint(x: 12, y: 2), CGPoint(x: 0 + flap * 3, y: 20 - flap * 8), width: 7)
        solid(&c, farFront, dim: true)
        solid(&c, paddle(CGPoint(x: -17, y: 3), CGPoint(x: -29, y: 8 + flap * 2), width: 5.5), dim: true)
        // The head and neck.
        let neck = CartoonFish.spline([CartoonFish.k(14, -6), CartoonFish.k(27, -8), CartoonFish.k(33, -3),
                                       CartoonFish.k(27, 4), CartoonFish.k(14, 5)])
        solid(&c, neck, dim: false)
        let head = CartoonFish.spline([CartoonFish.k(25, -7), CartoonFish.k(33, -11), CartoonFish.k(40, -7.5),
                                       CartoonFish.k(42.5, -2), CartoonFish.k(39, 2.5), CartoonFish.k(30, 3.5),
                                       CartoonFish.k(25, 0)])
        solid(&c, head, dim: false)
        var face = c
        face.clip(to: head)
        var plates = Path()
        for (x, y, r) in [(30.0, -8.0, 1.7), (33.5, -9.3, 1.5), (28.5, -4.5, 1.4), (35.5, -6.2, 1.2)] {
            plates.addEllipse(in: CGRect(x: x - r, y: y - r * 0.8, width: r * 2, height: r * 1.6))
        }
        face.fill(plates, with: .color(skinLit.opacity(0.55)))
        face.stroke(plates, with: .color(skinShade.opacity(0.6)), lineWidth: 0.4)
        CreaturePaint.eye(&c, at: CGPoint(x: 36, y: -5.2), r: 2.6,
                          iris: Color(red: 0.35, green: 0.22, blue: 0.10), outline: turtleInk, lineWidth: 0.6)
        var smile = Path()
        smile.move(to: CGPoint(x: 42, y: -0.6))
        smile.addQuadCurve(to: CGPoint(x: 35, y: 0.6), control: CGPoint(x: 39, y: 1.6))
        c.stroke(smile, with: .color(turtleInk), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
        // The plastron peeking under the rim.
        let belly = Path(roundedRect: CGRect(x: -20, y: 2.5, width: 40, height: 6.5), cornerRadius: 3.2)
        CreaturePaint.solid(&c, belly, lit: Color(red: 0.98, green: 0.92, blue: 0.70),
                            base: Color(red: 0.88, green: 0.76, blue: 0.48),
                            shade: Color(red: 0.62, green: 0.50, blue: 0.28), outline: turtleInk, lineWidth: lw, rim: 0)
        // The carapace: an amber dome of lit plates.
        CreaturePaint.solid(&c, turtleShell, lit: Color(red: 0.92, green: 0.78, blue: 0.42),
                            base: Color(red: 0.62, green: 0.48, blue: 0.22),
                            shade: Color(red: 0.30, green: 0.22, blue: 0.09), outline: turtleInk, lineWidth: lw)
        var shell = c
        shell.clip(to: turtleShell)
        for scute in turtleScutes {
            let r = scute.boundingRect
            shell.fill(scute, with: .radialGradient(
                Gradient(colors: [Color(red: 0.98, green: 0.84, blue: 0.48).opacity(0.85),
                                  Color(red: 0.55, green: 0.40, blue: 0.16).opacity(0.5)]),
                center: CGPoint(x: r.midX - r.width * 0.15, y: r.midY - r.height * 0.2),
                startRadius: 0, endRadius: r.width * 0.6))
            shell.stroke(scute, with: .color(Color(red: 0.24, green: 0.16, blue: 0.06).opacity(0.75)),
                         style: StrokeStyle(lineWidth: 0.8, lineJoin: .round))
        }
        // The rim's scalloped plates along the edge.
        var rim = Path()
        for k in 0..<9 {
            let x = -22.0 + Double(k) * 5.6
            rim.move(to: CGPoint(x: x, y: 5.5))
            rim.addLine(to: CGPoint(x: x + 0.8, y: 1.8))
        }
        shell.stroke(rim, with: .color(Color(red: 0.24, green: 0.16, blue: 0.06).opacity(0.55)), lineWidth: 0.6)
        CreaturePaint.gloss(&shell, CGRect(x: -8, y: -16, width: 20, height: 6), opacity: 0.45)
        c.stroke(turtleShell, with: .color(turtleInk), style: StrokeStyle(lineWidth: lw, lineJoin: .round))
        // The near flippers over the shell's edge.
        solid(&c, paddle(CGPoint(x: -15, y: 5), CGPoint(x: -26, y: 13 - flap * 3), width: 6), dim: false)
        solid(&c, paddle(CGPoint(x: 13, y: 4), CGPoint(x: -3 - flap * 3, y: 22 + flap * 9), width: 8.5), dim: false)
    }

    private static func solid(_ c: inout GraphicsContext, _ path: Path, dim: Bool) {
        CreaturePaint.solid(&c, path, lit: dim ? skin : skinLit, base: dim ? skinShade : skin,
                            shade: dim ? turtleInk : skinShade, outline: turtleInk, lineWidth: 0.8,
                            rim: dim ? 0 : 0.4)
    }

    // MARK: Octopus

    /// The octopus's colours, camouflaged to the substrate it sits on.
    struct OctopusSkin {
        var lit: Color
        var base: Color
        var shade: Color
    }

    private static let octoInk = Color(red: 0.20, green: 0.07, blue: 0.08)

    private static let octoMantle: Path = CartoonFish.spline([
        CartoonFish.k(-1.5, -27), CartoonFish.k(7, -24.5), CartoonFish.k(10.5, -16.5),
        CartoonFish.k(8.5, -8), CartoonFish.k(0, -4.5), CartoonFish.k(-8.5, -8),
        CartoonFish.k(-11, -17), CartoonFish.k(-8.5, -24.5),
    ])

    /// An octopus out on the sand: the mantle up, eight arms curling
    /// round it; `crawl` (−1…1) walks the arms.
    static func octopus(_ c: inout GraphicsContext, skin: OctopusSkin, crawl: Double) {
        // Eight arms fan out from under the mantle like a skirt: the
        // long outer pairs reach along the sand behind, the short inner
        // ones curl up in front.
        for k in [0, 7, 1, 6, 2, 5, 3, 4] {
            let u = (Double(k) - 3.5) / 3.5
            let side: Double = u < 0 ? -1 : 1
            let reach = 3.5 + 9.5 * abs(u)
            let sway = sin(crawl * .pi * 2 + Double(k) * 1.7) * 1.4
            let base = CGPoint(x: u * 6.5, y: -6.5)
            let end = CGPoint(x: base.x + side * reach + sway, y: 2.4 - (1 - abs(u)) * 0.8)
            let spine = [base,
                         CGPoint(x: base.x + (end.x - base.x) * 0.45, y: -0.6 - (1 - abs(u)) * 0.6),
                         end,
                         CGPoint(x: end.x + side * 2.3, y: 1.0),
                         CGPoint(x: end.x + side * 2.2, y: -1.3),
                         CGPoint(x: end.x + side * 0.9, y: -1.1)]
            let arm = CartoonFish.ribbon(spine, widths: [4.4, 3.4, 2.4, 1.7, 1.2, 0.8])
            let outer = abs(u) > 0.5
            CreaturePaint.solid(&c, arm, lit: outer ? skin.base : skin.lit, base: outer ? skin.shade : skin.base,
                                shade: skin.shade, outline: octoInk, lineWidth: 0.6, rim: outer ? 0 : 0.35)
            var suckers = Path()
            for t in [0.35, 0.55, 0.72] {
                let x = base.x + (end.x - base.x) * t
                suckers.addEllipse(in: CGRect(x: x - 0.65, y: 1.6 + t * 0.9, width: 1.3, height: 1.0))
            }
            c.fill(suckers, with: .color(Color(red: 1.0, green: 0.90, blue: 0.84).opacity(outer ? 0.5 : 0.85)))
        }
        mantle(&c, skin: skin)
        octoEye(&c, at: CGPoint(x: -4.3, y: -12), open: 1)
        octoEye(&c, at: CGPoint(x: 4.3, y: -12), open: 1)
        var smile = Path()
        smile.move(to: CGPoint(x: -1.8, y: -7.6))
        smile.addQuadCurve(to: CGPoint(x: 1.8, y: -7.6), control: CGPoint(x: 0, y: -6.3))
        c.stroke(smile, with: .color(octoInk), style: StrokeStyle(lineWidth: 0.6, lineCap: .round))
    }

    /// The octopus at home: its mantle slumped in the pot with the
    /// eyes lifted `lift` points over the rim, `open` (0…1) awake.
    static func octopusAtHome(_ c: inout GraphicsContext, skin: OctopusSkin, lift: Double, open: Double) {
        var m = c
        m.translateBy(x: 0, y: 12 - lift * 0.4)
        m.scaleBy(x: 1, y: 0.72)
        mantle(&m, skin: skin)
        octoEye(&c, at: CGPoint(x: -4.3, y: -lift), open: open)
        octoEye(&c, at: CGPoint(x: 4.3, y: -lift), open: open)
    }

    private static func mantle(_ c: inout GraphicsContext, skin: OctopusSkin) {
        CreaturePaint.solid(&c, octoMantle, lit: skin.lit, base: skin.base, shade: skin.shade,
                            outline: octoInk, lineWidth: 0.7)
        var spots = c
        spots.clip(to: octoMantle)
        var dots = Path()
        for (x, y, r) in [(-5.0, -22.0, 1.3), (1.5, -24.0, 1.0), (5.5, -19.5, 1.2), (-7.5, -16.0, 0.9),
                          (2.5, -17.5, 0.8), (-2.5, -19.0, 0.7)] {
            dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        spots.fill(dots, with: .color(skin.shade.opacity(0.45)))
        CreaturePaint.gloss(&spots, CGRect(x: -6.5, y: -26, width: 9, height: 5), opacity: 0.55)
    }

    /// An octopus eye: a warm white with the sideways slot of a pupil.
    private static func octoEye(_ c: inout GraphicsContext, at p: CGPoint, open: Double) {
        let white = Path(ellipseIn: CGRect(x: p.x - 2.6, y: p.y - 3.0, width: 5.2, height: 6.0))
        c.fill(white, with: .color(Color(red: 1.0, green: 0.97, blue: 0.86).opacity(open)))
        c.fill(Path(roundedRect: CGRect(x: p.x - 1.8, y: p.y - 0.9, width: 3.6, height: 2.4), cornerRadius: 1.1),
               with: .color(Color(red: 0.05, green: 0.03, blue: 0.04).opacity(open)))
        c.fill(Path(ellipseIn: CGRect(x: p.x - 0.1, y: p.y - 1.0, width: 1.2, height: 1.1)),
               with: .color(.white.opacity(open)))
        c.stroke(white, with: .color(octoInk.opacity(open)), lineWidth: 0.55)
    }

    // MARK: Axolotl

    private static let axoInk = Color(red: 0.46, green: 0.16, blue: 0.24)
    private static let axoLit = Color(red: 1.0, green: 0.88, blue: 0.90)
    private static let axo = Color(red: 0.98, green: 0.70, blue: 0.75)
    private static let axoShade = Color(red: 0.80, green: 0.45, blue: 0.54)

    private static let axoBody: Path = CartoonFish.spline([
        CartoonFish.k(-12, -4.5), CartoonFish.k(-3, -9.5), CartoonFish.k(9, -10),
        CartoonFish.k(15, -5), CartoonFish.k(13, 1.5), CartoonFish.k(3, 3), CartoonFish.k(-9, 2),
    ])

    private static let axoHead: Path = CartoonFish.spline([
        CartoonFish.k(9, -8), CartoonFish.k(15, -13.5), CartoonFish.k(24, -13.5), CartoonFish.k(30, -9),
        CartoonFish.k(31, -3), CartoonFish.k(26.5, 1.5), CartoonFish.k(16, 2), CartoonFish.k(9.5, -0.5),
    ])

    /// The axolotl on the sand: its tail sweeps on `swish`, its legs
    /// step on `step`, its gill fronds wave on `wave` (radians).
    static func axolotl(_ c: inout GraphicsContext, swish: Double, step: Double, wave: Double) {
        let lw = 0.75
        let frill = Color(red: 0.95, green: 0.32, blue: 0.50)
        let frillLit = Color(red: 1.0, green: 0.62, blue: 0.72)
        // The far legs, in shadow.
        for lx in [-4.0, 15.0] {
            leg(&c, at: lx + 2, step: -step, dim: true)
        }
        // The tail: a paddle with a fin crest running along it.
        let tail = CartoonFish.spline([
            CartoonFish.k(-7, -8.5), CartoonFish.k(-19, -11.5), CartoonFish.k(-31, -8 + swish),
            CartoonFish.corner(-37, -4 + swish * 1.2), CartoonFish.k(-30, -1 + swish * 0.8),
            CartoonFish.k(-18, 0.5), CartoonFish.k(-7, 1.5),
        ])
        CreaturePaint.solid(&c, tail, lit: axoLit, base: axo, shade: axoShade, outline: axoInk, lineWidth: lw)
        var crest = c
        crest.clip(to: tail)
        var fold = Path()
        fold.move(to: CGPoint(x: -9, y: -4.5))
        fold.addQuadCurve(to: CGPoint(x: -34, y: -4 + swish), control: CGPoint(x: -21, y: -6 + swish * 0.4))
        crest.stroke(fold, with: .color(axoShade.opacity(0.6)), lineWidth: 0.6)
        // The far gill fronds behind the head.
        fronds(&c, base: CGPoint(x: 14.5, y: -10.5), wave: wave + 0.9, color: Color(red: 0.72, green: 0.20, blue: 0.36),
               lit: frill, spread: 0.85)
        CreaturePaint.solid(&c, axoBody, lit: axoLit, base: axo, shade: axoShade, outline: axoInk, lineWidth: lw)
        CreaturePaint.solid(&c, axoHead, lit: axoLit, base: axo, shade: axoShade, outline: axoInk, lineWidth: lw)
        var cheek = c
        cheek.clip(to: axoHead)
        CreaturePaint.gloss(&cheek, CGRect(x: 15, y: -13, width: 10, height: 4), opacity: 0.6)
        // The near gill fronds, a cheek and the famous smile.
        fronds(&c, base: CGPoint(x: 13, y: -8.5), wave: wave, color: frill, lit: frillLit, spread: 1)
        for lx in [-6.0, 13.0] {
            leg(&c, at: lx, step: step, dim: false)
        }
        c.fill(Path(ellipseIn: CGRect(x: 19.5, y: -4.8, width: 5, height: 2.8)), with: .radialGradient(
            Gradient(colors: [Color(red: 1.0, green: 0.40, blue: 0.52).opacity(0.6), .clear]),
            center: CGPoint(x: 22, y: -3.4), startRadius: 0, endRadius: 2.6))
        CreaturePaint.eye(&c, at: CGPoint(x: 25.2, y: -7.6), r: 1.9,
                          iris: Color(red: 0.20, green: 0.08, blue: 0.12), outline: axoInk, lineWidth: 0.5, look: 0.2)
        var smile = Path()
        smile.move(to: CGPoint(x: 30.4, y: -3.4))
        smile.addQuadCurve(to: CGPoint(x: 21.5, y: -2.2), control: CGPoint(x: 27, y: 0.4))
        c.stroke(smile, with: .color(axoInk), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
    }

    private static func leg(_ c: inout GraphicsContext, at x: Double, step: Double, dim: Bool) {
        var leg = Path()
        leg.move(to: CGPoint(x: x, y: 0))
        leg.addQuadCurve(to: CGPoint(x: x + 2 + step, y: 6.2), control: CGPoint(x: x - 1.2, y: 3.5))
        c.stroke(leg, with: .color(axoInk), style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
        c.stroke(leg, with: .color(dim ? axoShade : axo), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        var toes = Path()
        for toe in [-1.5, 0.0, 1.5] {
            toes.move(to: CGPoint(x: x + 2 + step, y: 6.2))
            toes.addLine(to: CGPoint(x: x + 2 + step + toe, y: 7.9))
        }
        c.stroke(toes, with: .color(axoInk), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        c.stroke(toes, with: .color(dim ? axoShade : axo), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
    }

    /// Three feathery gill fronds fanning up and back from `base`.
    private static func fronds(_ c: inout GraphicsContext, base: CGPoint, wave: Double,
                               color: Color, lit: Color, spread: Double) {
        for k in 0..<3 {
            let a = (-1.75 - Double(k) * 0.5) * spread + sin(wave + Double(k) * 1.1) * 0.12
            let len = 8.5 + Double(k == 1 ? 1.5 : 0)
            let root = CGPoint(x: base.x - Double(k) * 0.6, y: base.y + Double(k) * 2.2)
            let tip = CGPoint(x: root.x + cos(a) * len, y: root.y + sin(a) * len)
            let bend = CGPoint(x: (root.x + tip.x) / 2 + sin(a) * 1.6, y: (root.y + tip.y) / 2 - cos(a) * 1.6)
            var frond = Path()
            frond.move(to: root)
            frond.addQuadCurve(to: tip, control: bend)
            var feathers = Path()
            for u in [0.3, 0.45, 0.6, 0.75, 0.9] {
                let px = root.x + (tip.x - root.x) * u, py = root.y + (tip.y - root.y) * u
                let fl = 2.6 * (1.1 - u * 0.5)
                for side in [-1.0, 1.0] {
                    feathers.move(to: CGPoint(x: px, y: py))
                    feathers.addLine(to: CGPoint(x: px + cos(a + side * 0.9) * fl, y: py + sin(a + side * 0.9) * fl))
                }
            }
            c.stroke(feathers, with: .color(color), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            c.stroke(feathers, with: .color(lit), style: StrokeStyle(lineWidth: 0.5, lineCap: .round))
            c.stroke(frond, with: .color(axoInk), style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
            c.stroke(frond, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
    }

    // MARK: Neon tetra

    /// The neon's parts, from the tetra kit so the school matches the
    /// tetra fish, cached once: fins, body, red flank and the stripe.
    private static let neon: (fins: Path, body: Path, red: Path, stripe: Path) = {
        let art = CartoonFish.art(for: .tetra)
        var fins = Path()
        for fin in art.fins where fin.layer != .near { fins.addPath(fin.path) }
        return (fins, art.body, art.marks.first?.path ?? Path(), art.flank)
    }()

    /// One neon tetra of the school, `length` points long, facing +x.
    static func neonTetra(_ c: inout GraphicsContext, length: Double) {
        var f = c
        f.scaleBy(x: length, y: length)
        let lw = 0.7 / length
        f.fill(neon.fins, with: .color(Color(red: 0.80, green: 0.90, blue: 0.96).opacity(0.5)))
        f.stroke(neon.body, with: .color(Color(red: 0.10, green: 0.16, blue: 0.24)), lineWidth: lw * 2)
        f.fill(neon.body, with: .linearGradient(
            Gradient(colors: [Color(red: 0.42, green: 0.52, blue: 0.62), Color(red: 0.93, green: 0.96, blue: 0.99)]),
            startPoint: CGPoint(x: 0, y: -0.16), endPoint: CGPoint(x: 0, y: 0.15)))
        var inner = f
        inner.clip(to: neon.body)
        inner.fill(neon.red, with: .color(Color(red: 0.95, green: 0.18, blue: 0.26).opacity(0.9)))
        var glow = inner
        glow.blendMode = .plusLighter
        glow.stroke(neon.stripe, with: .color(Color(red: 0.10, green: 0.75, blue: 1.0)),
                    style: StrokeStyle(lineWidth: 0.075, lineCap: .round))
        glow.stroke(neon.stripe, with: .color(Color(red: 0.70, green: 0.97, blue: 1.0)),
                    style: StrokeStyle(lineWidth: 0.025, lineCap: .round))
        f.fill(Path(ellipseIn: CGRect(x: 0.23, y: -0.12, width: 0.17, height: 0.17)), with: .color(.white))
        f.fill(Path(ellipseIn: CGRect(x: 0.27, y: -0.09, width: 0.11, height: 0.11)),
               with: .color(Color(red: 0.04, green: 0.05, blue: 0.08)))
        f.fill(Path(ellipseIn: CGRect(x: 0.32, y: -0.085, width: 0.04, height: 0.04)), with: .color(.white))
    }

    // MARK: Cleaner shrimp

    private static let shrimpInk = Color(red: 0.42, green: 0.08, blue: 0.10)

    private static let shrimpBody: Path = CartoonFish.spline([
        CartoonFish.corner(-10, 1.5), CartoonFish.k(-7, -3.5), CartoonFish.k(0, -6.5),
        CartoonFish.k(7, -5.2), CartoonFish.k(10.5, -2.5), CartoonFish.corner(13, -1.8),
        CartoonFish.k(9.5, 0.8), CartoonFish.k(1, 2.4), CartoonFish.k(-6, 2.6),
    ])

    /// A cleaner shrimp: a red-and-white arched body, a fan tail, busy
    /// legs and long white feelers that whisk on `whisk`.
    static func cleanerShrimp(_ c: inout GraphicsContext, whisk: Double) {
        let red = Color(red: 0.90, green: 0.18, blue: 0.20)
        for k in [-1.0, 1.0] {
            var feeler = Path()
            feeler.move(to: CGPoint(x: 11, y: -2.5))
            feeler.addQuadCurve(to: CGPoint(x: 26, y: -9 + k * 3.5 + whisk),
                                control: CGPoint(x: 18, y: -5 + k * 1.2))
            c.stroke(feeler, with: .color(.white.opacity(0.92)), style: StrokeStyle(lineWidth: 0.6, lineCap: .round))
        }
        var legs = Path()
        for k in 0..<5 {
            let lx = -4.0 + Double(k) * 2.8
            legs.move(to: CGPoint(x: lx, y: 1.8))
            legs.addQuadCurve(to: CGPoint(x: lx + 1.4, y: 6.4), control: CGPoint(x: lx - 0.4, y: 4.4))
        }
        c.stroke(legs, with: .color(shrimpInk.opacity(0.7)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        c.stroke(legs, with: .color(Color(red: 1.0, green: 0.90, blue: 0.88)), style: StrokeStyle(lineWidth: 0.55, lineCap: .round))
        var fan = Path()
        fan.move(to: CGPoint(x: -9, y: 0.5))
        fan.addLine(to: CGPoint(x: -15.5, y: -3.6))
        fan.addQuadCurve(to: CGPoint(x: -15.5, y: 4.2), control: CGPoint(x: -13.6, y: 0.3))
        fan.closeSubpath()
        CreaturePaint.solid(&c, fan, lit: Color(red: 1.0, green: 0.55, blue: 0.50), base: red,
                            shade: Color(red: 0.55, green: 0.08, blue: 0.10), outline: shrimpInk, lineWidth: 0.5)
        CreaturePaint.solid(&c, shrimpBody, lit: Color(red: 1.0, green: 0.58, blue: 0.52), base: red,
                            shade: Color(red: 0.56, green: 0.07, blue: 0.10), outline: shrimpInk, lineWidth: 0.55)
        var inner = c
        inner.clip(to: shrimpBody)
        // The white racing stripe along the back and the cream belly.
        var stripe = Path()
        stripe.move(to: CGPoint(x: -9, y: -1.8))
        stripe.addQuadCurve(to: CGPoint(x: 11, y: -3.2), control: CGPoint(x: 0, y: -8.2))
        inner.stroke(stripe, with: .color(.white), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        inner.fill(Path(CGRect(x: -12, y: 0.6, width: 26, height: 3)),
                   with: .color(Color(red: 1.0, green: 0.90, blue: 0.84).opacity(0.8)))
        var segments = Path()
        for k in 0..<3 {
            let sx = -5.5 + Double(k) * 3
            segments.move(to: CGPoint(x: sx, y: -6))
            segments.addQuadCurve(to: CGPoint(x: sx + 0.8, y: 2.6), control: CGPoint(x: sx - 1.2, y: -1.5))
        }
        inner.stroke(segments, with: .color(shrimpInk.opacity(0.4)), lineWidth: 0.45)
        c.fill(Path(ellipseIn: CGRect(x: 8.2, y: -4.9, width: 2.4, height: 2.4)),
               with: .color(Color(red: 0.05, green: 0.04, blue: 0.06)))
        c.fill(Path(ellipseIn: CGRect(x: 9.3, y: -4.6, width: 0.8, height: 0.8)), with: .color(.white))
    }

    // MARK: Manta

    /// The manta's diamond: swept wings, the two horn-like lobes at the
    /// mouth, a whip of a tail.
    private static func mantaWings(flap: Double) -> Path {
        let tip = 48 + flap * 7
        return CartoonFish.spline([
            CartoonFish.k(38, -6), CartoonFish.k(31, -13), CartoonFish.k(12, -30),
            CartoonFish.corner(-10, -tip), CartoonFish.k(-13, -30), CartoonFish.k(-20, -13),
            CartoonFish.k(-28, -4), CartoonFish.k(-28, 4), CartoonFish.k(-20, 13),
            CartoonFish.k(-13, 30), CartoonFish.corner(-10, tip), CartoonFish.k(12, 30),
            CartoonFish.k(31, 13), CartoonFish.k(38, 6),
        ])
    }

    /// A manta far back in the water: a big dim silhouette lit faintly
    /// from above.
    static func manta(_ c: inout GraphicsContext, flap: Double) {
        let deep = Color(red: 0.04, green: 0.08, blue: 0.14)
        let wings = mantaWings(flap: flap)
        var tail = Path()
        tail.move(to: CGPoint(x: -26, y: 0))
        tail.addQuadCurve(to: CGPoint(x: -70, y: 4), control: CGPoint(x: -48, y: -3))
        c.stroke(tail, with: .color(deep), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        c.fill(wings, with: .linearGradient(
            Gradient(colors: [Color(red: 0.12, green: 0.20, blue: 0.28), deep]),
            startPoint: CGPoint(x: 0, y: -40), endPoint: CGPoint(x: 0, y: 40)))
        var inner = c
        inner.clip(to: wings)
        inner.fill(Path(ellipseIn: CGRect(x: -24, y: -14, width: 60, height: 28)), with: .radialGradient(
            Gradient(colors: [Color(red: 0.30, green: 0.42, blue: 0.52).opacity(0.45), .clear]),
            center: CGPoint(x: 8, y: -4), startRadius: 0, endRadius: 30))
        for side in [-1.0, 1.0] {
            var lobe = Path()
            lobe.move(to: CGPoint(x: 36, y: side * 5))
            lobe.addQuadCurve(to: CGPoint(x: 46, y: side * 4), control: CGPoint(x: 43, y: side * 9))
            c.stroke(lobe, with: .color(deep), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
    }
}

extension CreaturePaint {
    /// A food pellet: a warm lit bead with a soft glow round it, so a
    /// treat reads as a treat against dark water. `alpha` fades it.
    static func pellet(_ c: inout GraphicsContext, at p: CGPoint, r: Double, alpha: Double) {
        var g = c
        g.opacity = alpha
        g.fill(Path(ellipseIn: CGRect(x: p.x - r * 2.2, y: p.y - r * 2.2, width: r * 4.4, height: r * 4.4)),
               with: .radialGradient(Gradient(colors: [Color(red: 1.0, green: 0.80, blue: 0.45).opacity(0.28), .clear]),
                                     center: p, startRadius: r * 0.6, endRadius: r * 2.2))
        let bead = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r * 0.9, width: r * 2, height: r * 1.8))
        g.stroke(bead, with: .color(Color(red: 0.32, green: 0.16, blue: 0.05)), lineWidth: 0.9)
        g.fill(bead, with: .radialGradient(
            Gradient(colors: [Color(red: 1.0, green: 0.84, blue: 0.52), Color(red: 0.80, green: 0.50, blue: 0.20),
                              Color(red: 0.50, green: 0.26, blue: 0.08)]),
            center: CGPoint(x: p.x - r * 0.35, y: p.y - r * 0.4), startRadius: 0, endRadius: r * 1.4))
        g.fill(Path(ellipseIn: CGRect(x: p.x - r * 0.55, y: p.y - r * 0.62, width: r * 0.55, height: r * 0.4)),
               with: .color(.white.opacity(0.8)))
    }
}

/// The small marks that float over a fish (W13's overlays): each a
/// distinct glyph — never a word — so a fixture that asserts
/// `overlay == .warningBuoy` sees the same mark the live tank draws.
/// Nothing here routes a command or answers anything.
enum FishOverlayArt {
    /// Draw `overlay` centred on `p`, `r` points in radius; `t` drives
    /// the slow shimmer on the ones that breathe.
    static func draw(_ overlay: FishOverlay, into c: inout GraphicsContext,
                     at p: CGPoint, r: Double, t: Double) {
        switch overlay {
        case .warningBuoy:
            // A warning buoy: an amber rounded triangle with a bar and
            // a dot, riding the water line.
            let tri = CartoonFish.spline([
                CartoonFish.k(p.x, p.y - r * 1.15), CartoonFish.k(p.x + r * 0.55, p.y - r * 0.2),
                CartoonFish.k(p.x + r * 1.05, p.y + r * 0.72), CartoonFish.k(p.x, p.y + r * 0.86),
                CartoonFish.k(p.x - r * 1.05, p.y + r * 0.72), CartoonFish.k(p.x - r * 0.55, p.y - r * 0.2),
            ])
            CreaturePaint.solid(&c, tri, lit: Color(red: 1.0, green: 0.86, blue: 0.40),
                                base: Color(red: 1.0, green: 0.62, blue: 0.12),
                                shade: Color(red: 0.86, green: 0.40, blue: 0.04),
                                outline: Color(red: 0.40, green: 0.16, blue: 0.02), lineWidth: 0.6)
            var bar = Path()
            bar.move(to: CGPoint(x: p.x, y: p.y - r * 0.45))
            bar.addLine(to: CGPoint(x: p.x, y: p.y + r * 0.12))
            c.stroke(bar, with: .color(.white), style: StrokeStyle(lineWidth: r * 0.24, lineCap: .round))
            c.fill(Path(ellipseIn: CGRect(x: p.x - r * 0.13, y: p.y + r * 0.34, width: r * 0.26, height: r * 0.26)),
                   with: .color(.white))
        case .attentionBuoy:
            // A permission ask: a bright ringed dot in a soft halo — the
            // lock cue reads as "decide this" rather than "answer me".
            let pulse = 0.5 + 0.5 * sin(t * 2.2)
            var halo = c
            halo.blendMode = .plusLighter
            halo.fill(Path(ellipseIn: CGRect(x: p.x - r * 1.9, y: p.y - r * 1.9, width: r * 3.8, height: r * 3.8)),
                      with: .radialGradient(Gradient(colors: [.white.opacity(0.18 + 0.12 * pulse), .clear]),
                                            center: p, startRadius: r * 0.6, endRadius: r * 1.9))
            let ring = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            c.fill(ring, with: .color(Color(red: 0.05, green: 0.14, blue: 0.26).opacity(0.55)))
            c.stroke(ring, with: .color(.white), lineWidth: max(1, r * 0.2))
            c.fill(Path(ellipseIn: CGRect(x: p.x - r * 0.42, y: p.y - r * 0.42, width: r * 0.84, height: r * 0.84)),
                   with: .color(.white))
        case .questionBubble:
            // The plain ask: the bubble is already the surfacing cue — a
            // steady dot inside it keeps a question from reading as an
            // idle sip.
            let bubble = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            c.fill(bubble, with: .radialGradient(
                Gradient(colors: [.white.opacity(0.06), .white.opacity(0.28)]),
                center: CGPoint(x: p.x - r * 0.2, y: p.y - r * 0.2), startRadius: 0, endRadius: r * 1.1))
            c.stroke(bubble, with: .color(.white.opacity(0.85)), lineWidth: max(0.8, r * 0.14))
            c.fill(Path(ellipseIn: CGRect(x: p.x - r * 0.62, y: p.y - r * 0.7, width: r * 0.42, height: r * 0.3)),
                   with: .color(.white.opacity(0.9)))
            c.fill(Path(ellipseIn: CGRect(x: p.x - r * 0.3, y: p.y - r * 0.2, width: r * 0.6, height: r * 0.6)),
                   with: .color(.white))
        case .pearl:
            // An unreviewed completion: a pearl the fish set down —
            // lustrous, with a slow gleam — cleared on review.
            var gleam = c
            gleam.blendMode = .plusLighter
            gleam.opacity = 0.35 + 0.25 * sin(t * 1.4)
            gleam.fill(Path(ellipseIn: CGRect(x: p.x - r * 1.8, y: p.y - r * 1.8, width: r * 3.6, height: r * 3.6)),
                       with: .radialGradient(Gradient(colors: [Color(red: 0.70, green: 0.92, blue: 1.0).opacity(0.6), .clear]),
                                             center: p, startRadius: 0, endRadius: r * 1.8))
            let pearl = Path(ellipseIn: CGRect(x: p.x - r * 0.8, y: p.y - r * 0.8, width: r * 1.6, height: r * 1.6))
            c.fill(pearl, with: .radialGradient(
                Gradient(stops: [
                    .init(color: .white, location: 0),
                    .init(color: Color(red: 0.94, green: 0.93, blue: 0.98), location: 0.45),
                    .init(color: Color(red: 0.80, green: 0.78, blue: 0.94), location: 0.8),
                    .init(color: Color(red: 0.62, green: 0.70, blue: 0.86), location: 1),
                ]),
                center: CGPoint(x: p.x - r * 0.28, y: p.y - r * 0.3), startRadius: 0, endRadius: r * 1.1))
            c.stroke(pearl, with: .color(Color(red: 0.30, green: 0.34, blue: 0.52).opacity(0.6)), lineWidth: 0.6)
            c.fill(Path(ellipseIn: CGRect(x: p.x - r * 0.45, y: p.y - r * 0.5, width: r * 0.36, height: r * 0.26)),
                   with: .color(.white))
        case .staleMarker:
            // AQ23's neutral marker: a hollow dashed ring — the fish
            // drifts, nothing precise is claimed.
            c.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .color(.white.opacity(0.45)),
                     style: StrokeStyle(lineWidth: 0.9, lineCap: .round, dash: [2, 2.6]))
        }
    }
}
