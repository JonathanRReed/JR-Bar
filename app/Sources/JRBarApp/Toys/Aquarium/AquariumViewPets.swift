import AppKit
import JRBarCore
import SwiftUI

/// The pets bought in the shop.
extension AquariumView {
    // MARK: Shop pets

    /// The sea turtle: a slow glide across midwater on a long lazy
    /// sweep, rising for a breath every minute or so — a patient
    /// silhouette behind the fish lane.
    func drawSeaTurtle(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let period = 90.0
        let phase = frac(t / period)
        // The glide: across the tank one way, back the next.
        let leg = frac(phase * 2)
        let dir = phase < 0.5 ? 1.0 : -1.0
        let x = size.width * (phase < 0.5 ? leg : 1 - leg)
        // Mostly mid-depth; the last stretch of each leg climbs to
        // sip the surface and sinks back.
        let breathe = smooth(clamp01((leg - 0.72) / 0.10))
            * smooth(clamp01((0.98 - leg) / 0.10))
        let baseY = size.height * 0.42
        let y = reduceMotion ? baseY
            : baseY + sin(t * 0.4) * 14 - breathe * (baseY - 46)
        let flap = reduceMotion ? 0 : sin(t * 2.4) * 0.35
        var c = canvas
        c.translateBy(x: x, y: y)
        c.scaleBy(x: dir, y: 1)
        c.opacity = 0.85
        let skinLit = Color(red: 0.70, green: 0.76, blue: 0.52)
        let skin = Color(red: 0.44, green: 0.52, blue: 0.34)
        let skinDark = Color(red: 0.20, green: 0.26, blue: 0.16)
        let line = Color(red: 0.10, green: 0.14, blue: 0.08).opacity(0.8)
        // Flippers behind the shell so the dome sits on top — broad
        // front paddles, small rear ones, each with a pale margin.
        var front = Path()
        front.move(to: CGPoint(x: 6, y: 3))
        front.addCurve(to: CGPoint(x: 26, y: 15 + flap * 10),
                       control1: CGPoint(x: 16, y: 0), control2: CGPoint(x: 24, y: 6 + flap * 6))
        front.addQuadCurve(to: CGPoint(x: 8, y: 10), control: CGPoint(x: 16, y: 13))
        front.closeSubpath()
        TankPaint.solid(&c, front, lit: skinLit, base: skin, shade: skinDark, outline: line, lineWidth: 0.7)
        var rear = Path()
        rear.move(to: CGPoint(x: -12, y: 4))
        rear.addQuadCurve(to: CGPoint(x: -24, y: 11 - flap * 6), control: CGPoint(x: -19, y: 2))
        rear.addQuadCurve(to: CGPoint(x: -12, y: 9), control: CGPoint(x: -16, y: 10))
        rear.closeSubpath()
        TankPaint.solid(&c, rear, lit: skinLit, base: skin, shade: skinDark, outline: line, lineWidth: 0.6)
        // The head: a blunt beak, a patterned cheek, a dark kind eye.
        let head = Path(ellipseIn: CGRect(x: 15, y: -6, width: 12, height: 9))
        TankPaint.solid(&c, head, lit: skinLit, base: skin, shade: skinDark, outline: line, lineWidth: 0.7, rim: 0.4)
        var scales = c
        scales.clip(to: head)
        var plates = Path()
        for (px, py) in [(17.5, -3.5), (20.0, -1.0), (17.0, 0.5), (22.5, -4.0)] as [(Double, Double)] {
            plates.addEllipse(in: CGRect(x: px - 1.4, y: py - 1, width: 2.8, height: 2))
        }
        scales.stroke(plates, with: .color(skinDark.opacity(0.6)), lineWidth: 0.4)
        c.fill(Path(ellipseIn: CGRect(x: 21.6, y: -3.6, width: 2.6, height: 2.6)),
               with: .color(Color(red: 0.05, green: 0.06, blue: 0.05)))
        c.fill(Path(ellipseIn: CGRect(x: 22.6, y: -3.2, width: 0.9, height: 0.9)),
               with: .color(.white.opacity(0.85)))
        var beak = Path()
        beak.move(to: CGPoint(x: 25.5, y: 0.5)); beak.addQuadCurve(to: CGPoint(x: 22, y: 1.4), control: CGPoint(x: 24, y: 1.8))
        c.stroke(beak, with: .color(line), lineWidth: 0.5)
        // The carapace: a domed shell with a rim, scutes down the
        // spine and along the flanks, lit on its crown.
        let dome = Path(ellipseIn: CGRect(x: -19, y: -13, width: 40, height: 23))
        let rim = Path(ellipseIn: CGRect(x: -20, y: -9, width: 42, height: 20))
        TankPaint.solid(&c, rim, lit: Color(red: 0.82, green: 0.72, blue: 0.44),
                        base: Color(red: 0.56, green: 0.46, blue: 0.24),
                        shade: Color(red: 0.26, green: 0.20, blue: 0.10), outline: line, lineWidth: 0.7, rim: 0)
        TankPaint.solid(&c, dome, lit: Color(red: 0.62, green: 0.60, blue: 0.30),
                        base: Color(red: 0.38, green: 0.40, blue: 0.20),
                        shade: Color(red: 0.14, green: 0.16, blue: 0.08), outline: line, lineWidth: 0.9, rim: 0.45)
        var shellInner = c
        shellInner.clip(to: dome)
        var scutes = Path()
        // The spine's row of hexagons.
        for k in -1...1 {
            let cx = Double(k) * 10 + 1
            let cy = -3.5 + abs(Double(k)) * 0.8
            for v in 0..<6 {
                let a = Double(v) / 6 * .pi * 2 + .pi / 6
                let pt = CGPoint(x: cx + cos(a) * 5.4, y: cy + sin(a) * 4.2)
                if v == 0 { scutes.move(to: pt) } else { scutes.addLine(to: pt) }
            }
            scutes.closeSubpath()
        }
        // The flank scutes: spokes from the spine row to the rim.
        for k in 0..<6 {
            let x0 = -14.0 + Double(k) * 6
            scutes.move(to: CGPoint(x: x0 + 2, y: 1))
            scutes.addLine(to: CGPoint(x: x0, y: 10))
        }
        shellInner.fill(scutes, with: .color(Color(red: 0.72, green: 0.66, blue: 0.34).opacity(0.18)))
        shellInner.stroke(scutes, with: .color(Color(red: 0.10, green: 0.12, blue: 0.05).opacity(0.55)), lineWidth: 0.7)
        TankPaint.speckle(&shellInner, dome, seed: 233, count: 26, size: 1.0,
                          dark: Color(red: 0.10, green: 0.10, blue: 0.04).opacity(0.3),
                          light: Color(red: 0.95, green: 0.90, blue: 0.60).opacity(0.25))
        // The breath: two bubbles off the nose on the way down.
        if breathe > 0.5 && !reduceMotion {
            for k in 0..<2 {
                let bp = frac(t * 0.9 + Double(k) * 0.5)
                var b = canvas
                b.opacity = (1 - bp) * 0.5
                b.stroke(Path(ellipseIn: CGRect(x: x + dir * 20 - 2 - bp * 4,
                                                y: y - 8 - bp * 30,
                                                width: 3 + bp * 3, height: 3 + bp * 3)),
                         with: .color(.white), lineWidth: 0.7)
            }
        }
    }

    /// The octopus: it keeps house in the amphora when the tank has
    /// one, else behind the first seeded rock. Every ~minute two eyes
    /// peek over the rim; every few it pours out, crawls a short arc
    /// across the sand, and pours back. It shades toward the
    /// substrate like the real thing.
    func drawOctopus(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        // Home: the amphora's slot, else the first rock's lee.
        let homeX: Double
        let homeY: Double
        if game?.owns(.amphora) == true,
           let s = AquariumModel.decorSlot(for: .amphora) {
            homeX = s.x * size.width
            homeY = backDuneTop(atX: s.x * size.width, in: size) - 4
        } else if let rock = Self.decor.first(where: { $0.kind == .rock }) {
            homeX = rock.x * size.width - 18
            homeY = decorBaseY(rock, in: size) - 2
        } else {
            homeX = size.width * 0.33
            homeY = sandTop(atX: homeX, in: size)
        }
        // Substrate camouflage: paler on white, darker on black.
        let mantle = substrateKey == "white"
            ? Color(red: 0.72, green: 0.55, blue: 0.48)
            : substrateKey == "black"
                ? Color(red: 0.32, green: 0.20, blue: 0.20)
                : Color(red: 0.58, green: 0.36, blue: 0.32)
        let dark = Color(red: 0.34, green: 0.20, blue: 0.18)

        // The wander: a seeded ~4-minute cycle — long home, a crawl
        // out, a pause in the open, a crawl home.
        let cycle = 240.0
        let p = frac(t / cycle + 0.31)
        // Out: p .60–.68 crawls out, .68–.82 sits out, .82–.90 crawls home.
        let outX = homeX + (homeX < size.width * 0.5 ? 1 : -1) * size.width * 0.09
        let outY = sandTop(atX: outX, in: size) - 6
        var pos = CGPoint(x: homeX, y: homeY)
        var crawl = 0.0
        if p >= 0.60, p < 0.68 {
            let k = smooth(clamp01((p - 0.60) / 0.08))
            pos = CGPoint(x: homeX + (outX - homeX) * k,
                          y: homeY + (outY - homeY) * k)
            crawl = reduceMotion ? 0 : sin(k * .pi * 6) * 0.5
        } else if p >= 0.68, p < 0.82 {
            pos = CGPoint(x: outX, y: outY)
        } else if p >= 0.82, p < 0.90 {
            let k = smooth(clamp01((p - 0.82) / 0.08))
            pos = CGPoint(x: outX + (homeX - outX) * k,
                          y: outY + (homeY - outY) * k)
            crawl = reduceMotion ? 0 : sin(k * .pi * 6) * 0.5
        }
        let out = pos.x != homeX
        // The peek: while home, eyes ride over the rim for a stretch
        // of each ~70 s sub-cycle.
        let peek = !out && frac(t / 68) < 0.5
        var c = canvas
        c.translateBy(x: pos.x, y: pos.y)
        c.opacity = out ? 0.97 : 0.92
        let mantleLit = substrateKey == "white"
            ? Color(red: 0.94, green: 0.78, blue: 0.70)
            : substrateKey == "black"
                ? Color(red: 0.56, green: 0.40, blue: 0.38)
                : Color(red: 0.86, green: 0.56, blue: 0.48)
        let line = Color(red: 0.16, green: 0.06, blue: 0.06).opacity(0.75)
        func octoEye(_ ex: Double, _ ey: Double, open: Double) {
            let white = Path(ellipseIn: CGRect(x: ex - 2.2, y: ey - 2.6, width: 4.4, height: 5.2))
            c.fill(white, with: .color(Color(red: 0.98, green: 0.94, blue: 0.80).opacity(open)))
            c.stroke(white, with: .color(line.opacity(open)), lineWidth: 0.4)
            // The octopus's sideways slot of a pupil.
            c.fill(Path(roundedRect: CGRect(x: ex - 1.5, y: ey - 0.5, width: 3, height: 1.2), cornerRadius: 0.6),
                   with: .color(Color(red: 0.05, green: 0.04, blue: 0.04).opacity(open)))
            c.fill(Path(ellipseIn: CGRect(x: ex - 1.2, y: ey - 1.9, width: 1, height: 0.9)),
                   with: .color(.white.opacity(0.9 * open)))
        }
        if out {
            // Crawling: the mantle low over eight curling arms, suckers
            // pale along their undersides.
            for i in 0..<8 {
                let ph = Double(i) / 8 * .pi * 2 + crawl * 2
                let tip = CGPoint(x: cos(ph) * 14, y: 5 + sin(ph) * 4)
                var arm = Path()
                arm.move(to: CGPoint(x: cos(ph) * 3, y: -1))
                arm.addQuadCurve(to: tip, control: CGPoint(x: cos(ph) * 9, y: 1.5))
                arm.addQuadCurve(to: CGPoint(x: tip.x - cos(ph) * 1.5, y: tip.y - 2.5),
                                 control: CGPoint(x: tip.x + cos(ph) * 2, y: tip.y - 1.2))
                c.stroke(arm, with: .color(line), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                c.stroke(arm, with: .linearGradient(Gradient(colors: [mantle, mantleLit]),
                                                    startPoint: .zero, endPoint: tip),
                         style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                var suckers = Path()
                for k in 1...3 {
                    let u = Double(k) / 4
                    suckers.addEllipse(in: CGRect(x: cos(ph) * (3 + 9 * u) - 0.5, y: 0.8 + u * 3.5 + sin(ph) * u * 3,
                                                  width: 1, height: 1))
                }
                c.fill(suckers, with: .color(Color(red: 1.0, green: 0.88, blue: 0.80).opacity(0.7)))
            }
            let head = Path(ellipseIn: CGRect(x: -8, y: -17, width: 16, height: 16))
            TankPaint.solid(&c, head, lit: mantleLit, base: mantle, shade: dark, outline: line, lineWidth: 0.6, rim: 0.4)
            TankPaint.speckle(&c, head, seed: 239, count: 14, size: 1.3,
                              dark: dark.opacity(0.5), light: mantleLit.opacity(0.4))
            octoEye(-3.4, -7.5, open: 1)
            octoEye(3.4, -7.5, open: 1)
        } else {
            // Home: the mantle slumped in/behind the pot, eyes up on a
            // peek, sunk below otherwise.
            let eyeLift = peek ? -10.0 : -3.0
            let head = Path(ellipseIn: CGRect(x: -8, y: -10, width: 16, height: 11))
            c.opacity = peek ? 0.95 : 0.55
            TankPaint.solid(&c, head, lit: mantleLit, base: mantle, shade: dark, outline: line, lineWidth: 0.5, rim: 0.3)
            octoEye(-4, eyeLift, open: peek ? 1 : 0.35)
            octoEye(4, eyeLift, open: peek ? 1 : 0.35)
        }
    }

    /// The axolotl: a wide pink smile on legs, three gill fronds a
    /// cheek waving as it ambles the sand on a long seeded patrol;
    /// every so often it kicks up and settles a body-width over.
    func drawAxolotl(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let period = 160.0
        let p = frac(t / period)
        // Amble mostly in place; a kick-hop at p .5 moves the yard.
        let home = size.width * 0.30
        let kick = smooth(clamp01((p - 0.48) / 0.03))
            * smooth(clamp01((0.56 - p) / 0.03))
        let x = home + 30 * smooth(clamp01(p / 0.5)) * 2 - 15
        let baseY = sandTop(atX: x, in: size) - 7
        let y = reduceMotion ? baseY : baseY - kick * 26
        var c = canvas
        c.translateBy(x: x, y: y)
        c.opacity = 0.92
        let pinkLit = Color(red: 1.0, green: 0.82, blue: 0.84)
        let pink = Color(red: 0.94, green: 0.62, blue: 0.66)
        let pinkDark = Color(red: 0.62, green: 0.30, blue: 0.36)
        let frill = Color(red: 0.98, green: 0.36, blue: 0.48)
        let line = Color(red: 0.36, green: 0.14, blue: 0.18).opacity(0.75)
        // The tail: a finned paddle sweeping behind.
        let swish = reduceMotion ? 0 : sin(t * 1.8) * 2
        var tail = Path()
        tail.move(to: CGPoint(x: -10, y: -6))
        tail.addQuadCurve(to: CGPoint(x: -30, y: -8 + swish), control: CGPoint(x: -20, y: -9))
        tail.addQuadCurve(to: CGPoint(x: -10, y: 1), control: CGPoint(x: -20, y: -1 + swish))
        tail.closeSubpath()
        TankPaint.solid(&c, tail, lit: pinkLit, base: pink, shade: pinkDark, outline: line, lineWidth: 0.6)
        // Four little legs with splayed toes, stepping while it walks.
        for k in 0..<2 {
            let step = reduceMotion ? 0 : sin(t * 3 + Double(k) * .pi) * 1.5
            let lx = -4 + Double(k) * 13
            var leg = Path()
            leg.move(to: CGPoint(x: lx, y: 1))
            leg.addQuadCurve(to: CGPoint(x: lx + 2 + step, y: 6.5), control: CGPoint(x: lx - 1, y: 4))
            c.stroke(leg, with: .color(line), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            c.stroke(leg, with: .color(pink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            var toes = Path()
            for toe in [-1.4, 0.0, 1.4] {
                toes.move(to: CGPoint(x: lx + 2 + step, y: 6.5)); toes.addLine(to: CGPoint(x: lx + 2 + step + toe, y: 8))
            }
            c.stroke(toes, with: .color(pinkDark), lineWidth: 0.6)
        }
        // Body & wide head.
        let body = Path(ellipseIn: CGRect(x: -12, y: -9, width: 28, height: 12))
        TankPaint.solid(&c, body, lit: pinkLit, base: pink, shade: pinkDark, outline: line, lineWidth: 0.6, rim: 0.4)
        // Gill fronds behind the head, waving on their own phase.
        for side in [-1.0, 1.0] {
            for k in 0..<3 {
                let wave = reduceMotion ? 0 : sin(t * 2.6 + Double(k) * 1.2 + side) * 2
                var fr = Path()
                let gy = -12 + Double(k) * 4
                fr.move(to: CGPoint(x: 13 + side * 3, y: gy))
                fr.addQuadCurve(to: CGPoint(x: 13 + side * (12 + Double(k) * 2), y: gy - 4 + wave),
                                control: CGPoint(x: 13 + side * 8, y: gy - 2))
                c.stroke(fr, with: .color(Color(red: 0.60, green: 0.12, blue: 0.24)),
                         style: StrokeStyle(lineWidth: 3.0, lineCap: .round))
                c.stroke(fr, with: .color(frill), style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
                // The feathery filaments along each frond.
                var fringe = Path()
                for u in [0.35, 0.6, 0.85] {
                    let fx = 13 + side * (3 + (9 + Double(k) * 2) * u)
                    let fy = gy - 3 * u + wave * u
                    fringe.move(to: CGPoint(x: fx, y: fy)); fringe.addLine(to: CGPoint(x: fx + side * 0.8, y: fy - 1.8))
                }
                c.stroke(fringe, with: .color(Color(red: 1.0, green: 0.62, blue: 0.70)), lineWidth: 0.6)
            }
        }
        let head = Path(ellipseIn: CGRect(x: 3, y: -14, width: 21, height: 16))
        TankPaint.solid(&c, head, lit: pinkLit, base: pink, shade: pinkDark, outline: line, lineWidth: 0.6, rim: 0.45)
        // The famous smile, bead eyes and a blush.
        for ex in [15.5, 21.0] {
            c.fill(Path(ellipseIn: CGRect(x: ex - 1.5, y: -9.5, width: 3, height: 3)),
                   with: .color(Color(red: 0.08, green: 0.05, blue: 0.08)))
            c.fill(Path(ellipseIn: CGRect(x: ex - 0.7, y: -9.1, width: 1, height: 1)),
                   with: .color(.white.opacity(0.9)))
        }
        c.fill(Path(ellipseIn: CGRect(x: 11, y: -5.5, width: 4, height: 2.4)),
               with: .color(Color(red: 1.0, green: 0.42, blue: 0.52).opacity(0.45)))
        var smile = Path()
        smile.move(to: CGPoint(x: 14.5, y: -4.2))
        smile.addQuadCurve(to: CGPoint(x: 23.5, y: -4.2), control: CGPoint(x: 19, y: -0.8))
        c.stroke(smile, with: .color(Color(red: 0.50, green: 0.20, blue: 0.26)),
                 style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        // The kicked-up sand puff as it lands.
        if kick > 0.5 && !reduceMotion {
            for k in 0..<4 {
                let a = Double(k) * .pi * 0.5 + 0.3
                var s = canvas
                s.opacity = (kick - 0.5) * 0.6
                s.fill(Path(ellipseIn: CGRect(x: x + cos(a) * 14 - 2,
                                              y: baseY + 2 - sin(a) * 6,
                                              width: 4, height: 4)),
                       with: .color(sandTones.speckDark))
            }
        }
    }

    /// The tetra school: seven little neons sharing one wander
    /// target, each orbiting the pack on its own phase — cohesion as
    /// a swarm, not a queue.
    func drawTetraSchool(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        // The pack's shared target sweeps the midwater slowly.
        let cx = size.width * (0.5 + 0.28 * sin(t * 0.09))
        let cy = size.height * (0.42 + 0.10 * sin(t * 0.13 + 1.7))
        let heading = cos(t * 0.09) >= 0 ? 1.0 : -1.0
        for i in 0..<7 {
            let h = scatter(AquariumModel.stableHash("tetra"), i)
            let orbit = 12 + Double(h & 0xFF) / 0xFF * 26
            let phase = Double((h >> 8) & 0xFF) / 0xFF * .pi * 2
            let speed = 1.2 + Double((h >> 16) & 0xFF) / 0xFF * 1.4
            let wobble = reduceMotion ? 0.0 : t * speed
            let fx = cx + cos(wobble + phase) * orbit
            let fy = cy + sin(wobble * 1.3 + phase) * orbit * 0.45
            let len = 13.0
            let face = heading
            var c = canvas
            c.translateBy(x: fx, y: fy)
            c.scaleBy(x: face, y: 1)
            c.opacity = 0.9
            // A silver body, the neon line glowing along it, the red
            // rear half, a clear tail and a bright eye.
            var tail = Path()
            tail.move(to: CGPoint(x: -len * 0.40, y: 0))
            tail.addLine(to: CGPoint(x: -len * 0.66, y: -len * 0.20))
            tail.addQuadCurve(to: CGPoint(x: -len * 0.66, y: len * 0.20), control: CGPoint(x: -len * 0.56, y: 0))
            tail.closeSubpath()
            c.fill(tail, with: .color(Color(red: 0.85, green: 0.90, blue: 0.95).opacity(0.45)))
            let bodyPath = Path(ellipseIn: CGRect(x: -len / 2, y: -len * 0.21, width: len, height: len * 0.42))
            c.fill(bodyPath, with: .linearGradient(
                Gradient(colors: [Color(red: 0.62, green: 0.70, blue: 0.78), Color(red: 0.94, green: 0.96, blue: 0.98)]),
                startPoint: CGPoint(x: 0, y: -len * 0.21), endPoint: CGPoint(x: 0, y: len * 0.21)))
            var inner = c
            inner.clip(to: bodyPath)
            inner.fill(Path(CGRect(x: -len / 2, y: len * 0.02, width: len * 0.55, height: len * 0.2)),
                       with: .color(Color(red: 0.92, green: 0.22, blue: 0.22).opacity(0.85)))
            var glow = inner
            glow.blendMode = .plusLighter
            glow.fill(Path(roundedRect: CGRect(x: -len * 0.42, y: -len * 0.10, width: len * 0.84, height: len * 0.11),
                           cornerRadius: len * 0.055),
                      with: .color(Color(red: 0.15, green: 0.85, blue: 1.0).opacity(0.95)))
            c.stroke(bodyPath, with: .color(Color(red: 0.20, green: 0.26, blue: 0.32).opacity(0.55)), lineWidth: 0.4)
            c.fill(Path(ellipseIn: CGRect(x: len * 0.24, y: -len * 0.11, width: 2.2, height: 2.2)),
                   with: .color(Color(red: 0.05, green: 0.06, blue: 0.08)))
            c.fill(Path(ellipseIn: CGRect(x: len * 0.24 + 1.1, y: -len * 0.11 + 0.3, width: 0.8, height: 0.8)),
                   with: .color(.white))
        }
    }

    /// The cleaner shrimp: it keeps station on a decor piece, then
    /// every ~40 s hops to the nearest idle fish, rides it a few
    /// seconds picking, and springs home.
    func drawCleanerShrimp(canvas: inout GraphicsContext, size: CGSize,
                                   t: Double, layouts: [String: Layout],
                                   roster: [Fish], now: Date) {
        // Station: the first seeded coral or rock's top.
        let station: CGPoint
        if let perch = Self.decor.first(where: { $0.kind == .coral || $0.kind == .rock }) {
            station = CGPoint(x: perch.x * size.width,
                              y: decorBaseY(perch, in: size) - 14 * perch.scale)
        } else {
            station = CGPoint(x: size.width * 0.2,
                              y: sandTop(atX: size.width * 0.2, in: size) - 10)
        }
        // The client: the shallowest idling fish.
        let client = roster.first(where: { $0.state == .idling && !$0.isFry })
        let clientPt = client.flatMap { layouts[$0.id] }
            .map { CGPoint(x: $0.x, y: $0.y - 10) }
        // The 40 s round: out on the first ~15%, riding till ~55%,
        // home by ~70%.
        let p = frac(t / 40)
        var pos = station
        var riding = false
        if let clientPt {
            if p < 0.15 {
                let k = smooth(clamp01(p / 0.15))
                pos = CGPoint(x: station.x + (clientPt.x - station.x) * k,
                              y: station.y + (clientPt.y - station.y) * k
                                  - sin(k * .pi) * 30)
            } else if p < 0.55 {
                pos = clientPt
                riding = true
            } else if p < 0.70 {
                let k = smooth(clamp01((p - 0.55) / 0.15))
                pos = CGPoint(x: clientPt.x + (station.x - clientPt.x) * k,
                              y: clientPt.y + (station.y - clientPt.y) * k
                                  - sin(k * .pi) * 30)
            }
        }
        var c = canvas
        c.translateBy(x: pos.x, y: pos.y)
        c.opacity = 0.9
        let shell = Color(red: 1.0, green: 0.86, blue: 0.80)
        let red = Color(red: 0.86, green: 0.18, blue: 0.20)
        let line = Color(red: 0.40, green: 0.10, blue: 0.10).opacity(0.7)
        // Legs and the fan tail under the arched body.
        var legs = Path()
        for k in 0..<4 {
            let lx = -3.0 + Double(k) * 2.4
            legs.move(to: CGPoint(x: lx, y: 2)); legs.addLine(to: CGPoint(x: lx + 1, y: 5.5))
        }
        c.stroke(legs, with: .color(shell.opacity(0.8)), lineWidth: 0.5)
        var fan = Path()
        fan.move(to: CGPoint(x: -6, y: 0))
        fan.addLine(to: CGPoint(x: -10, y: -3))
        fan.addQuadCurve(to: CGPoint(x: -10, y: 3), control: CGPoint(x: -8.5, y: 0))
        fan.closeSubpath()
        c.fill(fan, with: .color(red.opacity(0.85)))
        // The segmented body: white with a red saddle and a white stripe.
        var body = Path()
        body.move(to: CGPoint(x: -6.5, y: 1))
        body.addQuadCurve(to: CGPoint(x: 6.5, y: 0), control: CGPoint(x: 0, y: -6.5))
        body.addQuadCurve(to: CGPoint(x: -6.5, y: 1), control: CGPoint(x: 0, y: 3.5))
        body.closeSubpath()
        c.fill(body, with: .linearGradient(Gradient(colors: [red, Color(red: 0.98, green: 0.45, blue: 0.40)]),
                                           startPoint: CGPoint(x: 0, y: -4), endPoint: CGPoint(x: 0, y: 2)))
        var stripe = c
        stripe.clip(to: body)
        var line1 = Path()
        line1.move(to: CGPoint(x: -6, y: -0.8)); line1.addQuadCurve(to: CGPoint(x: 6, y: -1.5), control: CGPoint(x: 0, y: -5.5))
        stripe.stroke(line1, with: .color(.white.opacity(0.95)), lineWidth: 1.1)
        var segs = Path()
        for k in 0..<3 {
            let sx = -3.5 + Double(k) * 2.8
            segs.move(to: CGPoint(x: sx, y: -4)); segs.addLine(to: CGPoint(x: sx + 0.6, y: 2))
        }
        stripe.stroke(segs, with: .color(line.opacity(0.5)), lineWidth: 0.4)
        c.stroke(body, with: .color(line), lineWidth: 0.5)
        // Long white antennae whisking ahead, busier while it works.
        let whisk = riding && !reduceMotion ? sin(t * 9) * 2 : 0
        for k in [-1.0, 1.0] {
            var ant = Path()
            ant.move(to: CGPoint(x: 5.5, y: -1))
            ant.addQuadCurve(to: CGPoint(x: 17, y: -7 + k * 3 + whisk),
                             control: CGPoint(x: 11, y: -3 + k))
            c.stroke(ant, with: .color(.white.opacity(0.9)), lineWidth: 0.6)
        }
        c.fill(Path(ellipseIn: CGRect(x: 4, y: -2.8, width: 2, height: 2)),
               with: .color(Color(red: 0.05, green: 0.05, blue: 0.08)))
        c.fill(Path(ellipseIn: CGRect(x: 4.8, y: -2.6, width: 0.7, height: 0.7)),
               with: .color(.white))
    }

    /// The manta: a rare wide shadow crossing the back layer every
    /// few minutes — big, dim, unhurried. Reduce Motion skips the
    /// flight entirely.
    func drawManta(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        guard !reduceMotion else { return }
        // ~6 minutes between passes, a 20 s glide across.
        let period = 360.0
        let p = frac(t / period + 0.62)
        guard p < 0.06 else { return }
        let k = p / 0.06
        let x = -80 + (size.width + 160) * k
        let y = size.height * 0.30 + sin(k * .pi * 2) * 20
        let flap = sin(t * 1.6) * 0.18
        var c = canvas
        c.translateBy(x: x, y: y)
        c.opacity = 0.35 * sin(min(1, k * .pi) * .pi)
        // The diamond: two swept wings meeting at a point, a whip
        // tail behind.
        var wing = Path()
        wing.move(to: CGPoint(x: 42, y: 0))
        wing.addQuadCurve(to: CGPoint(x: -20, y: -30 - flap * 20),
                          control: CGPoint(x: 10, y: -26 - flap * 12))
        wing.addQuadCurve(to: CGPoint(x: -34, y: 0),
                          control: CGPoint(x: -28, y: -8))
        wing.addQuadCurve(to: CGPoint(x: -20, y: 30 + flap * 20),
                          control: CGPoint(x: -28, y: 8))
        wing.addQuadCurve(to: CGPoint(x: 42, y: 0),
                          control: CGPoint(x: 10, y: 26 + flap * 12))
        wing.closeSubpath()
        c.fill(wing, with: .color(Color(red: 0.05, green: 0.09, blue: 0.14)))
        var tailP = Path()
        tailP.move(to: CGPoint(x: -34, y: 0))
        tailP.addQuadCurve(to: CGPoint(x: -72, y: 6),
                           control: CGPoint(x: -52, y: -3))
        c.stroke(tailP, with: .color(Color(red: 0.05, green: 0.09, blue: 0.14)),
                 lineWidth: 1.6)
    }
}
