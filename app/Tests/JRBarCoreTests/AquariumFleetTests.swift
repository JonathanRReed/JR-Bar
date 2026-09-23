import Foundation
import Testing
@testable import JRBarCore

/// The tank's milestones about the work itself (docs/TOYS.md): a school
/// of six, a clean week, a week under budget, banked credits. The facts
/// come from the daemon's document; the log remembers them between
/// documents; the game pays each achievement once.
@Suite("Aquarium fleet milestones")
struct AquariumFleetTests {
    private static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private static let day: TimeInterval = 86_400

    private static func session(_ id: String, parent: String? = nil, mode: String = "tool_running",
                                lifecycle: String = "active") -> CoreSession {
        CoreSession(id: id, provider: "claude", kind: parent == nil ? "main" : "worker",
                    parent: parent, mode: mode, lifecycle: lifecycle)
    }

    private static func weekly(_ used: Double?, resets: Double, provider: String = "claude") -> CoreProviderUsage {
        CoreProviderUsage(id: provider, windows: [
            CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 99, resetsAt: resets - 3600),
            CoreUsageWindow(key: "weekly", name: "7d", usedPct: used, resetsAt: resets),
        ])
    }

    private static func state(sessions: [CoreSession] = [], providers: [CoreProviderUsage] = []) -> CoreState {
        CoreState(generation: 1, sessions: sessions, usage: CoreUsage(providers: providers))
    }

    // MARK: Facts

    @Test("the widest live school, the failed runs, the weekly windows and Codex's credits")
    func readsFacts() {
        var sessions = [Self.session("a"), Self.session("b")]
        sessions += (0..<4).map { Self.session("a\($0)", parent: "a") }
        sessions += (0..<2).map { Self.session("b\($0)", parent: "b") }
        sessions.append(Self.session("a-done", parent: "a", lifecycle: "completed"))
        sessions.append(Self.session("x", lifecycle: "failed"))
        sessions.append(Self.session("b-err", parent: "b", mode: "error"))
        let facts = AquariumFleetFacts.read(Self.state(sessions: sessions, providers: [
            Self.weekly(42, resets: 2_000_000),
            CoreProviderUsage(id: "codex", creditsRemaining: 12),
            CoreProviderUsage(id: "grok", creditsRemaining: 90),
        ]), now: Self.t0)
        #expect(facts.largestSchool == 4, "a finished or failed fry isn't swimming")
        #expect(facts.failedIDs == ["b-err", "x"])
        #expect(facts.weekly.count == 1, "the five-hour lane isn't a week")
        #expect(facts.weekly["claude|weekly"]?.usedPct == 42)
        #expect(facts.weekly["claude|weekly"]?.observedAt == Self.t0.timeIntervalSince1970)
        #expect(facts.codexCredits == ["codex": 12], "only Codex banks credits")
    }

    @Test("a weekly window with no reading, or no reset, says nothing")
    func unknownWeekly() {
        let facts = AquariumFleetFacts.read(Self.state(providers: [
            CoreProviderUsage(id: "claude", windows: [
                CoreUsageWindow(key: "weekly", name: "7d", usedPct: nil, resetsAt: 2_000_000),
                CoreUsageWindow(key: "seven_day", name: "7d", usedPct: 30, resetsAt: nil),
            ]),
        ]), now: Self.t0)
        #expect(facts.weekly.isEmpty)
    }

    // MARK: The log

    @Test("under budget: the window rolled over, the tank saw its last hours, and it ended under 80%")
    func underBudgetRule() {
        let resets = 2_000_000.0
        let last = AquariumWeeklyReading(usedPct: 64, resetsAt: resets, observedAt: resets - 3600)
        let next = AquariumWeeklyReading(usedPct: 1, resetsAt: resets + 7 * Self.day, observedAt: resets + 60)
        #expect(AquariumFleetLog.endedUnderBudget(last: last, next: next))
        var over = last
        over.usedPct = 80
        #expect(!AquariumFleetLog.endedUnderBudget(last: over, next: next), "80% is the line, not under it")
        var stale = last
        stale.observedAt = resets - 2 * Self.day
        #expect(!AquariumFleetLog.endedUnderBudget(last: stale, next: next),
                "a reading from days before says nothing about how the week ended")
        var drift = next
        drift.resetsAt = resets + 120
        #expect(!AquariumFleetLog.endedUnderBudget(last: last, next: drift), "the same week, restated")
    }

    @Test("a new failure resets the clean days; the same failure lingering doesn't")
    func failuresResetCleanDays() {
        var log = AquariumFleetLog()
        log.noteCompletion(day: 1)
        #expect(log.cleanDays == 0, "not watching yet")
        log.note(AquariumFleetFacts(), now: Self.t0)
        for day in 1...3 { log.noteCompletion(day: Double(day)) }
        log.noteCompletion(day: 3)
        #expect(log.cleanDays == 3, "one per calendar day")
        log.note(AquariumFleetFacts(failedIDs: ["x"]), now: Self.t0)
        #expect(log.cleanDays == 0)
        log.noteCompletion(day: 4)
        log.note(AquariumFleetFacts(failedIDs: ["x"]), now: Self.t0)
        #expect(log.cleanDays == 1, "x was already counted")
        log.note(AquariumFleetFacts(failedIDs: ["x", "y"]), now: Self.t0)
        #expect(log.cleanDays == 0)
    }

    @Test("banked credits: the first reading seeds, a rise counts, spending doesn't")
    func creditGains() {
        var log = AquariumFleetLog()
        log.note(AquariumFleetFacts(codexCredits: ["codex": 40]), now: Self.t0)
        #expect(log.creditGains == 0)
        log.note(AquariumFleetFacts(codexCredits: ["codex": 30]), now: Self.t0)
        #expect(log.creditGains == 0)
        log.note(AquariumFleetFacts(codexCredits: ["codex": 55]), now: Self.t0)
        #expect(log.creditGains == 1)
    }

    @Test("the log reads tolerantly and round-trips")
    func logCodable() throws {
        var log = AquariumFleetLog()
        log.note(AquariumFleetFacts(largestSchool: 3, failedIDs: ["x"],
                                    weekly: ["c|weekly": AquariumWeeklyReading(usedPct: 5, resetsAt: 9, observedAt: 1)],
                                    codexCredits: ["codex": 2]), now: Self.t0)
        let back = try JSONDecoder().decode(AquariumFleetLog.self, from: JSONEncoder().encode(log))
        #expect(back == log)
        let junk = try JSONDecoder().decode(AquariumFleetLog.self, from: Data(#"""
            {"cleanDays": -4, "largestSchool": "many", "weekly": 7, "creditGains": 2}
            """#.utf8))
        #expect(junk.cleanDays == 0 && junk.largestSchool == 0 && junk.weekly.isEmpty)
        #expect(junk.creditGains == 2)
        // A save from before the log existed still loads, with an empty one.
        let old = try JSONDecoder().decode(AquariumGame.self, from: Data(#"{"pearls": 12}"#.utf8))
        #expect(old.pearls == 12)
        #expect(old.fleet == AquariumFleetLog())
    }

    // MARK: The game

    @Test("six live sub-agents with one session: a school, paid once")
    func school() {
        var game = AquariumGame()
        var sessions = [Self.session("a")]
        sessions += (0..<5).map { Self.session("a\($0)", parent: "a") }
        let five = AquariumFleetFacts.read(Self.state(sessions: sessions), now: Self.t0)
        #expect(game.apply(.fleet(five), now: Self.t0).isEmpty)
        sessions.append(Self.session("a5", parent: "a"))
        let six = AquariumFleetFacts.read(Self.state(sessions: sessions), now: Self.t0)
        let effects = game.apply(.fleet(six), now: Self.t0)
        #expect(effects.contains(.achievementUnlocked(.school)))
        #expect(game.unlocked[AquariumAchievement.school.rawValue] != nil)
        #expect(!game.apply(.fleet(six), now: Self.t0).contains(.achievementUnlocked(.school)))
    }

    @Test("completions on seven days with no failure between them: a clean week")
    func cleanWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var game = AquariumGame()
        game.apply(.fleet(AquariumFleetFacts()), now: Self.t0, calendar: calendar)
        var unlockedOn: Int?
        for k in 0..<8 {
            let now = Self.t0.addingTimeInterval(Double(k) * Self.day)
            // Day 2 brings a failure: the count starts over after it.
            if k == 2 {
                game.apply(.fleet(AquariumFleetFacts(failedIDs: ["bad"])), now: now, calendar: calendar)
            }
            let effects = game.apply(.sessionCompleted(id: "s\(k)"), now: now, calendar: calendar)
            if effects.contains(.achievementUnlocked(.cleanWeek)) { unlockedOn = k }
        }
        #expect(game.fleet.cleanDays == 6)
        #expect(unlockedOn == nil, "six clean days since the failure, not seven")
        let now = Self.t0.addingTimeInterval(8 * Self.day)
        let effects = game.apply(.sessionCompleted(id: "s8"), now: now, calendar: calendar)
        #expect(effects.contains(.achievementUnlocked(.cleanWeek)))
    }

    @Test("a tank that never read the fleet never counts a clean day")
    func noFleetNoCleanDays() {
        var game = AquariumGame()
        for k in 0..<9 {
            game.apply(.sessionCompleted(id: "s\(k)"),
                       now: Self.t0.addingTimeInterval(Double(k) * Self.day))
        }
        #expect(game.fleet.cleanDays == 0)
        #expect(game.unlocked[AquariumAchievement.cleanWeek.rawValue] == nil)
    }

    @Test("a weekly window that ends under 80% while the tank watches: under budget")
    func underBudget() {
        var game = AquariumGame()
        let resets = Self.t0.timeIntervalSince1970 + 2 * 3600
        let late = AquariumFleetFacts.read(Self.state(providers: [Self.weekly(71, resets: resets)]),
                                           now: Self.t0)
        #expect(game.apply(.fleet(late), now: Self.t0).isEmpty)
        let after = Self.t0.addingTimeInterval(3 * 3600)
        let fresh = AquariumFleetFacts.read(
            Self.state(providers: [Self.weekly(0, resets: resets + 7 * Self.day)]), now: after)
        #expect(game.apply(.fleet(fresh), now: after).contains(.achievementUnlocked(.underBudget)))
    }

    @Test("Codex's banked credits going up: banked")
    func banked() {
        var game = AquariumGame()
        let seed = AquariumFleetFacts(codexCredits: ["codex": 10])
        #expect(game.apply(.fleet(seed), now: Self.t0).isEmpty)
        let rise = AquariumFleetFacts(codexCredits: ["codex": 25])
        let effects = game.apply(.fleet(rise), now: Self.t0)
        #expect(effects.contains(.achievementUnlocked(.bankedCredits)))
        #expect(game.lifetimePearls >= AquariumAchievement.bankedCredits.reward, "the reward paid")
    }
}
