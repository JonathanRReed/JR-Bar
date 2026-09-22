import Foundation
import Testing
@testable import JRBarCore

/// `PaletteUsage` is the ⌘⇧K palette's frecency: a decayed run count
/// per row id. It decides the Suggestions list and breaks ranking ties,
/// so the decay, the cap and the tolerant read are pinned here.
@Suite("Palette usage (frecency)")
struct PaletteUsageTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a run scores one, and the score halves every half-life")
    func decay() {
        var usage = PaletteUsage()
        usage.record("quiet.1h", at: t0)
        #expect(usage.score(for: "quiet.1h", at: t0) == 1)
        let later = t0.addingTimeInterval(PaletteUsage.halfLife)
        #expect(abs(usage.score(for: "quiet.1h", at: later) - 0.5) < 1e-9)
        #expect(usage.score(for: "never", at: later) == 0)
        #expect(usage.entries["quiet.1h"]?.count == 1)
    }

    @Test("a second run adds to the decayed score, not the raw one")
    func accumulate() {
        var usage = PaletteUsage()
        usage.record("a", at: t0)
        usage.record("a", at: t0.addingTimeInterval(PaletteUsage.halfLife))
        let now = t0.addingTimeInterval(PaletteUsage.halfLife)
        #expect(abs(usage.score(for: "a", at: now) - 1.5) < 1e-9)
        #expect(usage.entries["a"]?.count == 2)
    }

    @Test("daily use outranks a burst from weeks ago")
    func recencyBeatsOldFrequency() {
        var usage = PaletteUsage()
        for i in 0..<10 { usage.record("old", at: t0.addingTimeInterval(Double(i))) }
        let now = t0.addingTimeInterval(21 * 24 * 3600)
        for day in (0..<3).reversed() {
            usage.record("daily", at: now.addingTimeInterval(-Double(day) * 24 * 3600))
        }
        #expect(usage.top(2, at: now) == ["daily", "old"])
    }

    @Test("Suggestions skip keys that have faded below the floor")
    func topFloor() {
        var usage = PaletteUsage()
        usage.record("fresh", at: t0)
        usage.record("stale", at: t0.addingTimeInterval(-30 * 24 * 3600))
        #expect(usage.top(5, at: t0) == ["fresh"])
    }

    @Test("the table keeps only the strongest keys past the cap")
    func cap() {
        var usage = PaletteUsage()
        usage.record("keeper", at: t0)
        usage.record("keeper", at: t0)
        for i in 1...(PaletteUsage.limit + 5) {
            usage.record("session.\(i)", at: t0.addingTimeInterval(Double(i) * 60))
        }
        #expect(usage.entries.count == PaletteUsage.limit)
        #expect(usage.entries["keeper"] != nil, "the twice-used key outlives single runs")
        #expect(usage.entries["session.1"] == nil, "the oldest single run goes first")
        #expect(usage.entries["session.\(PaletteUsage.limit + 5)"] != nil)
    }

    @Test("an empty key is never recorded")
    func emptyKey() {
        var usage = PaletteUsage()
        usage.record("", at: t0)
        #expect(usage.entries.isEmpty)
    }

    @Test("usage rides UtilitiesState: round-trips, and a missing or mistyped block reads empty")
    func persisted() throws {
        var state = UtilitiesState()
        state.commandUses.record("menubar.app.com.example", at: t0)
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(UtilitiesState.self, from: data)
        #expect(back == state)
        #expect(back.commandUses.score(for: "menubar.app.com.example", at: t0) == 1)
        let older = try JSONDecoder().decode(UtilitiesState.self, from: Data(#"{"enabled": true}"#.utf8))
        #expect(older.commandUses == PaletteUsage())
        let mistyped = try JSONDecoder().decode(
            UtilitiesState.self, from: Data(#"{"commandUses": {"entries": "lots"}}"#.utf8))
        #expect(mistyped.commandUses == PaletteUsage())
    }
}
