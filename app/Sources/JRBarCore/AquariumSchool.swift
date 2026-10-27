import Foundation

/// A little school that moves as a flock: Craig Reynolds' boids
/// ("Flocks, Herds, and Schools", SIGGRAPH 1987), reimplemented from the
/// paper. Each fish keeps clear of the ones touching it (separation),
/// turns toward the way its neighbours swim (alignment) and drifts to
/// their middle (cohesion); a gentle pull to a goal (a parent's flank, a
/// wander target), soft walls and a push away from bigger fish keep the
/// school where it belongs. Fry and the tetra school use it.
///
/// It steps on a fixed clock, `step` seconds at a time, so the school
/// moves the same at 30 fps and 15, and a frame never pays for more than
/// `maxStepsPerFrame` steps: a long gap (a hidden window) is skipped,
/// not replayed. Each fish counts at most `Tuning.maxNeighbours`
/// neighbours, so a step is bounded however the school bunches.
///
/// Fish never mirror: `facing` eases from one side to the other at a
/// capped rate and passes through head-on on the way, like every other
/// turn in the tank.
public struct SchoolFlock: Equatable, Sendable {
    /// One fish of the school, in the tank's points.
    public struct Member: Equatable, Sendable {
        public var id: String
        public var x: Double
        public var y: Double
        public var vx: Double
        public var vy: Double
        /// The side-on share it faces, +1 right to −1 left, eased.
        public var facing: Double
        /// Whether it flocks: a fish sinking or leaving holds still here
        /// while its own animation plays.
        public var active = true
        /// The frame clock it was last asked for, to forget leavers.
        public var seen: Double

        public init(id: String, x: Double, y: Double, vx: Double = 0, vy: Double = 0,
                    facing: Double = 1, seen: Double) {
            self.id = id
            self.x = x
            self.y = y
            self.vx = vx
            self.vy = vy
            self.facing = facing
            self.seen = seen
        }
    }

    /// A round thing to swim around: a bigger fish.
    public struct Obstacle: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var radius: Double

        public init(x: Double, y: Double, radius: Double) {
            self.x = x
            self.y = y
            self.radius = radius
        }
    }

    /// The school's character, in points and seconds.
    public struct Tuning: Equatable, Sendable {
        /// Who counts as a neighbour, about three body lengths.
        public var neighbourRadius: Double
        /// Closer than this, a neighbour pushes away; strongest at touch.
        public var separationRadius: Double
        public var separation: Double
        public var alignment: Double
        public var cohesion: Double
        /// The pull toward the goal, per point of distance.
        public var goalPull: Double
        /// Past this far from the goal the pull grows steeply: no fish
        /// strays from its school.
        public var leash: Double
        public var maxSpeed: Double
        public var minSpeed: Double
        /// The steering's cap: how hard a fish can turn or speed up.
        public var maxAccel: Double
        /// How far ahead of an obstacle's edge a fish starts to veer.
        public var avoidMargin: Double
        /// How long a full turn from one side to the other takes.
        public var turnTime: Double
        public var maxNeighbours = 6

        public init(neighbourRadius: Double, separationRadius: Double, separation: Double,
                    alignment: Double, cohesion: Double, goalPull: Double, leash: Double,
                    maxSpeed: Double, minSpeed: Double, maxAccel: Double, avoidMargin: Double,
                    turnTime: Double) {
            self.neighbourRadius = neighbourRadius
            self.separationRadius = separationRadius
            self.separation = separation
            self.alignment = alignment
            self.cohesion = cohesion
            self.goalPull = goalPull
            self.leash = leash
            self.maxSpeed = maxSpeed
            self.minSpeed = minSpeed
            self.maxAccel = maxAccel
            self.avoidMargin = avoidMargin
            self.turnTime = turnTime
        }

        /// A parent's fry: tight round its flank.
        public static let fry = Tuning(neighbourRadius: 58, separationRadius: 20, separation: 620,
                                       alignment: 1.6, cohesion: 1.1, goalPull: 2.2, leash: 62,
                                       maxSpeed: 95, minSpeed: 10, maxAccel: 260, avoidMargin: 10,
                                       turnTime: 0.34)
        /// The tetra school: looser, quicker, out in the midwater.
        public static let tetra = Tuning(neighbourRadius: 46, separationRadius: 15, separation: 520,
                                         alignment: 1.8, cohesion: 0.9, goalPull: 0.9, leash: 90,
                                         maxSpeed: 70, minSpeed: 14, maxAccel: 200, avoidMargin: 14,
                                         turnTime: 0.4)
    }

    /// The tank's walls, the soft kind: a fish nearing one is turned back.
    public struct Bounds: Equatable, Sendable {
        public var minX: Double
        public var minY: Double
        public var maxX: Double
        public var maxY: Double

        public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
        }
    }

    /// The fixed step, seconds.
    public static let step = 1.0 / 30
    /// The most steps one frame pays for.
    public static let maxStepsPerFrame = 4
    /// A fish not asked for this long has left the school.
    public static let forgetAfter = 1.0

    /// Sorted by id, so a step visits them in the same order every run.
    public private(set) var members: [Member] = []
    /// The frame clock the school has stepped to; nil before its first.
    public private(set) var time: Double?

    public init() {}

    /// The member `id`, if it swims here.
    public func member(_ id: String) -> Member? {
        index(of: id).map { members[$0] }
    }

    private func index(of id: String) -> Int? {
        var low = 0
        var high = members.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if members[mid].id == id { return mid }
            if members[mid].id < id { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    /// Ask for `id` at frame `t`: a newcomer joins at `spawn`, facing
    /// `facing`. Marks it seen and says whether it flocks this frame.
    @discardableResult
    public mutating func join(_ id: String, at t: Double, spawn: () -> (x: Double, y: Double),
                              facing: Double, active: Bool = true) -> Member {
        if let i = index(of: id) {
            members[i].seen = t
            if members[i].active != active {
                members[i].active = active
                if active {
                    // Back from a pause of its own: it sets off slowly.
                    members[i].vx = 0
                    members[i].vy = 0
                }
            }
            return members[i]
        }
        let at = spawn()
        var member = Member(id: id, x: at.x, y: at.y, facing: facing >= 0 ? 1 : -1, seen: t)
        member.active = active
        let slot = members.firstIndex { $0.id > id } ?? members.count
        members.insert(member, at: slot)
        return member
    }

    /// Step the school to frame `t` in fixed steps, toward `goal`, inside
    /// `bounds`, around `obstacles`. `pace` scales the speeds (an idling
    /// school mills at under half); a clock set back holds the school
    /// still and counts from the new clock.
    public mutating func advance(to t: Double, goal: (x: Double, y: Double), bounds: Bounds,
                                 obstacles: [Obstacle], tuning: Tuning, pace: Double = 1) {
        guard let from = time else {
            time = t
            return
        }
        guard t > from else {
            if t < from { time = t }
            return
        }
        // A hair of slack: a frame clock far from zero lands a whisker
        // short of a whole step, and must not owe it to the next frame.
        let due = Int(((t - from) / Self.step + 0.01).rounded(.down))
        guard due > 0 else { return }
        // Only a stepping frame forgets the fry that left.
        if members.contains(where: { t - $0.seen > Self.forgetAfter }) {
            members.removeAll { t - $0.seen > Self.forgetAfter }
        }
        let steps = min(due, Self.maxStepsPerFrame)
        for _ in 0..<steps {
            stepOnce(goal: goal, bounds: bounds, obstacles: obstacles, tuning: tuning, pace: pace)
        }
        // A gap longer than the frame may pay for is skipped, not owed.
        time = due > steps ? t : from + Double(steps) * Self.step
    }

    private mutating func stepOnce(goal: (x: Double, y: Double), bounds: Bounds,
                                   obstacles: [Obstacle], tuning k: Tuning, pace: Double) {
        let dt = Self.step
        let maxSpeed = k.maxSpeed * pace
        let minSpeed = k.minSpeed * pace
        let snapshot = members
        for i in members.indices where snapshot[i].active {
            let me = snapshot[i]
            var ax = 0.0
            var ay = 0.0
            var count = 0
            var sumVX = 0.0
            var sumVY = 0.0
            var sumX = 0.0
            var sumY = 0.0
            for j in snapshot.indices where j != i && snapshot[j].active {
                let other = snapshot[j]
                let dx = me.x - other.x
                let dy = me.y - other.y
                let d2 = dx * dx + dy * dy
                guard d2 < k.neighbourRadius * k.neighbourRadius else { continue }
                let d = max(0.5, d2.squareRoot())
                if d < k.separationRadius {
                    // Strongest at touch, nothing at the radius.
                    let push = (1 - d / k.separationRadius) * k.separation
                    ax += dx / d * push
                    ay += dy / d * push
                }
                sumVX += other.vx
                sumVY += other.vy
                sumX += other.x
                sumY += other.y
                count += 1
                if count >= k.maxNeighbours { break }
            }
            if count > 0 {
                let n = Double(count)
                ax += (sumVX / n - me.vx) * k.alignment
                ay += (sumVY / n - me.vy) * k.alignment
                ax += (sumX / n - me.x) * k.cohesion
                ay += (sumY / n - me.y) * k.cohesion
            }
            // The goal: a steady pull, steep past the leash.
            let gx = goal.x - me.x
            let gy = goal.y - me.y
            let gd = (gx * gx + gy * gy).squareRoot()
            let stray = max(0, gd - k.leash) / max(1, k.leash)
            let pull = k.goalPull * (1 + 6 * stray * stray)
            ax += gx * pull - me.vx * 0.6
            ay += gy * pull - me.vy * 0.6
            // Staying out of things comes first (Reynolds' prioritised
            // steering): the walls and the fish in the way spend the turn
            // budget, and the school's own wishes get what is left.
            let cap = k.maxAccel * max(0.4, pace)
            var urgent = Self.avoidance(me, index: i, obstacles: obstacles, bounds: bounds,
                                        tuning: k, cap: cap)
            let u = (urgent.x * urgent.x + urgent.y * urgent.y).squareRoot()
            if u > cap {
                urgent.x *= cap / u
                urgent.y *= cap / u
            }
            let room = max(0, cap - min(u, cap))
            let a = (ax * ax + ay * ay).squareRoot()
            if a > room {
                let share = room / max(a, 0.0001)
                ax *= share
                ay *= share
            }
            ax += urgent.x
            ay += urgent.y
            var next = me
            next.vx += ax * dt
            next.vy += ay * dt
            let speed = (next.vx * next.vx + next.vy * next.vy).squareRoot()
            if speed > maxSpeed {
                next.vx *= maxSpeed / speed
                next.vy *= maxSpeed / speed
            } else if speed < minSpeed, speed > 0.001 {
                next.vx *= minSpeed / speed
                next.vy *= minSpeed / speed
            }
            next.x += next.vx * dt
            next.y += next.vy * dt
            next.x = min(bounds.maxX, max(bounds.minX, next.x))
            next.y = min(bounds.maxY, max(bounds.minY, next.y))
            next.facing = Self.ease(facing: me.facing, vx: next.vx, speed: max(speed, 0.001),
                                    dt: dt, turnTime: k.turnTime)
            members[i] = next
        }
    }

    /// The push away from the walls and from the bigger fish ahead:
    /// straight off an obstacle, plus a sideways slip past it — to the
    /// side the fish already leans, or by its place in the school when it
    /// heads dead centre — so a school parts round a fish and re-forms.
    static func avoidance(_ me: Member, index: Int, obstacles: [Obstacle], bounds: Bounds,
                          tuning k: Tuning, cap: Double) -> (x: Double, y: Double) {
        var x = 0.0
        var y = 0.0
        let speed = (me.vx * me.vx + me.vy * me.vy).squareRoot()
        let look = speed * 0.45
        for obstacle in obstacles {
            let ox = me.x - obstacle.x
            let oy = me.y - obstacle.y
            let od = max(0.5, (ox * ox + oy * oy).squareRoot())
            let reach = obstacle.radius + k.avoidMargin + look
            guard od < reach else { continue }
            let near = min(1, max(0, 1 - (od - obstacle.radius) / max(1, reach - obstacle.radius)))
            // Off it…
            x += ox / od * near * cap * 1.6
            y += oy / od * near * cap * 1.6
            // …and round it, if it lies ahead.
            let ahead = -(ox * me.vx + oy * me.vy) / max(0.001, od * speed)
            guard ahead > 0, speed > 0.001 else { continue }
            let cross = me.vx * oy - me.vy * ox
            let side: Double = abs(cross) > 0.5 * speed ? (cross > 0 ? 1 : -1) : (index.isMultiple(of: 2) ? 1 : -1)
            x += -me.vy / speed * side * near * ahead * cap * 1.2
            y += me.vx / speed * side * near * ahead * cap * 1.2
        }
        let margin = 24.0
        if me.x < bounds.minX + margin { x += (bounds.minX + margin - me.x) * 9 }
        if me.x > bounds.maxX - margin { x -= (me.x - bounds.maxX + margin) * 9 }
        if me.y < bounds.minY + margin { y += (bounds.minY + margin - me.y) * 9 }
        if me.y > bounds.maxY - margin { y -= (me.y - bounds.maxY + margin) * 9 }
        return (x, y)
    }

    /// The side-on share after one step: toward the side it swims, at
    /// most `2 / turnTime` a second, so a reversal passes through
    /// head-on and never flips. A fish swimming nearly straight up or
    /// down keeps the side it had.
    static func ease(facing: Double, vx: Double, speed: Double, dt: Double, turnTime: Double) -> Double {
        let lean = vx / speed
        let target: Double
        if lean > 0.25 { target = 1 } else if lean < -0.25 { target = -1 } else { target = facing >= 0 ? 1 : -1 }
        let most = 2 / turnTime * dt
        return facing + min(most, max(-most, target - facing))
    }
}
