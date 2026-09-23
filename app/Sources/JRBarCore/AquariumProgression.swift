import Foundation

/// The tank's ladder (docs/TOYS.md): lifetime pearls — earnings the
/// shop can never take back — are the tank level, and the level is
/// what opens the shop's deeper shelves. Pure functions over the
/// save's own counters; nothing here reads a clock.
public enum AquariumProgression {
    /// Lifetime pearls required for each tank level, ascending.
    public static let levelThresholds: [Int] =
        [0, 50, 150, 400, 900, 1800, 3200, 5200, 8000, 12000]
    /// The tank level that opens each shop tier.
    public static let tierUnlockLevels: [Int] = [0, 1, 3, 5, 7]

    /// The highest threshold the lifetime total has reached.
    public static func tankLevel(lifetimePearls: Int) -> Int {
        var level = 0
        for (index, threshold) in levelThresholds.enumerated()
        where lifetimePearls >= threshold {
            level = index
        }
        return level
    }

    /// The lifetime total that promotes the tank, or nil at the top.
    public static func nextLevelAt(lifetimePearls: Int) -> Int? {
        let level = tankLevel(lifetimePearls: lifetimePearls)
        guard level + 1 < levelThresholds.count else { return nil }
        return levelThresholds[level + 1]
    }

    /// The tank level a shop tier asks for.
    public static func tierUnlockLevel(tier: Int) -> Int {
        tierUnlockLevels[max(0, min(tierUnlockLevels.count - 1, tier))]
    }
}

/// A tank milestone (docs/TOYS.md): checked after every event, paid
/// once, remembered in `AquariumGame.unlocked` by raw value — the save
/// file's key, so never rename a shipped case.
public enum AquariumAchievement: String, Codable, CaseIterable, Sendable {
    case firstPearl
    case firstPurchase
    case fullGrown
    case fiveResidents
    case streak7
    case streak30
    case hundredPellets
    case hundredCompletions
    case nightOwl
    case earlyBird
    case collector
    case curator
    case level5
    case level9
    case treasureHunter
    case marathon
    // The work's own milestones, read from the daemon's document.
    case school
    case cleanWeek
    case underBudget
    case bankedCredits

    public var title: String {
        switch self {
        case .firstPearl: return "First pearl"
        case .firstPurchase: return "First purchase"
        case .fullGrown: return "Full grown"
        case .fiveResidents: return "A full tank"
        case .streak7: return "One week"
        case .streak30: return "One month"
        case .hundredPellets: return "Well fed"
        case .hundredCompletions: return "A hundred done"
        case .nightOwl: return "Night owl"
        case .earlyBird: return "Early bird"
        case .collector: return "Collector"
        case .curator: return "Curator"
        case .level5: return "Tank level 5"
        case .level9: return "Tank level 9"
        case .treasureHunter: return "Treasure hunter"
        case .marathon: return "Marathon"
        case .school: return "A school"
        case .cleanWeek: return "Clean week"
        case .underBudget: return "Under budget"
        case .bankedCredits: return "Banked"
        }
    }

    /// What the tank did to earn it, for the locked row.
    public var detail: String {
        switch self {
        case .firstPearl: return "Earned a first pearl."
        case .firstPurchase: return "Bought something in the shop."
        case .fullGrown: return "Raised a fish to its biggest stage."
        case .fiveResidents: return "Five raised fish swimming at once."
        case .streak7: return "Seven days in a row with a completion."
        case .streak30: return "Thirty days in a row. A habit now."
        case .hundredPellets: return "A hundred pellets eaten."
        case .hundredCompletions: return "A hundred sessions completed."
        case .nightOwl: return "A completion between midnight and 5am."
        case .earlyBird: return "A completion between 5am and 7am."
        case .collector: return "Ten shop items owned."
        case .curator: return "Twenty-five shop items owned."
        case .level5: return "Reached tank level 5."
        case .level9: return "Reached tank level 9 — the whole ladder."
        case .treasureHunter: return "Dug up a buried treasure."
        case .marathon: return "Four straight hours of working sessions."
        case .school: return "Six sub-agents swimming with one session at once."
        case .cleanWeek: return "Completions on seven days, no failed run between them."
        case .underBudget: return "A weekly window reset with under 80% of it spent."
        case .bankedCredits: return "Codex's banked credits went up."
        }
    }

    /// Pearls the unlock pays.
    public var reward: Int {
        switch self {
        case .firstPearl, .firstPurchase: return 5
        case .bankedCredits: return 10
        case .school: return 15
        case .underBudget: return 20
        case .cleanWeek: return 30
        case .nightOwl, .earlyBird: return 10
        case .fullGrown, .treasureHunter: return 15
        case .streak7, .hundredPellets, .collector: return 20
        case .fiveResidents, .level5: return 25
        case .hundredCompletions: return 30
        case .marathon: return 40
        case .curator: return 60
        case .streak30: return 75
        case .level9: return 100
        }
    }
}

/// Today's small errand (docs/TOYS.md): one deterministic chore per
/// day — the same for every tank that day — paid once when it's done.
public struct AquariumDailyGoal: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case completions
        case pellets
        case workMinutes
        case dropsCollected

        public var target: Int {
            switch self {
            case .completions: return 3
            case .pellets: return 10
            case .workMinutes: return 90
            case .dropsCollected: return 5
            }
        }

        /// The shop header's name for the chore.
        public var displayName: String {
            switch self {
            case .completions: return "Sessions finished"
            case .pellets: return "Pellets eaten"
            case .workMinutes: return "Minutes worked"
            case .dropsCollected: return "Pearls collected"
            }
        }

        /// The kind a given day gets: the same one everywhere, picked
        /// by the date itself so nothing needs a seed store.
        public static func forDay(_ day: Double) -> Kind {
            let dayIndex = Int(day / 86400)
            let kinds = Kind.allCases
            return kinds[((dayIndex % kinds.count) + kinds.count) % kinds.count]
        }
    }

    public var kind: Kind
    public var target: Int
    public var progress: Int
    /// `calendar.startOfDay` epoch the goal belongs to.
    public var day: Double
    /// The reward was paid — a met goal never pays twice that day.
    public var claimed: Bool

    public init(kind: Kind, target: Int, progress: Int = 0,
                day: Double = 0, claimed: Bool = false) {
        self.kind = kind
        self.target = target
        self.progress = progress
        self.day = day
        self.claimed = claimed
    }
}

/// A glint in the sand (docs/TOYS.md): spawned by the tick every
/// `treasureInterval`, dug up in `treasureTaps` taps, gone after
/// `treasureLifetime` if nobody digs. `x` is a unit position along the
/// sand so the model never learns about pixels.
public struct AquariumTreasure: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Along the sand, 0…1.
    public var x: Double
    /// Digs landed so far.
    public var taps: Int
    /// Spawn epoch.
    public var buriedAt: Double
    /// Pearls the dig pays.
    public var value: Int

    public init(id: String, x: Double, taps: Int, buriedAt: Double, value: Int) {
        self.id = id
        self.x = x
        self.taps = taps
        self.buriedAt = buriedAt
        self.value = value
    }
}

/// The tank's occasional passers-by (docs/TOYS.md): queued by the
/// reducer when their trigger lands — the view parades them across
/// once and answers `visitorShown`. Each queues at most once a day.
public enum AquariumVisitor: String, Codable, CaseIterable, Sendable {
    /// Crosses when the tank worked two hours straight.
    case whale
    /// Crosses when today reaches ten completions.
    case diver
    /// Crosses on a quota reset.
    case submarine

    public var displayName: String {
        switch self {
        case .whale: return "whale"
        case .diver: return "diver"
        case .submarine: return "submarine"
        }
    }
}
