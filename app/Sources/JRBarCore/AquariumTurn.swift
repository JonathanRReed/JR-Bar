import Foundation

/// How busy the tank's swimmers are (docs/TOYS.md §Aquarium, Swimming):
/// how hard the wander bends a path, how long a fish waits between
/// turns, how long a turn takes and how fast it cruises. Natural is the
/// tank's own feel; Calm and Lively lean either way from it.
public enum SwimPace: String, Codable, CaseIterable, Sendable {
    case calm
    case natural
    case lively

    /// The card's word for it.
    public var displayName: String {
        switch self {
        case .calm: return "Calm"
        case .natural: return "Natural"
        case .lively: return "Lively"
        }
    }

    /// The most the wander bends a path, radians per second.
    public var wanderRate: Double {
        switch self {
        case .calm: return 0.22
        case .natural: return 0.35
        case .lively: return 0.50
        }
    }

    /// Seconds after one turn ends before a fish will start another
    /// on a whim. Food and a scare may cut in sooner.
    public var cooldown: Double {
        switch self {
        case .calm: return 4.0
        case .natural: return 2.5
        case .lively: return 1.5
        }
    }

    /// Multiplies every turn's length.
    public var turnScale: Double {
        switch self {
        case .calm: return 1.2
        case .natural: return 1.0
        case .lively: return 0.8
        }
    }

    /// Multiplies the cruise speed.
    public var cruiseScale: Double {
        switch self {
        case .calm: return 0.85
        case .natural: return 1.0
        case .lively: return 1.15
        }
    }
}

/// One committed U-turn in progress (`SwimBody.turn`): what set it off,
/// when, how long it lasts, the way the fish faced going in and which
/// way the loop bows. The steering advances `progress`; the view poses
/// the fish from it with `AquariumTurn.pose`.
public struct SwimTurn: Equatable, Sendable {
    /// What the turn is for — it sets the length (`AquariumTurn.duration`).
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        /// A change of mind in open water.
        case cruise
        /// The glass ahead.
        case wall
        /// An idling fish's lazy about-face.
        case idle
        /// Food behind it.
        case food
        /// A tap on the glass.
        case startle
    }

    public var kind: Kind
    /// The step clock when it began.
    public var start: Double
    /// Seconds from facing one way to facing the other.
    public var duration: Double
    /// The side-on facing going in, ±1; it comes out facing `-from`.
    public var from: Double
    /// +1 bows the loop down a little, -1 up.
    public var arc: Double
    /// 0 going in … 1 facing the other way.
    public var progress: Double

    public init(kind: Kind, start: Double, duration: Double, from: Double, arc: Double,
                progress: Double = 0) {
        self.kind = kind
        self.start = start
        self.duration = duration
        self.from = from
        self.arc = arc
        self.progress = progress
    }
}

/// The U-turn in depth (docs/TOYS.md §Aquarium, Swimming), after the
/// classic 2D turn strip: the fish stays level, the head swings round
/// first, it passes through a real head-on frame where the mirror can't
/// be seen, and its tail kicks it out the other way. Pure, so the
/// timing and the shape are tested without drawing a fish.
public enum AquariumTurn {
    /// Below this side-on share the view draws the head-on frame; above
    /// it, the side view squashed by the same share. A hard cut, as the
    /// strip does it — the two silhouettes match in width here.
    public static let frontCut = 0.265

    /// One moment of a turn.
    public struct Pose: Equatable, Sendable {
        /// The signed side-on share: `dir0` going in, through 0 head-on,
        /// `-dir0` coming out. Continuous, so the facing only ever
        /// changes inside the head-on frame.
        public var c: Double
        /// How far the head is turned beyond the body's middle, radians:
        /// ahead while the turn comes round, behind while it opens out.
        public var lead: Double
        /// The drawn pitch through the turn, radians, nose down positive:
        /// the fish levels out and dips a touch toward the loop's bow.
        public var pitch: Double
        /// Multiplies the tail's swing: the kick out of the turn.
        public var ampMul: Double
        /// Multiplies the tail's beat: slower while it comes round.
        public var beatMul: Double
        /// Beats per second added on top: the push-off.
        public var kickHz: Double

        public init(c: Double, lead: Double = 0, pitch: Double = 0, ampMul: Double = 1,
                    beatMul: Double = 1, kickHz: Double = 0) {
            self.c = c
            self.lead = lead
            self.pitch = pitch
            self.ampMul = ampMul
            self.beatMul = beatMul
            self.kickHz = kickHz
        }

        /// Side-on and cruising, facing `dir`.
        public static func still(facing dir: Double, pitch: Double = 0) -> Pose {
            Pose(c: dir >= 0 ? 1 : -1, pitch: pitch)
        }

        /// The head-on frame is drawn instead of the side view.
        public var isFront: Bool { abs(c) < AquariumTurn.frontCut }
        /// +1 or -1: the facing any mirror-only consumer should use.
        public var facing: Double { c >= 0 ? 1 : -1 }
    }

    static func smootherstep(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// The pose at `p` (0…1) of a turn that began facing `dir0` and
    /// bows toward `arc`. `climb` is the travel angle it carries through
    /// the turn, levelled out in the middle.
    public static func pose(p: Double, dir0: Double, arc: Double, climb: Double = 0) -> Pose {
        let p = min(1, max(0, p))
        let dir0: Double = dir0 >= 0 ? 1 : -1
        // The yaw comes round on a smootherstep and lingers near
        // head-on: |u|^1.5 flattens the middle, so the face holds for a
        // few frames instead of flashing past.
        let u = 2 * smootherstep(p) - 1
        let bent = pow(abs(u), 1.5)
        let yaw = Double.pi * (0.5 + 0.5 * (u < 0 ? -bent : bent))
        let c = cos(yaw) * dir0
        let s = sin(Double.pi * p)
        // The head swings first (lead > 0), then the tail follows it
        // round (lead < 0); side-on there's nothing to lead.
        let lead = 0.40 * sin(2 * Double.pi * p) * (1 - 0.6 * abs(c))
        let pitch = climb * (1 - 0.85 * s) + arc * 0.16 * s
        let kick = exp(-pow((p - 0.82) / 0.13, 2))
        return Pose(c: c, lead: lead, pitch: pitch,
                    ampMul: 0.75 + 0.95 * kick,
                    beatMul: 0.7 + 0.3 * abs(cos(Double.pi * p)),
                    kickHz: 1.4 * kick)
    }

    /// How long a turn of `kind` takes at `pace`, in seconds, before the
    /// swimming-speed tempo divides it.
    public static func duration(for kind: SwimTurn.Kind, pace: SwimPace) -> Double {
        let base: Double
        switch kind {
        case .cruise: base = 0.9
        case .wall: base = 0.8
        case .idle: base = 1.2
        case .food: base = 0.55
        case .startle: base = 0.45
        }
        return base * pace.turnScale
    }

    /// The pose of `body` right now: its turn's, or side-on facing its
    /// way with its drawn pitch. Reduce Motion (`still`) only ever shows
    /// a turn's ends, so a fish is never drawn mid-turn.
    public static func pose(of body: SwimBody, still: Bool = false) -> Pose {
        guard let turn = body.turn else { return .still(facing: body.dir, pitch: body.pitch) }
        let p = still ? (turn.progress < 0.5 ? 0 : 1) : turn.progress
        var pose = pose(p: p, dir0: turn.from, arc: turn.arc, climb: body.climb)
        // The steering's damped pitch already eases toward the turn's.
        pose.pitch = body.pitch
        if still { pose.lead = 0 }
        return pose
    }
}
