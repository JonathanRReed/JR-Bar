import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// A broken source's past reset, everywhere a reset is said: the Usage
/// Center's card caption, ring and combined row, the palette's usage
/// row, the notch card's meter and the Screen Bar's meter ear all name
/// the fix the panel leads with, where "waiting for a new reading"
/// would promise a reading that never comes.
@Suite("Stale reset words")
@MainActor
struct StaleResetWordsTests {
    private let now = BrokenUsageSources.now

    // MARK: The helper

    @Test("past its reset a broken source names its fix; a reset still ahead is still counted down")
    func helperNamesTheFix() {
        let past = now.timeIntervalSince1970 - 5 * 60
        #expect(PanelStore.countdown(to: past, now: now, fix: "Reconnect Claude") == "Reconnect Claude")
        #expect(PanelStore.countdown(to: now.timeIntervalSince1970 + 0.5, now: now, fix: "Run grok login")
                == "Run grok login", "under a second to go is past, as countdown counts it")
        #expect(PanelStore.countdown(to: now.timeIntervalSince1970 + 90 * 60, now: now, fix: "Reconnect Claude")
                == "resets in 1h 30m")
        #expect(PanelStore.countdown(to: nil, now: now, fix: "Reconnect Claude") == nil,
                "no reset to stand in for")
    }

    @Test("without a fix the helper says exactly what countdown says")
    func helperKeepsTodaysWords() {
        let offsets: [Double] = [-86_400, -5, 0, 0.5, 1, 59, 5_400, 259_200]
        for offset in offsets {
            let epoch = now.timeIntervalSince1970 + offset
            let plain = PanelStore.countdown(to: epoch, now: now)
            #expect(PanelStore.countdown(to: epoch, now: now, fix: nil) == plain, "offset \(offset)")
            #expect(PanelStore.countdown(to: epoch, now: now, fix: "") == plain, "offset \(offset)")
        }
        #expect(PanelStore.countdown(to: now.timeIntervalSince1970 - 5, now: now, fix: nil)
                == "reset — waiting for a new reading")
    }

    @Test("a source is broken when it is stale, by state or fidelity, and has a fix to name")
    func staleFixRule() {
        #expect(BrokenUsageSources.claude.staleFix == "Reconnect Claude")
        #expect(BrokenUsageSources.grok.staleFix == "Run grok login")
        let byFidelity = BrokenUsageSources.provider("claude", 19, state: "ready", fidelity: "stale",
                                                     action: " Reconnect Claude ")
        #expect(byFidelity.staleFix == "Reconnect Claude", "stale by fidelity, the fix trimmed")
        #expect(BrokenUsageSources.provider("claude", 19, state: "STALE", action: "Reconnect Claude").staleFix
                == "Reconnect Claude")
        #expect(BrokenUsageSources.staleWithoutFix.staleFix == nil)
        #expect(BrokenUsageSources.provider("claude", 19, state: "stale", action: "  ").staleFix == nil)
        #expect(BrokenUsageSources.healthyPast.staleFix == nil, "a fix-it on a ready source is not a broken one")
    }

    // MARK: The surfaces

    @Test("the Usage Center's caption, ring and combined row name a broken source's fix")
    func usageCenterWords() throws {
        for (usage, words) in BrokenUsageSources.resetWords {
            let window = try #require(usage.windows.first)
            #expect(UsageCenterStore.resetText(window, of: usage, now: now) == words, "\(usage.id)")
            #expect(UsageCenterStore.headlineResetLine(window, of: usage, now: now) == "5-hour window · \(words)",
                    "\(usage.id)")
            let leading = UsageCenterStore.primaryWindow(of: usage)
            #expect(UsageCenterStore.resetText(leading, of: usage, now: now) == words, "\(usage.id)")
        }
        // A broken source's weekly reset is still ahead, and still true.
        var both = BrokenUsageSources.claude
        let weekly = CoreUsageWindow(key: "7d", name: "7d", usedPct: 12,
                                     resetsAt: now.timeIntervalSince1970 + 3 * 86_400)
        both.windows.append(weekly)
        #expect(UsageCenterStore.resetText(weekly, of: both, now: now) == "resets in 3d 0h")
        #expect(UsageCenterStore.headlineResetLine(weekly, of: both, now: now) == "7-day window · resets in 3d 0h")
        // No window, no reset: the row leaves it blank and the caption says so.
        #expect(UsageCenterStore.resetText(nil, of: both, now: now) == nil)
        let unclocked = CoreUsageWindow(key: "credits", name: "Credits", usedPct: 31)
        var credits = BrokenUsageSources.grok
        credits.windows = [unclocked]
        #expect(UsageCenterStore.headlineResetLine(unclocked, of: credits, now: now) == "Credits window · no reset time")
    }

    @Test("the palette's usage row names a broken source's fix after the window")
    func paletteWords() {
        let usage = BrokenUsageSources.resetWords.map(\.usage)
        let rows = UsagePaletteRows.items(usage: usage, now: now) { _ in }
        let expected: [String] = BrokenUsageSources.resetWords.map { "5h · \($0.words)" }
        #expect(rows.map { $0.subtitle ?? "" } == expected)
        var work = BrokenUsageSources.claude
        work.instance = "work"
        let workRow = UsagePaletteRows.items(usage: [work], now: now) { _ in }.first
        #expect(workRow?.subtitle == "5h · Reconnect Claude · work")
    }

    @Test("the notch card's meter carries the fix, and the Screen Bar's meter ear says it")
    func meterWords() throws {
        for (usage, words) in BrokenUsageSources.resetWords {
            let meter = try #require(NotchIsland.meters(CoreUsage(providers: [usage])).first)
            #expect(meter.fix == usage.staleFix, "\(usage.id)")
            #expect(PanelStore.countdown(to: meter.resetsAt, now: now, fix: meter.fix) == words, "\(usage.id)")
            #expect(PanelStore.meterWingText(meter, now: now) == "\(meter.percentText) · \(words)", "\(usage.id)")
        }
        var outage = BrokenUsageSources.claude
        outage.incident = "Elevated errors"
        let ear = try #require(NotchIsland.meters(CoreUsage(providers: [outage])).first)
        #expect(ear.fix == "Reconnect Claude")
        #expect(PanelStore.meterWingText(ear, now: now) == "19% · Reconnect Claude · incident")
    }
}
