import Foundation

/// One fish's motion state, in unit tank space (x 0…1 across, y 0…1
/// down — y grows toward the sand like screen coordinates). The view
/// keeps one per fish and integrates it per frame; the steering itself
/// is pure so the behaviours are testable without a window.
///
/// Where the fish is going and which way it faces are kept apart: `dir`
/// is the side-on facing, `climb` how steeply it travels, and a
/// reversal is a committed U-turn (`turn`) rather than the heading
/// swinging through vertical.
public struct SwimBody: Equatable, Sendable {
    /// Position, unit tank space.
    public var x: Double
    public var y: Double
    /// The side-on facing: +1 swims right, -1 left.
    public var dir: Double
    /// The travel angle off level, radians: positive dives (y is down),
    /// negative climbs. Capped — a fish never swims straight up.
    public var climb: Double
    /// Cruise speed in tank-widths per second.
    public var speed: Double
    /// The tightest the path can bend, radians per second.
    public var turnRate: Double
    /// The personality scalar (docs/TOYS.md: some dart, some drift):
    /// <1 drifts, >1 darts.
    public var energy: Double
    /// The depth this fish prefers; wander springs weakly back to it.
    public var homeY: Double
    /// The U-turn under way, if any.
    public var turn: SwimTurn?
    /// The step clock when the last turn finished; the next waits out
    /// the pace's cooldown from here.
    public var lastTurnEnd: Double = -.infinity
    /// The fish's drawn length in tank widths — how far ahead the glass
    /// has to be seen.
    public var length: Double = 0.07
    /// The drawn pitch, radians, nose down positive: the travel's slope
    /// clamped and eased, so it never snaps.
    public var pitch: Double = 0
    /// How hard it is swimming against its cruise, eased so a dart, a
    /// hover and a glide all speed up and slow down rather than jump.
    public var throttle: Double = 1
    /// How long, in seconds, the way it wants to go has pointed behind
    /// it — a whim has to last a beat before the fish turns for it.
    public var backFor: Double = 0
    /// Turns made so far; seeds each turn's bow.
    public var turns: Int = 0
    /// A working fish's fin lift, unit tank heights per second (down
    /// positive): at a station it rises and sinks with the point it
    /// works at instead of swimming loops to follow it. Eased, 0 off
    /// station.
    public var lift: Double = 0

    /// Direction of travel in radians: 0 swims right, +π/2 dives,
    /// ±π swims left. Read from `dir` and `climb`; setting it splits it
    /// back into the two.
    public var heading: Double {
        get { dir > 0 ? climb : .pi - climb }
        set {
            dir = cos(newValue) >= 0 ? 1 : -1
            climb = asin(max(-1, min(1, sin(newValue))))
        }
    }

    /// The original shape: a heading instead of a facing and a climb.
    public init(x: Double, y: Double, heading: Double, speed: Double,
                turnRate: Double, energy: Double, homeY: Double) {
        self.x = x
        self.y = y
        self.dir = cos(heading) >= 0 ? 1 : -1
        self.climb = asin(max(-1, min(1, sin(heading))))
        self.speed = speed
        self.turnRate = turnRate
        self.energy = energy
        self.homeY = homeY
    }

    public init(x: Double, y: Double, dir: Double, climb: Double = 0, speed: Double,
                turnRate: Double, energy: Double, homeY: Double, length: Double = 0.07) {
        self.x = x
        self.y = y
        self.dir = dir >= 0 ? 1 : -1
        self.climb = climb
        self.speed = speed
        self.turnRate = turnRate
        self.energy = energy
        self.homeY = homeY
        self.length = length
    }
}

/// The swimmable rectangle in unit space, plus the soft margin inside
/// it where the boundary avoidance starts turning the fish away.
public struct SwimBounds: Equatable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double
    /// Distance from a wall where the soft turn begins.
    public var margin: Double

    public init(minX: Double = 0.04, minY: Double = 0.07,
                maxX: Double = 0.96, maxY: Double = 0.86,
                margin: Double = 0.10) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
        self.margin = margin
    }
}

/// What one step of `AquariumSteering.step` weighs: food seeking wins,
/// then a station, then the glass, then a light pull toward the school,
/// then wander.
public struct SwimContext: Sendable {
    public var bounds: SwimBounds
    /// A pellet the fish is going for, unit space. nil: no food.
    public var food: (x: Double, y: Double)?
    /// The school's centre, unit space — same-provider fish loosely
    /// group. nil: this fish swims alone.
    public var school: (x: Double, y: Double)?
    /// How hard the wander noise bends the path; an idling fish passes
    /// a small value, a darting one a large.
    public var wander: Double
    /// How hard the fish chases food: a hungry dart is faster than a
    /// cruise.
    public var hunger: Double
    /// Pace multiplier on the whole step: an idling fish passes ~0.4
    /// and drifts, a working one passes 1.
    public var effort: Double
    /// A work station's moving point (`AquariumStations.target`): the
    /// fish swims there and hovers once it arrives, rather than
    /// chasing it like food.
    public var station: (x: Double, y: Double)?
    /// The food is a place to flee to, not a meal: a tap on the glass.
    public var startled: Bool
    /// The idle state's lazy turns.
    public var idling: Bool
    /// The tank's swim pace.
    public var pace: SwimPace
    /// The swimming-speed setting: 2 covers twice the ground in the
    /// same time along the same shape of path — speed and turning scale
    /// together, so the turning radius holds.
    public var tempo: Double

    public init(bounds: SwimBounds = SwimBounds(),
                food: (x: Double, y: Double)? = nil,
                school: (x: Double, y: Double)? = nil,
                wander: Double = 1,
                hunger: Double = 1,
                effort: Double = 1,
                station: (x: Double, y: Double)? = nil,
                startled: Bool = false,
                idling: Bool = false,
                pace: SwimPace = .natural,
                tempo: Double = 1) {
        self.bounds = bounds
        self.food = food
        self.school = school
        self.wander = wander
        self.hunger = hunger
        self.effort = effort
        self.station = station
        self.startled = startled
        self.idling = idling
        self.pace = pace
        self.tempo = tempo
    }
}

/// Steering behaviours for the tank (docs/TOYS.md): wander gently bends
/// the path at a turn *rate*, a weak spring holds the fish near its
/// depth, the glass is seen coming, food is a dart, a station is swum to
/// and hovered at, and the school is a weak pull toward the same-provider
/// group's centre. Turning back is its own committed behaviour — a
/// U-turn with a beat of hesitation before it and a cooldown after —
/// so a fish reverses a couple of times a minute, mostly at the glass,
/// instead of spinning. Everything is a pure function of the body, the
/// clock and the seed: two fish never share a path.
public enum AquariumSteering {
    /// The climb a cruising fish keeps under, radians (about 26°).
    public static let cruiseClimb = 0.45
    /// The climb a fish may take for food, a scare or a station.
    public static let seekClimb = 0.9
    /// The drawn pitch never tips past this, radians.
    public static let maxPitch = 0.55
    /// How fast the drawn pitch follows the travel, per second.
    public static let pitchDamping = 5.0
    /// How long a whim to turn back must last, seconds.
    public static let hesitation = 0.25
    /// Food and a scare may turn a fish this soon after its last turn.
    public static let urgentCooldown = 0.6
    /// The most a working fish's fins lift or sink it, as a share of
    /// its cruise.
    public static let stationLift = 0.8

    /// Smooth wander noise in −1…1: a few incommensurate sines off the
    /// seed, so it never repeats on any human timescale and every fish
    /// drifts differently. Deterministic — the same seed and clock
    /// always give the same nudge.
    public static func wanderNoise(seed: UInt64, at t: Double) -> Double {
        let a = Double(seed & 0xFFFF) / 0xFFFF * .pi * 2
        let b = Double((seed >> 16) & 0xFFFF) / 0xFFFF * .pi * 2
        let c = Double((seed >> 32) & 0xFFFF) / 0xFFFF * .pi * 2
        return sin(t * 0.31 + a) * 0.52
            + sin(t * 0.83 + b) * 0.31
            + sin(t * 1.97 + c) * 0.17
    }

    /// The cruise's slow breathing, 0.64…1: a fish swims on, eases into
    /// a glide and swims on again, on its own seeded rhythm.
    public static func glide(seed: UInt64, at t: Double) -> Double {
        let a = Double((seed >> 8) & 0xFFFF) / 0xFFFF * .pi * 2
        let b = Double((seed >> 40) & 0xFFFF) / 0xFFFF * .pi * 2
        return 0.82 + 0.12 * sin(t * 0.21 + a) + 0.06 * sin(t * 0.57 + b)
    }

    /// The side of the tank a fish is drawn toward, −1…1, drifting over
    /// a couple of minutes on its own seed. Near ±1 it is a change of
    /// mind: a fish heading the other way in open water turns round.
    public static func whim(seed: UInt64, at t: Double) -> Double {
        let a = Double((seed >> 24) & 0xFFFF) / 0xFFFF * .pi * 2
        return sin(t * 0.043 + a)
    }

    /// The shortest signed turn from `from` to `to`, in −π…π.
    public static func turnDelta(from: Double, to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: .pi * 2)
        if d > .pi { d -= .pi * 2 }
        if d < -.pi { d += .pi * 2 }
        return d
    }

    /// Rotate `heading` toward `desired`, at most `maxTurn` radians.
    /// The fish can never snap — it arcs.
    public static func steer(_ heading: Double, toward desired: Double,
                             maxTurn: Double) -> Double {
        let d = turnDelta(from: heading, to: desired)
        return heading + min(maxTurn, max(-maxTurn, d))
    }

    /// The boundary's preferred heading, or nil while the fish is clear
    /// of every wall. Inside the margin the fish is steered straight
    /// off the wall: the correction vector points into the tank,
    /// growing as the wall nears, and the resulting heading blends the
    /// repulsion with the fish's own direction so the turn reads as a
    /// bank rather than a bounce.
    public static func boundaryDesired(_ body: SwimBody, bounds: SwimBounds) -> Double? {
        let m = bounds.margin
        var rx = 0.0
        var ry = 0.0
        if body.x < bounds.minX + m { rx += (bounds.minX + m - body.x) / m }
        if body.x > bounds.maxX - m { rx -= (body.x - (bounds.maxX - m)) / m }
        if body.y < bounds.minY + m { ry += (bounds.minY + m - body.y) / m }
        if body.y > bounds.maxY - m { ry -= (body.y - (bounds.maxY - m)) / m }
        guard rx != 0 || ry != 0 else { return nil }
        // Blend the repulsion with the current travel direction so a
        // fish skimming the wall keeps swimming along it instead of
        // stalling nose-into-the-glass.
        let vx = cos(body.heading) + rx * 2.2
        let vy = sin(body.heading) + ry * 2.2
        return atan2(vy, vx)
    }

    /// The new fish's body, from its id's seed: somewhere inside the
    /// glass at its home depth, facing the way its swim says, at a
    /// calm cruise. `fishSpeed` is the model's per-fish speed; the
    /// steering maps it into a narrow band so the quickest fish still
    /// crosses the tank in a quarter of a minute or so.
    public static func spawn(seed h: UInt64, fishSpeed: Double, direction: Double,
                             homeY: Double, length: Double) -> SwimBody {
        func unit(_ shift: UInt64) -> Double {
            Double((h >> shift) & 0xFFFF) / 0xFFFF
        }
        return SwimBody(x: 0.15 + 0.7 * unit(0), y: homeY, dir: direction, climb: 0,
                        speed: cruiseSpeed(fishSpeed: fishSpeed),
                        turnRate: 1.8 + 1.2 * unit(24),
                        energy: 0.88 + 0.24 * unit(40),
                        homeY: homeY, length: length)
    }

    /// A fish's cruise in tank widths per second for the model's speed
    /// (0.05…0.14): 0.026…0.050, about half to four fifths of a body
    /// length a second on a tank-sized fish.
    public static func cruiseSpeed(fishSpeed: Double) -> Double {
        0.026 + 0.27 * min(0.09, max(0, fishSpeed - 0.05))
    }

    /// One integration step. A turn under way runs on; otherwise the
    /// fish weighs food, then its station, then the glass, then the
    /// school, then wander, and either bends its climb toward what it
    /// wants or — when that lies behind it for long enough — commits
    /// to a U-turn. `dt` is seconds since the last step, already
    /// clamped by the caller; `t` is the frame clock for the noise.
    public static func step(_ body: inout SwimBody, dt: Double, t: Double,
                            seed: UInt64, context: SwimContext) {
        guard dt > 0 else { return }
        let tempo = min(3, max(0.25, context.tempo))
        let pace = context.pace
        let bounds = context.bounds
        let cruise = body.speed * body.energy * pace.cruiseScale * tempo

        // At a station the fins hold the fish level with the point,
        // through a turn as much as out of one.
        var liftTarget = 0.0
        if context.food == nil, let goal = context.station {
            let most = stationLift * cruise
            liftTarget = min(most, max(-most, (goal.y - body.y) * 1.5 * tempo))
        }
        body.lift += (liftTarget - body.lift) * min(1, 3 * tempo * dt)

        if body.turn != nil {
            stepTurn(&body, dt: dt, t: t, cruise: cruise, context: context)
            return
        }

        let heading = body.heading
        let dir = body.dir
        // The wander bends the path at a gentle rate; the depth spring
        // eases the climb toward the angle that would bring it home.
        let noise = wanderNoise(seed: seed, at: t)
        let depthAngle = atan2((body.homeY - body.y) * 0.9, 1.25)
        var climbRate = noise * dir * context.wander * pace.wanderRate * tempo
            + 0.35 * tempo * (depthAngle - body.climb)
        var cap = cruiseClimb
        var urgency = 1.0
        var throttleTarget = context.effort * glide(seed: seed, at: t)

        // What the fish would turn back for, and how.
        var backKind: SwimTurn.Kind?
        var urgent = false
        var immediate = false
        // A turn back toward a station waits out the station's longer
        // cooldown: working fish potter, they don't pace.
        var stationBack = false
        // A goal ahead and close suppresses the glass's lookahead: it
        // swims up to food by the wall instead of turning away from it.
        var goalAheadX: Double?

        // The school only pulls a fish with nothing better to do: food
        // and work both outrank it.
        if context.food == nil, context.station == nil, let school = context.school {
            let dx = school.x - body.x
            let dy = school.y - body.y
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist > 0.14 {
                let pull = min(1, (dist - 0.14) * 3) * 0.5
                let want = heading + turnDelta(from: heading, to: atan2(dy, dx)) * pull
                if cos(want) * dir < -0.25 {
                    backKind = context.idling ? .idle : .cruise
                } else {
                    climbRate += pull * 1.2 * tempo * (clampClimb(want, cap) - body.climb)
                }
            }
        }

        // A change of mind, now and then, well clear of the glass and
        // well after the last turn — never with food, a scare or work
        // to see to.
        let clear = min(body.x - bounds.minX, bounds.maxX - body.x) > 0.3
            && t - body.lastTurnEnd > 6 / tempo
        if clear, context.food == nil, context.station == nil,
           whim(seed: seed, at: t) * dir < -0.985 {
            backKind = context.idling ? .idle : .cruise
        }

        if let food = context.food {
            let dx = food.x - body.x
            let dy = food.y - body.y
            cap = seekClimb
            urgency = 1.9 * context.hunger
            // A dart, easing off into the last few points so the mouth
            // meets the food instead of shooting past it; a scare is all
            // dart.
            let reach = context.startled ? 1 : min(1, max(0.15, (dx * dx + dy * dy).squareRoot() / 0.05))
            throttleTarget = 1.9 * context.hunger * reach
            if dx * dir < 0 && abs(dx) > 0.004 {
                backKind = context.startled ? .startle : .food
                urgent = true
                immediate = true
            } else {
                let want = atan2(dy, max(abs(dx), 0.01) * dir)
                climbRate = 4 * tempo * (clampClimb(want, cap) - body.climb)
                goalAheadX = abs(dx)
            }
        } else if let goal = context.station {
            let dx = goal.x - body.x
            let dy = goal.y - body.y
            let dist = (dx * dx + dy * dy).squareRoot()
            let ahead = dx * dir
            let arrived = dist < AquariumStations.arriveRadius
            cap = arrived ? cruiseClimb : seekClimb
            // Only a point well behind turns it round — behind by more
            // than the station's reach, and by more than half how far
            // it lies above or below, so a point overhead is risen to
            // (the fins' lift) rather than paced under.
            if ahead < -max(AquariumStations.arriveRadius, 0.5 * abs(dy)) {
                backKind = .cruise
                stationBack = true
                throttleTarget = min(throttleTarget, 0.04)
            } else {
                // The pace follows how far ahead the point lies: a swim
                // across to it, easing to a hover as it draws level.
                let near = min(1, max(0, (ahead + 0.01) / 0.10))
                throttleTarget = max(0.04, throttleTarget * near)
                let want = atan2(dy, max(abs(dx), 0.02) * dir)
                climbRate = (arrived ? 1.5 : 2) * tempo * (clampClimb(want, cap) - body.climb)
                goalAheadX = max(0, ahead)
            }
        }

        // The glass, top and bottom: ease the climb off the surface and
        // the sand before the hard clamp has to.
        let m = bounds.margin
        if body.y < bounds.minY + m {
            let ry = min(1, (bounds.minY + m - body.y) / m)
            climbRate += 3 * tempo * ry * (cruiseClimb * min(1, ry * 1.5) - body.climb)
        } else if body.y > bounds.maxY - m {
            let ry = min(1, (body.y - (bounds.maxY - m)) / m)
            climbRate += 3 * tempo * ry * (-cruiseClimb * min(1, ry * 1.5) - body.climb)
        }
        // A climb over the cap (left from a dart) eases back under it.
        if abs(body.climb) > cap {
            climbRate += -(body.climb - (body.climb > 0 ? cap : -cap)) * 3 * tempo
        }

        // The glass ahead, seen far enough off that the turn's forward
        // drift and half a body still fit: a wall turn, no hesitation.
        let v = cruise * max(body.throttle, throttleTarget)
        let wallT = AquariumTurn.duration(for: .wall, pace: pace, tempo: tempo)
        let reach = v * wallT / .pi + 0.55 * body.length + v * dt
        let room = dir > 0 ? bounds.maxX - body.x : body.x - bounds.minX
        if room < reach, goalAheadX.map({ $0 >= room - 0.55 * body.length }) ?? true {
            if backKind == nil || !urgent { backKind = .wall }
            immediate = true
            stationBack = false
        }

        // Turn back, or wait for it.
        if let kind = backKind {
            body.backFor += dt
            let since = t - body.lastTurnEnd
            let rest = stationBack ? max(pace.cooldown, AquariumStations.turnCooldown) : pace.cooldown
            let cooled = since >= rest / tempo
                || (urgent && since >= urgentCooldown)
            if cooled && (immediate || body.backFor >= hesitation) {
                beginTurn(&body, kind: kind, t: t, seed: seed, pace: pace, tempo: tempo,
                          bounds: bounds)
                stepTurn(&body, dt: dt, t: t, cruise: cruise, context: context)
                return
            }
            if !cooled {
                // Waiting it out: level off and ease back, never
                // rotating through vertical — and never darting the
                // wrong way while food behind it waits its short beat.
                // Only a scare keeps its dash.
                climbRate = 2 * tempo * (0 - body.climb)
                if kind == .wall {
                    throttleTarget = min(throttleTarget, 0.15)
                } else if kind != .startle {
                    throttleTarget = min(throttleTarget, 0.3)
                }
            }
        } else {
            body.backFor = 0
        }

        let maxRate = body.turnRate * urgency * tempo
        climbRate = min(maxRate, max(-maxRate, climbRate))
        // Under the cap it stays under; a climb left over the cap from a
        // dart may only ease back toward it, never steepen.
        let limit = max(cap, abs(body.climb))
        body.climb = min(limit, max(-limit, body.climb + climbRate * dt))

        easeThrottle(&body, toward: throttleTarget, dt: dt, tempo: tempo)
        let speed = cruise * body.throttle
        let vx = speed * dir * cos(body.climb)
        let vy = speed * sin(body.climb)
        body.x += vx * dt
        body.y += (vy + body.lift) * dt
        clampInside(&body, bounds)
        // A fin lift tips the nose only a little: the fish rises level.
        let travel = atan2(vy + 0.3 * body.lift, abs(vx) + 0.25 * max(cruise, 1e-6))
        easePitch(&body, toward: travel, dt: dt)
    }

    /// A turn under way: the U-turn in depth, seen side-on. The screen
    /// x-speed runs `cos(πp)` — it dips through zero and comes back the
    /// other way — while the loop bows a little up or down, and the
    /// climb it carried fades out through the middle and back.
    private static func stepTurn(_ body: inout SwimBody, dt: Double, t: Double, cruise: Double,
                                 context: SwimContext) {
        guard var turn = body.turn else { return }
        let tempo = min(3, max(0.25, context.tempo))
        // A dart speeds up into the turn; any other turn keeps the pace
        // it came in with — a hovering fish turns round where it hovers.
        if turn.kind == .food || turn.kind == .startle {
            easeThrottle(&body, toward: 1.9 * context.hunger, dt: dt, tempo: tempo)
        }
        turn.progress = min(1, turn.progress + dt / max(0.05, turn.duration))
        let p = turn.progress
        let s = sin(.pi * p)
        let v0 = cruise * body.throttle
        let vx = v0 * turn.from * cos(.pi * p)
        let vy = v0 * (0.20 * turn.arc * s + sin(body.climb) * (1 - s))
        body.x += vx * dt
        body.y += (vy + body.lift) * dt
        clampInside(&body, context.bounds)
        let pose = AquariumTurn.pose(p: p, dir0: turn.from, arc: turn.arc, climb: body.climb)
        easePitch(&body, toward: pose.pitch, dt: dt)
        if p >= 1 {
            body.dir = -turn.from
            body.turn = nil
            body.lastTurnEnd = t
            body.turns += 1
            body.backFor = 0
        } else {
            body.turn = turn
        }
    }

    private static func beginTurn(_ body: inout SwimBody, kind: SwimTurn.Kind, t: Double,
                                  seed: UInt64, pace: SwimPace, tempo: Double,
                                  bounds: SwimBounds) {
        // The loop's bow, seeded per fish and per turn, but always away
        // from whichever of the surface or the sand is close.
        let roll = (seed &+ UInt64(body.turns) &* 0x9E37_79B9_7F4A_7C15) >> 29
        var arc: Double = roll & 1 == 0 ? 1 : -1
        if body.y - bounds.minY < 0.12 { arc = 1 }
        if bounds.maxY - body.y < 0.12 { arc = -1 }
        body.turn = SwimTurn(kind: kind, start: t,
                             duration: AquariumTurn.duration(for: kind, pace: pace, tempo: tempo),
                             from: body.dir, arc: arc)
        body.backFor = 0
    }

    /// The climb that `heading` asks for, as a fish facing its own way
    /// can take it: its rise or fall, capped.
    private static func clampClimb(_ heading: Double, _ cap: Double) -> Double {
        let raw = asin(max(-1, min(1, sin(heading))))
        return min(cap, max(-cap, raw))
    }

    private static func easeThrottle(_ body: inout SwimBody, toward target: Double, dt: Double,
                                     tempo: Double) {
        let rate = (target > body.throttle ? 3.0 : 2.0) * tempo
        body.throttle += (target - body.throttle) * min(1, rate * dt)
    }

    private static func easePitch(_ body: inout SwimBody, toward target: Double, dt: Double) {
        let clamped = min(maxPitch, max(-maxPitch, target))
        body.pitch += (clamped - body.pitch) * (1 - exp(-pitchDamping * dt))
    }

    /// Hard clamp: the glass is a behaviour, not a guarantee — a fast
    /// fish in a small tank still never leaves the water.
    private static func clampInside(_ body: inout SwimBody, _ bounds: SwimBounds) {
        body.x = min(bounds.maxX, max(bounds.minX, body.x))
        body.y = min(bounds.maxY, max(bounds.minY, body.y))
    }

    /// The drawn angle for a heading: how far the body rotates about
    /// its centre, positive pitching the nose down. Works under the
    /// view's facing-flip: `asin(sin)` is the pitch both facings share.
    @available(*, deprecated, message: "Use SwimBody.pitch, the eased and clamped drawn pitch.")
    public static func pitch(forHeading heading: Double) -> Double {
        asin(sin(heading))
    }
}
