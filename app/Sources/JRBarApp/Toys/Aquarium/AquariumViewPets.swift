import AppKit
import JRBarCore
import SwiftUI

/// Where a pet is this frame and how far round it is turned: `c` is the
/// signed side-on share, +1 facing right, -1 left — the pets turn round
/// by squashing through zero, never by mirroring in one frame.
struct PetPose: Equatable {
    var x: Double
    var y: Double
    var c: Double
}

/// The pets bought in the shop.
extension AquariumView {
    // MARK: Shop pets

    /// How long the turtle takes to come round at each end, seconds.
    static let turtleTurn = 1.4

    /// The sea turtle's path: across the tank one way and back the next
    /// on a 90-second sweep, easing to a stop at each end and coming
    /// round there over 1.4 s with a small dip, rising for a breath near
    /// the end of each leg.
    func seaTurtlePose(size: CGSize, t: Double) -> PetPose {
        let period = 90.0
        let legTime = period / 2
        let tau = frac(t / period) * period
        let speed = size.width / legTime
        let half = Self.turtleTurn / 2
        // Seconds from the nearest end of a leg: the right end at 45,
        // the left at 0 (and 90).
        let fromRight = tau - legTime
        let fromLeft = tau < legTime ? tau : tau - period
        let x: Double
        var c: Double
        var dip = 0.0
        if abs(fromRight) < half {
            // The triangle's corner, rounded: it slows, stops, comes back.
            x = size.width - speed * (fromRight * fromRight + half * half) / (2 * half)
            let k = (fromRight + half) / Self.turtleTurn
            c = cos(.pi * k)
            dip = sin(.pi * k)
        } else if abs(fromLeft) < half {
            x = speed * (fromLeft * fromLeft + half * half) / (2 * half)
            let k = (fromLeft + half) / Self.turtleTurn
            c = -cos(.pi * k)
            dip = sin(.pi * k)
        } else if tau < legTime {
            x = speed * tau
            c = 1
        } else {
            x = size.width - speed * (tau - legTime)
            c = -1
        }
        if reduceMotion { c = c >= 0 ? 1 : -1 }
        // Mostly mid-depth; the last stretch of each leg climbs to sip
        // the surface and sinks back.
        let leg = (tau < legTime ? tau : tau - legTime) / legTime
        let breathe = smooth(clamp01((leg - 0.72) / 0.10))
            * smooth(clamp01((0.98 - leg) / 0.10))
        let baseY = size.height * 0.42
        let y = reduceMotion ? baseY
            : baseY + sin(t * 0.4) * 14 - breathe * (baseY - 46) + dip * 10
        return PetPose(x: x, y: y, c: c)
    }

    /// The sea turtle: a slow glide across midwater on a long lazy
    /// sweep, rising for a breath every minute or so — a patient
    /// silhouette behind the fish lane.
    func drawSeaTurtle(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let pose = seaTurtlePose(size: size, t: t)
        let x = pose.x, y = pose.y
        let period = 90.0
        let leg = frac(frac(t / period) * 2)
        let breathe = smooth(clamp01((leg - 0.72) / 0.10))
            * smooth(clamp01((0.98 - leg) / 0.10))
        var c = canvas
        c.translateBy(x: x, y: y)
        c.scaleBy(x: pose.c, y: 1)
        c.opacity = 0.92
        PetArt.seaTurtle(&c, flap: reduceMotion ? 0 : sin(t * 2.4))
        // The breath: two bubbles off the nose on the way down.
        if breathe > 0.5 && !reduceMotion {
            for k in 0..<2 {
                let bp = frac(t * 0.9 + Double(k) * 0.5)
                var b = canvas
                b.opacity = (1 - bp) * 0.5
                b.stroke(Path(ellipseIn: CGRect(x: x + pose.c * 40 - 2 - bp * 4,
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
        let skin: PetArt.OctopusSkin
        switch substrateKey {
        case "white":
            skin = PetArt.OctopusSkin(lit: Color(red: 0.96, green: 0.82, blue: 0.74),
                                      base: Color(red: 0.76, green: 0.58, blue: 0.50),
                                      shade: Color(red: 0.46, green: 0.30, blue: 0.26))
        case "black":
            skin = PetArt.OctopusSkin(lit: Color(red: 0.60, green: 0.42, blue: 0.40),
                                      base: Color(red: 0.34, green: 0.21, blue: 0.21),
                                      shade: Color(red: 0.16, green: 0.09, blue: 0.10))
        default:
            skin = PetArt.OctopusSkin(lit: Color(red: 0.92, green: 0.60, blue: 0.50),
                                      base: Color(red: 0.66, green: 0.38, blue: 0.33),
                                      shade: Color(red: 0.36, green: 0.19, blue: 0.17))
        }

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
        if out {
            c.opacity = 0.97
            PetArt.octopus(&c, skin: skin, crawl: crawl)
        } else {
            // Home: slumped in or behind the pot, the eyes up over the
            // rim on a peek and sunk low otherwise.
            c.opacity = peek ? 0.95 : 0.55
            PetArt.octopusAtHome(&c, skin: skin, lift: peek ? 10 : 3, open: peek ? 1 : 0.35)
        }
    }

    /// How long the axolotl takes to turn round at each end, seconds.
    static let axolotlTurn = 2.0

    /// The axolotl's patrol: a lazy amble along the sand one way over
    /// most of 80 seconds, a kick-hop halfway, then it turns round where
    /// it stopped and ambles back — so the loop comes home to where it
    /// began instead of jumping there.
    func axolotlPose(size: CGSize, t: Double) -> (pose: PetPose, kick: Double, baseY: Double) {
        let period = 160.0
        let legTime = period / 2
        let amble = legTime - Self.axolotlTurn
        let tau = frac(t / period) * period
        let home = size.width * 0.30
        let out = tau < legTime
        let local = out ? tau : tau - legTime
        let q = clamp01(local / amble)
        let along = smooth(q)
        let x = out ? home - 15 + 60 * along : home + 45 - 60 * along
        var c: Double = out ? 1 : -1
        if local > amble {
            let k = (local - amble) / Self.axolotlTurn
            c = (out ? 1 : -1) * cos(.pi * k)
        }
        if reduceMotion { c = c >= 0 ? 1 : -1 }
        // The kick-hop halfway along each leg.
        let kick = smooth(clamp01((q - 0.46) / 0.04)) * smooth(clamp01((0.54 - q) / 0.04))
        let baseY = sandTop(atX: x, in: size) - 7
        let y = reduceMotion ? baseY : baseY - kick * 26
        return (PetPose(x: x, y: y, c: c), kick, baseY)
    }

    /// The axolotl: a wide pink smile on legs, three gill fronds a
    /// cheek waving as it ambles the sand on a long seeded patrol;
    /// every so often it kicks up and settles a body-width over.
    func drawAxolotl(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let placed = axolotlPose(size: size, t: t)
        let x = placed.pose.x, y = placed.pose.y
        let kick = placed.kick, baseY = placed.baseY
        var c = canvas
        c.translateBy(x: x, y: y)
        c.scaleBy(x: placed.pose.c, y: 1)
        c.opacity = 0.95
        PetArt.axolotl(&c, swish: reduceMotion ? 0 : sin(t * 1.8) * 2,
                       step: reduceMotion ? 0 : sin(t * 3) * 1.5,
                       wave: reduceMotion ? 0 : t * 2.6)
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

    /// How long a tetra takes to come round, seconds.
    static let tetraTurn = 0.5

    /// The tetra school's seven places: one shared wander target, each
    /// fish orbiting the pack on its own phase. When the pack reverses,
    /// each tetra turns round on its own beat — up to 0.4 s either side
    /// of the others, by its place in the orbit — squashing through zero
    /// rather than the whole school mirroring in one frame.
    func tetraPoses(size: CGSize, t: Double) -> [PetPose] {
        // The pack's shared target sweeps the midwater slowly.
        let cx = size.width * (0.5 + 0.28 * sin(t * 0.09))
        let cy = size.height * (0.42 + 0.10 * sin(t * 0.13 + 1.7))
        return (0..<7).map { i in
            let h = scatter(AquariumModel.stableHash("tetra"), i)
            let orbit = 12 + Double(h & 0xFF) / 0xFF * 26
            let phase = Double((h >> 8) & 0xFF) / 0xFF * .pi * 2
            let speed = 1.2 + Double((h >> 16) & 0xFF) / 0xFF * 1.4
            let wobble = reduceMotion ? 0.0 : t * speed
            let fx = cx + cos(wobble + phase) * orbit
            let fy = cy + sin(wobble * 1.3 + phase) * orbit * 0.45
            // This tetra's own clock for the pack's reversals.
            let stagger = sin(phase) * 0.4
            let tau = (t - stagger) * 0.09 - .pi / 2
            let k = (tau / .pi).rounded()
            let since = (tau - k * .pi) / 0.09
            let dir0: Double = abs(k.truncatingRemainder(dividingBy: 2)) < 0.5 ? 1 : -1
            let p = clamp01((since + Self.tetraTurn / 2) / Self.tetraTurn)
            var c = dir0 * cos(.pi * p)
            if reduceMotion { c = c >= 0 ? 1 : -1 }
            return PetPose(x: fx, y: fy, c: c)
        }
    }

    /// The tetra school: seven little neons sharing one wander
    /// target, each orbiting the pack on its own phase — cohesion as
    /// a swarm, not a queue.
    func drawTetraSchool(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        for pose in tetraPoses(size: size, t: t) {
            var c = canvas
            c.translateBy(x: pose.x, y: pose.y)
            c.scaleBy(x: pose.c, y: 1)
            c.opacity = 0.92
            PetArt.neonTetra(&c, length: 15)
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
        c.opacity = 0.95
        // The feelers whisk harder while it works.
        PetArt.cleanerShrimp(&c, whisk: riding && !reduceMotion ? sin(t * 9) * 2 : 0)
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
        var c = canvas
        c.translateBy(x: x, y: y)
        // Fades in off the far wall and back out, darkest mid-pass.
        c.opacity = 0.35 * sin(k * .pi)
        PetArt.manta(&c, flap: sin(t * 1.6))
    }
}
