import Foundation

/// The snail's errands (docs/TOYS.md): a small simulation the tank steps
/// once a frame. With a pearl on the sand it hustles to the oldest one
/// and picks it up; with none it creeps from one end of the bed to the
/// other, and after five quiet minutes it naps for one. It never flips
/// in a frame: `facing` is its x-scale, and a turn squashes it through
/// zero over about 0.6 s while it slows to a stop and sets off again.
/// If an hour of open tank passes without a single pearl, its shell
/// warms toward red and it huffs. Pure — the tests step it at 1/30 s.
struct SnailSim: Equatable {
    /// Across the bed, 0…1 of the tank's width.
    var x: Double
    /// The x-scale it draws with: +1 faces right, −1 left, and every
    /// value between during a turn.
    var facing: Double = 1
    /// Where it's creeping to when there's nothing to fetch.
    var creepTarget: Double = 0.94
    /// Seconds since it last picked up a pearl (the huff's clock).
    var sinceMeal: Double = 0
    /// Seconds it has crept with nothing to fetch (the nap's clock).
    var sinceNap: Double = 0
    /// Seconds left of the current nap; 0 when awake.
    var napLeft: Double = 0

    /// The slow creep, in tank widths a second — about four minutes a
    /// crossing.
    static let creepSpeed = 0.0037
    /// The hustle toward a pearl.
    static let hustleSpeed = 0.12
    /// How fast `facing` swings, per second: −1 → +1 in 0.6 s.
    static let turnRate = 2 / 0.6
    /// Close enough to pick a pearl up.
    static let reach = 0.012
    /// The bed's ends it creeps between.
    static let ends = (0.06, 0.94)
    /// Quiet creeping before a nap, and how long the nap lasts.
    static let napAfter: Double = 5 * 60
    static let napFor: Double = 60
    /// No pearl for this long and the shell starts to warm…
    static let huffAfter: Double = 60 * 60
    /// …reaching full red this much later.
    static let huffRamp: Double = 15 * 60

    init(x: Double = 0.42) {
        self.x = x
    }

    /// How warm the shell is: 0 content, 1 fully red.
    var huff: Double {
        min(1, max(0, (sinceMeal - Self.huffAfter) / Self.huffRamp))
    }

    var napping: Bool { napLeft > 0 }

    /// Whether it's hurrying after a pearl right now — the legs and the
    /// dust puff read it.
    private(set) var hustling = false

    /// One step of `dt` seconds. `pearl` is the x of the pearl it should
    /// fetch (the oldest resting one), or nil. Returns true when it
    /// reached the pearl this step — the caller collects it. A pearl
    /// resting past the end of the bed (a leaving fish's, dropped at the
    /// glass) is fetched from the end the snail can reach. Reduce
    /// Motion (`still`) skips the walk: the snail is simply there.
    @discardableResult
    mutating func step(dt: Double, pearl: Double?, still: Bool = false) -> Bool {
        let dt = max(0, min(0.25, dt))
        sinceMeal += dt
        guard let resting = pearl else {
            hustling = false
            return creep(dt: dt, still: still)
        }
        let pearl = min(Self.ends.1, max(Self.ends.0, resting))
        napLeft = 0
        sinceNap = 0
        hustling = true
        if still {
            x = pearl
            return arrive()
        }
        if abs(pearl - x) <= Self.reach { return arrive() }
        move(toward: pearl, speed: Self.hustleSpeed, dt: dt)
        if abs(pearl - x) <= Self.reach { return arrive() }
        return false
    }

    private mutating func arrive() -> Bool {
        sinceMeal = 0
        return true
    }

    /// Nothing to fetch: creep end to end, napping now and then.
    private mutating func creep(dt: Double, still: Bool) -> Bool {
        if napLeft > 0 {
            napLeft = max(0, napLeft - dt)
            return false
        }
        sinceNap += dt
        if sinceNap >= Self.napAfter {
            sinceNap = 0
            napLeft = Self.napFor
            return false
        }
        if still { return false }
        if abs(creepTarget - x) < 0.004 {
            creepTarget = creepTarget > 0.5 ? Self.ends.0 : Self.ends.1
        }
        move(toward: creepTarget, speed: Self.creepSpeed, dt: dt)
        return false
    }

    /// Turn toward `target` first — the body swings through zero — and
    /// move at `speed` scaled by how far round it has come, so it slows
    /// into a turn and picks up again out of it.
    private mutating func move(toward target: Double, speed: Double, dt: Double) {
        let want: Double = target >= x ? 1 : -1
        let swing = Self.turnRate * dt
        facing = want > facing ? min(want, facing + swing) : max(want, facing - swing)
        let push = facing * want > 0 ? abs(facing) : 0
        let step = min(abs(target - x), speed * push * dt)
        x += want * step
        x = min(Self.ends.1, max(Self.ends.0, x))
    }
}

/// The hermit crab's rounds (docs/TOYS.md): it walks the bed one way,
/// sits tucked in its shell a while, turns — its body swinging round
/// through zero over 0.6 s, never a one-frame flip — and walks back.
/// A pure function of the clock, so every frame agrees.
enum HermitCrabRounds {
    /// One leg: 63 s walking, then 27 s tucked.
    static let leg: Double = 90
    static let walkShare = 0.7
    /// The bed's ends it walks between, 0…1 of the width.
    static let ends = (0.10, 0.88)
    static let turnSeconds = 0.6

    /// Where it is at `t`: x across the bed (0…1), its x-scale (±1, and
    /// between during a turn), and whether it's walking.
    static func pose(at t: Double) -> (x: Double, facing: Double, walking: Bool) {
        let u = t / leg + 0.13
        let legIndex = Int(u.rounded(.down))
        let into = (u - u.rounded(.down)) * leg
        let outbound = legIndex.isMultiple(of: 2)
        let walk = walkShare * leg
        let p = min(1, into / walk)
        // Ease in and out of each walk so it sets off and stops gently.
        let eased = p * p * (3 - 2 * p)
        let from = outbound ? ends.0 : ends.1
        let to = outbound ? ends.1 : ends.0
        let x = from + (to - from) * eased
        let heading: Double = outbound ? 1 : -1
        // The last moments of the rest: it turns to face the way back.
        let turnStart = leg - turnSeconds
        var facing = heading
        if into > turnStart {
            let q = (into - turnStart) / turnSeconds
            facing = heading * cos(.pi * q)
        }
        return (x, facing, into < walk)
    }
}
