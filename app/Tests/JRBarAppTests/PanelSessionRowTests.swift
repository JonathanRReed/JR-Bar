import Foundation
import Testing
import JRBarCore
import JRBarUI
@testable import JRBarApp

/// What a panel row says under its title, and how its clock reads.
@Suite("Panel session rows")
@MainActor
struct PanelSessionRowTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func row(_ id: String = "claude:r", label: String? = "Sample task", cwd: String? = "/tmp/sample/project",
                    mode: String = "working", minutesAgo: Double = 2, event: String? = nil, tool: String? = nil,
                    stale: Bool = false, snoozedUntil: Double? = nil) -> SessionRow {
        var session = CoreSession(id: id, provider: "claude", label: label, cwd: cwd, mode: mode,
                                  since: now.timeIntervalSince1970 - minutesAgo * 60, event: event, tool: tool)
        session.stale = stale
        session.snoozedUntil = snoozedUntil
        return SessionRow(session: session, pinnedAsk: nil)
    }

    @Test("a working row is quiet after ten minutes, unless a tool is still running")
    func quietAfterTenMinutesWithNoToolOpen() {
        #expect(!Self.row(minutesAgo: 9, event: "PostToolUse").isQuiet(now: Self.now))
        #expect(Self.row(minutesAgo: 10, event: "PostToolUse").quietText(now: Self.now) == "Quiet 10m")
        #expect(Self.row(minutesAgo: 12, event: "PostToolUse").help(now: Self.now)?.contains("with no tool running") == true)
        // A long build says nothing for an hour and is not a stuck agent.
        let building = Self.row(mode: "tool_running", minutesAgo: 60, event: "PreToolUse")
        #expect(building.openToolCall)
        #expect(!building.isQuiet(now: Self.now))
        #expect(building.elapsedText(now: Self.now)?.hasPrefix("Quiet") == false)
        // The finishing event hands the row back to the clock.
        #expect(Self.row(minutesAgo: 60, event: "PostToolUse").isQuiet(now: Self.now))
    }

    @Test("ages step once a minute: seconds only under a minute")
    func agesAreWholeMinutes() {
        let start = Self.now
        #expect(PanelStore.elapsed(since: start.addingTimeInterval(-45), now: start) == "45s")
        #expect(PanelStore.elapsed(since: start.addingTimeInterval(-700), now: start) == "11m")
        #expect(PanelStore.elapsed(since: start.addingTimeInterval(-3_659), now: start) == "1h")
        #expect(PanelStore.elapsed(since: start.addingTimeInterval(-3_960), now: start) == "1h 06m")
    }

    @Test("a stale, snoozed, feed-quiet or ended row says so instead of looking idle")
    func warningsComeFirst() throws {
        let stale = try #require(Self.row(mode: "idle", stale: true).caption(now: Self.now))
        #expect(stale.warning && stale.text.hasPrefix("Stale"))
        let until = Self.now.timeIntervalSince1970 + 3_600
        let snoozed = try #require(Self.row(mode: "waiting", snoozedUntil: until).caption(now: Self.now))
        #expect(snoozed.warning && snoozed.text.hasPrefix("Snoozed until "))
        let quiet = try #require(Self.row(tool: "Bash").caption(now: Self.now, feedQuiet: "feed quiet 15m"))
        #expect(quiet == .init(text: "Feed quiet 15m", warning: true))
        let ended = try #require(Self.row(mode: "ended").caption(now: Self.now))
        #expect(ended.warning)
        #expect(Self.row(mode: "idle", stale: true).dotLabel == "Stale")
        #expect(Self.row(mode: "idle").dotLabel == "Idle")
        #expect(Self.row(mode: "ended").dotLabel == "Ended")
    }

    @Test("otherwise the line says what the agent is doing, else its folder")
    func activityThenFolder() {
        let busy = Self.row(event: "PreToolUse", tool: "Bash").caption(now: Self.now)
        #expect(busy == .init(text: "Running Bash", warning: false))
        let done = Self.row(mode: "done")
        #expect(done.cwdTail != nil)
        #expect(done.caption(now: Self.now)?.text == done.cwdTail)
    }

    @Test("a generated title that already names the folder does not repeat it")
    func noRepeatedFolder() {
        let generated = Self.row(label: nil, mode: "done")
        #expect(generated.label.hasSuffix(generated.cwdTail ?? "<none>"), "\(generated.label)")
        #expect(generated.distinctFolder == nil)
        #expect(generated.caption(now: Self.now) == nil)
    }

    @Test("the context bar shows only past seven tenths of a live run's window")
    func contextBarFloor() {
        var row = Self.row()
        row.usage = SessionUsage(model: "claude-sonnet", contextTokens: 50_000, contextWindow: 200_000)
        #expect(row.contextBarFraction == nil)
        row.usage = SessionUsage(model: "claude-sonnet", contextTokens: 160_000, contextWindow: 200_000)
        #expect(row.contextBarFraction == 0.8)
    }
}
