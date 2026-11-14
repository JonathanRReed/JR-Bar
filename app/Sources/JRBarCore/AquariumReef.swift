import Foundation

/// The reef (docs/TOYS.md): what makes the tank an idle game and not a
/// shop. Four builders each turn one real fact into pearls. Pearls grow
/// the builders, a grown builder pays more, and the next level costs
/// more, so there is always a next thing to buy and the rate keeps
/// climbing.
///
/// The tank still pays what it always paid, straight into the wallet: a
/// pearl for every five minutes of agent work and five for a finished
/// run. Everything a builder adds on top of that waits in the reef as a
/// harvest, for one tap. A harvest never decays and has no cap.
///
/// Every input is a fact: agent work, finished runs, asks that closed
/// while their session lived, quota resets and streak days. Nothing here
/// pays for starting a session, and past a few agent-hours a day more
/// work pays less and less, so the tank is never a reason to keep an
/// agent running.
public enum ReefBuilder: String, Codable, CaseIterable, Sendable {
    /// Eats agent-hours of working state.
    case kelp
    /// Eats finished runs.
    case oyster
    /// Eats asks that closed while their session lived.
    case anemone
    /// Eats quota resets and new streak days.
    case tide

    public var displayName: String {
        switch self {
        case .kelp: "Kelp bed"
        case .oyster: "Oyster bed"
        case .anemone: "Anemone"
        case .tide: "Tide pool"
        }
    }

    /// What one unit of the builder's fact is, after "pearls".
    public var unitWords: String {
        switch self {
        case .kelp: "an agent-hour"
        case .oyster: "a finished run"
        case .anemone: "an answered ask"
        case .tide: "a quota reset or streak day"
        }
    }

    /// What it turns into pearls, as a sentence for the Reef page.
    public var detail: String {
        switch self {
        case .kelp: "Grows on the time your agents spend working."
        case .oyster: "Makes a pearl of every run that finishes."
        case .anemone: "Pays when an ask is settled and its session carries on."
        case .tide: "Fills on every quota reset and every new streak day."
        }
    }

    /// The tank level that opens the builder.
    public var opensAtLevel: Int {
        switch self {
        case .kelp, .oyster: 0
        case .anemone: 2
        case .tide: 4
        }
    }

    /// The level every tank has for nothing: the kelp and oyster beds
    /// start at one, which is the tank's old income.
    public var freeLevels: Int {
        switch self {
        case .kelp, .oyster: 1
        case .anemone, .tide: 0
        }
    }

    /// Pearls a unit of the builder's fact pays at level one.
    public var baseYield: Double {
        switch self {
        case .kelp: 3600 / AquariumRules.workSecondsPerPearl
        case .oyster: Double(AquariumRules.completionBonus)
        case .anemone: 3
        case .tide: 6
        }
    }

    /// Pearls a unit gains with each further level.
    public var yieldStep: Double {
        switch self {
        case .kelp: 4
        case .oyster: 2
        case .anemone: 1.5
        case .tide: 3
        }
    }

    /// The first level's price, and how each next one multiplies it.
    public var baseCost: Double {
        switch self {
        case .kelp: 20
        case .oyster: 35
        case .anemone: 60
        case .tide: 120
        }
    }

    public var costGrowth: Double {
        switch self {
        case .kelp: 1.15
        case .oyster: 1.17
        case .anemone: 1.18
        case .tide: 1.20
        }
    }

    /// The units of its fact a day that count in full; past it they count
    /// for half, and past twice it for a quarter. Nil: no daily limit.
    public var dailyFull: Double? {
        switch self {
        case .kelp: 4
        case .oyster: 12
        case .anemone, .tide: nil
        }
    }
}

/// Why a builder did not grow.
public enum ReefGrowDenial: Equatable, Sendable {
    /// The tank level has not opened it yet.
    case locked(needsLevel: Int)
    /// It is as big as this tank can hold.
    case full(cap: Int)
    /// The wallet is short; carries the price.
    case cannotAfford(cost: Int)
}

/// The reef's own state inside the save: levels, the waiting harvest and
/// the day's counted work.
public struct AquariumReef: Codable, Equatable, Sendable {
    /// Levels bought, by builder raw value. The free level is not stored.
    public var bought: [String: Int]
    /// Pearls waiting to be collected, by builder raw value.
    public var harvest: [String: Double]
    /// `calendar.startOfDay` epoch of the day `counted` belongs to.
    public var day: Double
    /// Units of each builder's fact counted so far today, before the
    /// daily soft limit.
    public var counted: [String: Double]
    /// Asks already paid for, newest last, so one ask pays once.
    public var settledAsks: [String]
    /// Pearls the reef has ever grown, collected or not.
    public var grown: Double

    public init(bought: [String: Int] = [:], harvest: [String: Double] = [:], day: Double = 0,
                counted: [String: Double] = [:], settledAsks: [String] = [], grown: Double = 0) {
        self.bought = bought
        self.harvest = harvest
        self.day = day
        self.counted = counted
        self.settledAsks = settledAsks
        self.grown = grown
    }

    // MARK: Rules

    /// The levels at which a builder's whole yield doubles.
    public static let milestones = [10, 25, 50, 100]
    /// The hand's share on top of a harvest collected by a tap.
    public static let handBonus = 0.10
    /// The most asks remembered as paid.
    public static let settledAsksKept = 256
    /// The most a level counter may read from a file.
    public static let levelCeiling = 10_000

    /// The builder's level: the free one plus the ones bought.
    public func level(_ builder: ReefBuilder) -> Int {
        builder.freeLevels + max(0, bought[builder.rawValue] ?? 0)
    }

    /// The most levels a builder may reach in a tank at `tankLevel`: the
    /// reef cannot outgrow the tank.
    public static func cap(tankLevel: Int) -> Int { 5 + 3 * max(0, tankLevel) }

    /// Pearls one unit of the builder's fact pays at `level`, before any
    /// bonus: nothing at level 0.
    public static func yield(_ builder: ReefBuilder, level: Int) -> Double {
        guard level > 0 else { return 0 }
        return builder.baseYield + builder.yieldStep * Double(level - 1)
    }

    /// The price of the builder's next level from `level`.
    public static func cost(_ builder: ReefBuilder, level: Int) -> Int {
        let n = max(0, level - builder.freeLevels)
        let raw = builder.baseCost * pow(builder.costGrowth, Double(n))
        guard raw.isFinite, raw < Double(AquariumGame.counterCeiling) else { return AquariumGame.counterCeiling }
        return Int(raw.rounded(.up))
    }

    /// How many times the builder's yield has doubled by `level`.
    public static func doublings(level: Int) -> Int {
        milestones.filter { level >= $0 }.count
    }

    /// The next level at which the builder's yield doubles, or nil past
    /// the last.
    public static func nextMilestone(after level: Int) -> Int? {
        milestones.first { $0 > level }
    }

    /// `units` counted under a daily limit of `full`: all of it up to the
    /// limit, half of it up to twice the limit, a quarter past that.
    public static func soft(_ units: Double, full: Double) -> Double {
        guard units.isFinite, units > 0 else { return 0 }
        guard full > 0 else { return units }
        if units <= full { return units }
        if units <= 2 * full { return full + (units - full) / 2 }
        return 1.5 * full + (units - 2 * full) / 4
    }

    /// The share every builder gains from the tank around it: 5 % for
    /// each raised fish that lives here (up to six), 2 % for each day of
    /// the streak (up to fifteen) and 1 % for each decor piece on the
    /// sand (up to twenty-five).
    public static func careBonus(residents: Int, streakDays: Int, decor: Int) -> Double {
        0.05 * Double(min(AquariumRules.maxResidents, max(0, residents)))
            + min(0.30, 0.02 * Double(max(0, streakDays)))
            + min(0.25, 0.01 * Double(max(0, decor)))
    }

    /// Pearls one unit pays at `level` with everything counted: the
    /// yield, the tank's care bonus and the milestone doublings.
    public static func rate(_ builder: ReefBuilder, level: Int, careBonus: Double) -> Double {
        yield(builder, level: level) * (1 + max(0, careBonus)) * pow(2, Double(doublings(level: level)))
    }

    /// Pearls waiting across the reef, whole ones only.
    public var waiting: Int {
        let total = harvest.values.reduce(0) { $0 + ($1.isFinite ? max(0, $1) : 0) }
        return Int(min(Double(AquariumGame.counterCeiling), total).rounded(.down))
    }

    /// Whole pearls waiting at one builder.
    public func waiting(at builder: ReefBuilder) -> Int {
        let held = harvest[builder.rawValue] ?? 0
        return held.isFinite ? Int(min(Double(AquariumGame.counterCeiling), max(0, held)).rounded(.down)) : 0
    }

    // MARK: Growing a harvest

    /// Count `units` of `builder`'s fact on `day` and bank what the reef
    /// adds on top of the tank's old income. `basePaid` is the pearls a
    /// unit already paid straight into the wallet (the old income for the
    /// kelp and oyster beds, nothing for the others). Returns the pearls
    /// added to the harvest.
    @discardableResult
    public mutating func grow(_ builder: ReefBuilder, units: Double, day today: Double,
                              careBonus: Double, basePaid: Double) -> Double {
        guard units.isFinite, units > 0 else { return 0 }
        if day != today {
            day = today
            counted = [:]
        }
        let level = level(builder)
        guard level > 0 else { return 0 }
        let before = counted[builder.rawValue] ?? 0
        let after = before + units
        counted[builder.rawValue] = after
        var effective = units
        if let full = builder.dailyFull {
            effective = Self.soft(after, full: full) - Self.soft(before, full: full)
        }
        // The old income was paid on every unit; the reef adds the rest of
        // what the counted units earn, and never takes any back.
        let added = max(0, effective * Self.rate(builder, level: level, careBonus: careBonus) - units * basePaid)
        guard added > 0 else { return 0 }
        harvest[builder.rawValue, default: 0] += added
        grown += added
        return added
    }

    /// Take every whole pearl out of the reef. A tap adds the hand's
    /// share. The fractions stay behind for next time.
    public mutating func collect(byHand: Bool) -> Int {
        var total = 0.0
        for builder in ReefBuilder.allCases {
            let held = harvest[builder.rawValue] ?? 0
            guard held.isFinite, held >= 1 else { continue }
            let whole = held.rounded(.down)
            total += whole
            harvest[builder.rawValue] = held - whole
        }
        guard total > 0 else { return 0 }
        let paid = byHand ? total * (1 + Self.handBonus) : total
        return Int(min(Double(AquariumGame.counterCeiling), paid).rounded(.down))
    }

    /// Whether `askID` has not been paid for yet; remembers it if so.
    public mutating func noteSettled(_ askID: String) -> Bool {
        guard !askID.isEmpty, !settledAsks.contains(askID) else { return false }
        settledAsks.append(askID)
        if settledAsks.count > Self.settledAsksKept {
            settledAsks.removeFirst(settledAsks.count - Self.settledAsksKept)
        }
        return true
    }

    // MARK: Tolerant decode

    private enum CodingKeys: String, CodingKey {
        case bought, harvest, day, counted, settledAsks, grown
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let levels = (try? c.decodeIfPresent([String: Int].self, forKey: .bought)) ?? [:]
        bought = levels.filter { ReefBuilder(rawValue: $0.key) != nil }
            .mapValues { min(Self.levelCeiling, max(0, $0)) }
        func amounts(_ key: CodingKeys) -> [String: Double] {
            ((try? c.decodeIfPresent([String: Double].self, forKey: key)) ?? [:])
                .filter { ReefBuilder(rawValue: $0.key) != nil && $0.value.isFinite && $0.value > 0 }
                .mapValues { min(Double(AquariumGame.counterCeiling), $0) }
        }
        harvest = amounts(.harvest)
        counted = amounts(.counted)
        let stamp = (try? c.decodeIfPresent(Double.self, forKey: .day)) ?? 0
        day = stamp.isFinite ? max(0, stamp) : 0
        var seen = Set<String>()
        settledAsks = Array(((try? c.decodeIfPresent([String].self, forKey: .settledAsks)) ?? [])
            .filter { seen.insert($0).inserted }.suffix(Self.settledAsksKept))
        let total = (try? c.decodeIfPresent(Double.self, forKey: .grown)) ?? 0
        grown = total.isFinite ? min(Double(AquariumGame.counterCeiling), max(0, total)) : 0
    }
}
