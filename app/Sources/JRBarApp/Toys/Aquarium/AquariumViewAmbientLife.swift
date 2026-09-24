import AppKit
import JRBarCore
import SwiftUI

/// The ambient life that drifts through the water.
extension AquariumView {
    // MARK: Ambient life

    /// A jellyfish pulses through the mid-water every ~40 s — or, when
    /// the tank is empty (`resident`), stays on as the standing guest
    /// on a slow figure-eight, so a quiet tank still has one living
    /// thing in it. A translucent bell over four trailing tentacles.
    /// Reduce Motion parks it mid-tank, unpulsed.
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
            alpha = 0.62
        } else {
            let progress: Double
            if reduceMotion {
                progress = 0.45
                pulse = 0
                alpha = 0.35
            } else {
                let life = frac(t / 40 + 0.31) * 40
                guard life < 15 else { return }
                progress = life / 15
                pulse = sin(t * 1.9) * 0.10
                alpha = 0.45 * smooth(clamp01(min(progress / 0.18, (1 - progress) / 0.12)))
            }
            x = size.width * (1.08 - 1.24 * progress)
            y = size.height * (0.30 + 0.10 * sin(progress * .pi * 2 + 1))
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
        j.fill(bell, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.97, green: 0.84, blue: 0.93).opacity(0.95), location: 0),
                .init(color: Color(red: 0.90, green: 0.72, blue: 0.85).opacity(0.45), location: 0.7),
                .init(color: Color(red: 0.85, green: 0.65, blue: 0.80).opacity(0.15), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: -0.5), endPoint: CGPoint(x: 0, y: 0.3)))
        // A rim of light along the bell's lower lip.
        var lip = Path()
        lip.move(to: CGPoint(x: -0.5, y: 0.12))
        lip.addQuadCurve(to: CGPoint(x: 0.5, y: 0.12), control: CGPoint(x: 0, y: 0.30))
        j.stroke(lip, with: .color(Color(red: 0.98, green: 0.88, blue: 0.95).opacity(0.5)),
                 lineWidth: 0.04)
        for k in 0..<4 {
            let tx = -0.30 + Double(k) * 0.20
            var tent = Path()
            tent.move(to: CGPoint(x: tx, y: 0.12))
            tent.addCurve(to: CGPoint(x: tx + sin(t * 1.3 + Double(k) * 1.7) * 0.08, y: 0.85),
                          control1: CGPoint(x: tx - 0.06, y: 0.35),
                          control2: CGPoint(x: tx + 0.06, y: 0.60))
            j.stroke(tent, with: .color(Color(red: 0.9, green: 0.75, blue: 0.85).opacity(0.6)),
                     lineWidth: 0.05)
        }
        j.fill(Path(ellipseIn: CGRect(x: -0.16, y: -0.30, width: 0.32, height: 0.30)),
               with: .color(.white.opacity(0.5)))
    }

    /// Tap-dropped food: small brown pellets sinking toward the sand
    /// with a slow sway. The claim ring under a claimed pellet shows
    /// which fish is coming for it — informational only; the eat
    /// event fires in `stepSwim` when the fish actually arrives.
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
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(Color(red: 0.55, green: 0.38, blue: 0.20).opacity(a)))
            canvas.fill(
                Path(ellipseIn: CGRect(x: x - r * 0.4, y: y - r * 0.55,
                                       width: r * 0.8, height: r * 0.5)),
                with: .color(Color(red: 0.85, green: 0.68, blue: 0.42).opacity(a * 0.5)))
            if m.claims[pellet.id] != nil {
                canvas.stroke(
                    Path(ellipseIn: CGRect(x: x - r - 3, y: y - r - 3,
                                           width: (r + 3) * 2, height: (r + 3) * 2)),
                    with: .color(.white.opacity(a * 0.25)), lineWidth: 0.7)
            }
        }
    }

    /// Purchased decor (docs/TOYS.md shop), the moving half: the
    /// plant's leaves sway and the castle's pennant streams. The still
    /// pieces bake into the bed (`drawShopDecorStill`). Nothing here
    /// touches session state; it's pure dressing.
    func drawShopDecor(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        guard let game else { return }
        let tone = decorTone()
        if game.owns(.plant) {
            let x = size.width * 0.115
            let baseY = sandTop(atX: x, in: size)
            var p = canvas
            p.translateBy(x: x, y: baseY)
            // Broad, veined leaves fanning up, swaying gently, lit
            // along their near edge.
            for k in 0..<5 {
                let h = AquariumModel.stableHash("shop-plant-\(k)")
                let lean = (Double(h & 0xFF) / 0xFF - 0.5) * 1.1
                let reach = 30 + Double((h >> 8) & 0xFF) / 0xFF * 28
                let sway = reduceMotion ? 0 : sin(t * 0.9 + Double(k) * 1.4) * 3.5
                let tip = CGPoint(x: lean * reach + sway, y: -reach)
                var leaf = Path()
                leaf.move(to: .zero)
                leaf.addQuadCurve(to: tip, control: CGPoint(x: lean * reach * 0.2 - 7 + sway * 0.3, y: -reach * 0.55))
                leaf.addQuadCurve(to: .zero, control: CGPoint(x: tip.x * 0.7 + 8, y: -reach * 0.42))
                leaf.closeSubpath()
                let shade = 0.40 + Double(k) * 0.08
                p.fill(leaf, with: .linearGradient(
                    Gradient(colors: [tone(Color(red: 0.06, green: shade * 0.7, blue: 0.20)),
                                      tone(Color(red: 0.40, green: min(1, shade + 0.35), blue: 0.30))]),
                    startPoint: .zero, endPoint: tip))
                var vein = Path()
                vein.move(to: .zero)
                vein.addQuadCurve(to: tip, control: CGPoint(x: tip.x * 0.45, y: -reach * 0.5))
                p.stroke(vein, with: .color(tone(Color(red: 0.75, green: 0.95, blue: 0.60)).opacity(0.45)), lineWidth: 0.8)
                p.stroke(leaf, with: .color(tone(Color(red: 0.04, green: 0.20, blue: 0.10)).opacity(0.6)), lineWidth: 0.6)
            }
            // A crown of pebbles at the root.
            for (px, pw) in [(-7.0, 7.0), (0.0, 8.5), (7.0, 6.0)] {
                let pebble = Path(ellipseIn: CGRect(x: px - pw / 2, y: -4, width: pw, height: 5))
                TankPaint.solid(&p, pebble, lit: tone(Color(red: 0.72, green: 0.68, blue: 0.62)),
                                base: tone(Color(red: 0.48, green: 0.45, blue: 0.40)),
                                shade: tone(Color(red: 0.24, green: 0.22, blue: 0.20)), lineWidth: 0.5)
            }
        }
        if game.owns(.castle) {
            // The keep bakes into the bed; only its pennant moves.
            var c = canvas
            c.translateBy(x: size.width * 0.885, y: sandTop(atX: size.width * 0.885, in: size))
            c.scaleBy(x: size.height / 242, y: size.height / 242)
            drawCastleFlag(&c, t: t, tone: tone)
        }
    }

    /// Purchased decor, the still half — the rock a big lump with a
    /// quartz vein, the chest a smaller second treasure box, the castle
    /// a keep with its towers — baked into the cached bed pass with
    /// the rest of the dressing, so none of it costs a frame.
    func drawShopDecorStill(canvas: inout GraphicsContext, size: CGSize) {
        guard let game else { return }
        let tone = decorTone()
        if game.owns(.rock) {
            let x = size.width * 0.315
            let baseY = sandTop(atX: x, in: size)
            groundShadow(canvas: &canvas, x: x, y: baseY + 1, halfW: 30, halfH: 6, alpha: 0.34)
            var rock = Path()
            rock.move(to: CGPoint(x: x - 27, y: baseY))
            rock.addCurve(to: CGPoint(x: x - 8, y: baseY - 31),
                          control1: CGPoint(x: x - 26, y: baseY - 22),
                          control2: CGPoint(x: x - 19, y: baseY - 31))
            rock.addCurve(to: CGPoint(x: x + 14, y: baseY - 25),
                          control1: CGPoint(x: x + 2, y: baseY - 33),
                          control2: CGPoint(x: x + 10, y: baseY - 29))
            rock.addCurve(to: CGPoint(x: x + 27, y: baseY),
                          control1: CGPoint(x: x + 23, y: baseY - 17),
                          control2: CGPoint(x: x + 27, y: baseY - 6))
            rock.closeSubpath()
            TankPaint.solid(&canvas, rock, lit: tone(Color(red: 0.70, green: 0.70, blue: 0.70)),
                            base: tone(Color(red: 0.44, green: 0.45, blue: 0.47)),
                            shade: tone(Color(red: 0.16, green: 0.17, blue: 0.19)), lineWidth: 0.9, rim: 0.4)
            TankPaint.speckle(&canvas, rock, seed: 211, count: 50, size: 1.5)
            // A vein of quartz across its face, and weed at the foot.
            var vein = Path()
            vein.move(to: CGPoint(x: x - 20, y: baseY - 12))
            vein.addQuadCurve(to: CGPoint(x: x + 18, y: baseY - 20), control: CGPoint(x: x - 2, y: baseY - 10))
            var inner = canvas
            inner.clip(to: rock)
            inner.stroke(vein, with: .color(.white.opacity(0.28)), lineWidth: 1.4)
            TankPaint.moss(&canvas, clip: rock, from: x - 26, to: x + 26, y: baseY, height: 5, seed: 223, fade: 0.9)
        }
        if game.owns(.treasureChest) {
            // A second, smaller chest — the seeded one keeps the
            // milestone plume; this one is the player's trophy.
            let x = size.width * 0.68
            let baseY = sandTop(atX: x, in: size)
            groundShadow(canvas: &canvas, x: x, y: baseY + 1, halfW: 18, halfH: 4, alpha: 0.32)
            var c = canvas
            c.translateBy(x: x, y: baseY)
            c.scaleBy(x: 0.72, y: 0.72)
            Self.paintChest(&c, width: 40, height: 26, open: 0.12, t: 0, reduceMotion: true, tone: tone)
        }
        if game.owns(.castle) {
            let x = size.width * 0.885
            let baseY = sandTop(atX: x, in: size)
            groundShadow(canvas: &canvas, x: x - 2 * size.height / 242, y: baseY + 2,
                         halfW: 40 * size.height / 242, halfH: 7, alpha: 0.32)
            var c = canvas
            c.translateBy(x: x, y: baseY)
            // Sized off the tank like the rest of the owned set —
            // ~130 px tall at 700, the keep a landmark, not a trinket.
            c.scaleBy(x: size.height / 242, y: size.height / 242)
            drawCastle(&c)
        }
    }

    /// The shop's castle: a crenellated keep between a round tower
    /// under a tiled cone and a squat side tower, dressed stone lit
    /// from the surface, lamp-lit windows, an arched gate with a
    /// portcullis, moss creeping up from the sand and a pennant that
    /// streams in the current. Local units, origin at the gate's foot.
    private func drawCastle(_ c: inout GraphicsContext) {
        let tone = decorTone()
        let lit = tone(Color(red: 0.86, green: 0.83, blue: 0.86))
        let base = tone(Color(red: 0.66, green: 0.63, blue: 0.70))
        let shade = tone(Color(red: 0.38, green: 0.36, blue: 0.46))
        let line = tone(Color(red: 0.16, green: 0.14, blue: 0.22)).opacity(0.75)
        let warm = Color(red: 1.0, green: 0.78, blue: 0.40)
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
        func window(_ cx: Double, _ top: Double, _ w: Double, _ h: Double) {
            var win = Path()
            win.move(to: CGPoint(x: cx - w / 2, y: top + h))
            win.addLine(to: CGPoint(x: cx - w / 2, y: top + w / 2))
            win.addArc(center: CGPoint(x: cx, y: top + w / 2), radius: w / 2,
                       startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            win.addLine(to: CGPoint(x: cx + w / 2, y: top + h))
            win.closeSubpath()
            c.fill(win, with: .linearGradient(
                Gradient(colors: [warm, Color(red: 0.85, green: 0.45, blue: 0.18)]),
                startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: top + h)))
            c.stroke(win, with: .color(line), lineWidth: 0.6)
            TankPaint.glow(&c, at: CGPoint(x: cx, y: top + h * 0.5), radius: w * 2.4,
                           color: warm.opacity(0.28))
        }

        // The squat side tower on the right, behind the keep.
        let right = crenellated(12, 27, top: -27, merlon: 3)
        TankPaint.solid(&c, right, lit: lit, base: base, shade: shade, outline: line, lineWidth: 0.7)
        TankPaint.courses(&c, right, rect: CGRect(x: 12, y: -27, width: 15, height: 27),
                          rowHeight: 3.6, blockWidth: 6, lineWidth: 0.35, seed: 11)
        window(21, -21, 3, 5)

        // The round tower on the left: a cylinder under a tiled cone.
        let towerRect = CGRect(x: -31, y: -33, width: 14, height: 33)
        let tower = Path(roundedRect: towerRect, cornerRadius: 1)
        TankPaint.cylinder(&c, tower, lit: lit, base: base, shade: shade, outline: line, lineWidth: 0.7)
        TankPaint.courses(&c, tower, rect: towerRect, rowHeight: 3.6, blockWidth: 5, lineWidth: 0.35, seed: 23)
        window(-24, -26, 3, 5.5)
        var cone = Path()
        cone.move(to: CGPoint(x: -33, y: -32))
        cone.addQuadCurve(to: CGPoint(x: -24, y: -52), control: CGPoint(x: -29, y: -40))
        cone.addQuadCurve(to: CGPoint(x: -15, y: -32), control: CGPoint(x: -19, y: -40))
        cone.closeSubpath()
        TankPaint.cylinder(&c, cone, lit: tone(Color(red: 0.92, green: 0.46, blue: 0.36)),
                           base: tone(Color(red: 0.74, green: 0.28, blue: 0.24)),
                           shade: tone(Color(red: 0.40, green: 0.12, blue: 0.14)), outline: line, lineWidth: 0.7)
        var tiles = c
        tiles.clip(to: cone)
        var tileLines = Path()
        for k in 1..<5 {
            let y = -32.0 - Double(k) * 4
            tileLines.move(to: CGPoint(x: -34, y: y + 1.2))
            tileLines.addQuadCurve(to: CGPoint(x: -14, y: y + 1.2), control: CGPoint(x: -24, y: y + 2.6))
        }
        tiles.stroke(tileLines, with: .color(.black.opacity(0.28)), lineWidth: 0.4)
        // The pennant's pole; the pennant itself streams on the live
        // pass (`drawCastleFlag`).
        var pole = Path()
        pole.move(to: CGPoint(x: -24, y: -51))
        pole.addLine(to: CGPoint(x: -24, y: -62))
        c.stroke(pole, with: .color(tone(Color(red: 0.28, green: 0.24, blue: 0.20))), lineWidth: 0.8)

        // The keep, a little tapered, crenellated.
        let keep = crenellated(-14, 14, top: -40, merlon: 3.5)
        TankPaint.solid(&c, keep, lit: lit, base: base, shade: shade, outline: line, lineWidth: 0.8)
        TankPaint.courses(&c, keep, rect: CGRect(x: -14, y: -44, width: 28, height: 44),
                          rowHeight: 4, blockWidth: 7, lineWidth: 0.38, seed: 37)
        TankPaint.speckle(&c, keep, seed: 41, count: 40, size: 0.8)
        // A string course under the battlements.
        c.fill(Path(CGRect(x: -15, y: -37, width: 30, height: 2)), with: .color(shade.opacity(0.85)))
        c.fill(Path(CGRect(x: -15, y: -37, width: 30, height: 0.7)), with: .color(lit.opacity(0.9)))
        window(-6, -31, 3.2, 6)
        window(6, -31, 3.2, 6)
        // The gate: a dark arch with a raised portcullis and lamplight.
        var gate = Path()
        gate.move(to: CGPoint(x: -5.5, y: 0))
        gate.addLine(to: CGPoint(x: -5.5, y: -10))
        gate.addArc(center: CGPoint(x: 0, y: -10), radius: 5.5,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        gate.addLine(to: CGPoint(x: 5.5, y: 0))
        gate.closeSubpath()
        c.fill(gate, with: .linearGradient(
            Gradient(colors: [tone(Color(red: 0.10, green: 0.07, blue: 0.10)), tone(Color(red: 0.42, green: 0.22, blue: 0.10))]),
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
        grid.stroke(bars, with: .color(tone(Color(red: 0.25, green: 0.22, blue: 0.24))), lineWidth: 0.6)
        TankPaint.glow(&c, at: CGPoint(x: 0, y: -2), radius: 9, color: warm.opacity(0.22))
        // The arch's voussoirs.
        var arch = Path()
        arch.addArc(center: CGPoint(x: 0, y: -10), radius: 6.6,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        c.stroke(arch, with: .color(shade), lineWidth: 2)
        c.stroke(arch, with: .color(line), lineWidth: 0.5)

        // Moss up every foot, a few rocks at the base.
        TankPaint.moss(&c, clip: nil, from: -33, to: 28, y: 0.5, height: 4.5, seed: 53)
        for (rx, rw) in [(-36.0, 7.0), (29.0, 6.0), (10.0, 4.5)] {
            let rock = Path(ellipseIn: CGRect(x: rx - rw / 2, y: -rw * 0.55, width: rw, height: rw * 0.75))
            TankPaint.solid(&c, rock, lit: tone(Color(red: 0.62, green: 0.60, blue: 0.58)),
                            base: tone(Color(red: 0.42, green: 0.40, blue: 0.40)),
                            shade: tone(Color(red: 0.20, green: 0.19, blue: 0.20)), outline: line, lineWidth: 0.5)
        }
    }

    /// The castle's pennant, streaming in the current — in the keep's
    /// local units, over the baked keep.
    private func drawCastleFlag(_ c: inout GraphicsContext, t: Double, tone: TankPaint.Tone) {
        let line = Color(red: 0.16, green: 0.14, blue: 0.22).opacity(0.75)
        let flutter = reduceMotion ? 0 : sin(t * 2.6) * 1.2
        var flag = Path()
        flag.move(to: CGPoint(x: -24, y: -62))
        flag.addQuadCurve(to: CGPoint(x: -13, y: -59 + flutter), control: CGPoint(x: -18, y: -63 - flutter))
        flag.addQuadCurve(to: CGPoint(x: -24, y: -56.5), control: CGPoint(x: -18, y: -56 + flutter))
        flag.closeSubpath()
        c.fill(flag, with: .linearGradient(
            Gradient(colors: [tone(Color(red: 0.95, green: 0.32, blue: 0.36)), tone(Color(red: 0.70, green: 0.14, blue: 0.22))]),
            startPoint: CGPoint(x: -24, y: -60), endPoint: CGPoint(x: -13, y: -58)))
        c.stroke(flag, with: .color(line), lineWidth: 0.5)
    }

    /// A treasure chest in local units, its foot at the origin: plank
    /// body and domed lid with wood grain, brass bands and corners with
    /// rivets, a lock plate — and, when `open` lifts the lid, gold
    /// glinting in the gap.
    static func paintChest(_ c: inout GraphicsContext, width w: Double, height h: Double,
                           open: Double, t: Double, reduceMotion: Bool,
                           tone: TankPaint.Tone = .none) {
        let woodLit = tone(Color(red: 0.70, green: 0.46, blue: 0.24))
        let wood = tone(Color(red: 0.46, green: 0.29, blue: 0.14))
        let woodDark = tone(Color(red: 0.20, green: 0.12, blue: 0.05))
        let brassLit = tone(Color(red: 1.0, green: 0.88, blue: 0.52))
        let brass = tone(Color(red: 0.80, green: 0.60, blue: 0.24))
        let brassDark = tone(Color(red: 0.40, green: 0.26, blue: 0.08))
        let line = tone(Color(red: 0.14, green: 0.08, blue: 0.03)).opacity(0.85)
        let bodyTop = -h * 0.60
        let body = Path(roundedRect: CGRect(x: -w / 2, y: bodyTop, width: w, height: h * 0.60), cornerRadius: w * 0.05)
        if open > 0 {
            // The hoard in the gap, glowing.
            let gap = Path(CGRect(x: -w / 2 + 2, y: bodyTop - h * 0.14 * open, width: w - 4, height: h * 0.16 * open + 1))
            c.fill(gap, with: .linearGradient(Gradient(colors: [brassLit, brass]),
                                              startPoint: CGPoint(x: 0, y: bodyTop - 4), endPoint: CGPoint(x: 0, y: bodyTop + 1)))
            TankPaint.glow(&c, at: CGPoint(x: 0, y: bodyTop - 2), radius: w * 0.5, color: brassLit.opacity(0.35))
        }
        TankPaint.solid(&c, body, lit: woodLit, base: wood, shade: woodDark, outline: line, lineWidth: w * 0.02)
        TankPaint.grain(&c, body, from: CGPoint(x: -w / 2, y: bodyTop + 3), to: CGPoint(x: w / 2, y: bodyTop + 2),
                        spacing: h * 0.07, width: w * 0.006, seed: 227, color: woodDark.opacity(0.35))
        var planks = c
        planks.clip(to: body)
        var seams = Path()
        for k in 1..<3 {
            let y = bodyTop + h * 0.2 * Double(k)
            seams.move(to: CGPoint(x: -w / 2, y: y)); seams.addLine(to: CGPoint(x: w / 2, y: y))
        }
        planks.stroke(seams, with: .color(woodDark.opacity(0.6)), lineWidth: w * 0.015)
        // The lid, raised by `open` about its back edge.
        var lidCtx = c
        lidCtx.translateBy(x: 0, y: bodyTop)
        lidCtx.rotate(by: .radians(-open * 0.35))
        var lid = Path()
        lid.move(to: CGPoint(x: -w / 2 - w * 0.04, y: 0))
        lid.addQuadCurve(to: CGPoint(x: w / 2 + w * 0.04, y: 0), control: CGPoint(x: 0, y: -h * 0.64))
        lid.closeSubpath()
        TankPaint.solid(&lidCtx, lid, lit: tone(Color(red: 0.80, green: 0.56, blue: 0.30)), base: wood, shade: woodDark,
                        outline: line, lineWidth: w * 0.02, rim: 0.45)
        TankPaint.grain(&lidCtx, lid, from: CGPoint(x: -w / 2, y: -h * 0.12), to: CGPoint(x: w / 2, y: -h * 0.14),
                        spacing: h * 0.07, width: w * 0.006, seed: 229, color: woodDark.opacity(0.35))
        // Brass: two bands over lid and body, corners, the lock plate.
        for bandX in [-0.30, 0.30] as [Double] {
            let bx = w * bandX
            let strap = Path(CGRect(x: bx - w * 0.055, y: bodyTop, width: w * 0.11, height: h * 0.60))
            TankPaint.cylinder(&c, strap, lit: brassLit, base: brass, shade: brassDark, outline: line, lineWidth: w * 0.012)
            // Over the lid the strap runs straight up its face to the
            // dome's silhouette.
            var over = lidCtx
            over.clip(to: lid)
            let lidStrap = Path(CGRect(x: bx - w * 0.055, y: -h * 0.7, width: w * 0.11, height: h * 0.7))
            TankPaint.cylinder(&over, lidStrap, lit: brassLit, base: brass, shade: brassDark, outline: line,
                               lineWidth: w * 0.012)
            var rivets = Path()
            for k in 0..<3 {
                let ry = bodyTop + h * 0.1 + Double(k) * h * 0.18
                rivets.addEllipse(in: CGRect(x: bx - w * 0.018, y: ry - w * 0.018, width: w * 0.036, height: w * 0.036))
            }
            c.fill(rivets, with: .color(brassLit))
        }
        let plate = Path(roundedRect: CGRect(x: -w * 0.1, y: bodyTop - h * 0.06, width: w * 0.2, height: h * 0.24),
                         cornerRadius: w * 0.03)
        TankPaint.solid(&c, plate, lit: brassLit, base: brass, shade: brassDark, outline: line, lineWidth: w * 0.012)
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
