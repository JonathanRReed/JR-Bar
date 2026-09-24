import Foundation

/// A place in the tank where a planned action happens (docs/TOYS.md):
/// W13's tool-level actions given somewhere to be, so the tank reads
/// "Claude is reading, Codex is running the tests" at a glance. The
/// planner decides *what* a fish is doing from the hook's own tool name;
/// a station is only *where* it goes to do it — it adds no claim the
/// plan didn't already make.
public enum TankStation: String, Equatable, Sendable, CaseIterable {
    /// AQ06 forage (a read): up and down a kelp strand.
    case kelp
    /// AQ07 explore (a search): back and forth between two landmarks.
    case survey
    /// AQ08 tend stones (an edit): nosing along the rocks on the sand.
    case pebbles
    /// AQ09 current work (a shell command): holding station in the
    /// rising bubble column, tail working against it.
    case current
    /// AQ10 inspect, AQ11 result (a test or build): circling the wreck
    /// — or the coral, in a tank that hasn't bought one.
    case wreck
    /// AQ12 service visit (an MCP call): hovering at the chest's lid.
    case chest
    /// AQ05 feed station (any other tool): a neutral bench on the sand,
    /// by the starfish — somewhere to work that claims nothing specific.
    case bench

    /// The inspector's words for it: where the fish is and what that
    /// means, in the plan's own terms.
    public var phrase: String {
        switch self {
        case .kelp: return "foraging the kelp — reading"
        case .survey: return "exploring the tank — searching"
        case .pebbles: return "tending the stones — editing"
        case .current: return "holding in the current — running a command"
        case .wreck: return "circling the wreck — testing or building"
        case .chest: return "at the chest — calling a tool server"
        case .bench: return "at the bench — using a tool"
        }
    }
}

/// How a test or build came out, when the wire says so: `PostToolUse`
/// on a test/build tool is a pass, `PostToolUseFailure` a failure.
public enum FishResultTone: String, Equatable, Sendable {
    case pass
    case fail
}

/// What the tank draws for a fish's tool-level action beyond its swim:
/// the station, the result bubble's colour when a test or build just
/// finished, and when the evidence was observed — so the view stops
/// claiming it the moment it is old, even if no new document arrives.
public struct FishCue: Equatable, Sendable {
    public var station: TankStation
    public var tone: FishResultTone?
    /// The session's `updated_at` when the cue was read; nil when the
    /// row carried none (the planner treats that as current, and so
    /// does the cue).
    public var observedAt: Date?

    public init(station: TankStation, tone: FishResultTone? = nil, observedAt: Date? = nil) {
        self.station = station
        self.tone = tone
        self.observedAt = observedAt
    }

    /// Still something happening now: inside the planner's own tool
    /// life. The tank re-reads this per frame, because the daemon only
    /// sends a document when something changes — a long think after a
    /// read would otherwise keep the fish foraging on old news.
    public func isFresh(at now: Date) -> Bool {
        guard let observedAt else { return true }
        return now.timeIntervalSince(observedAt) <= AquariumPlanner.toolEventLife
    }

    /// The inspector's line: the station's phrase, or the result.
    public var phrase: String {
        switch tone {
        case .pass: return "the test or build passed"
        case .fail: return "the test or build failed"
        case nil: return station.phrase
        }
    }
}

/// Stations, pure: which action goes where, and the moving point a fish
/// chases while it's there. Unit tank space throughout (x across, y
/// down), the steering's own.
public enum AquariumStations {
    /// The planner's test/build tool names, mirrored for the failure
    /// read — the planner only names a finished run's result on a
    /// `PostToolUse`, and a failed test is exactly as much a result.
    static let testTools: Set<String> = ["test", "pytest", "swiftbuild", "swifttest", "build"]

    /// Where an action takes the fish; nil for actions that are swims
    /// (patrol, hover, the attention and terminal states) or exchanges
    /// (a delegation's token pass happens between fish, not at a place).
    public static func station(for action: FishAction) -> TankStation? {
        switch action {
        case .forage: return .kelp
        case .explore: return .survey
        case .tendStones: return .pebbles
        case .currentWork: return .current
        case .inspectStructure, .resultBubble: return .wreck
        case .serviceVisit: return .chest
        case .feedStation: return .bench
        case .enter, .idleRest, .patrol, .attentiveHover, .tokenPass,
             .surfaceQuestion, .attentionBuoy, .warningBuoy, .pearlDeposit,
             .returnNormal, .uncertainDrift, .inactiveDrift:
            return nil
        }
    }

    /// The cue for a session under its plan. The plan's action decides
    /// the station; a finished test or build adds its tone. A failed one
    /// (`PostToolUseFailure`, which the planner leaves as the base swim
    /// — patrol, or the hover while it thinks) still earns its red bubble
    /// at the wreck: the wire named the failure, and the evidence line
    /// cites the event, so drawing it claims nothing more than that.
    public static func cue(for session: CoreSession, plan: FishPlan, now: Date) -> FishCue? {
        let observed = session.updatedAt.map { Date(timeIntervalSince1970: $0) }
        if plan.action == .resultBubble {
            return FishCue(station: .wreck, tone: .pass, observedAt: observed)
        }
        if plan.action == .patrol || plan.action == .attentiveHover,
           isFailedResult(session, now: now) {
            return FishCue(station: .wreck, tone: .fail, observedAt: observed)
        }
        guard let station = station(for: plan.action) else { return nil }
        return FishCue(station: station, observedAt: observed)
    }

    /// A `PostToolUseFailure` on a test/build tool, recent and no longer
    /// running — the failed twin of the planner's AQ11 result.
    static func isFailedResult(_ session: CoreSession, now: Date) -> Bool {
        guard session.event?.lowercased() == "posttoolusefailure",
              let tool = session.tool?.lowercased(), testTools.contains(tool),
              session.mode?.lowercased() != "tool_running",
              let updated = session.updatedAt
        else { return false }
        return now.timeIntervalSince1970 - updated <= AquariumPlanner.toolEventLife
    }

    /// A station's place in the tank, resolved by the view from the
    /// decor it actually drew: the point, how far the fish ranges around
    /// it, and — for a survey — the second landmark.
    public struct Anchor: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var spanX: Double
        public var spanY: Double
        public var altX: Double
        public var altY: Double

        public init(x: Double, y: Double, spanX: Double = 0.05, spanY: Double = 0.05,
                    altX: Double? = nil, altY: Double? = nil) {
            self.x = x
            self.y = y
            self.spanX = spanX
            self.spanY = spanY
            self.altX = altX ?? x
            self.altY = altY ?? y
        }
    }

    /// How long a survey leg lasts before the fish heads for the other
    /// landmark: long enough to swim across at a cruise and look about
    /// when it gets there, so a surveyor turns back a couple of times a
    /// minute, not every few seconds.
    public static let surveyLeg: TimeInterval = 24
    /// Seconds per lap of the wreck. Seen side-on a lap is two turns, so
    /// a slow lap keeps an inspector to under three a minute.
    public static let wreckLap: TimeInterval = 44

    /// The point a fish at `station` chases at clock `t`. Each station's
    /// path is its verb: a forager climbs and drops along the strand, a
    /// surveyor crosses between two landmarks, a stone-tender works the
    /// sand from side to side, a current worker holds nearly still,
    /// an inspector laps the wreck, a caller hovers at the lid. The seed
    /// staggers fish sharing a station so they never stack.
    public static func target(for station: TankStation, anchor a: Anchor,
                              t: Double, seed: UInt64) -> (x: Double, y: Double) {
        let phase = Double(seed & 0xFFFF) / 0xFFFF * .pi * 2
        let side: Double = (seed >> 17) & 1 == 0 ? 1 : -1
        switch station {
        case .kelp:
            let climb = 0.5 + 0.5 * sin(t * 0.2 + phase)
            return (a.x + side * a.spanX * 0.55 + sin(t * 0.6 + phase) * a.spanX * 0.25,
                    a.y - a.spanY * climb)
        case .survey:
            let leg = Int(((t + phase * surveyLeg / (.pi * 2)) / surveyLeg).rounded(.down))
            let atAlt = leg % 2 != 0
            let x = atAlt ? a.altX : a.x
            let y = atAlt ? a.altY : a.y
            return (x + sin(t * 0.8 + phase) * a.spanX * 0.3,
                    y + sin(t * 0.55 + phase) * a.spanY * 0.3)
        case .pebbles:
            return (a.x + sin(t * 0.45 + phase) * a.spanX,
                    a.y - abs(sin(t * 0.9 + phase)) * a.spanY * 0.25)
        case .current:
            return (a.x + sin(t * 0.9 + phase) * a.spanX * 0.2,
                    a.y + sin(t * 0.5 + phase) * a.spanY * 0.15)
        case .wreck:
            let angle = t * (2 * .pi / wreckLap) * side + phase
            return (a.x + cos(angle) * a.spanX, a.y + sin(angle) * a.spanY)
        case .chest:
            return (a.x + side * a.spanX * 0.3 + sin(t * 0.7 + phase) * a.spanX * 0.15,
                    a.y + sin(t * 1.1 + phase) * a.spanY * 0.2)
        case .bench:
            return (a.x + side * a.spanX * 0.4 + sin(t * 0.4 + phase) * a.spanX * 0.2,
                    a.y + sin(t * 0.7 + phase) * a.spanY * 0.15)
        }
    }

    /// How long a working fish waits after one turn before it turns back
    /// for its station again, seconds (the pace's own cooldown when that
    /// is longer).
    public static let turnCooldown: TimeInterval = 6
    /// The pace at a holding station once the fish has arrived.
    public static let holdEffort = 0.35
    /// Inside this distance (unit space) of its station's point a fish
    /// has arrived: it slows to a hover and noses at the point within its
    /// own facing instead of circling it.
    public static let arriveRadius = 0.06

    /// How hard the fish swims toward its station point. The ranging
    /// stations keep moving; the holding ones — current, chest, bench,
    /// pebbles — ease off as the fish arrives, so it settles and works
    /// instead of circling its own target.
    public static func effort(for station: TankStation, distance: Double) -> Double {
        switch station {
        case .kelp, .survey, .wreck:
            return 0.85
        case .current, .chest, .bench, .pebbles:
            let far = 0.12, near = 0.03
            if distance >= far { return 1 }
            if distance <= near { return holdEffort }
            return holdEffort + (1 - holdEffort) * (distance - near) / (far - near)
        }
    }
}
