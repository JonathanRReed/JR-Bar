import AppKit
import JRBarCore
import SwiftUI

/// The ambient life that drifts through the water.
extension AquariumView {
    // MARK: Ambient life

    /// A jellyfish pulses through the mid-water every ~40 s — or, when
    /// the tank is empty (`resident`), stays on as the standing guest
    /// on a slow figure-eight, so a quiet tank still has one living
    /// thing in it. A glassy bell lit along its crown, four frilled
    /// oral arms and a veil of fine tentacles; after dark and in the
    /// deep themes it glows. Reduce Motion parks it mid-tank, unpulsed.
    func drawJellyfish(canvas: inout GraphicsContext, size: CGSize, t: Double,
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
            alpha = 0.72
        } else {
            let progress: Double
            if reduceMotion {
                progress = 0.45
                pulse = 0
                alpha = 0.45
            } else {
                let life = frac(t / 40 + 0.31) * 40
                guard life < 15 else { return }
                progress = life / 15
                pulse = sin(t * 1.9) * 0.10
                alpha = 0.58 * smooth(clamp01(min(progress / 0.18, (1 - progress) / 0.12)))
            }
            x = size.width * (1.08 - 1.24 * progress)
            y = size.height * (0.30 + 0.10 * sin(progress * .pi * 2 + 1))
        }
        let night = isDarkTheme ? 1 : nightFactor(t: t)
        let body = Color(red: 0.98, green: 0.86, blue: 0.95)
        let glowTint = Color(red: 0.80, green: 0.70, blue: 1.0)
        // The glow it carries after dark — light, so it adds.
        if night > 0.2 {
            TankPaint.glow(&canvas, at: CGPoint(x: x, y: y), radius: 46,
                           color: glowTint.opacity(0.22 * night * alpha))
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
        // Fine marginal tentacles off the whole lip, trailing long.
        let drift = reduceMotion ? 0 : t
        var fine = Path()
        for k in 0..<13 {
            let u = Double(k) / 12
            let tx = -0.48 + u * 0.96
            let ty = 0.12 + 0.17 * (1 - pow(u * 2 - 1, 2))
            fine.move(to: CGPoint(x: tx, y: ty))
            fine.addCurve(to: CGPoint(x: tx + sin(drift * 1.1 + Double(k)) * 0.10, y: ty + 0.95),
                          control1: CGPoint(x: tx - 0.05, y: ty + 0.35),
                          control2: CGPoint(x: tx + 0.06, y: ty + 0.65))
        }
        j.stroke(fine, with: .linearGradient(
            Gradient(colors: [body.opacity(0.5), body.opacity(0.05)]),
            startPoint: CGPoint(x: 0, y: 0.1), endPoint: CGPoint(x: 0, y: 1.1)), lineWidth: 0.012)
        // Four frilled oral arms under the bell.
        var arms = Path()
        for k in 0..<4 {
            let tx = -0.21 + Double(k) * 0.14
            arms.move(to: CGPoint(x: tx, y: 0.18))
            arms.addCurve(to: CGPoint(x: tx + sin(drift * 1.3 + Double(k) * 1.7) * 0.08, y: 0.72),
                          control1: CGPoint(x: tx - 0.08, y: 0.36),
                          control2: CGPoint(x: tx + 0.08, y: 0.54))
        }
        j.stroke(arms, with: .linearGradient(
            Gradient(colors: [Color(red: 1.0, green: 0.82, blue: 0.93).opacity(0.8),
                              Color(red: 0.92, green: 0.72, blue: 0.88).opacity(0.1)]),
            startPoint: CGPoint(x: 0, y: 0.18), endPoint: CGPoint(x: 0, y: 0.72)),
                 style: StrokeStyle(lineWidth: 0.07, lineCap: .round, dash: [0.05, 0.02]))
        // The bell: glassy, clearest at the rim, lit on its crown.
        j.fill(bell, with: .radialGradient(
            Gradient(stops: [
                .init(color: body.opacity(0.95), location: 0),
                .init(color: body.opacity(0.55), location: 0.45),
                .init(color: Color(red: 0.88, green: 0.70, blue: 0.86).opacity(0.22), location: 1),
            ]),
            center: CGPoint(x: -0.1, y: -0.28), startRadius: 0, endRadius: 0.62))
        // The moon jelly's four pale rings, seen through the bell.
        var rings = Path()
        for k in 0..<4 {
            let a = Double(k) / 4 * .pi * 2 + .pi / 4
            rings.addEllipse(in: CGRect(x: cos(a) * 0.15 - 0.075, y: -0.14 + sin(a) * 0.08 - 0.05,
                                        width: 0.15, height: 0.10))
        }
        j.stroke(rings, with: .color(Color(red: 1.0, green: 0.66, blue: 0.86).opacity(0.55)), lineWidth: 0.028)
        // A rim of light along the bell's lower lip and a crown sheen.
        var lip = Path()
        lip.move(to: CGPoint(x: -0.5, y: 0.12))
        lip.addQuadCurve(to: CGPoint(x: 0.5, y: 0.12), control: CGPoint(x: 0, y: 0.30))
        j.stroke(lip, with: .color(.white.opacity(0.55)), lineWidth: 0.035)
        j.stroke(bell, with: .color(.white.opacity(0.35)), lineWidth: 0.02)
        j.fill(Path(ellipseIn: CGRect(x: -0.30, y: -0.34, width: 0.26, height: 0.14)),
               with: .color(.white.opacity(0.55)))
    }

    /// Tap-dropped food: small flakes of feed sinking toward the sand
    /// with a slow sway, lit on top. The claim ring under a claimed
    /// pellet shows which fish is coming for it — informational only;
    /// the eat event fires in `stepSwim` when the fish actually
    /// arrives.
    func drawFeed(canvas: inout GraphicsContext, size: CGSize, now: Date) {
        let m = motion
        for pellet in m.pellets {
            let age = now.timeIntervalSince(pellet.bornAt)
            let appear = smooth(clamp01(age / 0.25))
            // Fading out over the last few seconds of its life keeps
            // uneaten food from popping.
            let fade = 1 - smooth(clamp01((age - 20) / 4))
            let a = appear * fade
            guard a > 0.01 else { continue }
            let sway = reduceMotion ? 0 : sin(age * 3.1 + Double(pellet.id)) * 4
            let x = pellet.x * size.width + sway
            let y = pellet.y * size.height
            let r = 2.6
            canvas.fill(
                Path(ellipseIn: CGRect(x: x - r, y: y - r * 0.8, width: r * 2, height: r * 1.6)),
                with: .radialGradient(
                    Gradient(colors: [Color(red: 0.92, green: 0.72, blue: 0.44).opacity(a),
                                      Color(red: 0.62, green: 0.40, blue: 0.20).opacity(a),
                                      Color(red: 0.38, green: 0.22, blue: 0.10).opacity(a)]),
                    center: CGPoint(x: x - r * 0.3, y: y - r * 0.35), startRadius: 0, endRadius: r * 1.2))
            if m.claims[pellet.id] != nil {
                canvas.stroke(
                    Path(ellipseIn: CGRect(x: x - r - 3, y: y - r - 3,
                                           width: (r + 3) * 2, height: (r + 3) * 2)),
                    with: .color(.white.opacity(a * 0.25)), lineWidth: 0.7)
            }
        }
    }

    /// Purchased decor (docs/TOYS.md shop), the swaying half: the leafy
    /// plant's broad leaves, drawn over the fish lane. The still pieces
    /// bake into the near bed (`drawShopDecorStill`), and the castle's
    /// pennant streams on its own pass behind the fish
    /// (`drawShopPennant`). Nothing here touches session state; it's
    /// pure dressing.
    func drawShopDecor(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        guard let game, game.owns(.plant) else { return }
        let tone = decorTone()
        let x = size.width * 0.115
        let baseY = sandTop(atX: x, in: size) + 1
        let unit = size.height / 700
        contactShadow(canvas: &canvas, x: x, y: baseY, halfW: 20 * unit, alpha: 0.30)
        // An Amazon sword: broad, veined leaves rising from one crown,
        // no two alike — the outer ones arching over, the inner ones
        // standing — each swaying on its own clock.
        var leaves = Path()
        var veins = Path()
        var top = baseY
        let still = reduceMotion
        for k in 0..<8 {
            let h = AquariumModel.stableHash("shop-plant-\(k)")
            let jitter = Double((h >> 20) & 0xFF) / 0xFF - 0.5
            let spread = (Double(k) - 3.5) / 3.5 + jitter * 0.25
            let reach = (36 + Double((h >> 8) & 0xFF) / 0xFF * 40) * unit * (1 - abs(spread) * 0.35)
            let sway = still ? 0 : sin(t * 0.9 + Double(k) * 1.4) * 0.06
            let angle = -.pi / 2 + spread * 0.72 + sway
            let base = CGPoint(x: x + spread * 4 * unit, y: baseY - 2 * unit)
            leaves.addPath(leaf(from: base, angle: angle, length: reach, width: reach * (0.20 + abs(jitter) * 0.12),
                                curl: spread * reach * (0.16 + abs(spread) * 0.12)))
            veins.move(to: base)
            veins.addQuadCurve(to: CGPoint(x: base.x + cos(angle) * reach * 0.85 + spread * reach * 0.05,
                                           y: base.y + sin(angle) * reach * 0.85),
                               control: CGPoint(x: base.x + cos(angle) * reach * 0.45,
                                                y: base.y + sin(angle) * reach * 0.45))
            top = min(top, base.y + sin(angle) * reach)
        }
        canvas.fill(leaves, with: .linearGradient(
            Gradient(colors: [tone(Color(red: 0.05, green: 0.20, blue: 0.13)),
                              tone(Color(red: 0.16, green: 0.42, blue: 0.24)),
                              tone(Color(red: 0.46, green: 0.70, blue: 0.36))]),
            startPoint: CGPoint(x: x, y: baseY), endPoint: CGPoint(x: x, y: top)))
        canvas.stroke(veins, with: .color(tone(Color(red: 0.78, green: 0.96, blue: 0.62)).opacity(0.45)),
                      lineWidth: max(0.6, 0.9 * unit))
        canvas.stroke(leaves, with: .color(tone(Color(red: 0.04, green: 0.18, blue: 0.10)).opacity(0.35)),
                      lineWidth: 0.5)
    }

    /// The castle's pennant, the one moving part of a keep that bakes
    /// into the bed. It draws before the fish so it layers with its
    /// tower and pole: a fish crossing the castle passes in front of
    /// all three.
    func drawShopPennant(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        guard let game, game.owns(.castle) else { return }
        var c = canvas
        c.translateBy(x: size.width * 0.885, y: sandTop(atX: size.width * 0.885, in: size))
        c.scaleBy(x: size.height / 242, y: size.height / 242)
        drawCastleFlag(&c, t: t, tone: decorTone())
    }

    /// Purchased decor, the still half — the rock a big lump with a
    /// quartz vein, the chest a smaller second treasure box, the castle
    /// a keep with its towers — baked into the near bed with the rest
    /// of the dressing, so none of it costs a frame. Each is seated in
    /// the water; the castle's lamps and the chest's gold are light,
    /// so they glow over the veil.
    func drawShopDecorStill(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        guard let game else { return }
        let veil = atmosphere(depth: Self.frontRowDepth, t: t)
        if game.owns(.rock) {
            let x = size.width * 0.315
            let baseY = sandTop(atX: x, in: size) + 2
            let unit = size.height / 700
            contactShadow(canvas: &canvas, x: x, y: baseY, halfW: 30 * unit, alpha: 0.40)
            let rock = stonePath(center: CGPoint(x: x, y: baseY - 15 * unit), width: 58 * unit,
                                 height: 36 * unit, seed: 211)
            let sand = sandPalette
            TankPaint.seat(&canvas, in: rock.boundingRect, atmosphere: veil, seed: 211) { c in
                paintStone(&c, rock, lit: .init(0.74, 0.74, 0.74), base: .init(0.46, 0.47, 0.49),
                           shade: .init(0.16, 0.17, 0.19), bounce: sand.lit, seed: 223, moss: 0.9)
                // A vein of quartz across its face.
                var vein = Path()
                vein.move(to: CGPoint(x: x - 22 * unit, y: baseY - 14 * unit))
                vein.addQuadCurve(to: CGPoint(x: x + 20 * unit, y: baseY - 22 * unit),
                                  control: CGPoint(x: x - 2 * unit, y: baseY - 12 * unit))
                var inner = c
                inner.clip(to: rock)
                inner.stroke(vein, with: .color(.white.opacity(0.45)), lineWidth: 1.6 * unit)
                inner.stroke(vein.offsetBy(dx: 0, dy: 1.2 * unit), with: .color(.black.opacity(0.12)),
                             lineWidth: 0.8 * unit)
            }
        }
        if game.owns(.treasureChest) {
            // A second, smaller chest — the seeded one keeps the
            // milestone plume; this one is the player's trophy, lid
            // cracked on its gold.
            let x = size.width * 0.68
            let baseY = sandTop(atX: x, in: size) + 2
            contactShadow(canvas: &canvas, x: x, y: baseY - 1, halfW: 17, alpha: 0.38)
            var c = canvas
            c.translateBy(x: x, y: baseY)
            c.scaleBy(x: 0.72, y: 0.72)
            TankPaint.seat(&c, in: CGRect(x: -24, y: -30, width: 48, height: 31), unit: 0.72,
                           atmosphere: veil, seed: 227) { c in
                Self.paintChest(&c, width: 40, height: 26, open: 0.12, t: 0, reduceMotion: true)
            }
            TankPaint.glow(&c, at: CGPoint(x: 0, y: -16), radius: 22,
                           color: Color(red: 1.0, green: 0.86, blue: 0.46).opacity(0.28))
        }
        if game.owns(.castle) {
            let x = size.width * 0.885
            let baseY = sandTop(atX: x, in: size)
            let unit = size.height / 242
            contactShadow(canvas: &canvas, x: x - 2 * unit, y: baseY + 1, halfW: 36 * unit, alpha: 0.40)
            var c = canvas
            c.translateBy(x: x, y: baseY)
            // Sized off the tank like the rest of the owned set —
            // ~130 px tall at 700, the keep a landmark, not a trinket.
            c.scaleBy(x: unit, y: unit)
            TankPaint.seat(&c, in: CGRect(x: -38, y: -64, width: 70, height: 65), unit: unit,
                           atmosphere: veil, seed: 37) { c in
                drawCastle(&c)
            }
            drawCastleLights(&c)
        }
    }

    /// The castle's windows, where lamplight shows: centre x, top,
    /// width and height in the keep's local units.
    private static let castleWindows: [(x: Double, top: Double, w: Double, h: Double)] = [
        (21, -21, 3, 5), (-24, -26, 3, 5.5), (-6, -31, 3.2, 6), (6, -31, 3.2, 6),
    ]

    /// The shop's castle: a crenellated keep between a round tower
    /// under a tiled cone and a squat side tower, dressed stone lit
    /// from the surface, lamp-lit windows, an arched gate with a
    /// portcullis, moss creeping up from the sand. Local units, origin
    /// at the gate's foot; the lamps' glow is `drawCastleLights`.
    private func drawCastle(_ c: inout GraphicsContext) {
        let lit = Color(red: 0.90, green: 0.87, blue: 0.88)
        let base = Color(red: 0.68, green: 0.65, blue: 0.72)
        let shade = Color(red: 0.38, green: 0.36, blue: 0.47)
        let edge = Color(red: 0.24, green: 0.22, blue: 0.32).opacity(0.55)
        let warm = Color(red: 1.0, green: 0.80, blue: 0.44)
        func crenellated(_ x0: Double, _ x1: Double, top: Double, merlon: Double) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: x0, y: 0))
            p.addLine(to: CGPoint(x: x0, y: top))
            var x = x0
            var up = true
            while x < x1 - 0.01 {
                let nx = min(x1, x + merlon)
                if up {
                    p.addLine(to: CGPoint(x: x, y: top - merlon * 0.9))
                    p.addLine(to: CGPoint(x: nx, y: top - merlon * 0.9))
                    p.addLine(to: CGPoint(x: nx, y: top))
                } else {
                    p.addLine(to: CGPoint(x: nx, y: top))
                }
                x = nx
                up.toggle()
            }
            p.addLine(to: CGPoint(x: x1, y: 0))
            p.closeSubpath()
            return p
        }
        func window(_ w: (x: Double, top: Double, w: Double, h: Double)) {
            var win = Path()
            win.move(to: CGPoint(x: w.x - w.w / 2, y: w.top + w.h))
            win.addLine(to: CGPoint(x: w.x - w.w / 2, y: w.top + w.w / 2))
            win.addArc(center: CGPoint(x: w.x, y: w.top + w.w / 2), radius: w.w / 2,
                       startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            win.addLine(to: CGPoint(x: w.x + w.w / 2, y: w.top + w.h))
            win.closeSubpath()
            c.fill(win, with: .linearGradient(
                Gradient(colors: [warm, Color(red: 0.88, green: 0.48, blue: 0.20)]),
                startPoint: CGPoint(x: 0, y: w.top), endPoint: CGPoint(x: 0, y: w.top + w.h)))
            c.stroke(win, with: .color(shade), lineWidth: 0.5)
        }
        let windows = Self.castleWindows

        // The squat side tower on the right, behind the keep.
        let right = crenellated(12, 27, top: -27, merlon: 3)
        TankPaint.solid(&c, right, lit: lit, base: base, shade: shade, outline: edge, lineWidth: 0.5)
        TankPaint.courses(&c, right, rect: CGRect(x: 12, y: -27, width: 15, height: 27),
                          rowHeight: 3.6, blockWidth: 6, lineWidth: 0.3, seed: 11)
        window(windows[0])

        // The round tower on the left: a cylinder under a tiled cone.
        let towerRect = CGRect(x: -31, y: -33, width: 14, height: 33)
        let tower = Path(roundedRect: towerRect, cornerRadius: 1)
        TankPaint.cylinder(&c, tower, lit: lit, base: base, shade: shade, outline: edge, lineWidth: 0.5)
        TankPaint.courses(&c, tower, rect: towerRect, rowHeight: 3.6, blockWidth: 5, lineWidth: 0.3, seed: 23)
        window(windows[1])
        var cone = Path()
        cone.move(to: CGPoint(x: -33, y: -32))
        cone.addQuadCurve(to: CGPoint(x: -24, y: -52), control: CGPoint(x: -29, y: -40))
        cone.addQuadCurve(to: CGPoint(x: -15, y: -32), control: CGPoint(x: -19, y: -40))
        cone.closeSubpath()
        let roofShade = Color(red: 0.42, green: 0.13, blue: 0.15)
        TankPaint.cylinder(&c, cone, lit: Color(red: 0.94, green: 0.50, blue: 0.40),
                           base: Color(red: 0.76, green: 0.30, blue: 0.26),
                           shade: roofShade, outline: roofShade.opacity(0.6), lineWidth: 0.5)
        var tiles = c
        tiles.clip(to: cone)
        var tileLines = Path()
        for k in 1..<5 {
            let y = -32.0 - Double(k) * 4
            tileLines.move(to: CGPoint(x: -34, y: y + 1.2))
            tileLines.addQuadCurve(to: CGPoint(x: -14, y: y + 1.2), control: CGPoint(x: -24, y: y + 2.6))
        }
        tiles.stroke(tileLines, with: .color(roofShade.opacity(0.55)), lineWidth: 0.4)
        tiles.stroke(tileLines.offsetBy(dx: 0, dy: -0.5), with: .color(.white.opacity(0.15)), lineWidth: 0.3)
        // The pennant's pole; the pennant itself streams on the live
        // pass (`drawCastleFlag`).
        var pole = Path()
        pole.move(to: CGPoint(x: -24, y: -51))
        pole.addLine(to: CGPoint(x: -24, y: -62))
        c.stroke(pole, with: .color(Color(red: 0.30, green: 0.26, blue: 0.22)), lineWidth: 0.8)

        // The keep, a little tapered, crenellated.
        let keep = crenellated(-14, 14, top: -40, merlon: 3.5)
        TankPaint.solid(&c, keep, lit: lit, base: base, shade: shade, outline: edge, lineWidth: 0.6)
        TankPaint.courses(&c, keep, rect: CGRect(x: -14, y: -44, width: 28, height: 44),
                          rowHeight: 4, blockWidth: 7, lineWidth: 0.32, seed: 37)
        TankPaint.speckle(&c, keep, seed: 41, count: 40, size: 0.8)
        // A string course under the battlements.
        c.fill(Path(CGRect(x: -15, y: -37, width: 30, height: 2)), with: .color(shade.opacity(0.8)))
        c.fill(Path(CGRect(x: -15, y: -37, width: 30, height: 0.7)), with: .color(lit))
        window(windows[2])
        window(windows[3])
        // The gate: a dark arch with a raised portcullis.
        var gate = Path()
        gate.move(to: CGPoint(x: -5.5, y: 0))
        gate.addLine(to: CGPoint(x: -5.5, y: -10))
        gate.addArc(center: CGPoint(x: 0, y: -10), radius: 5.5,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        gate.addLine(to: CGPoint(x: 5.5, y: 0))
        gate.closeSubpath()
        c.fill(gate, with: .linearGradient(
            Gradient(colors: [Color(red: 0.10, green: 0.07, blue: 0.10), Color(red: 0.46, green: 0.24, blue: 0.10)]),
            startPoint: CGPoint(x: 0, y: -15), endPoint: CGPoint(x: 0, y: 0)))
        var grid = c
        grid.clip(to: gate)
        var bars = Path()
        for k in -2...2 {
            bars.move(to: CGPoint(x: Double(k) * 2.2, y: -16))
            bars.addLine(to: CGPoint(x: Double(k) * 2.2, y: -7))
        }
        for y in [-13.0, -10.0] {
            bars.move(to: CGPoint(x: -6, y: y))
            bars.addLine(to: CGPoint(x: 6, y: y))
        }
        grid.stroke(bars, with: .color(Color(red: 0.26, green: 0.23, blue: 0.25)), lineWidth: 0.6)
        // The arch's voussoirs.
        var arch = Path()
        arch.addArc(center: CGPoint(x: 0, y: -10), radius: 6.6,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        c.stroke(arch, with: .color(shade), lineWidth: 2)
        c.stroke(arch.offsetBy(dx: 0, dy: -0.6), with: .color(lit.opacity(0.6)), lineWidth: 0.5)

        // Moss up every foot, a few stones at the base.
        TankPaint.moss(&c, clip: nil, from: -33, to: 28, y: 0.5, height: 4.5, seed: 53)
        let sand = sandPalette
        for (i, stone) in [(-36.0, 7.0), (29.0, 6.0), (10.0, 4.5)].enumerated() {
            let pebble = stonePath(center: CGPoint(x: stone.0, y: -stone.1 * 0.22), width: stone.1,
                                   height: stone.1 * 0.7, seed: 57 &+ UInt64(i))
            paintStone(&c, pebble, lit: .init(0.66, 0.64, 0.62), base: .init(0.44, 0.42, 0.42),
                       shade: .init(0.20, 0.19, 0.20), bounce: sand.lit, seed: 61 &+ UInt64(i), moss: 0)
        }
    }

    /// The castle's lamplight: every window and the gate glow out into
    /// the water — light, so it sits over the veil.
    private func drawCastleLights(_ c: inout GraphicsContext) {
        let warm = Color(red: 1.0, green: 0.78, blue: 0.40)
        for w in Self.castleWindows {
            TankPaint.glow(&c, at: CGPoint(x: w.x, y: w.top + w.h * 0.5), radius: w.w * 2.6,
                           color: warm.opacity(0.30))
        }
        TankPaint.glow(&c, at: CGPoint(x: 0, y: -3), radius: 9, color: warm.opacity(0.22))
    }

    /// The castle's pennant, streaming in the current — in the keep's
    /// local units, over the baked keep and under the fish.
    private func drawCastleFlag(_ c: inout GraphicsContext, t: Double, tone: TankPaint.Tone) {
        let flutter = reduceMotion ? 0 : sin(t * 2.6) * 1.2
        let ripple = reduceMotion ? 0 : sin(t * 3.4 + 1) * 0.6
        var flag = Path()
        flag.move(to: CGPoint(x: -24, y: -62))
        flag.addQuadCurve(to: CGPoint(x: -13, y: -59 + flutter), control: CGPoint(x: -18, y: -63 - flutter + ripple))
        flag.addQuadCurve(to: CGPoint(x: -24, y: -56.5), control: CGPoint(x: -18, y: -56 + flutter - ripple))
        flag.closeSubpath()
        c.fill(flag, with: .linearGradient(
            Gradient(colors: [tone(Color(red: 0.98, green: 0.36, blue: 0.38)), tone(Color(red: 0.72, green: 0.16, blue: 0.24))]),
            startPoint: CGPoint(x: -24, y: -60), endPoint: CGPoint(x: -13, y: -58)))
        c.stroke(flag, with: .color(tone(Color(red: 0.45, green: 0.08, blue: 0.14)).opacity(0.5)), lineWidth: 0.4)
    }

    /// A treasure chest in local units, its foot at the origin: plank
    /// body and domed lid with wood grain, brass bands and corners with
    /// rivets, a lock plate — and, when `open` lifts the lid, gold
    /// glinting in the gap.
    static func paintChest(_ c: inout GraphicsContext, width w: Double, height h: Double,
                           open: Double, t: Double, reduceMotion: Bool,
                           tone: TankPaint.Tone = .none) {
        let woodLit = tone(Color(red: 0.74, green: 0.50, blue: 0.27))
        let wood = tone(Color(red: 0.48, green: 0.30, blue: 0.15))
        let woodDark = tone(Color(red: 0.21, green: 0.12, blue: 0.05))
        let brassLit = tone(Color(red: 1.0, green: 0.90, blue: 0.56))
        let brass = tone(Color(red: 0.82, green: 0.62, blue: 0.26))
        let brassDark = tone(Color(red: 0.42, green: 0.27, blue: 0.09))
        let edge = woodDark.opacity(0.6)
        let bodyTop = -h * 0.60
        let body = Path(roundedRect: CGRect(x: -w / 2, y: bodyTop, width: w, height: h * 0.60), cornerRadius: w * 0.05)
        if open > 0 {
            // The hoard in the gap, glowing.
            let gap = Path(CGRect(x: -w / 2 + 2, y: bodyTop - h * 0.14 * open, width: w - 4, height: h * 0.16 * open + 1))
            c.fill(gap, with: .linearGradient(Gradient(colors: [brassLit, brass]),
                                              startPoint: CGPoint(x: 0, y: bodyTop - 4), endPoint: CGPoint(x: 0, y: bodyTop + 1)))
        }
        TankPaint.solid(&c, body, lit: woodLit, base: wood, shade: woodDark, outline: edge, lineWidth: w * 0.015)
        TankPaint.grain(&c, body, from: CGPoint(x: -w / 2, y: bodyTop + 3), to: CGPoint(x: w / 2, y: bodyTop + 2),
                        spacing: h * 0.07, width: w * 0.006, seed: 227, color: woodDark.opacity(0.30))
        var planks = c
        planks.clip(to: body)
        var seams = Path()
        for k in 1..<3 {
            let y = bodyTop + h * 0.2 * Double(k)
            seams.move(to: CGPoint(x: -w / 2, y: y)); seams.addLine(to: CGPoint(x: w / 2, y: y))
        }
        planks.stroke(seams, with: .color(woodDark.opacity(0.5)), lineWidth: w * 0.014)
        planks.stroke(seams.offsetBy(dx: 0, dy: w * 0.012), with: .color(woodLit.opacity(0.35)), lineWidth: w * 0.008)
        // The lid, raised by `open` about its back edge.
        var lidCtx = c
        lidCtx.translateBy(x: 0, y: bodyTop)
        lidCtx.rotate(by: .radians(-open * 0.35))
        var lid = Path()
        lid.move(to: CGPoint(x: -w / 2 - w * 0.04, y: 0))
        lid.addQuadCurve(to: CGPoint(x: w / 2 + w * 0.04, y: 0), control: CGPoint(x: 0, y: -h * 0.64))
        lid.closeSubpath()
        TankPaint.solid(&lidCtx, lid, lit: tone(Color(red: 0.84, green: 0.60, blue: 0.33)), base: wood, shade: woodDark,
                        outline: edge, lineWidth: w * 0.015, rim: 0.45)
        TankPaint.grain(&lidCtx, lid, from: CGPoint(x: -w / 2, y: -h * 0.12), to: CGPoint(x: w / 2, y: -h * 0.14),
                        spacing: h * 0.07, width: w * 0.006, seed: 229, color: woodDark.opacity(0.30))
        // Brass: two bands over lid and body, corners, the lock plate.
        let brassEdge = brassDark.opacity(0.6)
        for bandX in [-0.30, 0.30] as [Double] {
            let bx = w * bandX
            let strap = Path(CGRect(x: bx - w * 0.055, y: bodyTop, width: w * 0.11, height: h * 0.60))
            TankPaint.cylinder(&c, strap, lit: brassLit, base: brass, shade: brassDark, outline: brassEdge,
                               lineWidth: w * 0.01)
            // Over the lid the strap runs straight up its face to the
            // dome's silhouette.
            var over = lidCtx
            over.clip(to: lid)
            let lidStrap = Path(CGRect(x: bx - w * 0.055, y: -h * 0.7, width: w * 0.11, height: h * 0.7))
            TankPaint.cylinder(&over, lidStrap, lit: brassLit, base: brass, shade: brassDark, outline: brassEdge,
                               lineWidth: w * 0.01)
            var rivets = Path()
            for k in 0..<3 {
                let ry = bodyTop + h * 0.1 + Double(k) * h * 0.18
                rivets.addEllipse(in: CGRect(x: bx - w * 0.018, y: ry - w * 0.018, width: w * 0.036, height: w * 0.036))
            }
            c.fill(rivets, with: .color(brassLit))
        }
        let plate = Path(roundedRect: CGRect(x: -w * 0.1, y: bodyTop - h * 0.06, width: w * 0.2, height: h * 0.24),
                         cornerRadius: w * 0.03)
        TankPaint.solid(&c, plate, lit: brassLit, base: brass, shade: brassDark, outline: brassEdge, lineWidth: w * 0.01)
        var keyhole = Path()
        keyhole.addEllipse(in: CGRect(x: -w * 0.022, y: bodyTop + h * 0.01, width: w * 0.044, height: w * 0.044))
        keyhole.move(to: CGPoint(x: -w * 0.012, y: bodyTop + h * 0.05))
        keyhole.addLine(to: CGPoint(x: w * 0.012, y: bodyTop + h * 0.05))
        keyhole.addLine(to: CGPoint(x: w * 0.02, y: bodyTop + h * 0.13))
        keyhole.addLine(to: CGPoint(x: -w * 0.02, y: bodyTop + h * 0.13))
        keyhole.closeSubpath()
        c.fill(keyhole, with: .color(woodDark))
    }
}
