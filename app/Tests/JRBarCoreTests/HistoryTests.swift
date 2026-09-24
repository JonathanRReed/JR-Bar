import Foundation
import Testing
@testable import JRBarCore

@Suite("Activity history")
struct HistoryTests {
    static let now = Date(timeIntervalSince1970: 1_788_982_900)
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    static func row(_ offset: Double, _ kind: String, _ provider: String, label: String, detail: String? = nil, duration: Double? = nil, unseen: Bool = false) -> CoreHistoryRow {
        CoreHistoryRow(at: now.timeIntervalSince1970 - offset, kind: kind, provider: provider, session: "\(provider):\(label)", label: label, detail: detail, duration: duration, unseen: unseen)
    }

    static let rows: [CoreHistoryRow] = [
        row(60, "completed", "gemini", label: "docs-sweep", detail: "Swept 14 documents", duration: 610, unseen: true),
        row(600, "asked", "claude", label: "jr-bar-b7", detail: "Run: swift test", unseen: true),
        row(2700, "completed", "codex", label: "sidepulse-core", detail: "Wrote the hook installer", duration: 4500, unseen: true),
        row(7200, "started", "codex", label: "sidepulse-core", detail: "Terminal"),
        row(86400 + 2200, "failed", "codex", label: "sidepulse-core", detail: "pytest: 3 failed", duration: 420),
        row(86400 + 5370, "completed", "claude", label: "jr-bar-b7", detail: "Ported the LEDS sampler", duration: 1830, unseen: true),
        row(3 * 86400, "ended", "gemini", label: "docs-sweep"),
    ]

    @Test("filters compose: providers, kinds and text")
    func filtering() {
        #expect(HistoryFilter().apply(Self.rows).count == 7)
        #expect(HistoryFilter(providers: ["codex"]).apply(Self.rows).map(\.kind) == ["completed", "started", "failed"])
        #expect(HistoryFilter(kinds: ["completed"]).apply(Self.rows).map(\.provider) == ["gemini", "codex", "claude"])
        #expect(HistoryFilter(providers: ["codex"], kinds: ["completed", "failed"]).apply(Self.rows).count == 2)
        #expect(HistoryFilter(text: "SWIFT").apply(Self.rows).map(\.label) == ["jr-bar-b7"])
        #expect(HistoryFilter(text: "needed you").apply(Self.rows).map(\.kind) == ["asked"], "the kind word is searchable too")
        #expect(HistoryFilter(text: "  ").apply(Self.rows).count == 7)
        #expect(HistoryFilter(providers: ["pi"]).apply(Self.rows).isEmpty)
        #expect(HistoryFilter().isEmpty)
        #expect(!HistoryFilter(kinds: ["asked"]).isEmpty)
    }

    @Test("rows group by day, newest first, with Today and Yesterday titles")
    func grouping() {
        let days = HistoryGrouping.days(Self.rows, now: Self.now, calendar: Self.calendar)
        #expect(days.map(\.title).prefix(2) == ["Today", "Yesterday"])
        #expect(days.count == 3)
        #expect(days[0].rows.map(\.kind) == ["completed", "asked", "completed"], "newest first inside a day")
        #expect(days[0].folded[days[0].rows[2].id]?.map(\.kind) == ["started"],
                "sidepulse-core's start folds under the completion that followed it")
        #expect(days[1].rows.count == 2)
        #expect(days[2].rows.count == 1)
        #expect(days[2].title.contains(" "), "older days carry a weekday and date")
        #expect(HistoryGrouping.days([], now: Self.now).isEmpty)
    }

    @Test("the away summary counts only the unseen run at the newest end")
    func away() throws {
        let summary = try #require(AwaySummary.make(from: Self.rows))
        #expect(summary.rows.count == 3, "the unseen row from yesterday is behind a seen one and does not count")
        #expect(summary.counts == ["completed": 2, "asked": 1])
        #expect(summary.text == "While you were away: 2 finished, 1 needed you")
        #expect(summary.since == Self.rows[2].date)
        var seen = Self.rows
        seen[0].unseen = false
        #expect(AwaySummary.make(from: seen) == nil)
        #expect(AwaySummary.make(from: []) == nil)
    }

    /// Two sessions ending turn after turn, one failing between, and a
    /// sessionless quota crossing.
    static let turns: [CoreHistoryRow] = [
        row(10, "completed", "codex", label: "inkling", unseen: true),
        row(20, "completed", "codex", label: "inkling", unseen: true),
        row(30, "asked", "codex", label: "inkling", unseen: true),
        row(40, "completed", "claude", label: "scaling", unseen: true),
        row(50, "failed", "claude", label: "scaling", unseen: true),
        row(60, "completed", "claude", label: "scaling", unseen: true),
        row(70, "completed", "claude", label: "scaling", unseen: true),
        CoreHistoryRow(at: now.timeIntervalSince1970 - 80, kind: "quota_crossed", provider: "codex", detail: "90 %",
                       unseen: true),
        row(90, "completed", "codex", label: "inkling", unseen: true),
    ]

    @Test("consecutive rows of one session fold under the newest; a failure stands alone")
    func folding() {
        let run = HistoryGrouping.fold(Self.turns)
        #expect(run.rows.map { "\($0.label ?? $0.kind):\($0.kind)" } == [
            "inkling:completed", "scaling:completed", "scaling:failed", "scaling:completed",
            "quota_crossed:quota_crossed", "inkling:completed",
        ])
        #expect(run.folded[run.rows[0].id]?.map(\.kind) == ["completed", "asked"])
        #expect(run.folded[run.rows[1].id] == nil, "the failure does not fold into the turn after it")
        #expect(run.folded[run.rows[2].id] == nil)
        #expect(run.folded[run.rows[3].id]?.count == 1)
        #expect(run.folded[run.rows[5].id] == nil, "the quota crossing between them keeps inkling's rows apart")
        #expect(HistoryGrouping.foldedSummary(run.folded[run.rows[0].id] ?? []) == "Finished · Needed you")
        #expect(HistoryGrouping.foldedSummary(Array(Self.turns.prefix(2))) == "Finished ×2")
    }

    @Test("the away banner counts sessions, not the turns they ended")
    func awayCountsSessions() throws {
        let summary = try #require(AwaySummary.make(from: Self.turns))
        #expect(summary.rows.count == 9)
        #expect(summary.sessions == 3, "inkling, scaling and the quota crossing")
        #expect(summary.counts == ["completed": 2, "asked": 1, "failed": 1, "quota_crossed": 1])
        #expect(summary.text == "While you were away: 2 finished, 1 needed you, 1 failed, 1 quota crossing")
    }

    @Test("rows decode with defaults for missing fields")
    func decoding() throws {
        let data = Data(#"[{"at":1,"kind":"completed","provider":"claude","label":"x","duration":12.5},{"at":2}]"#.utf8)
        let rows = try JSONDecoder().decode([CoreHistoryRow].self, from: data)
        #expect(rows[0].duration == 12.5)
        #expect(rows[0].unseen == false)
        #expect(rows[0].kindWord == "Finished")
        #expect(rows[1].kind == "event")
        #expect(rows[1].kindWord == "Event")
        #expect(CoreHistoryRow(at: 0, kind: "asked").kindWord == "Needed you")
    }
}

@Suite("History labels")
struct HistoryLabelTests {
    @Test("the daemon's 'Provider <uuid>' labels read as the panel's session labels")
    func displayLabel() {
        let real = CoreHistoryRow(at: 1, kind: "completed", provider: "claude", session: "claude:session:8870963f-850a-424b-aec2-8351d1a4ee8a",
                                  label: "Claude 8870963f-850a-424b-aec2-8351d1a4ee8a")
        #expect(real.displayLabel == "8870963f")
        let named = CoreHistoryRow(at: 1, kind: "asked", provider: "codex", session: "codex:session:x", label: "Codex sidepulse-core")
        #expect(named.displayLabel == "sidepulse-core")
        let plain = CoreHistoryRow(at: 1, kind: "failed", provider: "gemini", session: "gemini:session:d", label: "docs-sweep")
        #expect(plain.displayLabel == "docs-sweep")
        let bare = CoreHistoryRow(at: 1, kind: "started", provider: nil, session: "pi:session:01a08b62-aaaa-bbbb-cccc-ddddeeeeffff", label: nil)
        #expect(bare.displayLabel == "01a08b62")
        let nothing = CoreHistoryRow(at: 1, kind: "ended", provider: "grok", session: nil, label: nil)
        #expect(nothing.displayLabel == "Grok")
    }
}
