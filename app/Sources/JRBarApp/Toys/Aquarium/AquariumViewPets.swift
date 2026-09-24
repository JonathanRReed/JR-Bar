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
        let shell = Color(red: 0.30, green: 0.38, blue: 0.26)
        let skin = Color(red: 0.45, green: 0.52, blue: 0.38)
        // Flippers behind the shell so the dome sits on top.
        var front = Path()
        front.move(to: CGPoint(x: 8, y: 4))
        front.addQuadCurve(to: CGPoint(x: 24, y: 12 + flap * 8),
                           control: CGPoint(x: 18, y: 2))
        front.addQuadCurve(to: CGPoint(x: 10, y: 10),
                           control: CGPoint(x: 16, y: 10))
        front.closeSubpath()
        c.fill(front, with: .color(skin.opacity(0.9)))
        var rear = Path()
        rear.move(to: CGPoint(x: -12, y: 4))
        rear.addQuadCurve(to: CGPoint(x: -24, y: 10 - flap * 6),
                          control: CGPoint(x: -18, y: 3))
        rear.addQuadCurve(to: CGPoint(x: -12, y: 9),
                          control: CGPoint(x: -16, y: 9))
        rear.closeSubpath()
        c.fill(rear, with: .color(skin.opacity(0.85)))
        // Head poking ahead.
        c.fill(Path(ellipseIn: CGRect(x: 16, y: -5, width: 10, height: 8)),
               with: .color(skin))
        c.fill(Path(ellipseIn: CGRect(x: 22, y: -3, width: 2, height: 2)),
               with: .color(.black.opacity(0.7)))
        // The dome with its plate seams.
        let dome = Path(ellipseIn: CGRect(x: -18, y: -12, width: 38, height: 22))
        c.fill(dome, with: .color(shell))
        c.stroke(dome, with: .color(Color(red: 0.18, green: 0.24, blue: 0.16)),
                 lineWidth: 1.2)
        for k in -1...1 {
            var seam = Path()
            seam.move(to: CGPoint(x: Double(k) * 9, y: -11))
            seam.addQuadCurve(to: CGPoint(x: Double(k) * 9 + 3, y: 9),
                              control: CGPoint(x: Double(k) * 9 - 2, y: -1))
            c.stroke(seam, with: .color(Color(red: 0.18, green: 0.24, blue: 0.16)
                                        .opacity(0.5)),
                     lineWidth: 0.8)
        }
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
        c.opacity = out ? 0.95 : 0.9
        if out {
            // Crawling: the mantle low over eight working arms.
            for i in 0..<8 {
                let ph = Double(i) / 8 * .pi * 2 + crawl * 2
                var arm = Path()
                arm.move(to: .zero)
                arm.addQuadCurve(
                    to: CGPoint(x: cos(ph) * 12, y: 4 + sin(ph) * 4),
                    control: CGPoint(x: cos(ph) * 7, y: 2))
                c.stroke(arm, with: .color(mantle.opacity(0.9)),
                         style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
            c.fill(Path(ellipseIn: CGRect(x: -7, y: -14, width: 14, height: 13)),
                   with: .color(mantle))
            c.fill(Path(ellipseIn: CGRect(x: -4, y: -10, width: 3, height: 3)),
                   with: .color(dark))
            c.fill(Path(ellipseIn: CGRect(x: 2, y: -10, width: 3, height: 3)),
                   with: .color(dark))
        } else {
            // Home: the mantle slumped in/behind the pot, eyes up on a
            // peek, sunk below otherwise.
            let eyeLift = peek ? -10.0 : -3.0
            c.fill(Path(ellipseIn: CGRect(x: -8, y: -10, width: 16, height: 11)),
                   with: .color(mantle.opacity(peek ? 1 : 0.55)))
            for k in [-1.0, 1.0] {
                c.fill(Path(ellipseIn: CGRect(x: k * 4 - 1.8, y: eyeLift - 2,
                                              width: 3.6, height: 4.6)),
                       with: .color(.white.opacity(peek ? 0.9 : 0.3)))
                c.fill(Path(ellipseIn: CGRect(x: k * 4 - 0.8, y: eyeLift - 0.6,
                                              width: 1.6, height: 2.4)),
                       with: .color(dark.opacity(peek ? 1 : 0.4)))
            }
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
        let pink = Color(red: 0.92, green: 0.60, blue: 0.62)
        let frill = Color(red: 0.95, green: 0.45, blue: 0.50)
        // Tail sweeping behind.
        var tail = Path()
        tail.move(to: CGPoint(x: -12, y: -2))
        tail.addQuadCurve(to: CGPoint(x: -26, y: -8),
                          control: CGPoint(x: -20, y: -2))
        c.stroke(tail, with: .color(pink.opacity(0.8)),
                 style: StrokeStyle(lineWidth: 5, lineCap: .round))
        // Little legs, stepping while it walks.
        for k in 0..<2 {
            let step = reduceMotion ? 0 : sin(t * 3 + Double(k) * .pi) * 1.5
            c.stroke(Path(CGRect(x: -4 + Double(k) * 12, y: 2,
                                 width: 5, height: 4)),
                     with: .color(pink), lineWidth: 3)
            _ = step
        }
        // Body & wide head.
        c.fill(Path(ellipseIn: CGRect(x: -12, y: -9, width: 30, height: 13)),
               with: .color(pink))
        c.fill(Path(ellipseIn: CGRect(x: 4, y: -13, width: 20, height: 15)),
               with: .color(pink))
        // Gill fronds, waving on their own phase.
        for side in [-1.0, 1.0] {
            for k in 0..<3 {
                let wave = reduceMotion ? 0
                    : sin(t * 2.6 + Double(k) * 1.2 + side) * 2
                var fr = Path()
                let gy = -12 + Double(k) * 4
                fr.move(to: CGPoint(x: 12 + side * 3, y: gy))
                fr.addQuadCurve(
                    to: CGPoint(x: 12 + side * (12 + Double(k) * 2), y: gy - 4 + wave),
                    control: CGPoint(x: 12 + side * 8, y: gy - 2))
                c.stroke(fr, with: .color(frill),
                         style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
        }
        // The famous smile & bead eyes.
        c.fill(Path(ellipseIn: CGRect(x: 14, y: -9, width: 3, height: 3)),
               with: .color(.black.opacity(0.75)))
        c.fill(Path(ellipseIn: CGRect(x: 20, y: -9, width: 3, height: 3)),
               with: .color(.black.opacity(0.75)))
        var smile = Path()
        smile.move(to: CGPoint(x: 15, y: -4))
        smile.addQuadCurve(to: CGPoint(x: 23, y: -4), control: CGPoint(x: 19, y: -1))
        c.stroke(smile, with: .color(Color(red: 0.60, green: 0.30, blue: 0.32)),
                 lineWidth: 1)
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
            // The neon line — a glow band over the silver body.
            c.fill(Path(ellipseIn: CGRect(x: -len / 2, y: -len * 0.22,
                                          width: len, height: len * 0.44)),
                   with: .color(Color(red: 0.80, green: 0.86, blue: 0.90)))
            var glow = c
            glow.blendMode = .plusLighter
            glow.fill(Path(roundedRect: CGRect(x: -len * 0.40, y: -len * 0.10,
                                               width: len * 0.80, height: len * 0.12),
                           cornerRadius: len * 0.06),
                      with: .color(Color(red: 0.20, green: 0.85, blue: 0.95)
                                   .opacity(0.9)))
            // The red tail half.
            c.fill(Path(ellipseIn: CGRect(x: -len / 2, y: -len * 0.16,
                                          width: len * 0.45, height: len * 0.32)),
                   with: .color(Color(red: 0.90, green: 0.30, blue: 0.25)
                                .opacity(0.85)))
            c.fill(Path(ellipseIn: CGRect(x: len * 0.28, y: -len * 0.12,
                                          width: 1.6, height: 1.6)),
                   with: .color(.black.opacity(0.8)))
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
        let body = Color(red: 0.92, green: 0.75, blue: 0.70)
        let red = Color(red: 0.80, green: 0.25, blue: 0.25)
        // A slim arched body with a red saddle.
        c.fill(Path(ellipseIn: CGRect(x: -6, y: -3, width: 12, height: 6)),
               with: .color(body))
        c.fill(Path(ellipseIn: CGRect(x: -2, y: -3, width: 5, height: 6)),
               with: .color(red.opacity(0.8)))
        // Long antennae whisking ahead, busier while it works.
        let whisk = riding && !reduceMotion ? sin(t * 9) * 2 : 0
        for k in [-1.0, 1.0] {
            var ant = Path()
            ant.move(to: CGPoint(x: 5, y: -1))
            ant.addQuadCurve(to: CGPoint(x: 15, y: -6 + k * 3 + whisk),
                             control: CGPoint(x: 10, y: -3 + k))
            c.stroke(ant, with: .color(body.opacity(0.8)), lineWidth: 0.8)
        }
        c.fill(Path(ellipseIn: CGRect(x: 4, y: -2.5, width: 1.6, height: 1.6)),
               with: .color(.black.opacity(0.8)))
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
