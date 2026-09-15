import Foundation

/// One fish's motion state, in unit tank space (x 0…1 across, y 0…1
/// down — y grows toward the sand like screen coordinates). The view
/// keeps one per fish and integrates it per frame; the steering itself
/// is pure so the behaviours are testable without a window.
public struct SwimBody: Equatable, Sendable {
    /// Position, unit tank space.
    public var x: Double
    public var y: Double
    /// Direction of travel in radians: 0 swims right, +π/2 dives
    /// (y is down), ±π swims left.
    public var heading: Double
    /// Cruise speed in tank-widths per second.
    public var speed: Double
    /// The tightest turn it can make, radians per second.
    public var turnRate: Double
    /// The personality scalar (docs/TOYS.md: some dart, some drift):
    /// <1 drifts, >1 darts.
    public var energy: Double
    /// The depth this fish prefers; wander springs weakly back to it.
    public var homeY: Double

    public init(x: Double, y: Double, heading: Double, speed: Double,
                turnRate: Double, energy: Double, homeY: Double) {
        self.x = x
        self.y = y
        self.heading = heading
        self.speed = speed
        self.turnRate = turnRate
        self.energy = energy
        self.homeY = homeY
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
/// then the glass, then a light pull toward the school, then wander.
public struct SwimContext: Sendable {
    public var bounds: SwimBounds
    /// A pellet the fish is going for, unit space. nil: no food.
    public var food: (x: Double, y: Double)?
    /// The school's centre, unit space — same-provider fish loosely
    /// group. nil: this fish swims alone.
    public var school: (x: Double, y: Double)?
    /// How hard the wander noise pushes the heading around; an idling
    /// fish passes a small value, a darting one a large.
    public var wander: Double
    /// How hard the fish chases food: a hungry dart is faster than a
    /// cruise.
    public var hunger: Double
    /// Pace multiplier on the whole step: an idling fish passes ~0.4
    /// and drifts, a working one passes 1.
    public var effort: Double

    public init(bounds: SwimBounds = SwimBounds(),
                food: (x: Double, y: Double)? = nil,
                school: (x: Double, y: Double)? = nil,
                wander: Double = 1,
                hunger: Double = 1,
                effort: Double = 1) {
        self.bounds = bounds
        self.food = food
        self.school = school
        self.wander = wander
        self.hunger = hunger
        self.effort = effort
    }
}

/// Steering behaviours for the tank (docs/TOYS.md): wander is
/// perlin-ish heading noise keyed off the fish's seed, the glass turns
/// a fish away softly before it arrives, food is a direct seek, and
/// the school is a weak pull toward the same-provider group's centre —
/// strong enough to read as company, weak enough that paths never
/// lock together. Everything is a pure function of the body, the
/// clock and the seed: two fish never share a path.
public enum AquariumSteering {
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

    /// One integration step. Priority: food (a direct seek, at a dart),
    /// then the glass (soft turn), then the school (weak pull when far
    /// away), then wander noise around a weak spring toward home
    /// depth. `dt` is seconds since the last step, already clamped by
    /// the caller; `t` is the frame clock for the noise.
    public static func step(_ body: inout SwimBody, dt: Double, t: Double,
                            seed: UInt64, context: SwimContext) {
        var desired = body.heading
        var urgency = 1.0

        // Wander: noise-bent heading with a weak spring home in depth.
        let wanderTurn = wanderNoise(seed: seed, at: t) * context.wander * 0.85
        let depthPull = atan2((body.homeY - body.y) * 0.9, cos(body.heading).magnitude + 0.25)
        desired = body.heading + wanderTurn + depthPull * 0.35

        // Schooling: only pulls when the group has drifted apart, and
        // never harder than half way — a school that fuses into one
        // point stops looking like fish.
        if let school = context.school {
            let dx = school.x - body.x
            let dy = school.y - body.y
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist > 0.14 {
                let pull = min(1, (dist - 0.14) * 3) * 0.5
                let toward = atan2(dy, dx)
                desired = body.heading + turnDelta(from: body.heading, to: desired) * (1 - pull)
                    + turnDelta(from: body.heading, to: toward) * pull
            }
        }

        // The glass outranks wander & school — swimming into the wall
        // reads broken no matter how good the wander was.
        if let wall = boundaryDesired(body, bounds: context.bounds) {
            desired = wall
            urgency = 1.5
        }

        // Food outranks everything: a pellet is a straight seek.
        if let food = context.food {
            desired = atan2(food.y - body.y, food.x - body.x)
            urgency = 1.9 * context.hunger
        }

        body.heading = steer(body.heading, toward: desired,
                             maxTurn: body.turnRate * urgency * dt)
        let pace = body.speed * body.energy * context.effort
            * (context.food != nil ? 1.9 * context.hunger : 1)
        body.x += cos(body.heading) * pace * dt
        body.y += sin(body.heading) * pace * dt
        // Hard clamp: the soft turn is a behaviour, not a guarantee —
        // a fast fish in a small tank still never leaves the water.
        body.x = min(context.bounds.maxX, max(context.bounds.minX, body.x))
        body.y = min(context.bounds.maxY, max(context.bounds.minY, body.y))
    }

    /// The drawn angle for a heading: how far the body rotates about
    /// its centre, positive pitching the nose down. Works under the
    /// view's facing-flip: `asin(sin)` is the pitch both facings share.
    public static func pitch(forHeading heading: Double) -> Double {
        asin(sin(heading))
    }
}
