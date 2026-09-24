import Foundation
import Testing
@testable import JRBarCore

/// `AquariumGame.apply` is the tank's whole economy (docs/TOYS.md):
/// pearls from work, completion bonuses, feeding & growth, starvation,
/// drops, the shop, the streak and the away summary. Pure — every test
/// feeds events and reads the document.
@Suite("Aquarium game")
struct AquariumGameTests {
    /// A fixed UTC calendar so streak-day tests don't wobble with the
    /// machine's timezone.
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Earning

    @Test("a work tick mints a pearl per workSecondsPerPearl")
    func workPearl() {
        var game = AquariumGame()
        game.apply(.workTick(seconds: AquariumRules.workSecondsPerPearl, working: ["a"]),
                   now: Self.t0)
        // The first pearl minted also unlocks its milestone reward.
        #expect(game.pearls == 1 + AquariumAchievement.firstPearl.reward)
        #expect(game.lifetimePearls == 1 + AquariumAchievement.firstPearl.reward)
        // The fractional bank is spent, not carried twice.
        #expect(game.pearlProgress < 1)
        // Two half-ticks mint the same pearl once.
        var again = AquariumGame()
        again.apply(.workTick(seconds: AquariumRules.workSecondsPerPearl / 2, working: ["a"]),
                    now: Self.t0)
        #expect(again.pearls == 0)
        again.apply(.workTick(seconds: AquariumRules.workSecondsPerPearl / 2, working: ["a"]),
                    now: Self.t0 + 10)
        #expect(again.pearls == 1 + AquariumAchievement.firstPearl.reward)
    }

    @Test("concurrent working scales mildly and caps")
    func concurrency() {
        var game = AquariumGame()
        let many = (0..<20).map { "s\($0)" }
        game.apply(.workTick(seconds: AquariumRules.workSecondsPerPearl, working: many),
                   now: Self.t0)
        // 1 + 0.25·19 = 5.75 uncapped → capped at 3×, plus the first-pearl reward.
        #expect(game.pearls == 3 + AquariumAchievement.firstPearl.reward)
        var two = AquariumGame()
        two.apply(.workTick(seconds: AquariumRules.workSecondsPerPearl, working: ["a", "b"]),
                  now: Self.t0)
        #expect(two.pearls == 1 + AquariumAchievement.firstPearl.reward)
        #expect(two.pearlProgress > 0.2)
    }

    @Test("a completed session pays the bonus once")
    func completionBonus() {
        var game = AquariumGame()
        game.apply(.sessionCompleted(id: "a"), now: Self.t0, calendar: Self.utc)
        #expect(game.pearls == AquariumRules.completionBonus
                + AquariumAchievement.firstPearl.reward)
        // Still listed, still done — never paid twice.
        game.apply(.sessionCompleted(id: "a"), now: Self.t0 + 5, calendar: Self.utc)
        #expect(game.pearls == AquariumRules.completionBonus
                + AquariumAchievement.firstPearl.reward)
        #expect(game.totals.completions == 1)
        // A different session pays its own.
        game.apply(.sessionCompleted(id: "b"), now: Self.t0 + 6, calendar: Self.utc)
        #expect(game.pearls == AquariumRules.completionBonus * 2
                + AquariumAchievement.firstPearl.reward)
    }

    @Test("a waiting session earns nothing")
    func waitingEarnsNothing() {
        var game = AquariumGame()
        // The caller only ever lists working sessions in `working` —
        // a tick with an empty working set moves nothing.
        game.apply(.workTick(seconds: AquariumRules.workSecondsPerPearl * 4, working: []),
                   now: Self.t0)
        #expect(game.pearls == 0)
        // And a pet is never even created for a session that only waited.
        #expect(game.pets.isEmpty)
    }

    // MARK: Feeding & growth

    @Test("K feedings plus work-time grows a stage; the costs are spent")
    func growth() {
        var game = AquariumGame()
        // Feedings alone aren't enough — the stage wants work-time too.
        for _ in 0..<AquariumRules.feedingsPerStage {
            game.apply(.pelletEaten(fishID: "a"), now: Self.t0)
        }
        #expect(game.pets["a"]?.stage == 0)
        // Work alone isn't enough either.
        var worked = AquariumGame()
        worked.apply(.workTick(seconds: AquariumRules.growthWorkSeconds + 1, working: ["a"]),
                     now: Self.t0)
        #expect(worked.pets["a"]?.stage == 0)
        // Both budgets met → stage 1, counters spent.
        game.apply(.workTick(seconds: AquariumRules.growthWorkSeconds + 1, working: ["a"]),
                   now: Self.t0 + 60)
        #expect(game.pets["a"]?.stage == 1)
        #expect(game.pets["a"]?.feedings == 0)
        #expect(game.pets["a"]?.workSeconds ?? 9 < 5)
    }

    @Test("an eaten pellet pays a pearl and feeds the fish")
    func pellet() {
        var game = AquariumGame()
        game.apply(.pelletEaten(fishID: "a"), now: Self.t0)
        #expect(game.pearls == AquariumRules.pelletPearl
                + AquariumAchievement.firstPearl.reward)
        #expect(game.pets["a"]?.feedings == 1)
        #expect(game.totals.feedings == 1)
    }

    @Test("only feedingsPerFishPerDay pellets a day pay & count; the rest are just supper")
    func feedingCap() {
        var game = AquariumGame()
        let cap = AquariumRules.feedingsPerFishPerDay
        for _ in 0..<(cap + 4) {
            game.apply(.pelletEaten(fishID: "a"), now: Self.t0, calendar: Self.utc)
        }
        // The cap, not the tap count, is what the fish banked.
        #expect(game.pets["a"]?.feedings == cap)
        #expect(game.pets["a"]?.feedingsToday == cap)
        #expect(game.totals.feedings == cap)
        // Pearls: one per counted pellet, the first-pearl milestone,
        // and the day's chore when t0's goal happens to be pellets —
        // counted feedings reach its target exactly at the cap.
        var expected = cap * AquariumRules.pelletPearl
            + AquariumAchievement.firstPearl.reward
        if game.dailyGoal?.kind == .pellets, game.dailyGoal?.claimed == true {
            expected += AquariumRules.dailyGoalReward
        }
        #expect(game.pearls == expected)
        // …but every pellet still nourishes — a fed fish is a fed fish.
        #expect(game.pets["a"]?.hungry(at: Self.t0 + 60) == false)
        // Another fish eats under its own cap the same day.
        game.apply(.pelletEaten(fishID: "b"), now: Self.t0, calendar: Self.utc)
        #expect(game.totals.feedings == cap + 1)
        // Tomorrow the counter rolls over.
        let tomorrow = Self.utc.date(byAdding: .day, value: 1, to: Self.t0)!
        let effects = game.apply(.pelletEaten(fishID: "a"), now: tomorrow, calendar: Self.utc)
        #expect(effects.contains(.pearlsEarned(AquariumRules.pelletPearl)))
        #expect(game.pets["a"]?.feedings == cap + 1)
        #expect(game.pets["a"]?.feedingsToday == 1)
    }

    @Test("a work beat after a stale gap restarts the marathon clock")
    func staleWorkBank() {
        var game = AquariumGame()
        game.apply(.workTick(seconds: 600, working: ["a"]), now: Self.t0)
        #expect(game.continuousWorkSeconds == 600)
        // Inside the gap it keeps accumulating.
        game.apply(.workTick(seconds: 60, working: ["a"]),
                   now: Self.t0 + AquariumRules.workContinuityGap - 1)
        #expect(game.continuousWorkSeconds == 660)
        // Past the gap the bank is stale — the new beat is a fresh
        // stretch, not 660 + 60.
        game.apply(.workTick(seconds: 60, working: ["a"]),
                   now: Self.t0 + 2 * AquariumRules.workContinuityGap + 1)
        #expect(game.continuousWorkSeconds == 60)
        // A stale bank can never ride into the whale: two hours banked
        // a day ago (say, a save from before load-resetting) followed
        // by a fresh beat queues nothing.
        var saved = AquariumGame()
        saved.continuousWorkSeconds = AquariumRules.whaleWorkSeconds + 60
        saved.lastWorkAt = Self.t0.timeIntervalSince1970
        let effects = saved.apply(.workTick(seconds: 20, working: ["a"]),
                                  now: Self.t0 + 24 * 3600)
        #expect(saved.continuousWorkSeconds == 20)
        #expect(!effects.contains(.visitor(.whale)))
        #expect(saved.unlocked["marathon"] == nil)
    }

    @Test("a visitor's departure reports back for the goodbye beat")
    func visitorDeparture() {
        var game = AquariumGame()
        game.apply(.quotaReset, now: Self.t0)
        #expect(game.pendingVisitors == [.submarine])
        game.apply(.visitorShown(.submarine), now: Self.t0 + 10)
        let effects = game.apply(.visitorDeparted(.submarine), now: Self.t0 + 24)
        #expect(effects.contains(.visitorDeparted(.submarine)))
        // It changes nothing else — the parade is the view's business.
        #expect(game.totals.visitorsSeen == 1)
        #expect(game.pendingVisitors.isEmpty)
    }

    @Test("a starved fish shrinks one stage per starve period, never below zero")
    func starvation() {
        var game = AquariumGame()
        var care = FishCare(stage: 2, lastNourishedAt: Self.t0.timeIntervalSince1970,
                            starvingAt: Self.t0.timeIntervalSince1970 + AquariumRules.starveAfter,
                            createdAt: Self.t0.timeIntervalSince1970)
        game.pets["a"] = care
        let t1 = Self.t0 + AquariumRules.starveAfter + 1
        game.apply(.tick, now: t1)
        #expect(game.pets["a"]?.stage == 1)
        // The clock restarted: the next tick alone doesn't shrink again.
        game.apply(.tick, now: t1 + 60)
        #expect(game.pets["a"]?.stage == 1)
        game.apply(.tick, now: t1 + AquariumRules.starveAfter + 1)
        #expect(game.pets["a"]?.stage == 0)
        // Never dies: stage floors at zero even after ages.
        game.apply(.tick, now: t1 + AquariumRules.starveAfter * 100)
        #expect(game.pets["a"]?.stage == 0)
        #expect(game.pets["a"] != nil)
        care = game.pets["a"]!
        #expect(care.hungry(at: t1 + AquariumRules.starveAfter * 100))
    }

    @Test("a fed or working fish isn't hungry")
    func nourished() {
        var game = AquariumGame()
        game.apply(.pelletEaten(fishID: "a"), now: Self.t0)
        #expect(game.pets["a"]?.hungry(at: Self.t0 + 60) == false)
        #expect(game.pets["a"]?.hungry(at: Self.t0 + AquariumRules.starveAfter + 1) == true)
        game.apply(.workTick(seconds: 10, working: ["a"]),
                   now: Self.t0 + AquariumRules.starveAfter + 2)
        #expect(game.pets["a"]?.hungry(at: Self.t0 + AquariumRules.starveAfter + 3) == false)
    }

    // MARK: Pearl drops

    @Test("a full-grown fish drops a pearl each interval; smaller fish never do")
    func drops() {
        var game = AquariumGame()
        game.pets["big"] = FishCare(stage: AquariumRules.maxStage,
                                    starvingAt: .infinity,
                                    lastDropAt: Self.t0.timeIntervalSince1970,
                                    createdAt: Self.t0.timeIntervalSince1970)
        game.pets["small"] = FishCare(stage: 0,
                                      starvingAt: .infinity,
                                      lastDropAt: Self.t0.timeIntervalSince1970,
                                      createdAt: Self.t0.timeIntervalSince1970)
        let t1 = Self.t0 + AquariumRules.pearlDropInterval + 1
        game.apply(.tick, now: t1)
        #expect(game.drops.count == 1)
        #expect(game.drops.first?.fishID == "big")
        // The interval restarted.
        game.apply(.tick, now: t1 + 60)
        #expect(game.drops.count == 1)
        // Collecting pays — plus the first-pearl milestone and the
        // full-grown one the stage-2 "big" fish already earned.
        let id = game.drops[0].id
        game.apply(.collectDrop(id), now: t1 + 61)
        #expect(game.pearls == AquariumRules.dropPearlValue
                + AquariumAchievement.firstPearl.reward
                + AquariumAchievement.fullGrown.reward)
        #expect(game.drops.isEmpty)
        #expect(game.totals.dropsCollected == 1)
        // An unknown id is a no-op.
        game.apply(.collectDrop("ghost"), now: t1 + 62)
        #expect(game.pearls == AquariumRules.dropPearlValue
                + AquariumAchievement.firstPearl.reward
                + AquariumAchievement.fullGrown.reward)
    }

    @Test("an owned snail collects a sat drop; no snail, it waits")
    func snail() {
        var game = AquariumGame()
        game.drops = [PearlDrop(id: "d1", fishID: "a",
                                at: Self.t0.timeIntervalSince1970,
                                value: AquariumRules.dropPearlValue)]
        game.apply(.tick, now: Self.t0 + AquariumRules.snailCollectAfter + 1)
        #expect(game.drops.count == 1)   // nobody picked it up
        game.inventory[ShopItem.snail.rawValue] = 1
        game.apply(.tick, now: Self.t0 + AquariumRules.snailCollectAfter + 2)
        #expect(game.drops.isEmpty)
        #expect(game.pearls == 1 + AquariumAchievement.firstPearl.reward)
        #expect(game.totals.dropsCollected == 1)
    }

    // MARK: Shop

    @Test("a purchase spends pearls once; re-buying or overspending is denied")
    func purchase() {
        // Lifetime 50 puts the tank at level 1 — the castle's tier.
        var game = AquariumGame(pearls: 60, lifetimePearls: 50)
        let effects = game.apply(.purchase(.castle), now: Self.t0)
        // The spend is exact; the first-pearl and first-purchase
        // milestones pay on top.
        #expect(game.pearls == AquariumAchievement.firstPearl.reward
                + AquariumAchievement.firstPurchase.reward)
        #expect(game.owns(.castle))
        #expect(game.totals.purchases == 1)
        #expect(effects.contains(.pearlsSpent(ShopItem.castle.price)))
        // Already owned.
        #expect(game.apply(.purchase(.castle), now: Self.t0).contains(.purchaseDenied(.castle)))
        // Can't afford.
        #expect(game.apply(.purchase(.snail), now: Self.t0).contains(.purchaseDenied(.snail)))
        #expect(!game.owns(.snail))
    }

    @Test("a theme applies on purchase and by selection; an unowned one can't be set")
    func themes() {
        var game = AquariumGame(pearls: 100)
        #expect(game.themeID == "classic")
        game.apply(.purchase(.themeLagoon), now: Self.t0)
        #expect(game.themeID == "lagoon")
        #expect(game.apply(.selectTheme(.themeReef), now: Self.t0)
            .contains(.purchaseDenied(.themeReef)))
        game.apply(.purchase(.themeReef), now: Self.t0)
        #expect(game.themeID == "reef")
        game.apply(.selectTheme(.themeLagoon), now: Self.t0)
        #expect(game.themeID == "lagoon")
    }

    @Test("a hat equips to one fish at a time and comes off")
    func hats() {
        var game = AquariumGame(pearls: 20)
        // Unowned hats can't be equipped.
        #expect(game.apply(.equipHat(.hatBeanie, fishID: "a"), now: Self.t0)
            .contains(.purchaseDenied(.hatBeanie)))
        game.apply(.purchase(.hatBeanie), now: Self.t0)
        game.apply(.equipHat(.hatBeanie, fishID: "a"), now: Self.t0)
        #expect(game.hat(for: "a") == .hatBeanie)
        // Re-seating moves the hat; the first fish is bare again.
        game.apply(.equipHat(.hatBeanie, fishID: "b"), now: Self.t0)
        #expect(game.hat(for: "a") == nil)
        #expect(game.hat(for: "b") == .hatBeanie)
        // nil takes it off entirely.
        game.apply(.equipHat(.hatBeanie, fishID: nil), now: Self.t0)
        #expect(game.hat(for: "b") == nil)
    }

    // MARK: Streak

    @Test("the streak counts distinct completion days, restarts after a gap")
    func streak() {
        var game = AquariumGame()
        let cal = Self.utc
        // Two completions the same day count once.
        game.apply(.sessionCompleted(id: "a"), now: Self.t0, calendar: cal)
        game.apply(.sessionCompleted(id: "b"), now: Self.t0 + 3600, calendar: cal)
        #expect(game.streakDays == 1)
        // The next day extends it.
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Self.t0)!
        game.apply(.sessionCompleted(id: "c"), now: tomorrow, calendar: cal)
        #expect(game.streakDays == 2)
        // A gap restarts at one.
        let later = cal.date(byAdding: .day, value: 5, to: Self.t0)!
        game.apply(.sessionCompleted(id: "d"), now: later, calendar: cal)
        #expect(game.streakDays == 1)
    }

    // MARK: Away summary

    @Test("a closed window accumulates an away summary; opening drains it once")
    func awaySummary() {
        var game = AquariumGame()
        game.apply(.setWindowOpen(true), now: Self.t0)
        // Earnings while open are not "away".
        game.apply(.workTick(seconds: AquariumRules.workSecondsPerPearl, working: ["a"]),
                   now: Self.t0 + 1)
        game.apply(.setWindowOpen(false), now: Self.t0 + 2)
        game.apply(.workTick(seconds: AquariumRules.workSecondsPerPearl, working: ["a"]),
                   now: Self.t0 + 3)
        game.apply(.pelletEaten(fishID: "a"), now: Self.t0 + 4)
        game.apply(.sessionCompleted(id: "a"), now: Self.t0 + 5, calendar: Self.utc)
        let effects = game.apply(.setWindowOpen(true), now: Self.t0 + 6)
        guard case .awaySummary(let summary) = effects.first(where: {
            if case .awaySummary = $0 { return true }; return false
        }) else {
            Issue.record("expected an awaySummary effect")
            return
        }
        #expect(summary.pearlsEarned == 1 + AquariumRules.pelletPearl + AquariumRules.completionBonus)
        #expect(summary.completions == 1)
        // Drained: closing and reopening with nothing in between is empty.
        game.apply(.setWindowOpen(false), now: Self.t0 + 7)
        let again = game.apply(.setWindowOpen(true), now: Self.t0 + 8)
        #expect(!again.contains(where: {
            if case .awaySummary = $0 { return true }; return false
        }))
    }

    @Test("the snail's closed-tank rounds credit the away summary on reopen")
    func snailAwayCatchUp() {
        var game = AquariumGame()
        game.inventory[ShopItem.snail.rawValue] = 1
        game.apply(.setWindowOpen(true), now: Self.t0)
        game.apply(.setWindowOpen(false), now: Self.t0 + 1)
        // Two drops were on the sand when the tank closed: one long
        // past the snail's pick-up wait by reopen, one still fresh.
        game.drops = [
            PearlDrop(id: "ripe", fishID: "a",
                      at: (Self.t0 + 1).timeIntervalSince1970,
                      value: AquariumRules.dropPearlValue),
            PearlDrop(id: "fresh", fishID: "a",
                      at: (Self.t0 + 1).timeIntervalSince1970
                          + AquariumRules.snailCollectAfter + 4,
                      value: AquariumRules.dropPearlValue)]
        let reopen = Self.t0 + 1 + AquariumRules.snailCollectAfter + 6
        let effects = game.apply(.setWindowOpen(true), now: reopen)
        let summary = effects.compactMap { effect -> AquariumAwaySummary? in
            if case .awaySummary(let s) = effect { return s }
            return nil
        }.first
        // The ripe drop was collected while the away window was still
        // open — it lands in the summary; the fresh one stays on the
        // sand for the next live tick.
        #expect(summary?.dropsCollected == 1)
        #expect(summary?.pearlsEarned == AquariumRules.dropPearlValue)
        #expect(game.drops.map(\.id) == ["fresh"])
        #expect(game.totals.dropsCollected == 1)
    }

    @Test("with no snail, closed-window drops wait on the sand")
    func noSnailNoCatchUp() {
        var game = AquariumGame()
        game.drops = [PearlDrop(id: "d1", fishID: "a",
                                at: Self.t0.timeIntervalSince1970,
                                value: AquariumRules.dropPearlValue)]
        game.apply(.setWindowOpen(true), now: Self.t0)
        game.apply(.setWindowOpen(false), now: Self.t0 + 1)
        let effects = game.apply(.setWindowOpen(true),
                                 now: Self.t0 + 1 + AquariumRules.snailCollectAfter + 60)
        #expect(game.drops.map(\.id) == ["d1"])
        #expect(game.totals.dropsCollected == 0)
        // Nothing happened while closed, so nothing is reported.
        #expect(!effects.contains(where: {
            if case .awaySummary = $0 { return true }; return false
        }))
    }

    @Test("the reopen catch-up runs before the window flips open — the drops count as away")
    func catchUpCreditsAwayWindow() {
        var game = AquariumGame()
        game.inventory[ShopItem.snail.rawValue] = 1
        game.drops = [PearlDrop(id: "d1", fishID: "a",
                                at: Self.t0.timeIntervalSince1970,
                                value: AquariumRules.dropPearlValue)]
        // Reopening drains a summary whose only content is the snail's
        // pick-up — the collection itself minted it.
        let effects = game.apply(.setWindowOpen(true),
                                 now: Self.t0 + AquariumRules.snailCollectAfter + 1)
        let summary = effects.compactMap { effect -> AquariumAwaySummary? in
            if case .awaySummary(let s) = effect { return s }
            return nil
        }.first
        #expect(summary?.dropsCollected == 1)
        // The drop's pearl landed inside the away window too.
        #expect(summary?.pearlsEarned == AquariumRules.dropPearlValue)
        #expect(game.windowOpen)
        #expect(game.drops.isEmpty)
    }

    @Test("nothing accrues without events — no wall-clock catch-up")
    func noCatchUp() {
        var game = AquariumGame()
        game.apply(.workTick(seconds: 60, working: ["a"]), now: Self.t0)
        // Simulate a quit & relaunch days later: a tick alone mints
        // nothing, shrinks nothing (the fish isn't even neglected past
        // one starve period? it IS — but only one stage, and never dies).
        let later = Self.t0 + 7 * 24 * 3600
        game.apply(.tick, now: later)
        #expect(game.pearls == 0)
        #expect(game.lifetimePearls == 0)
    }

    @Test("prune drops the oldest non-live pets over the cap")
    func prune() {
        var game = AquariumGame()
        for i in 0..<(AquariumRules.maxPets + 4) {
            game.pets["old-\(i)"] = FishCare(createdAt: Double(i))
        }
        game.pets["live"] = FishCare(createdAt: 0)
        game.apply(.prune(liveIDs: ["live"]), now: Self.t0)
        #expect(game.pets.count == AquariumRules.maxPets)
        #expect(game.pets["live"] != nil)
        // The oldest went first.
        #expect(game.pets["old-0"] == nil)
    }
}

// MARK: Residents — sessions stay fish

extension AquariumGameTests {
    @Test("identify names a record that exists and never mints one for a passer-by")
    func identify() {
        var game = AquariumGame()
        _ = game.apply(.identify(id: "ghost", label: "run ghost", provider: "claude"), now: Self.t0)
        #expect(game.pets["ghost"] == nil, "a session that only swam through earns no record")
        _ = game.apply(.workTick(seconds: 10, working: ["a"]), now: Self.t0)
        _ = game.apply(.identify(id: "a", label: "run a", provider: "codex"), now: Self.t0)
        #expect(game.pets["a"]?.label == "run a")
        #expect(game.pets["a"]?.provider == "codex")
    }

    @Test("residents are the raised, named fish not on the live roster — best-raised first, capped")
    func residents() {
        var game = AquariumGame()
        // Raise several fish to different stages by hand.
        for (id, stage) in [("a", 3), ("b", 1), ("c", 0), ("d", 2), ("e", 2), ("f", 1), ("g", 1), ("h", 1)] {
            game.pets[id] = FishCare(stage: stage, lastNourishedAt: Double(stage), createdAt: 1,
                                     label: "run \(id)", provider: "claude")
        }
        // Nameless records (from before the field) never surface.
        game.pets["nameless"] = FishCare(stage: 3, createdAt: 1)
        let residents = game.residents(excluding: ["b"])
        #expect(!residents.map(\.id).contains("c"), "stage 0 is a fish that was never raised")
        #expect(!residents.map(\.id).contains("b"), "a live session's fish is the session's, not a resident")
        #expect(!residents.map(\.id).contains("nameless"))
        #expect(residents.first?.id == "a", "the best-raised fish leads")
        #expect(residents.count == AquariumRules.maxResidents)
        #expect(residents.map(\.stage) == residents.map(\.stage).sorted(by: >))
    }

    @Test("a care record from before the field decodes nameless, and names round-trip")
    func residentCodable() throws {
        // Every field a pre-resident save wrote, none of the new ones.
        let old = try JSONDecoder().decode(FishCare.self, from: Data(
            #"{"stage": 2, "feedings": 1, "workSeconds": 30, "lastNourishedAt": 5, "starvingAt": 9, "lastDropAt": 5, "completionGranted": false, "createdAt": 1}"#.utf8))
        #expect(old.stage == 2)
        #expect(old.label == nil)
        let named = FishCare(stage: 1, label: "run x", provider: "grok")
        let back = try JSONDecoder().decode(FishCare.self, from: JSONEncoder().encode(named))
        #expect(back == named)
    }
}

// MARK: Keeping what a newer build bought

extension AquariumGameTests {
    @Test("an item this build doesn't know survives a decode/encode round trip")
    func unknownInventoryPassthrough() throws {
        let json = #"{"pearls": 7, "inventory": {"snail": 1, "themeFromTheFuture": 1, "zero": 0}}"#
        let game = try JSONDecoder().decode(AquariumGame.self, from: Data(json.utf8))
        #expect(game.owns(.snail))
        #expect(game.inventory["themeFromTheFuture"] == nil, "only known items count as owned")
        #expect(game.unknownInventory == ["themeFromTheFuture": 1])
        let back = try JSONDecoder().decode([String: AnyCodableInventory].self,
                                            from: JSONEncoder().encode(game))
        #expect(back["inventory"]?.items == ["snail": 1, "themeFromTheFuture": 1])
        // And the document itself round-trips unchanged.
        let again = try JSONDecoder().decode(AquariumGame.self, from: JSONEncoder().encode(game))
        #expect(again == game)
    }
}

/// Reads just the `inventory` object out of an encoded game.
private struct AnyCodableInventory: Decodable {
    var items: [String: Int]?

    init(from decoder: any Decoder) throws {
        items = try? decoder.singleValueContainer().decode([String: Int].self)
    }
}

// MARK: Going back to classic

extension AquariumGameTests {
    @Test("useClassic returns each surface to classic without owning anything")
    func useClassic() {
        var game = AquariumGame(themeID: "midnight", substrateID: "black", backdropID: "rocky")
        game.apply(.useClassic(.water), now: Self.t0)
        #expect(game.themeID == "classic")
        #expect(game.substrateID == "black", "one surface at a time")
        game.apply(.useClassic(.floor), now: Self.t0)
        #expect(game.substrateID == "classic")
        game.apply(.useClassic(.wall), now: Self.t0)
        #expect(game.backdropID == "classic")
        // Already classic stays classic, and nothing is spent.
        let effects = game.apply(.useClassic(.water), now: Self.t0)
        #expect(game.themeID == "classic")
        #expect(!effects.contains { if case .purchaseDenied = $0 { return true }; return false })
    }
}

// MARK: The snail fetches

extension AquariumGameTests {
    private static func snailTank(windowOpen: Bool) -> AquariumGame {
        var game = AquariumGame()
        game.inventory[ShopItem.snail.rawValue] = 1
        game.windowOpen = windowOpen
        game.drops = [PearlDrop(id: "d1", fishID: "a", at: Self.t0.timeIntervalSince1970,
                                value: AquariumRules.dropPearlValue)]
        return game
    }

    @Test("snailCollected pays once; a second send for the same drop is a no-op")
    func snailCollectedPaysOnce() {
        var game = Self.snailTank(windowOpen: true)
        game.apply(.snailCollected(dropID: "d1"), now: Self.t0 + 3)
        #expect(game.drops.isEmpty)
        #expect(game.totals.dropsCollected == 1)
        let paid = game.pearls
        game.apply(.snailCollected(dropID: "d1"), now: Self.t0 + 4)
        #expect(game.pearls == paid)
        #expect(game.totals.dropsCollected == 1)
    }

    @Test("a tank without a snail can't be paid by one")
    func snailCollectedNeedsASnail() {
        var game = Self.snailTank(windowOpen: true)
        game.inventory = [:]
        game.apply(.snailCollected(dropID: "d1"), now: Self.t0 + 3)
        #expect(game.drops.count == 1)
    }

    @Test("with the window open the tick leaves a 10 s drop, and the 120 s backstop collects it")
    func snailBackstop() {
        var game = Self.snailTank(windowOpen: true)
        game.apply(.tick, now: Self.t0 + AquariumRules.snailCollectAfter + 1)
        #expect(game.drops.count == 1, "the snail is on its way; the tick waits for it")
        game.apply(.tick, now: Self.t0 + AquariumRules.snailBackstop - 1)
        #expect(game.drops.count == 1)
        game.apply(.tick, now: Self.t0 + AquariumRules.snailBackstop + 1)
        #expect(game.drops.isEmpty, "a drop the snail never reached still pays")
        #expect(game.totals.dropsCollected == 1)
    }

    @Test("with the window closed the tick still collects after 10 s")
    func snailClosedTick() {
        var game = Self.snailTank(windowOpen: false)
        game.apply(.tick, now: Self.t0 + AquariumRules.snailCollectAfter + 1)
        #expect(game.drops.isEmpty)
        #expect(game.away.dropsCollected == 1)
    }
}
