import Foundation
import Testing
@testable import JRBarCore

/// The reef (docs/TOYS.md): four builders that turn real facts into
/// pearls, a harvest that waits, and prices that keep climbing. Pure
/// reducer, synthetic sessions.
@Suite("Aquarium reef")
struct AquariumReefTests {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A tank whose milestones are all behind it, so a test reads the
    /// reef's own numbers and not a first-pearl reward.
    private static func tank(pearls: Int = 0, lifetimePearls: Int = 0,
                             inventory: [String: Int] = [:]) -> AquariumGame {
        AquariumGame(pearls: pearls, lifetimePearls: lifetimePearls, inventory: inventory,
                     unlocked: Dictionary(uniqueKeysWithValues:
                        AquariumAchievement.allCases.map { ($0.rawValue, 1.0) }))
    }

    /// What the wallet has taken in beyond `start`, less a daily goal's
    /// reward if the day's chore happened to be met on the way.
    private static func income(_ game: AquariumGame, from start: Int = 0) -> Int {
        game.lifetimePearls - start - (game.dailyGoal?.claimed == true ? AquariumRules.dailyGoalReward : 0)
    }

    private static func worked(_ game: inout AquariumGame, hours: Double, agents: Int = 1,
                               at now: Date = t0) {
        let ids = (0..<agents).map { "s\($0)" }
        // Five-minute beats: each is exactly one of the wallet's pearls for
        // one agent, so the sums below are exact.
        let beats = Int((hours * 12).rounded())
        for beat in 0..<beats {
            game.apply(.workTick(seconds: 300, working: ids),
                       now: now.addingTimeInterval(Double(beat) * 300), calendar: utc)
        }
    }

    // MARK: Prices and yields

    @Test("each level costs more than the last: the first prices of every builder")
    func costs() {
        func prices(_ builder: ReefBuilder, _ count: Int) -> [Int] {
            (0..<count).map { AquariumReef.cost(builder, level: builder.freeLevels + $0) }
        }
        #expect(prices(.kelp, 6) == [20, 23, 27, 31, 35, 41])
        #expect(prices(.oyster, 4) == [35, 41, 48, 57])
        #expect(prices(.anemone, 4) == [60, 71, 84, 99])
        #expect(prices(.tide, 4) == [120, 144, 173, 208])
        #expect(AquariumReef.cost(.kelp, level: 30) == 1152)
        // A level far past play never overflows the wallet's range.
        #expect(AquariumReef.cost(.tide, level: 5000) == AquariumGame.counterCeiling)
    }

    @Test("level one of the kelp and oyster beds is the tank's old income; each level adds its step")
    func yields() {
        #expect(AquariumReef.yield(.kelp, level: 1) == 12)
        #expect(AquariumReef.yield(.oyster, level: 1) == 5)
        #expect(AquariumReef.yield(.kelp, level: 5) == 28)
        #expect(AquariumReef.yield(.anemone, level: 0) == 0, "an unbuilt builder pays nothing")
        #expect(AquariumReef.yield(.anemone, level: 3) == 6)
        #expect(AquariumReef.yield(.tide, level: 2) == 9)
    }

    @Test("a builder's whole yield doubles at levels 10, 25, 50 and 100")
    func doublings() {
        #expect(AquariumReef.doublings(level: 9) == 0)
        #expect(AquariumReef.doublings(level: 10) == 1)
        #expect(AquariumReef.doublings(level: 25) == 2)
        #expect(AquariumReef.doublings(level: 100) == 4)
        #expect(AquariumReef.rate(.kelp, level: 9, careBonus: 0) == 44)
        #expect(AquariumReef.rate(.kelp, level: 10, careBonus: 0) == 96)
        #expect(AquariumReef.nextMilestone(after: 9) == 10)
        #expect(AquariumReef.nextMilestone(after: 10) == 25)
        #expect(AquariumReef.nextMilestone(after: 100) == nil)
    }

    @Test("a looked-after tank pays more: raised fish, the streak and decor, each with its ceiling")
    func careBonus() {
        #expect(AquariumReef.careBonus(residents: 0, streakDays: 0, decor: 0) == 0)
        #expect(abs(AquariumReef.careBonus(residents: 2, streakDays: 3, decor: 4) - 0.20) < 1e-12)
        #expect(abs(AquariumReef.careBonus(residents: 40, streakDays: 400, decor: 400) - 0.85) < 1e-12)
        #expect(abs(AquariumReef.rate(.oyster, level: 3, careBonus: 0.5) - 13.5) < 1e-12)
    }

    @Test("the day's work counts in full up to the limit, then by half, then by a quarter")
    func softLimit() {
        #expect(AquariumReef.soft(3, full: 4) == 3)
        #expect(AquariumReef.soft(4, full: 4) == 4)
        #expect(AquariumReef.soft(8, full: 4) == 6)
        #expect(AquariumReef.soft(16, full: 4) == 8)
        #expect(AquariumReef.soft(-1, full: 4) == 0)
        #expect(AquariumReef.soft(.nan, full: 4) == 0)
        // It only ever rises: more work is never worth less than none.
        var last = 0.0
        for step in 0...100 {
            let counted = AquariumReef.soft(Double(step) * 0.25, full: 4)
            #expect(counted >= last)
            last = counted
        }
    }

    // MARK: The old income is untouched

    @Test("a new tank earns exactly what it always did, straight into the wallet, and the reef holds nothing")
    func levelOneIsTheOldIncome() {
        var game = Self.tank()
        Self.worked(&game, hours: 1)
        #expect(Self.income(game) == 12)
        #expect(game.reef.waiting == 0)
        let effects = game.apply(.sessionCompleted(id: "s0"), now: Self.t0, calendar: Self.utc)
        #expect(effects.contains(.pearlsEarned(5)))
        #expect(Self.income(game) == 17)
        #expect(game.reef.waiting == 0)
        #expect(game.reef.harvest.values.allSatisfy { $0 < 1e-9 })
    }

    @Test("a grown kelp bed adds its extra to the harvest, on top of the wallet's old pearl every five minutes")
    func grownKelpFillsTheHarvest() {
        var game = Self.tank(pearls: 100)
        #expect(game.apply(.growBuilder(.kelp), now: Self.t0, calendar: Self.utc)
            == [.pearlsSpent(20), .builderGrew(.kelp, level: 2)])
        #expect(game.pearls == 80)
        Self.worked(&game, hours: 1)
        #expect(Self.income(game) == 12, "the wallet's twelve an hour")
        #expect(abs((game.reef.harvest["kelp"] ?? 0) - 4) < 1e-6, "level 2 adds four an agent-hour")
        #expect(game.reef.waiting == 3 || game.reef.waiting == 4, "whole pearls only")
    }

    @Test("three agents at once count as one and a half agent-hours an hour, as the wallet always counted them")
    func concurrency() {
        var game = Self.tank()
        game.reef.bought["kelp"] = 4
        Self.worked(&game, hours: 1, agents: 3)
        #expect(Self.income(game) == 18)
        // Level 5 pays 28 an agent-hour: 1.5 agent-hours is 42, less the 18 the wallet took.
        #expect(abs((game.reef.harvest["kelp"] ?? 0) - 24) < 1e-6)
    }

    @Test("past four agent-hours in a day the kelp bed counts the rest by half, and a new day starts over")
    func kelpDailyLimit() {
        var game = Self.tank()
        game.reef.bought["kelp"] = 4   // level 5: 28 an agent-hour
        Self.worked(&game, hours: 4)
        #expect(abs((game.reef.harvest["kelp"] ?? 0) - 4 * 16) < 1e-6)
        Self.worked(&game, hours: 4, at: Self.t0.addingTimeInterval(4 * 3600))
        // The second four hours count as two: 2 × 28 = 56, less the 48 the wallet took.
        #expect(abs((game.reef.harvest["kelp"] ?? 0) - (64 + 8)) < 1e-6)
        #expect(Self.income(game) == 96, "the wallet's old income has no limit and never did")
        Self.worked(&game, hours: 1, at: Self.t0.addingTimeInterval(26 * 3600))
        #expect(abs((game.reef.harvest["kelp"] ?? 0) - (72 + 16)) < 1e-6, "the next day counts in full again")
    }

    @Test("a level-one bed past its daily limit never takes pearls back")
    func limitNeverGoesNegative() {
        var game = Self.tank()
        Self.worked(&game, hours: 9)
        #expect(Self.income(game) == 108)
        #expect(game.reef.harvest.values.allSatisfy { $0 >= 0 })
        #expect(game.reef.waiting == 0)
    }

    @Test("a finished run fills the oyster bed once, however often it is reported")
    func oysterBed() {
        var game = Self.tank()
        game.reef.bought["oyster"] = 2   // level 3: 9 a run
        game.apply(.sessionCompleted(id: "a"), now: Self.t0, calendar: Self.utc)
        game.apply(.sessionCompleted(id: "a"), now: Self.t0, calendar: Self.utc)
        #expect(Self.income(game) == 5)
        // The run also began a streak, which adds 2 % to every builder.
        #expect(abs((game.reef.harvest["oyster"] ?? 0) - 4) < 1e-9, "the first run is paid before its own streak day counts")
        game.apply(.sessionCompleted(id: "b"), now: Self.t0.addingTimeInterval(60), calendar: Self.utc)
        #expect(abs((game.reef.harvest["oyster"] ?? 0) - (4 + 9 * 1.02 - 5)) < 1e-9)
    }

    // MARK: Growing

    @Test("a builder grows only when it is open, has room and can be paid for")
    func growRules() {
        var game = Self.tank(pearls: 10)
        #expect(game.apply(.growBuilder(.kelp), now: Self.t0, calendar: Self.utc)
            == [.growDenied(.kelp, .cannotAfford(cost: 20))])
        #expect(game.apply(.growBuilder(.anemone), now: Self.t0, calendar: Self.utc)
            == [.growDenied(.anemone, .locked(needsLevel: 2))])
        #expect(game.apply(.growBuilder(.tide), now: Self.t0, calendar: Self.utc)
            == [.growDenied(.tide, .locked(needsLevel: 4))])
        #expect(game.pearls == 10 && game.reef.bought.isEmpty)

        // Tank level 2 opens the anemone; its first level is bought, not given.
        var open = Self.tank(pearls: 500, lifetimePearls: 150)
        #expect(open.reef.level(.anemone) == 0)
        #expect(open.apply(.growBuilder(.anemone), now: Self.t0, calendar: Self.utc)
            == [.pearlsSpent(60), .builderGrew(.anemone, level: 1)])
        #expect(open.growCost(.anemone) == 71)

        // The reef cannot outgrow the tank: 5 + 3 × the tank level.
        var small = Self.tank(pearls: 100_000)
        #expect(AquariumReef.cap(tankLevel: 0) == 5)
        for _ in 0..<4 { small.apply(.growBuilder(.kelp), now: Self.t0, calendar: Self.utc) }
        #expect(small.reef.level(.kelp) == 5)
        #expect(small.apply(.growBuilder(.kelp), now: Self.t0, calendar: Self.utc)
            == [.growDenied(.kelp, .full(cap: 5))])
        #expect(small.totals.purchases == 0, "a builder's level is not a shop purchase")
    }

    @Test("the Reef page points at the builder that pays its price back soonest")
    func bestGrow() {
        #expect(AquariumGame(pearls: 5).bestGrow == nil, "nothing affordable, nothing to point at")
        let fresh = AquariumGame(pearls: 1000)
        // Kelp: 20 pearls for 4 × 4 a day. Oyster: 35 for 2 × 3 a day.
        #expect(fresh.bestGrow == .kelp)
        var late = AquariumGame(pearls: 100_000, lifetimePearls: 12_000)
        late.reef.bought = ["kelp": 24]   // level 25: the next one costs hundreds and adds little
        #expect(late.bestGrow != .kelp)
        #expect(late.bestGrow != nil)
    }

    // MARK: The harvest

    @Test("a tap brings the whole harvest in with a tenth more; the fraction stays for next time")
    func collectByHand() {
        var game = Self.tank()
        game.reef.harvest = ["kelp": 40.6, "oyster": 9.9, "tide": 0.4]
        let effects = game.apply(.collectHarvest(byHand: true), now: Self.t0, calendar: Self.utc)
        // 40 + 9 whole pearls, and a tenth on top: 53.9, paid as 53.
        #expect(effects == [.harvestCollected(53), .pearlsEarned(53)])
        #expect(game.pearls == 53 && game.lifetimePearls == 53)
        #expect(abs((game.reef.harvest["kelp"] ?? 0) - 0.6) < 1e-9)
        #expect(abs((game.reef.harvest["tide"] ?? 0) - 0.4) < 1e-9)
        #expect(game.apply(.collectHarvest(byHand: true), now: Self.t0, calendar: Self.utc).isEmpty,
                "nothing whole left to take")
    }

    @Test("the snail brings the harvest in at the plain rate while the tank is closed, and leaves it for the hand while it is open")
    func snailCollects() {
        var game = Self.tank(inventory: ["snail": 1])
        game.reef.harvest = ["kelp": 30]
        game.apply(.setWindowOpen(true), now: Self.t0, calendar: Self.utc)
        game.apply(.tick, now: Self.t0, calendar: Self.utc)
        #expect(game.reef.waiting == 30, "the person is at the glass: the tap is theirs")
        game.apply(.setWindowOpen(false), now: Self.t0, calendar: Self.utc)
        let effects = game.apply(.tick, now: Self.t0.addingTimeInterval(20), calendar: Self.utc)
        #expect(effects.contains(.harvestCollected(30)))
        #expect(game.pearls == 30 && game.reef.waiting == 0)
        #expect(game.away.pearlsEarned == 30, "the away card counts it")

        var none = Self.tank()
        none.reef.harvest = ["kelp": 30]
        none.apply(.tick, now: Self.t0, calendar: Self.utc)
        #expect(none.reef.waiting == 30, "with no snail the harvest waits, and never decays")
        none.apply(.tick, now: Self.t0.addingTimeInterval(400 * 86_400), calendar: Self.utc)
        #expect(none.reef.waiting == 30)
    }

    @Test("a settled ask pays the anemone once, and only once it is built")
    func anemone() {
        var game = Self.tank(lifetimePearls: 150)
        game.apply(.askSettled(id: "ask-1"), now: Self.t0, calendar: Self.utc)
        #expect(game.reef.waiting == 0, "no anemone yet")
        #expect(game.reef.settledAsks.isEmpty, "and the ask is not spent: it can pay once one is built")
        game.reef.bought["anemone"] = 2
        game.apply(.askSettled(id: "ask-1"), now: Self.t0, calendar: Self.utc)
        game.apply(.askSettled(id: "ask-1"), now: Self.t0, calendar: Self.utc)
        game.apply(.askSettled(id: ""), now: Self.t0, calendar: Self.utc)
        #expect(abs((game.reef.harvest["anemone"] ?? 0) - 4.5) < 1e-9)
        game.apply(.askSettled(id: "ask-2"), now: Self.t0, calendar: Self.utc)
        #expect(abs((game.reef.harvest["anemone"] ?? 0) - 9) < 1e-9)
        // The memory of paid asks is bounded.
        for index in 0..<400 { game.apply(.askSettled(id: "bulk-\(index)"), now: Self.t0, calendar: Self.utc) }
        #expect(game.reef.settledAsks.count == AquariumReef.settledAsksKept)
    }

    @Test("a quota reset and a new streak day each fill the tide pool")
    func tidePool() {
        var game = Self.tank(lifetimePearls: 900)
        game.apply(.quotaReset, now: Self.t0, calendar: Self.utc)
        #expect(game.reef.waiting == 0, "no tide pool yet")
        game.reef.bought["tide"] = 1
        game.apply(.quotaReset, now: Self.t0, calendar: Self.utc)
        #expect(abs((game.reef.harvest["tide"] ?? 0) - 6) < 1e-9)
        game.apply(.sessionCompleted(id: "a"), now: Self.t0, calendar: Self.utc)
        // The streak's first day: one unit, with that day's 2 % already counted.
        #expect(abs((game.reef.harvest["tide"] ?? 0) - (6 + 6 * 1.02)) < 1e-9)
        game.apply(.sessionCompleted(id: "b"), now: Self.t0.addingTimeInterval(60), calendar: Self.utc)
        #expect(abs((game.reef.harvest["tide"] ?? 0) - (6 + 6 * 1.02)) < 1e-9, "one streak unit a day")
    }

    @Test("the rate the HUD shows is the kelp bed's, at today's concurrency")
    func workRate() {
        var game = AquariumGame()
        #expect(game.workRate(working: 0) == 0)
        #expect(game.workRate(working: 1) == 12)
        #expect(game.workRate(working: 3) == 18)
        game.reef.bought["kelp"] = 9   // level 10: 48, doubled
        #expect(game.workRate(working: 1) == 96)
        #expect(game.workRate(working: 9) == 288, "concurrency is capped at three times")
    }

    // MARK: The save

    @Test("the reef survives a round trip, and a save from before it loads with level-one beds and an empty harvest")
    func saveRoundTrip() throws {
        var game = AquariumGame(pearls: 40, lifetimePearls: 400)
        game.reef = AquariumReef(bought: ["kelp": 6, "anemone": 2], harvest: ["kelp": 12.5],
                                 day: 1_799_971_200, counted: ["kelp": 3.25],
                                 settledAsks: ["a", "b"], grown: 512.5)
        let data = try JSONEncoder().encode(game)
        let back = try JSONDecoder().decode(AquariumGame.self, from: data)
        #expect(back.reef == game.reef)
        #expect(back == game)

        let old = try JSONDecoder().decode(AquariumGame.self,
                                           from: Data(#"{"pearls": 7, "lifetimePearls": 900}"#.utf8))
        #expect(old.reef == AquariumReef())
        #expect(old.reef.level(.kelp) == 1 && old.reef.level(.oyster) == 1)
        #expect(old.reef.level(.anemone) == 0 && old.reef.level(.tide) == 0)
    }

    @Test("a damaged reef loads clamped and never costs the rest of the save")
    func tolerantDecode() throws {
        let json = #"""
        {"pearls": 7, "reef": {"bought": {"kelp": -4, "oyster": 99999999, "nonsense": 3},
                               "harvest": {"kelp": -12, "oyster": 1e300, "tide": 3.5, "nonsense": 9},
                               "day": -5, "counted": "many",
                               "settledAsks": ["a", "a", "b"], "grown": -1}}
        """#
        let game = try JSONDecoder().decode(AquariumGame.self, from: Data(json.utf8))
        #expect(game.pearls == 7)
        #expect(game.reef.level(.kelp) == 1)
        #expect(game.reef.level(.oyster) == 1 + AquariumReef.levelCeiling)
        #expect(game.reef.bought["nonsense"] == nil)
        #expect(game.reef.harvest["kelp"] == nil)
        #expect(game.reef.harvest["oyster"] == Double(AquariumGame.counterCeiling))
        #expect(game.reef.harvest["tide"] == 3.5)
        #expect(game.reef.day == 0 && game.reef.counted.isEmpty && game.reef.grown == 0)
        #expect(game.reef.settledAsks == ["a", "b"])
        #expect(game.reef.waiting == AquariumGame.counterCeiling, "the total is clamped too")

        let wrongType = try JSONDecoder().decode(AquariumGame.self,
                                                 from: Data(#"{"pearls": 3, "reef": "kelp"}"#.utf8))
        #expect(wrongType.pearls == 3 && wrongType.reef == AquariumReef())
    }
}
