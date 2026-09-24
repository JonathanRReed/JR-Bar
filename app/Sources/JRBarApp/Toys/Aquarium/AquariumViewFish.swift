import AppKit
import JRBarCore
import SwiftUI

/// The fish: where each swims, and the shape it is drawn with.
extension AquariumView {
    // MARK: Fish

    /// Where a fish is right now: position, which way it faces, how far
    /// through its turn it is.
    struct Layout {
        var x: Double = 0
        var y: Double = 0
        /// +1 faces right, -1 faces left.
        var facing: Double = 1
        /// Screen-space radians; positive pitches the nose down for
        /// either facing (the draw rotates by `pitch * facing`).
        var pitch: Double = 0
        /// 1 at cruise, ~0.2 mid-turn: the fish seen head-on.
        var thin: Double = 1
        var scale: Double = 1
        var opacity: Double = 1
        /// 0 at cruise … 1 deepest into a wall turn.
        var turn: Double = 0
        /// Tail-beat amplitude multiplier (0 stills the tail).
        var wag: Double = 1
        /// Where a surfacing fish started its rise; the bubble trail
        /// climbs from there.
        var riseFrom: Double = 0
        /// The glass-tap ring's phase (0 just emitted … 1 faded) while a
        /// waiting fish pulses; -1 means no ring this frame.
        var tapRing: Double = -1
        /// How deep into a surface sip an idle fish is (0…1); the view
        /// trails a bubble off it.
        var sip: Double = 0
        /// How deep into the night doze an idling fish is (0…1); the
        /// view breathes out the occasional "z".
        var sleep: Double = 0
    }

    /// The cruise patrol: a sinusoidal sweep between the walls, so the
    /// fish eases to a stop at the glass instead of mirror-flipping.
    /// `u` is the velocity proxy (±1 mid-tank, 0 at a wall) and `turn`
    /// grows through the turnaround.
    func patrol(of fish: Fish, in size: CGSize, at t: Double, margin: Double)
        -> (x: Double, u: Double, turn: Double) {
        let h = fish.seed
        let x0 = Double((h >> 33) & 0x3FF) / 0x3FF
        // Deep lanes swim slower: parallax.
        let omega = Double.pi * fish.speed * (1 - fish.lane * 0.3)
        // The phase picks the start point on the sweep AND the first
        // direction, so `fish.direction` still means something.
        let s = min(1, max(-1, x0 * 2 - 1))
        let phase = fish.direction > 0 ? asin(s) : Double.pi - asin(s)
        let theta = omega * t + phase
        let u = cos(theta)
        let turn = min(1, max(0, 1 - abs(u) / 0.5))
        // The nose pokes a touch past the patrol line mid-turn.
        let pos = 0.5 * (1 + sin(theta))
        let x = margin + pos * max(0, size.width - 2 * margin) + turn * 7 * sin(theta)
        return (x, u, turn)
    }

    /// The lane's resting height: near the surface at lane 0, clear of
    /// the raised bed (the highest dune crest is ~92 pt up) at lane 1.
    func laneY(for fish: Fish, in size: CGSize) -> Double {
        let top = 34.0
        let bottom = size.height - 108.0
        return top + fish.lane * max(0, bottom - top)
    }

    func layout(of fish: Fish, in size: CGSize, at t: Double, now: Date,
                        parent: (fish: Fish, layout: Layout)? = nil) -> Layout {
        if fish.isFry, let parent {
            return fryLayout(of: fish, at: t, now: now, parent: parent)
        }
        let h = fish.seed
        let phase = Double((h >> 43) & 0xFF) / 0xFF * .pi * 2
        // Half the fish loop up over the top, half dive under.
        let turnUp = (h >> 52) & 1 == 0
        let margin = 36.0
        let laneY = laneY(for: fish, in: size)
        let bob = reduceMotion ? 0 : sin(t * 1.1 + phase) * 5
        let p = patrol(of: fish, in: size, at: t, margin: margin)
        // The steering body this frame (nil before the first step, or
        // for fry) and where the current state found the fish.
        let body = motion.bodies[fish.id]
        let home = anchor(of: fish, in: size)

        var l = Layout()
        l.scale = 1.08 - fish.lane * 0.4
        l.riseFrom = laneY
        // The shared turn pose: the pitch stays level through cruise &
        // sweeps in at the glass (smoothstep), the head-on squash holds
        // a tighter window than the pitch, and the fish arcs a little
        // toward the side of the loop.
        let turnPitch = smooth(p.turn) * (turnUp ? -0.9 : 0.9)
        let turnArc = p.turn * (turnUp ? -6.0 : 6.0)
        let thin = 1 - smooth(clamp01(1 - abs(p.u) / 0.28)) * 0.82

        /// The steering readout: facing off the heading's x sign, pitch
        /// off its y (`asin(sin)` is the pitch both facings share), and
        /// the head-on factor doubles as the squash a vertical swim
        /// reads as.
        func steeringReadout(_ b: SwimBody)
            -> (facing: Double, pitch: Double, thin: Double, turn: Double) {
            let c = cos(b.heading)
            let headOn = abs(c)
            return (c >= 0 ? 1 : -1,
                    AquariumSteering.pitch(forHeading: b.heading),
                    0.30 + 0.70 * headOn,
                    smooth(clamp01(1 - headOn)))
        }

        switch fish.state {
        case .swimming, .idling:
            if let b = body {
                // The steering body IS the position: wander noise, a
                // soft turn off the glass, a dart at food, a weak pull
                // toward the school. `bob` rides on top so the water
                // still breathes under it.
                let s = steeringReadout(b)
                let px = b.x * size.width
                let py = b.y * size.height
                l.x = px
                l.facing = s.facing
                l.thin = s.thin
                l.turn = s.turn
                if fish.state == .swimming {
                    l.y = py + bob * (1 - s.turn * 0.5)
                    l.pitch = s.pitch
                    l.wag = 1.25
                    // The flourish: every minute or so a glad swimmer
                    // throws a barrel roll mid-stroke — a hop and a
                    // full spin, seeded so it never lands on a clock
                    // you can catch. Never near the ceiling (the roll
                    // would leave the water) or mid-startle.
                    if !reduceMotion, b.y > 0.15, motion.startles[fish.id] == nil,
                       let roll = AquariumBehavior.flourishProgress(seed: h, at: t) {
                        l.pitch += roll * .pi * 2 * AquariumBehavior.flourishDirection(seed: h)
                        l.y -= sin(roll * .pi) * 15
                        l.wag += sin(roll * .pi) * 0.6
                    }
                } else {
                    // Holds midwater on a slow drift — the body steps
                    // at a third of the effort — and still rises to
                    // sip the surface every half-minute or so.
                    // The doze: deep in the tank's night wash an idler
                    // settles toward the sand, stills its tail and dims
                    // a touch — `drawFish` breathes out the "z"s. A
                    // curious pointer is worth waking up for.
                    let doze = reduceMotion || fish.id == motion.curiousID
                        ? 0 : AquariumBehavior.doze(seed: h, night: nightFactor(t: t))
                    let sipPeriod = 26 + Double((h >> 60) & 0xF)
                    let sip = frac(t / sipPeriod + phase / (.pi * 2))
                    let sipping = (reduceMotion ? 0
                        : smooth(clamp01(sip / 0.07)) * smooth(clamp01((0.18 - sip) / 0.07)))
                        * (1 - doze)
                    l.y = py + bob * 0.6 * (1 - s.turn * 0.5)
                        - sipping * max(0, py - 34)
                    // A sleeper sinks to just off the sand under it.
                    let floorY = sandTop(atX: px, in: size) - 44
                    l.y += max(0, floorY - l.y) * doze * 0.9
                    l.pitch = s.pitch - sipping * 0.55 + doze * 0.12
                    l.wag = (0.35 + sipping * 0.7) * (1 - doze * 0.75)
                    l.sip = sipping
                    l.sleep = doze
                    l.opacity *= 1 - 0.15 * doze
                }
            } else if fish.state == .swimming {
                // No body stepped yet (first frame, a paused resume):
                // the old sine sweep stands in until one lands.
                l.x = p.x
                l.y = laneY + bob * (1 - p.turn * 0.5) + turnArc
                l.facing = p.u >= 0 ? 1 : -1
                l.pitch = turnPitch
                l.thin = thin
                l.turn = p.turn
                l.wag = 1.25
            } else {
                let d = patrol(of: fish, in: size, at: t * 0.3, margin: margin)
                let dPitch = smooth(d.turn) * (turnUp ? -0.9 : 0.9)
                let dArc = d.turn * (turnUp ? -6.0 : 6.0)
                // The fixture path dozes too — same night, same rule.
                let doze = reduceMotion ? 0
                    : AquariumBehavior.doze(seed: h, night: nightFactor(t: t))
                let sipPeriod = 26 + Double((h >> 60) & 0xF)
                let sip = frac(t / sipPeriod + phase / (.pi * 2))
                let sipping = (reduceMotion ? 0
                    : smooth(clamp01(sip / 0.07)) * smooth(clamp01((0.18 - sip) / 0.07)))
                    * (1 - doze)
                l.x = d.x
                l.y = laneY + bob * 0.6 * (1 - d.turn * 0.5) + dArc
                    - sipping * (laneY - 34)
                let floorY = sandTop(atX: l.x, in: size) - 44
                l.y += max(0, floorY - l.y) * doze * 0.9
                l.facing = d.u >= 0 ? 1 : -1
                l.pitch = dPitch - sipping * 0.55 + doze * 0.12
                l.thin = 1 - smooth(clamp01(1 - abs(d.u) / 0.28)) * 0.82
                l.turn = d.turn
                l.wag = (0.35 + sipping * 0.7) * (1 - doze * 0.75)
                l.sip = sipping
                l.sleep = doze
                l.opacity *= 1 - 0.15 * doze
            }
        case .surfacing:
            // Rises from where it was to just under the surface over
            // about a second, nose up on the way, then bobs there at
            // the glass — closer to the viewer, turned half toward you
            // so both eyes are on you, pulsing a soft glow ring off its
            // nose like a tap on the pane.
            let age = now.timeIntervalSince(fish.stateSince)
            let rise = smooth(clamp01(age / 1.15))
            l.riseFrom = home.y
            l.x = home.x + (reduceMotion ? 0 : sin(t * 0.7 + phase) * 6 * rise)
            l.y = l.riseFrom + (24 - l.riseFrom) * rise
                + (reduceMotion ? 0 : sin(t * 2.3 + phase) * 3.5 * rise)
            l.facing = body.map { cos($0.heading) >= 0 ? 1.0 : -1.0 } ?? (p.u >= 0 ? 1 : -1)
            l.pitch = (body.map { steeringReadout($0).pitch } ?? turnPitch)
                - (1 - rise) * 0.75
            l.thin = min(body.map { steeringReadout($0).thin } ?? thin, 1 - 0.42 * rise)
            l.turn = body.map { steeringReadout($0).turn } ?? p.turn
            l.wag = 0.45 + (1 - rise) * 0.7
            let ring = reduceMotion ? 0.55
                : frac(age / 2.2 + Double((h >> 56) & 0xF) / 0xF)
            l.tapRing = ring
            l.scale *= 1 + (0.13 + 0.05 * exp(-ring * 5)) * rise
        case .sinking:
            // It stops where it was, drops nose down onto the sand,
            // rolls onto its side for a beat, then fades out.
            let frozen = home
            let age = now.timeIntervalSince(fish.stateSince)
            let drop = clamp01(age / 2.4)
            let eased = drop * drop
            let settle = smooth(clamp01((age - 2.4) / 1.0))
            let decay = exp(-max(0, age - 2.4) * 0.5)
            let rock = reduceMotion ? 0 : sin(age * 3.0 + phase) * 0.22 * decay
            l.x = frozen.x
            // It comes to rest on the dune under it, not the glass.
            let floorY = sandTop(atX: frozen.x, in: size) - 12
            l.y = min(frozen.y + (floorY - frozen.y) * eased, floorY) + rock * 4
            l.facing = body.map { cos($0.heading) >= 0 ? 1.0 : -1.0 } ?? 1
            let pose = 0.55 * eased + (0.16 - 0.55 * eased) * settle
            let side = ((h >> 58) & 1 == 0) ? 1.3 : -1.3
            let rest = smooth(clamp01((age - 3.0) / 1.2))
            l.pitch = pose + (side - pose) * rest + rock * (1 - rest)
            // A failed fry doesn't get the full rock-on-sand: it just
            // drops & fades.
            let fade = smooth(clamp01((age - 5.6) / 2.6))
            l.opacity = (fish.isFry ? 1 - 0.7 * drop : 1 - 0.15 * drop)
                * (1 - 0.62 * fade)
            l.wag = (1 - drop) * (1 - rest)
        case .leaving:
            // From wherever it was, corkscrewing up and out the
            // top-right edge.
            let progress = fish.leaveProgress(at: now)
            let eased = smooth(progress)
            let start = home.x
            let loopPhase = progress * .pi * 3.4 + phase
            let loopR = reduceMotion ? 0 : 26 * (1 - progress)
            l.x = start + (size.width + margin + 60 - start) * eased
                + cos(loopPhase) * loopR * 0.6
            l.y = home.y + bob * (1 - progress) - eased * max(0, home.y - 10)
                + sin(loopPhase) * loopR
            l.facing = 1
            l.pitch = -0.4 * eased + sin(loopPhase + .pi / 2) * 0.35 * (1 - progress)
            l.opacity = 1 - 0.5 * progress
            l.wag = 1 + progress * 0.8
        }

        // The curious fish wiggles a little harder — it sees you.
        if fish.id == motion.curiousID { l.wag *= 1.35 }

        // A new fish swims in from the edge behind its heading instead
        // of popping into the middle of the tank.
        if fish.state == .swimming || fish.state == .idling || fish.state == .surfacing {
            let enterDuration = 2.2
            let age = now.timeIntervalSince(fish.enteredAt)
            if age < enterDuration {
                let e = 1 - pow(1 - age / enterDuration, 3)
                let edge: Double = fish.direction > 0 ? -70 : size.width + 70
                l.x = edge + (l.x - edge) * e
                l.opacity *= 0.2 + 0.8 * e
                // The turn pose fades in with the entrance: the fish
                // comes through the glass fully formed.
                l.thin = 1 - (1 - l.thin) * e
                l.turn *= e
                l.pitch *= e
            }
        }
        return l
    }

    /// A fry's place in its school (docs/TOYS.md): a loose orbit
    /// around the parent fish — per-fry radius, direction & phase
    /// from its id's hash — riding a touch higher, because fry sit up
    /// in the water. The orbit follows the parent's layout, so an
    /// ask-rise, a sink or a drift off the edge carries the school.
    private func fryLayout(of fish: Fish, at t: Double, now: Date,
                           parent: (fish: Fish, layout: Layout)) -> Layout {
        let h = fish.seed
        let phase = Double(h & 0xFF) / 0xFF * .pi * 2
        let orbitR = 30 + Double((h >> 8) & 0xFF) / 0xFF * 26
        let omega = (0.45 + Double((h >> 16) & 0xFF) / 0xFF * 0.45)
            * ((h >> 24) & 1 == 0 ? 1.0 : -1.0)
        // An idling parent's school mills about at less than half speed.
        let idle = fish.state == .idling
        let angle = phase + (reduceMotion ? 0 : omega * t * (idle ? 0.45 : 1))
        let pl = parent.layout

        var l = Layout()
        l.scale = pl.scale * 1.08
        l.riseFrom = pl.riseFrom
        l.opacity = pl.opacity
        // Little tails beat faster.
        l.wag = pl.wag * 1.4

        switch fish.state {
        case .swimming, .idling, .surfacing:
            l.x = pl.x + cos(angle) * orbitR
            l.y = pl.y + sin(angle) * orbitR * 0.5 - 12
            // Face along the orbit's travel.
            l.facing = -sin(angle) * omega >= 0 ? 1 : -1
            l.pitch = pl.pitch * 0.5 + (reduceMotion ? 0 : sin(t * 1.7 + phase) * 0.12)
        case .sinking:
            // A failed worker just fades & drops a little.
            let age = now.timeIntervalSince(fish.stateSince)
            let drop = smooth(clamp01(age / 1.6))
            l.x = pl.x + cos(angle) * orbitR * 0.7
            l.y = pl.y + sin(angle) * orbitR * 0.5 - 12 + drop * 44
            l.facing = pl.facing
            l.pitch = 0.5 * drop
            l.opacity = pl.opacity * (1 - 0.72 * drop)
            l.wag = pl.wag * (1 - drop)
        case .leaving:
            // The school spirals in as it follows its parent off.
            let progress = fish.leaveProgress(at: now)
            let shrink = orbitR * (1 - 0.55 * progress)
            l.x = pl.x + cos(angle) * shrink
            l.y = pl.y + sin(angle) * shrink * 0.5 - 12
            l.facing = 1
            l.pitch = pl.pitch
        }
        return l
    }

    // MARK: Fish shape

    /// A failed fish's colour: slate, drained of its provider's.
    static let sinkingNS = NSColor(srgbRed: 0.58, green: 0.62, blue: 0.68, alpha: 1)

    /// The water colour fish & kelp wash toward with depth.
    static let waterNS = NSColor(srgbRed: 0.05, green: 0.18, blue: 0.33, alpha: 1)

    /// W13's overlay markers — a small glyph floating just above the
    /// fish, one per plan (`FishOverlayArt` draws each distinct shape).
    private func drawOverlayMarker(_ overlay: FishOverlay, l: Layout,
                                   canvas: inout GraphicsContext,
                                   length: Double, height: Double, t: Double) {
        let r = max(3.4, length * 0.10)
        let x = l.x + l.facing * length * 0.18
        let y = l.y - height * 0.5 - r - 6
        var m = canvas
        m.opacity = l.opacity * 0.95
        FishOverlayArt.draw(overlay, into: &m, at: CGPoint(x: x, y: y), r: r, t: t)
    }

    /// A grown, mid-lane fish's drawn length in points before its
    /// species and depth scale it.
    static let fishBaseLength = 60.0

    /// How big `fish` draws under layout `l`: its length in points, and
    /// how far its art — fins and all — reaches above and below its
    /// centre. The idle game's growth stages (docs/TOYS.md) scale it:
    /// small, grown, full — a fish with no care record swims at stage 0.
    func drawnSize(of fish: Fish, layout l: Layout) -> (length: Double, above: Double, below: Double) {
        let stage = game?.pets[fish.id]?.stage ?? 0
        let stageScale = [0.74, 0.92, 1.12][min(2, max(0, stage))]
        let length = Self.fishBaseLength * l.scale * fish.species.sizeScale
            * (fish.isFry ? AquariumModel.fryScale : 1) * stageScale
        let extent = CartoonFish.art(for: fish.species).extent
        return (length, -extent.minY * length, extent.maxY * length)
    }

    func drawFish(canvas: inout GraphicsContext, size: CGSize, t: Double, now: Date,
                          fish: Fish, layout l: Layout,
                          parent: (fish: Fish, layout: Layout)?, showLabels: Bool) {
        let h = fish.seed
        let phase = Double((h >> 43) & 0xFF) / 0xFF * .pi * 2
        // Fry ride at their school's depth, a little shallower.
        let lane = fish.isFry ? (parent?.fish.lane ?? fish.lane) * 0.85 : fish.lane
        let care = game?.pets[fish.id]
        let art = CartoonFish.art(for: fish.species)
        let drawn = drawnSize(of: fish, layout: l)
        let length = drawn.length
        // The overlays measure from the art's real reach, fins and all.
        let height = max(drawn.above, drawn.below) * 2

        // The golden ticket: ~1 fish in 24 swims in gold instead of its
        // provider colour — a seeded lottery, the same fish every
        // launch. A sinking fish is beyond vanity: it stays grey.
        let golden = !fish.isFry && fish.state != .sinking
            && AquariumBehavior.isGolden(seed: h)
        let base: NSColor = fish.state == .sinking
            ? Self.sinkingNS
            : (golden ? NSColor(srgbRed: 0.98, green: 0.76, blue: 0.22, alpha: 1)
                      : ProviderStyle.style(for: fish.providerID).nsAccent)
        // Depth: deeper lanes wash toward the column's floor colour.
        let palette = CartoonFish.Palette(accent: base, depth: lane, floor: floorNS)

        // The tail beats on the fish's own clock: faster the faster it
        // really swims, quicker still while its session is busy. A
        // lagging beat in the pitch gives the head the classic
        // follow-the-tail sway. Reduce Motion stills both — the fish
        // glides, poses stay.
        let recency = fish.lastUpdate.map { now.timeIntervalSince($0) } ?? .infinity
        let vigor = 1 + 0.5 * exp(-max(0, recency) / 9)
        let clock = FishSwimClock.shared.advance(fish.id, seed: phase, t: t, x: l.x, y: l.y,
                                                  length: length, vigor: vigor)
        let stroke = 0.2 * l.wag * (0.8 + 0.3 * min(1.3, clock.speed)) * (1 + l.turn * 0.3)
        let swim = CartoonFish.Swim(phase: clock.phase, amplitude: reduceMotion ? 0 : stroke,
                                    thin: l.thin)
        let sway = reduceMotion ? 0 : sin(clock.phase - 0.8) * 0.04 * l.wag

        // Squash-and-stretch: a fish that just ate or just grew a stage
        // pops wide and settles back over most of a second.
        var squashX = 1.0
        var squashY = 1.0
        if let until = motion.bounceUntil[fish.id], now < until {
            let k = clamp01(1 - until.timeIntervalSince(now) / 0.7)
            let s = sin(k * .pi)
            squashX = 1 + 0.16 * s
            squashY = 1 - 0.13 * s
        }

        // A fish pools a soft shadow on the sand under it; the pool
        // fades as it climbs but stays readable at mid-height — cheap
        // depth, one gradient fill.
        if fish.state != .leaving {
            let floorY = sandTop(atX: l.x, in: size) + 3
            let clearance = floorY - (l.y + height * 0.5)
            let range = size.height * 0.38
            if clearance < range {
                let fade = clamp01(1 - max(0, clearance) / range)
                groundShadow(canvas: &canvas, x: l.x, y: floorY,
                             halfW: length * 0.60, halfH: 7,
                             alpha: 0.44 * fade * l.opacity)
            }
        }

        // A trick in progress: the barrel roll is a full 360° about
        // the swim axis — the vertical squash goes through belly-up
        // and back; the bubble ring draws separately below.
        var rollY = 1.0
        if let trick = motion.tricks[fish.id], trick.kind == .roll, now < trick.until {
            let p = clamp01(1 - trick.until.timeIntervalSince(now) / AquariumBehavior.trickDuration)
            rollY = cos(p * .pi * 2)
        } else if let trick = motion.tricks[fish.id], now >= trick.until {
            motion.tricks.removeValue(forKey: fish.id)
        }

        var f = canvas
        f.opacity = l.opacity * (1 - lane * 0.28)
        // Surface refraction: anything within ~8% of the waterline
        // wobbles a touch sideways — the meniscus's parallax.
        let wobble = !reduceMotion && l.y < size.height * 0.085
            ? sin(t * 2.3 + phase) * 1.6 : 0
        f.translateBy(x: l.x + wobble, y: l.y)
        // Rotate before the body scale so the pitch is rigid (no shear)
        // and `pitch * facing` keeps "nose down" the same for both
        // facings.
        if l.pitch + sway != 0 { f.rotate(by: .radians((l.pitch + sway) * l.facing)) }
        f.scaleBy(x: l.facing * l.thin * length * squashX, y: length * squashY * rollY)

        // The mouth says the game: a smile just after a meal, a small
        // "o" while the fish is starving, a soft curve cruising. A
        // sinking fish gets the X eye and no mouth opinion.
        let dead = fish.state == .sinking
        let mouth: CartoonFish.MouthKind =
            (!dead && (motion.smileUntil[fish.id].map { now < $0 } ?? false)) ? .smile
            : (!dead && (care?.hungry(at: now) ?? false) ? .hungry : .plain)
        // The blink: a lid slides down & back every few seconds,
        // offset per fish by its seed — and a fish dozing through the
        // tank's night lets its eyes fall shut.
        let blinkPhase = frac(t / (3.4 + Double((h >> 20) & 0xF) * 0.28) + phase)
        let wink = smooth(clamp01((blinkPhase - 0.94) / 0.025))
            * smooth(clamp01((1.0 - blinkPhase) / 0.025))
        let drowsy = smooth(clamp01((l.sleep - 0.3) / 0.5))
        let blink = dead || reduceMotion ? 0.0 : max(wink, drowsy)
        let lw = CartoonFish.outlineWidth(length)
        CartoonFish.draw(into: &f, species: fish.species, palette: palette, swim: swim,
                         mouth: mouth, blink: blink, dead: dead,
                         pointSize: length,
                         variant: fish.isFry || dead ? nil : care?.earnedVariant)
        // A purchased hat rides the head — same unit space, so the
        // pitch, flip and squash all apply to it. Failing a bought
        // hat, a full-grown fish on a streak tank goes royal: three
        // days of completions and the grown-ups wear the crown.
        // Accessories get their own slot; when the accessory is itself
        // headwear (top hat, headphones) it wins the head and the hat
        // stays in the pocket.
        if !fish.isFry {
            let accessory = game?.accessory(for: fish.id)
            let headAccessory = accessory == .topHat || accessory == .headphones
            if !headAccessory {
                let hat = game?.hat(for: fish.id)
                    ?? (AquariumBehavior.wearsCrown(streakDays: game?.streakDays ?? 0,
                                                    stage: care?.stage ?? 0) ? .hatCrown : nil)
                if let hat {
                    CartoonFish.drawHat(hat, into: &f, at: art.hatAnchor, scale: art.hatScale,
                                        tilt: art.hatTilt, lineWidth: lw)
                }
            }
            if let accessory {
                // The laptop only comes out while its fish is on the
                // clock; residents left theirs in the office.
                if accessory != .tinyLaptop
                    || (fish.state == .swimming && !fish.isResident) {
                    CartoonFish.drawAccessory(accessory, into: &f, art: art,
                                              trail: reduceMotion ? 0 : sin(clock.phase * 0.5),
                                              lineWidth: lw)
                }
            }
        }

        // An ask comes up for air: a small trail climbs from where the
        // rise began, and a bubble rides overhead growing till it pops.
        // Fry don't get one — a worker's ask surfaces on its parent.
        if fish.state == .surfacing, !fish.isFry {
            let since = now.timeIntervalSince(fish.stateSince)
            for k in 0..<3 {
                let birth = 0.15 + Double(k) * 0.42
                let age = since - birth
                guard age > 0, age < 2.6 else { continue }
                let release = smooth(clamp01(birth / 1.15))
                let startY = l.riseFrom + (24 - l.riseFrom) * release
                let r = 1.4 + Double(k) * 0.5
                let bx = l.x - l.facing * 6 + Double(k - 1) * 4 + sin(age * 3 + Double(k) * 2.1) * 4
                let by = startY - 4 - age * 30
                guard by > 3 else { continue }
                var b = canvas
                b.opacity = l.opacity * (1 - age / 2.6) * 0.5
                b.stroke(Path(ellipseIn: CGRect(x: bx - r, y: by - r, width: r * 2, height: r * 2)),
                         with: .color(.white), lineWidth: 0.7)
            }
            let rise = frac(t * 0.45 + phase / (.pi * 2))
            let bx = l.x + l.facing * 6 + sin(t * 3 + phase) * 2
            let by = l.y - height * 0.5 - 8 - rise * 20
            let br = 2.6 + rise * 1.2
            var b = canvas
            b.opacity = l.opacity * (1 - rise) * 0.9
            b.stroke(Path(ellipseIn: CGRect(x: bx - br, y: by - br, width: br * 2, height: br * 2)),
                     with: .color(.white), lineWidth: 0.9)
        }

        // Waiting at the glass: a soft glow ring pulses off its nose,
        // like a tap on the pane asking for you.
        if l.tapRing >= 0, !fish.isFry {
            let rr = (10 + l.tapRing * 54) * (length / Self.fishBaseLength)
            var g = canvas
            g.blendMode = .plusLighter
            g.stroke(Path(ellipseIn: CGRect(x: l.x + l.facing * length * 0.30 - rr,
                                            y: l.y - 5 - rr * 0.8,
                                            width: rr * 2, height: rr * 1.6)),
                     with: .color(.white.opacity(l.opacity * (1 - l.tapRing) * 0.35)),
                     lineWidth: 1.6)
        }

        // W13's evidence overlays — one marker, only what the plan
        // cites. A buoy is a buoy: the same glyph a fixture asserts
        // the overlay enum carries, drawn small above the fish.
        if let overlay = fish.plan?.overlay, !fish.isFry {
            drawOverlayMarker(overlay, l: l, canvas: &canvas,
                              length: length, height: height, t: t)
        }

        // What it's doing, drawn where it's doing it: the station's
        // small tell, only while the fish is actually stationed and the
        // cue is fresh — a fixture with no steering draws the same tell
        // wherever the fish is, so the proof shots still show it.
        if !fish.isFry, fish.state == .swimming, let cue = fish.cue, cue.isFresh(at: now),
           motion.stationed[fish.id] != nil || motion.bodies[fish.id] == nil {
            drawStationCue(cue, l: l, canvas: &canvas, size: size,
                           length: length, height: height, t: t, phase: phase)
        }
        if !fish.isFry, fish.state == .swimming, let markers = fish.plan?.parallelMarkers,
           markers > 0 {
            drawParallelMarkers(markers, l: l, canvas: &canvas, length: length,
                                height: height, t: t, phase: phase)
        }

        // An idle fish sipping the surface leaves one small bubble.
        if l.sip > 0.4, !fish.isFry {
            let br = 1.8 + (l.sip - 0.4) * 2
            var b = canvas
            b.opacity = l.opacity * (l.sip - 0.4) * 0.9
            b.stroke(Path(ellipseIn: CGRect(x: l.x + l.facing * 5 - br,
                                            y: l.y - height * 0.5 - 8 - l.sip * 12 - br,
                                            width: br * 2, height: br * 2)),
                     with: .color(.white), lineWidth: 0.7)
        }

        // The golden one's shimmer: two seeded glints flaring and dying
        // on their own phases, readable across the tank.
        if golden, !reduceMotion {
            for k in 0..<2 {
                let gs = AquariumBehavior.scramble(h &+ UInt64(k + 1) &* 0x9E3779B97F4A7C15)
                let gp = frac(t * (0.35 + Double(k) * 0.17) + Double(gs & 0xFF) / 0xFF)
                let ga = smooth(clamp01(gp / 0.12)) * (1 - smooth(clamp01((gp - 0.45) / 0.4)))
                guard ga > 0.01 else { continue }
                var g = canvas
                g.blendMode = .plusLighter
                g.opacity = l.opacity * ga
                // Glints catch on the body itself, whatever its fins do.
                let bodyHeight = art.bounds.height * length
                g.translateBy(x: l.x + (Double((gs >> 8) & 0xFF) / 0xFF - 0.5) * length * 0.8,
                              y: l.y - bodyHeight * 0.25 + (Double((gs >> 16) & 0xFF) / 0xFF - 0.5) * bodyHeight)
                let gs2 = 5.5 * (0.5 + ga * 0.5)
                g.scaleBy(x: gs2, y: gs2)
                g.fill(Self.starPath, with: .color(.white.opacity(0.85)))
            }
        }

        // Doing laps: a working fish with fresh output trails small
        // bubbles off its tail — the tank's "it's on it" tell.
        if fish.state == .swimming, !fish.isFry, recency < 12, !reduceMotion {
            let trail = 1 - recency / 12
            for k in 0..<3 {
                let tp = frac(t * 0.8 + Double(k) / 3 + phase / (.pi * 2))
                let bx = l.x - l.facing * (length * 0.42 + tp * 22)
                let by = l.y + 2 - tp * 16
                let br = 1.0 + tp * 1.8
                var b = canvas
                b.opacity = l.opacity * trail * (1 - tp) * 0.5
                b.stroke(Path(ellipseIn: CGRect(x: bx - br, y: by - br,
                                                width: br * 2, height: br * 2)),
                         with: .color(.white), lineWidth: 0.6)
            }
        }

        // A dozing fish breathes out the occasional slow "z".
        if l.sleep > 0.35, !fish.isFry {
            let zc = frac(t / 3.8 + phase / (.pi * 2))
            for k in 0..<2 {
                let zz = frac(zc + Double(k) * 0.5)
                guard zz < 0.6 else { continue }
                let bz = zz / 0.6
                let bx = l.x + l.facing * length * 0.3 + bz * 10
                let by = l.y - height * 0.3 - bz * 30
                var b = canvas
                b.opacity = l.opacity * l.sleep * (1 - bz) * 0.8
                if k == 0 {
                    let (resolved, _) = textCache.tag(for: "z", canvas: canvas)
                    b.draw(resolved, at: CGPoint(x: bx, y: by), anchor: .center)
                } else {
                    let br = 1.4 + bz * 2
                    b.stroke(Path(ellipseIn: CGRect(x: bx - br, y: by - br,
                                                    width: br * 2, height: br * 2)),
                             with: .color(.white), lineWidth: 0.7)
                }
            }
        }

        // The curious fish saw the pointer: a small bright pip overhead.
        if motion.curiousID == fish.id, !fish.isFry {
            let (resolved, _) = textCache.tag(for: "!", canvas: canvas)
            var c = canvas
            c.opacity = l.opacity * 0.9
            c.draw(resolved, at: CGPoint(x: l.x, y: l.y - height * 0.5 - 13),
                   anchor: .center)
        }

        // The label rides under the fish like a floating tag: small
        // type in a thin translucent chip, tied to the body by a
        // hairline tether — not a heavy slab glued underneath.
        if showLabels, !fish.isFry {
            var lc = canvas
            lc.opacity = l.opacity * (fish.state == .sinking ? 0.45 : 0.85)
            // Resolved glyphs are cached across frames — the label
            // doesn't change between reduces, only its anchor does.
            let (resolved, textSize) = textCache.chip(for: fish.label, canvas: canvas)
            let chipX = min(max(l.x, textSize.width / 2 + 14), size.width - textSize.width / 2 - 14)
            let chipY = min(l.y + height / 2 + 14, size.height - 14)
            let chip = CGRect(x: chipX - textSize.width / 2 - 6.5,
                              y: chipY - textSize.height / 2 - 2.5,
                              width: textSize.width + 13, height: textSize.height + 5)
            // The tether: a hairline from the body's underside down to
            // the chip — invisible when the chip is clamped sideways.
            if abs(chipX - l.x) < 20 {
                var tether = Path()
                tether.move(to: CGPoint(x: l.x, y: l.y + height / 2 + 3))
                tether.addLine(to: CGPoint(x: chipX, y: chip.minY))
                lc.stroke(tether, with: .color(.white.opacity(0.16)), lineWidth: 0.7)
            }
            let pill = Path(roundedRect: chip, cornerRadius: chip.height / 2)
            lc.fill(pill, with: .color(Color(red: 0.02, green: 0.07, blue: 0.13).opacity(0.38)))
            // A glassy edge: brighter where the surface light catches it.
            lc.stroke(pill, with: .linearGradient(
                Gradient(colors: [.white.opacity(0.22), .white.opacity(0.05)]),
                startPoint: CGPoint(x: 0, y: chip.minY), endPoint: CGPoint(x: 0, y: chip.maxY)),
                lineWidth: 0.6)
            lc.draw(resolved, at: CGPoint(x: chipX, y: chipY), anchor: .center)
        }
    }

    /// The empty-tank caption, resolved & measured once per frame so
    /// the decor pass can keep clear of it: a small translucent
    /// capsule pinned to the bottom-left with a 16 pt margin, like a
    /// gallery plaque set on the sand.
    /// W14's inspector: the selected fish's name, species, and the
    /// plan's own evidence line — so what the card says and why the
    /// fish looks the way it does are one fact. Open raises the
    /// session's terminal; it never answers or acts.
    /// The idle-game footnote on a fish: what the tank remembers about
    /// this session — growth, meals, hunger, headwear, goldenness.
    /// Nil when there's nothing to say.
    private func careNote(for fish: Fish) -> String? {
        guard let game = toy?.game else { return nil }
        var bits: [String] = []
        if let care = game.pets[fish.id] {
            if care.stage >= 2 { bits.append("full-grown") }
            else if care.stage == 1 { bits.append("grown") }
            if care.feedings > 0 {
                bits.append("\(care.feedings) meal\(care.feedings == 1 ? "" : "s")")
            }
            if care.hungry(at: Date()) { bits.append("hungry") }
        }
        if let hat = game.hat(for: fish.id) {
            bits.append("wearing \(hat.displayName.lowercased())")
        } else if AquariumBehavior.wearsCrown(streakDays: game.streakDays,
                                              stage: game.pets[fish.id]?.stage ?? 0) {
            bits.append("royal")
        }
        if !fish.isFry, AquariumBehavior.isGolden(seed: fish.seed) {
            bits.append("golden")
        }
        if !fish.isFry, let variant = game.pets[fish.id]?.earnedVariant {
            bits.append(variant.word)
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    func inspectorStrip(_ fish: Fish) -> some View {
        HStack(spacing: 10) {
            ProviderTile(style: ProviderStyle.style(for: fish.providerID), size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(fish.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if fish.isResident {
                    // The logbook: the session it remembers, not a plan.
                    let log = residentLog?.id == fish.id ? residentLog?.log : nil
                    Text(log?.swam ?? "A resident")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let record = log?.record {
                        Text(record)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(fish.plan?.evidence ?? fish.state.rawValue)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // Where it's working and what that means — the station
                // the evidence line above put it at.
                if let cue = fish.cue, cue.isFresh(at: Date()), !fish.isFry {
                    Text(cue.phrase)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let note = careNote(for: fish) {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            // Recast every fish this provider swims as — the pick is a
            // per-provider override, so the school changes shape at once.
            Picker(selection: Binding<FishSpecies?>(
                get: { toy?.speciesOverride(for: fish.providerID) },
                set: { toy?.setSpecies($0, for: fish.providerID) })) {
                Text("Automatic").tag(FishSpecies?.none)
                ForEach(FishSpecies.allCases, id: \.self) { species in
                    Text(species.displayName).tag(FishSpecies?.some(species))
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 108)
            .help("The fish every \(fish.providerID) session swims as.")
            // A resident's session has left; there's nothing to raise.
            if !fish.isResident, let onOpen = toy?.core.openSession {
                Button("Open") { onOpen(fish.id) }
                    .controlSize(.small)
            }
            Button {
                selectedID = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close inspector")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
}
