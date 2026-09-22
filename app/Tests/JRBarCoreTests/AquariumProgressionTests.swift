import Foundation
import Testing
@testable import JRBarCore

/// The tank's deeper economy (docs/TOYS.md): the level ladder and
/// tier locks, milestones, the daily chore, buried treasure, visitors,
/// and the second wearable slot — all pure reducer, all over the same
/// Codable document an old save still decodes.
@Suite("Aquarium progression")
struct AquariumProgressionTests {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Save compatibility

    /// The fifteen keys a pre-expansion save wrote — nothing else.
    /// Every value must survive the decode; every new field defaults.
    @Test("an old save loads with every field intact and new fields defaulted")
    func oldSaveCompat() throws {
        let json = """
        {"pearls": 2657, "lifetimePearls": 3092, "pearlProgress": 0.63,
         "pets": {"s1": {"stage": 2, "feedings": 0, "workSeconds": 0,
                          "lastNourishedAt": 1800000000, "starvingAt": 1800259200,
                          "lastDropAt": 1800001000, "completionGranted": true,
                          "createdAt": 1799990000, "label": "main",
                          "provider": "claude"}},
         "inventory": {"castle": 1, "hatCrown": 1, "hermitCrab": 1,
                        "jellyfish": 1, "plant": 1, "rock": 1, "snail": 1,
                        "themeLagoon": 1, "themeMidnight": 1, "themeReef": 1,
                        "themeTwilight": 1, "treasureChest": 1},
         "themeID": "midnight",
         "hats": {"s1": "hatCrown"},
         "drops": [{"id": "drop-4", "fishID": "s1", "at": 1800002000, "value": 1}],
         "streakDays": 7, "lastStreakDay": 1800028800,
         "windowOpen": false,
         "away": {"since": 1800000000, "pearlsEarned": 5, "feedings": 1,
                   "completions": 1, "dropsCollected": 0},
         "totals": {"feedings": 41, "completions": 26, "purchases": 12,
                     "dropsCollected": 7},
         "dropSeq": 4, "createdAt": 1799000000}
        """
        let game = try JSONDecoder().decode(AquariumGame.self, from: Data(json.utf8))
        // Old values, intact.
        #expect(game.pearls == 2657)
        #expect(game.lifetimePearls == 3092)
        #expect(game.pearlProgress == 0.63)
        #expect(game.pets["s1"]?.stage == 2)
        #expect(game.pets["s1"]?.label == "main")
        #expect(game.themeID == "midnight")
        #expect(game.hat(for: "s1") == .hatCrown)
        #expect(game.drops.first?.id == "drop-4")
        #expect(game.streakDays == 7)
        #expect(game.lastStreakDay == 1800028800)
        #expect(game.windowOpen == false)
        #expect(game.away.pearlsEarned == 5)
        #expect(game.dropSeq == 4)
        #expect(game.createdAt == 1799000000)
        // No item is lost — all twelve keep.
        #expect(game.inventory.count == 12)
        #expect(game.owns(.castle) && game.owns(.snail) && game.owns(.themeMidnight))
        // The counters outlived the fields that came later.
        #expect(game.totals.feedings == 41)
        #expect(game.totals.completions == 26)
        #expect(game.totals.purchases == 12)
        #expect(game.totals.dropsCollected == 7)
        // New fields, defaulted.
        #expect(game.accessories.isEmpty)
        #expect(game.substrateID == "classic")
        #expect(game.backdropID == "classic")
        #expect(game.unlocked.isEmpty)
        #expect(game.dailyGoal == nil)
        #expect(game.treasure == nil)
        #expect(game.lastTreasureAt == 0)
        #expect(game.pendingVisitors.isEmpty)
        #expect(game.lastVisitorAt.isEmpty)
        #expect(game.continuousWorkSeconds == 0)
        #expect(game.completionsToday == 0)
        #expect(game.totals.treasuresFound == 0)
        #expect(game.totals.visitorsSeen == 0)
    }

    @Test("an old save collects its earned milestones on the first tick, once")
    func oldSaveAutoUnlock() throws {
        let json = """
        {"pearls": 2657, "lifetimePearls": 3092,
         "pets": {"s1": {"stage": 2, "feedings": 0, "workSeconds": 0,
                          "lastNourishedAt": 1800000000, "starvingAt": 1899999999,
                          "lastDropAt": 1800001000, "completionGranted": true,
                          "createdAt": 1799990000}},
         "inventory": {"castle": 1, "hatCrown": 1, "hermitCrab": 1,
                        "jellyfish": 1, "plant": 1, "rock": 1, "snail": 1,
                        "themeLagoon": 1, "themeMidnight": 1, "themeReef": 1,
                        "themeTwilight": 1, "treasureChest": 1},
         "streakDays": 7, "totals": {"feedings": 41, "completions": 26, "purchases": 12}}
        """
        var game = try JSONDecoder().decode(AquariumGame.self, from: Data(json.utf8))
        let effects = game.apply(.tick, now: Self.t0, calendar: Self.utc)
        // The state already satisfied: firstPearl, firstPurchase,
        // fullGrown (the stage-2 pet), streak7, collector (12 items),
        // level5 (3,092 lifetime).
        for expected in [AquariumAchievement.firstPearl, .firstPurchase,
                         .fullGrown, .streak7, .collector, .level5] {
            #expect(effects.contains(.achievementUnlocked(expected)),
                    "\(expected) should have unlocked")
            #expect(game.unlocked[expected.rawValue] != nil)
        }
        #expect(game.pearls == 2657 + 5 + 5 + 15 + 20 + 20 + 25)
        // Paid once — the next tick fires none of them again.
        let again = game.apply(.tick, now: Self.t0 + 60, calendar: Self.utc)
        #expect(!again.contains(.achievementUnlocked(.streak7)))
        #expect(!again.contains(.achievementUnlocked(.collector)))
        #expect(!again.contains(.achievementUnlocked(.level5)))
        #expect(game.pearls == 2657 + 5 + 5 + 15 + 20 + 20 + 25)
    }

    // MARK: The ladder

    @Test("the ladder's thresholds place the tank exactly")
    func ladder() {
        #expect(AquariumProgression.tankLevel(lifetimePearls: 0) == 0)
        #expect(AquariumProgression.tankLevel(lifetimePearls: 49) == 0)
        #expect(AquariumProgression.tankLevel(lifetimePearls: 50) == 1)
        #expect(AquariumProgression.tankLevel(lifetimePearls: 149) == 1)
        #expect(AquariumProgression.tankLevel(lifetimePearls: 150) == 2)
        #expect(AquariumProgression.tankLevel(lifetimePearls: 899) == 3)
        #expect(AquariumProgression.tankLevel(lifetimePearls: 900) == 4)
        #expect(AquariumProgression.tankLevel(lifetimePearls: 3092) == 5)
        #expect(AquariumProgression.tankLevel(lifetimePearls: 11_999) == 8)
        #expect(AquariumProgression.tankLevel(lifetimePearls: 12_000) == 9)
        #expect(AquariumProgression.tankLevel(lifetimePearls: 99_999) == 9)
        #expect(AquariumProgression.nextLevelAt(lifetimePearls: 0) == 50)
        #expect(AquariumProgression.nextLevelAt(lifetimePearls: 50) == 150)
        #expect(AquariumProgression.nextLevelAt(lifetimePearls: 3092) == 3200)
        #expect(AquariumProgression.nextLevelAt(lifetimePearls: 12_000) == nil)
        #expect(AquariumProgression.tierUnlockLevel(tier: 0) == 0)
        #expect(AquariumProgression.tierUnlockLevel(tier: 1) == 1)
        #expect(AquariumProgression.tierUnlockLevel(tier: 2) == 3)
        #expect(AquariumProgression.tierUnlockLevel(tier: 3) == 5)
        #expect(AquariumProgression.tierUnlockLevel(tier: 4) == 7)
    }

    @Test("a tier above the tank level locks until it climbs to the exact level")
    func tierLock() {
        var game = AquariumGame(pearls: 500)
        let locked = game.apply(.purchase(.castle), now: Self.t0)
        #expect(locked.contains(.purchaseLocked(.castle, needsLevel: 1)))
        #expect(!game.owns(.castle))
        #expect(game.pearls == 500)
        // Exactly at the threshold it sells.
        var leveled = AquariumGame(pearls: 500, lifetimePearls: 50)
        #expect(leveled.tankLevel == 1)
        leveled.apply(.purchase(.castle), now: Self.t0)
        #expect(leveled.owns(.castle))
        // Tier 2 asks for level 3 — level 2 is still short.
        var mid = AquariumGame(pearls: 9999, lifetimePearls: 150)
        #expect(mid.tankLevel == 2)
        #expect(mid.apply(.purchase(.shipwreck), now: Self.t0)
            .contains(.purchaseLocked(.shipwreck, needsLevel: 3)))
        mid.lifetimePearls = 400
        #expect(mid.tankLevel == 3)
        mid.apply(.purchase(.shipwreck), now: Self.t0)
        #expect(mid.owns(.shipwreck))
    }

    // MARK: Achievements

    @Test("streak milestones pay on their day, once")
    func streakMilestones() {
        var game = AquariumGame(streakDays: 7)
        let effects = game.apply(.tick, now: Self.t0, calendar: Self.utc)
        #expect(effects.contains(.achievementUnlocked(.streak7)))
        #expect(!effects.contains(.achievementUnlocked(.streak30)))
        #expect(game.unlocked["streak7"] != nil)
        #expect(game.pearls == AquariumAchievement.streak7.reward)
        // The streak reward itself earns the first-pearl milestone on
        // the next beat — catch-up firing is the point of the sweep.
        let again = game.apply(.tick, now: Self.t0 + 1, calendar: Self.utc)
        #expect(!again.contains(.achievementUnlocked(.streak7)))
        #expect(again.contains(.achievementUnlocked(.firstPearl)))
        #expect(game.pearls == AquariumAchievement.streak7.reward
                + AquariumAchievement.firstPearl.reward)

        var month = AquariumGame(streakDays: 30)
        let monthEffects = month.apply(.tick, now: Self.t0, calendar: Self.utc)
        #expect(monthEffects.contains(.achievementUnlocked(.streak7)))
        #expect(monthEffects.contains(.achievementUnlocked(.streak30)))
    }

    @Test("hundred-count milestones pay on the counter")
    func countMilestones() {
        var fed = AquariumGame()
        fed.totals.feedings = 100
        #expect(fed.apply(.tick, now: Self.t0)
            .contains(.achievementUnlocked(.hundredPellets)))
        #expect(fed.unlocked["hundredPellets"] != nil)

        var done = AquariumGame()
        done.totals.completions = 100
        #expect(done.apply(.tick, now: Self.t0)
            .contains(.achievementUnlocked(.hundredCompletions)))

        var grown = AquariumGame()
        grown.pets["a"] = FishCare(stage: AquariumRules.maxStage,
                                   starvingAt: .infinity, createdAt: 0)
        #expect(grown.apply(.tick, now: Self.t0)
            .contains(.achievementUnlocked(.fullGrown)))

        var full = AquariumGame()
        for i in 0..<5 {
            full.pets["f\(i)"] = FishCare(stage: 1, starvingAt: .infinity, createdAt: 0)
        }
        #expect(full.apply(.tick, now: Self.t0)
            .contains(.achievementUnlocked(.fiveResidents)))

        var shelf = AquariumGame()
        for item in ShopItem.allCases.prefix(10) {
            shelf.inventory[item.rawValue] = 1
        }
        #expect(shelf.apply(.tick, now: Self.t0)
            .contains(.achievementUnlocked(.collector)))
        #expect(!shelf.unlocked.keys.contains("curator"))
        for item in ShopItem.allCases.dropFirst(10).prefix(15) {
            shelf.inventory[item.rawValue] = 1
        }
        #expect(shelf.apply(.tick, now: Self.t0 + 1)
            .contains(.achievementUnlocked(.curator)))
    }

    @Test("level milestones pay at rungs five and nine")
    func levelMilestones() {
        var mid = AquariumGame(lifetimePearls: 1800)
        #expect(mid.apply(.tick, now: Self.t0)
            .contains(.achievementUnlocked(.level5)))
        #expect(!mid.unlocked.keys.contains("level9"))
        var top = AquariumGame(lifetimePearls: 12_000)
        #expect(top.apply(.tick, now: Self.t0)
            .contains(.achievementUnlocked(.level9)))
    }

    @Test("night owl and early bird fire on the completion's local hour")
    func oddHourMilestones() {
        let cal = Self.utc
        let day = cal.startOfDay(for: Self.t0)
        var owl = AquariumGame()
        let nightEffects = owl.apply(.sessionCompleted(id: "a"),
                                     now: day.addingTimeInterval(2 * 3600),
                                     calendar: cal)
        #expect(nightEffects.contains(.achievementUnlocked(.nightOwl)))
        #expect(!nightEffects.contains(.achievementUnlocked(.earlyBird)))

        var bird = AquariumGame()
        let morningEffects = bird.apply(.sessionCompleted(id: "a"),
                                        now: day.addingTimeInterval(6 * 3600),
                                        calendar: cal)
        #expect(morningEffects.contains(.achievementUnlocked(.earlyBird)))
        #expect(!morningEffects.contains(.achievementUnlocked(.nightOwl)))

        var noon = AquariumGame()
        let noonEffects = noon.apply(.sessionCompleted(id: "a"),
                                     now: day.addingTimeInterval(12 * 3600),
                                     calendar: cal)
        #expect(!noonEffects.contains(.achievementUnlocked(.nightOwl)))
        #expect(!noonEffects.contains(.achievementUnlocked(.earlyBird)))
        // Only a completion counts — a tick at 2am earns neither.
        var ticking = AquariumGame()
        #expect(!ticking.apply(.tick, now: day.addingTimeInterval(2 * 3600), calendar: cal)
            .contains(.achievementUnlocked(.nightOwl)))
    }

    @Test("the marathon pays for four unbroken hours and the clock resets")
    func marathon() {
        var game = AquariumGame()
        for i in 0..<5 {
            game.apply(.workTick(seconds: AquariumRules.marathonSeconds / 5 + 1,
                                 working: ["a"]),
                       now: Self.t0 + Double(i) * 30)
        }
        #expect(game.unlocked["marathon"] != nil)
        // A beat with nobody working snaps the clock — the next streak
        // starts from zero.
        game.apply(.workTick(seconds: 20, working: []), now: Self.t0 + 200)
        #expect(game.continuousWorkSeconds == 0)
        // And a quiet tick past two intervals decays it too.
        var lazy = AquariumGame()
        lazy.apply(.workTick(seconds: 600, working: ["a"]), now: Self.t0)
        #expect(lazy.continuousWorkSeconds == 600)
        lazy.apply(.tick, now: Self.t0 + AquariumRules.tickInterval * 2 + 1)
        #expect(lazy.continuousWorkSeconds == 0)
        // Inside the window it holds.
        var held = AquariumGame()
        held.apply(.workTick(seconds: 600, working: ["a"]), now: Self.t0)
        held.apply(.tick, now: Self.t0 + AquariumRules.tickInterval)
        #expect(held.continuousWorkSeconds == 600)
    }

    // MARK: Daily goal

    @Test("the day's chore is the same for every tank that day")
    func dailyGoalDeterministic() {
        let cal = Self.utc
        let day = cal.startOfDay(for: Self.t0).timeIntervalSince1970
        let expected = AquariumDailyGoal.Kind.forDay(day)
        var a = AquariumGame()
        var b = AquariumGame()
        a.apply(.tick, now: Self.t0, calendar: cal)
        b.apply(.tick, now: Self.t0, calendar: cal)
        #expect(a.dailyGoal?.kind == expected)
        #expect(a.dailyGoal == b.dailyGoal)
        #expect(a.dailyGoal?.day == day)
        // Consecutive days always hand out a different chore.
        #expect(AquariumDailyGoal.Kind.forDay(day + 86400) != expected)
    }

    @Test("the goal pays its reward once when the chore is done")
    func dailyGoalClaim() {
        let cal = Self.utc
        let today = cal.startOfDay(for: Self.t0).timeIntervalSince1970
        var game = AquariumGame()
        game.dailyGoal = AquariumDailyGoal(kind: .pellets, target: 10,
                                           progress: 9, day: today)
        let effects = game.apply(.pelletEaten(fishID: "a"), now: Self.t0, calendar: cal)
        #expect(effects.contains(.dailyGoalMet(game.dailyGoal!)))
        #expect(game.dailyGoal?.claimed == true)
        #expect(game.dailyGoal?.progress == 10)
        #expect(game.pearls == AquariumRules.pelletPearl + AquariumRules.dailyGoalReward
                + AquariumAchievement.firstPearl.reward)
        // More pellets the same day never pay again.
        let more = game.apply(.pelletEaten(fishID: "a"), now: Self.t0 + 1, calendar: cal)
        #expect(!more.contains(.dailyGoalMet(game.dailyGoal!)))
        #expect(game.pearls == AquariumRules.pelletPearl * 2 + AquariumRules.dailyGoalReward
                + AquariumAchievement.firstPearl.reward)
    }

    @Test("work minutes count through the carry; rollover brings a fresh chore")
    func dailyGoalMinutesAndRollover() {
        let cal = Self.utc
        let today = cal.startOfDay(for: Self.t0).timeIntervalSince1970
        var game = AquariumGame()
        game.dailyGoal = AquariumDailyGoal(kind: .workMinutes, target: 90,
                                           progress: 89, day: today)
        // 61 seconds of work: one whole minute lands, the second keeps.
        game.apply(.workTick(seconds: 61, working: ["a"]), now: Self.t0, calendar: cal)
        #expect(game.dailyGoal?.claimed == true)
        #expect(game.goalCarrySeconds == 1)
        // Midnight swaps the chore — progress never carries over.
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Self.t0)!
        game.apply(.tick, now: tomorrow, calendar: cal)
        let newDay = cal.startOfDay(for: tomorrow).timeIntervalSince1970
        #expect(game.dailyGoal?.day == newDay)
        #expect(game.dailyGoal?.kind == AquariumDailyGoal.Kind.forDay(newDay))
        #expect(game.dailyGoal?.progress == 0)
        #expect(game.dailyGoal?.claimed == false)
        #expect(game.goalCarrySeconds == 0)
    }

    // MARK: Treasure

    @Test("a glint surfaces on the interval, deterministic, and digs up in three taps")
    func treasure() {
        var game = AquariumGame()
        game.apply(.tick, now: Self.t0, calendar: Self.utc)
        guard let find = game.treasure else {
            Issue.record("expected a treasure after the first tick")
            return
        }
        #expect(find.taps == 0)
        #expect(find.x >= 0 && find.x <= 1)
        #expect(find.value == AquariumRules.treasureBaseValue)
        // The same clock buries the same chest — the hash is off the
        // interval bucket.
        var twin = AquariumGame()
        twin.apply(.tick, now: Self.t0, calendar: Self.utc)
        #expect(twin.treasure == find)
        // Two digs, still buried; the third pays.
        game.apply(.digTreasure(find.id), now: Self.t0 + 1, calendar: Self.utc)
        game.apply(.digTreasure(find.id), now: Self.t0 + 2, calendar: Self.utc)
        #expect(game.treasure?.taps == 2)
        #expect(game.pearls == 0)
        let effects = game.apply(.digTreasure(find.id), now: Self.t0 + 3, calendar: Self.utc)
        #expect(effects.contains(.treasureFound(find.value)))
        #expect(effects.contains(.achievementUnlocked(.treasureHunter)))
        #expect(game.treasure == nil)
        #expect(game.totals.treasuresFound == 1)
        #expect(game.pearls == find.value + AquariumAchievement.firstPearl.reward
                + AquariumAchievement.treasureHunter.reward)
        // A wrong id digs nothing.
        let banked = game.pearls
        game.apply(.digTreasure("ghost"), now: Self.t0 + 4, calendar: Self.utc)
        #expect(game.pearls == banked)
        #expect(game.treasure == nil)
        // The next glint waits out the interval from the dig.
        game.apply(.tick, now: Self.t0 + 3 + AquariumRules.treasureInterval - 1,
                   calendar: Self.utc)
        #expect(game.treasure == nil)
        game.apply(.tick, now: Self.t0 + 3 + AquariumRules.treasureInterval,
                   calendar: Self.utc)
        #expect(game.treasure != nil)
    }

    @Test("a treasure left buried six hours sinks back without paying")
    func treasureExpiry() {
        var game = AquariumGame()
        game.apply(.tick, now: Self.t0, calendar: Self.utc)
        #expect(game.treasure != nil)
        game.apply(.tick, now: Self.t0 + AquariumRules.treasureLifetime + 1,
                   calendar: Self.utc)
        #expect(game.treasure == nil)
        #expect(game.pearls == 0)
        #expect(game.totals.treasuresFound == 0)
        // The expiry stamped the clock — the sand stays bare until the
        // interval runs out from the sinking.
        game.apply(.tick, now: Self.t0 + AquariumRules.treasureLifetime
                   + AquariumRules.treasureInterval - 1, calendar: Self.utc)
        #expect(game.treasure == nil)
        game.apply(.tick, now: Self.t0 + AquariumRules.treasureLifetime
                   + AquariumRules.treasureInterval + 2, calendar: Self.utc)
        #expect(game.treasure != nil)
    }

    // MARK: Visitors

    @Test("each visitor trigger queues once a day; shown dequeues")
    func visitors() {
        var game = AquariumGame()
        // Two unbroken hours and the whale comes by.
        let effects = game.apply(
            .workTick(seconds: AquariumRules.whaleWorkSeconds + 60, working: ["a"]),
            now: Self.t0, calendar: Self.utc)
        #expect(effects.contains(.visitor(.whale)))
        #expect(game.pendingVisitors == [.whale])
        // Inside the window the trigger can't queue it again.
        let again = game.apply(.workTick(seconds: 60, working: ["a"]),
                               now: Self.t0 + 60, calendar: Self.utc)
        #expect(!again.contains(.visitor(.whale)))
        #expect(game.pendingVisitors == [.whale])
        // The view parades it, then reports it shown.
        game.apply(.visitorShown(.whale), now: Self.t0 + 120, calendar: Self.utc)
        #expect(game.pendingVisitors.isEmpty)
        #expect(game.totals.visitorsSeen == 1)
        // A quota reset brings the submarine — once a day too.
        let reset = game.apply(.quotaReset, now: Self.t0 + 200, calendar: Self.utc)
        #expect(reset.contains(.visitor(.submarine)))
        #expect(game.pendingVisitors == [.submarine])
        game.apply(.visitorShown(.submarine), now: Self.t0 + 300, calendar: Self.utc)
        let tooSoon = game.apply(.quotaReset, now: Self.t0 + 400, calendar: Self.utc)
        #expect(!tooSoon.contains(.visitor(.submarine)))
        #expect(game.pendingVisitors.isEmpty)
        // After the cooldown the lane resets welcome it again.
        let nextDay = game.apply(.quotaReset,
                                 now: Self.t0 + AquariumRules.visitorCooldown + 500,
                                 calendar: Self.utc)
        #expect(nextDay.contains(.visitor(.submarine)))
    }

    @Test("the tenth completion of the day brings the diver")
    func diver() {
        var game = AquariumGame()
        var sawDiver = false
        for i in 0..<AquariumRules.diverCompletions {
            let effects = game.apply(.sessionCompleted(id: "s\(i)"),
                                     now: Self.t0 + Double(i) * 60,
                                     calendar: Self.utc)
            sawDiver = sawDiver || effects.contains(.visitor(.diver))
        }
        #expect(sawDiver)
        #expect(game.pendingVisitors.contains(.diver))
        #expect(game.completionsToday == AquariumRules.diverCompletions)
        // A new day starts the count over — the next morning's first
        // completion queues nothing.
        let tomorrow = Self.utc.date(byAdding: .day, value: 1, to: Self.t0)!
        let effects = game.apply(.sessionCompleted(id: "next"), now: tomorrow,
                                 calendar: Self.utc)
        #expect(game.completionsToday == 1)
        #expect(!effects.contains(.visitor(.diver)))
    }

    // MARK: Accessories & surfaces

    @Test("an accessory rides its own slot — one per fish, off on nil")
    func accessories() {
        var game = AquariumGame(pearls: 200)
        // Unowned can't be worn.
        #expect(game.apply(.equipAccessory(.sunglasses, fishID: "a"), now: Self.t0)
            .contains(.purchaseDenied(.sunglasses)))
        game.apply(.purchase(.sunglasses), now: Self.t0)
        game.apply(.equipAccessory(.sunglasses, fishID: "a"), now: Self.t0)
        #expect(game.accessory(for: "a") == .sunglasses)
        // A hat is not an accessory — even owned, it is denied here.
        game.apply(.purchase(.hatBeanie), now: Self.t0)
        #expect(game.apply(.equipAccessory(.hatBeanie, fishID: "a"), now: Self.t0)
            .contains(.purchaseDenied(.hatBeanie)))
        // Re-seating moves it; the first fish is bare again.
        game.apply(.equipAccessory(.sunglasses, fishID: "b"), now: Self.t0)
        #expect(game.accessory(for: "a") == nil)
        #expect(game.accessory(for: "b") == .sunglasses)
        // The hat slot is independent.
        game.apply(.equipHat(.hatBeanie, fishID: "b"), now: Self.t0)
        #expect(game.hat(for: "b") == .hatBeanie)
        #expect(game.accessory(for: "b") == .sunglasses)
        // nil takes it off entirely.
        game.apply(.equipAccessory(.sunglasses, fishID: nil), now: Self.t0)
        #expect(game.accessory(for: "b") == nil)
    }

    @Test("substrate and backdrop apply on purchase and by selection, ownership-gated")
    func surfaces() {
        // Level 3 opens the whole substrate shelf.
        var game = AquariumGame(pearls: 500, lifetimePearls: 400)
        #expect(game.substrateID == "classic")
        #expect(game.backdropID == "classic")
        #expect(game.apply(.selectSubstrate(.sandWhite), now: Self.t0)
            .contains(.purchaseDenied(.sandWhite)))
        #expect(game.apply(.selectBackdrop(.rockyBackdrop), now: Self.t0)
            .contains(.purchaseDenied(.rockyBackdrop)))
        // A decor item is neither a substrate nor a backdrop.
        game.apply(.purchase(.plant), now: Self.t0)
        #expect(game.apply(.selectSubstrate(.plant), now: Self.t0)
            .contains(.purchaseDenied(.plant)))
        #expect(game.apply(.selectBackdrop(.plant), now: Self.t0)
            .contains(.purchaseDenied(.plant)))
        // Bought surfaces apply on purchase and reselect.
        game.apply(.purchase(.sandWhite), now: Self.t0)
        #expect(game.substrateID == "white")
        game.apply(.purchase(.gravelBlack), now: Self.t0)
        #expect(game.substrateID == "black")
        game.apply(.selectSubstrate(.sandWhite), now: Self.t0)
        #expect(game.substrateID == "white")
        game.apply(.purchase(.rockyBackdrop), now: Self.t0)
        #expect(game.backdropID == "rocky")
        game.apply(.purchase(.reefWallBackdrop), now: Self.t0)
        #expect(game.backdropID == "reefwall")
        game.apply(.selectBackdrop(.rockyBackdrop), now: Self.t0)
        #expect(game.backdropID == "rocky")
    }

    // MARK: The catalog

    @Test("every shop item is priced, tiered, uniquely keyed, and slotted right")
    func catalog() {
        let raws = ShopItem.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
        for item in ShopItem.allCases {
            #expect(item.price > 0, "\(item) is free")
            #expect((0...4).contains(item.tier), "\(item) tier out of range")
            #expect(item.isWearable == (item.category == .hats || item.category == .accessories),
                    "\(item) wearable flag wrong")
            #expect(item.isUnlocked(atLevel: 9), "\(item) never unlocks")
            if item.category != .themes { #expect(item.themeID == nil) }
            if item.category != .substrates {
                #expect(item.substrateID == nil && item.backdropID == nil)
            }
        }
        // Every theme item carries a theme id; every substrate item
        // carries exactly one surface id.
        for item in ShopItem.allCases where item.category == .themes {
            #expect(item.themeID != nil)
        }
        for item in ShopItem.allCases where item.category == .substrates {
            #expect((item.substrateID != nil) != (item.backdropID != nil))
        }
    }

    @Test("the decode filters keep accessories out of hats and vice versa")
    func wearableDecodeFilters() throws {
        let json = """
        {"hats": {"a": "sunglasses", "b": "hatBeanie", "c": "snail"},
         "accessories": {"d": "hatCrown", "e": "monocle", "f": "plant"}}
        """
        let game = try JSONDecoder().decode(AquariumGame.self, from: Data(json.utf8))
        #expect(game.hat(for: "a") == nil)
        #expect(game.hat(for: "b") == .hatBeanie)
        #expect(game.hat(for: "c") == nil)
        #expect(game.accessory(for: "d") == nil)
        #expect(game.accessory(for: "e") == .monocle)
        #expect(game.accessory(for: "f") == nil)
    }
}
