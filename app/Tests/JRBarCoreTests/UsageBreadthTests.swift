import Foundation
import Testing
@testable import JRBarCore

/// The Usage Center's breadth: where a window lands at reset, a verdict in
/// a word, pace that knows what is running, room for one more, who is
/// burning the window, and the per-model split.
@Suite("Usage breadth")
struct UsageBreadthTests {
    static let now: Double = 1_788_982_892
    static let utc = TimeZone(identifier: "UTC")!

    static func burning(used: Double = 40, rate: Double = 20, resetIn hours: Double = 2) -> UsageForecast {
        let exhaustsAt = now + (100 - used) / rate * 3600
        let resetsAt = now + hours * 3600
        return UsageForecast(window: "5h", usedPct: used, resetsAt: resetsAt,
                             verdict: exhaustsAt < resetsAt ? .runsOut(exhaustsAt: exhaustsAt) : .comfortable,
                             ratePctPerHour: rate, source: .daemon, pace: "ahead")
    }

    @Test("the ghost arc: used plus the rate until the reset, past 100 when it runs out first")
    func projection() {
        #expect(Self.burning(used: 40, rate: 20, resetIn: 2).projectedAtReset(now: Self.now) == 80)
        #expect(Self.burning(used: 40, rate: 40, resetIn: 2).projectedAtReset(now: Self.now) == 120)
        var exhausted = Self.burning(used: 100)
        exhausted.verdict = .exhausted
        #expect(exhausted.projectedAtReset(now: Self.now) == 100)
        let idle = UsageForecast(window: "5h", usedPct: 40, resetsAt: Self.now + 3600, verdict: .comfortable,
                                 ratePctPerHour: 0, source: .local)
        #expect(idle.projectedAtReset(now: Self.now) == nil)
    }

    @Test("verdicts read in a word")
    func verdictWords() {
        #expect(Self.burning(used: 40, rate: 40).verdictWord(timeZone: Self.utc).hasPrefix("Runs out "))
        #expect(Self.burning(used: 40, rate: 20).verdictWord() == "Resets first")
        var guarded = Self.burning()
        guarded.verdict = .guarded(reason: "stale_samples")
        #expect(guarded.verdictWord() == "Paused")
    }

    @Test("with nothing working here, a run-out holds instead — and says why")
    func idleHold() {
        let runsOut = Self.burning(used: 40, rate: 40)
        let held = SessionAwarePace.adjust(runsOut, working: 0)
        #expect(held.verdict == .comfortable)
        #expect(held.heldIdle)
        #expect(!held.isCritical)
        #expect(held.verdictWord() == "Holding")
        #expect(held.headline(now: Date(timeIntervalSince1970: Self.now)) == "Holding at 60 % left: no agent is working on it here")
        #expect(held.projectedAtReset(now: Self.now) == 40)

        let working = SessionAwarePace.adjust(runsOut, working: 2)
        #expect(!working.heldIdle)
        #expect(working.isCritical)
        #expect(working.workingAgents == 2)
    }

    @Test("room for one more: what each working agent burns, times one more, against the reset")
    func room() {
        // 40 % used, 20 %/h across two agents → 10 %/h each; three would
        // burn 30 %/h and need 2 h for the 60 % left: exactly the reset.
        let two = SessionAwarePace.adjust(Self.burning(used: 40, rate: 20, resetIn: 2), working: 2)
        #expect(SessionAwarePace.roomForOneMore(two, now: Self.now) == true)
        let tight = SessionAwarePace.adjust(Self.burning(used: 40, rate: 20, resetIn: 3), working: 2)
        #expect(SessionAwarePace.roomForOneMore(tight, now: Self.now) == false)
        #expect(SessionAwarePace.roomText(tight, now: Self.now) == "one more agent would run it out before the reset")
        let nobody = SessionAwarePace.adjust(Self.burning(), working: 0)
        #expect(SessionAwarePace.roomForOneMore(nobody, now: Self.now) == nil)
        #expect(SessionAwarePace.roomForOneMore(Self.burning(), now: Self.now) == nil)
    }

    @Test("burners rank by tokens, drop the idle, and share what this Mac spent")
    func burners() {
        let ranked = WindowBurner.rank([
            (id: "a", label: "JR-Bar refactor", tokens: 600),
            (id: "b", label: "docs", tokens: 300),
            (id: "c", label: "idle", tokens: 0),
            (id: "d", label: "tests", tokens: 100),
        ], limit: 2)
        #expect(ranked.map(\.id) == ["a", "b"])
        #expect(ranked[0].share == 0.6)
        #expect(WindowBurner.rank([(id: "x", label: "x", tokens: 0)]).isEmpty)
    }

    @Test("the per-model split decodes and names models the way a person says them")
    func models() throws {
        let json = """
        {"provider":"claude","range":"7d","days":[],"hours":[],
         "models":[{"model":"opus-4-5","tokens":900,"cost_usd":1.5,"records":3,"priced":true,"estimated":false},
                   {"model":"mystery","tokens":100,"cost_usd":0.01,"records":1,"priced":true,"estimated":true}]}
        """
        let history = try JSONDecoder().decode(UsageHistory.self, from: Data(json.utf8))
        #expect(history.models.map(\.displayName) == ["Opus 4.5", "mystery"])
        #expect(history.models[1].estimated)
        let older = try JSONDecoder().decode(UsageHistory.self, from: Data(#"{"provider":"codex","range":"7d"}"#.utf8))
        #expect(older.models.isEmpty)
    }

    @Test("the punch card puts each real hour in its weekday row and hour column")
    func punchCard() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        calendar.firstWeekday = 2   // Monday first
        calendar.locale = Locale(identifier: "en_US_POSIX")
        // 2026-09-21 is a Monday.
        let monday9 = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 9)))
        let sunday23 = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 23)))
        let card = UsagePunchCard.build(hours: [
            UsageHistoryHour(hour: "a", at: monday9.timeIntervalSince1970, tokensIn: 300),
            UsageHistoryHour(hour: "b", at: sunday23.timeIntervalSince1970, tokensIn: 100, cacheRead: 50),
        ], calendar: calendar)
        #expect(card.weekdayLabels.first == "Mon")
        #expect(card.weekdayLabels.last == "Sun")
        #expect(card.cells[0][9] == 300)
        #expect(card.cells[6][23] == 150)
        #expect(card.peak == 300)
        #expect(card.intensity(6, 23) == 0.5)
        #expect(UsagePunchCard.cell(of: monday9, calendar: calendar) == .init(weekday: 0, hour: 9))
    }

    @Test("a window's outline covers every hour it touched, the one it is in now included")
    func punchCardWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        calendar.firstWeekday = 2
        let monday = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 10, minute: 30)))
        let start = monday.timeIntervalSince1970
        // Opened 10:30, now 12:10: hours 10, 11 and 12 — stepping by an
        // hour from 10:30 alone would stop at 11.
        let cells = UsagePunchCard.cells(from: start, to: start + 100 * 60, calendar: calendar)
        #expect(cells == [.init(weekday: 0, hour: 10), .init(weekday: 0, hour: 11), .init(weekday: 0, hour: 12)])
        #expect(UsagePunchCard.cells(from: start, to: start - 1, calendar: calendar).isEmpty)
    }

    @Test("History's text passes a row its archived transcript matched, by session uuid")
    func historyTranscriptHits() {
        let uuid = "8870963f-850a-4bd2-9a4f-0c1a2b3c4d5e"
        let row = CoreHistoryRow(at: 1, kind: "completed", provider: "claude", session: "claude:session:\(uuid)", label: "Refactor")
        let filter = HistoryFilter(text: "middleware")
        #expect(!filter.matchesOwnWords(row))
        #expect(!filter.matches(row))
        #expect(filter.matches(row, transcriptHits: [uuid]))
        #expect(filter.apply([row], transcriptHits: [uuid]) == [row])
        // A hit never overrides the other chips.
        var kinds = filter
        kinds.kinds = ["failed"]
        #expect(!kinds.matches(row, transcriptHits: [uuid]))
        #expect(HistoryFilter().matchesOwnWords(row))
    }

    @Test("History's day filter keeps one calendar day, and parses the heatmap's key")
    func historyDay() throws {
        let day = try #require(HistoryDayParse.date("2026-09-16"))
        let filter = HistoryFilter(day: day)
        #expect(!filter.isEmpty)
        #expect(filter.matches(CoreHistoryRow(at: day.timeIntervalSince1970 + 3600, kind: "completed")))
        #expect(!filter.matches(CoreHistoryRow(at: day.timeIntervalSince1970 - 3600, kind: "completed")))
        #expect(HistoryDayParse.date("16 Sep") == nil)
    }

    @Test("the daily report lists the days that carried anything, newest first")
    func daily() {
        let history = UsageHistory(provider: "claude", range: "7d", days: [
            UsageHistoryDay(date: "2026-09-20", tokensIn: 5),
            UsageHistoryDay(date: "2026-09-21"),
            UsageHistoryDay(date: "2026-09-22", tokensOut: 7, costUsd: 0.1),
        ])
        #expect(history.activeDaysNewestFirst.map(\.date) == ["2026-09-22", "2026-09-20"])
    }
}
