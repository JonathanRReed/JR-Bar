import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The usage card's source honesty: no meter for a provider with no quota
/// source, detail windows kept off the rings, and a caption that names a
/// stand-in source.
@Suite("Usage source notes")
struct UsageSourceNotesTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func aProviderWithNoQuotaSourceSaysSoInWords() {
        let noKey = CoreProviderUsage(id: "opencode", state: "unsupported", reason: "opencode_no_quota_source",
                                      quotaSource: false)
        let zenOnly = CoreProviderUsage(id: "opencode", state: "unsupported", reason: "opencode_go_not_subscribed",
                                        quotaSource: false)
        let metered = CoreProviderUsage(id: "claude", state: "ready")
        #expect(UsageSourceNotes.noQuotaLine(noKey, name: "OpenCode")?.contains("no quota on this Mac") == true)
        #expect(UsageSourceNotes.noQuotaLine(zenOnly, name: "OpenCode")?.contains("no Go subscription") == true)
        #expect(UsageSourceNotes.noQuotaLine(metered, name: "Claude") == nil)
    }

    @Test func detailWindowsLeaveTheRings() {
        var monthly = CoreUsageWindow(key: "go-monthly", name: "Monthly", usedPct: 7, bindable: false)
        monthly.detail = true
        let windows = [
            CoreUsageWindow(key: "go-rolling", name: "5h", usedPct: 42, resetsAt: Self.now.timeIntervalSince1970 + 3600),
            CoreUsageWindow(key: "go-weekly", name: "7d", usedPct: 18),
            monthly,
        ]
        #expect(UsageSourceNotes.ringWindows(windows).map(\.id) == ["go-rolling", "go-weekly"])
        #expect(UsageSourceNotes.detailWindows(windows).map(\.id) == ["go-monthly"])
        let detail = UsageSourceNotes.detailText(windows[2], now: Self.now, fix: nil)
        #expect(detail == "Monthly 7% used")
    }

    /// Jonathan's own Claude reading: "7d Fable" is not bindable, but it is
    /// Fable's real weekly cap, so it stays a ring (and a column in All
    /// providers). So does a Codex Spark sub-cap.
    @Test func anUnboundModelCapKeepsItsRing() {
        let claude = [
            CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 42),
            CoreUsageWindow(key: "weekly", name: "7d", usedPct: 61),
            CoreUsageWindow(key: "fable-only", name: "7d Fable", usedPct: 30, bindable: false),
        ]
        #expect(UsageSourceNotes.ringWindows(claude).map(\.id) == ["five-hour", "weekly", "fable-only"])
        #expect(UsageSourceNotes.detailWindows(claude).isEmpty)
        let codex = [
            CoreUsageWindow(key: "weekly", name: "7d", usedPct: 30),
            CoreUsageWindow(key: "spark-weekly", name: "Spark Weekly", usedPct: 12, bindable: false),
        ]
        #expect(UsageSourceNotes.ringWindows(codex).count == 2)
    }

    @Test func aProviderWhoseWindowsAreAllDetailKeepsItsRings() {
        var pro = CoreUsageWindow(key: "model-gemini-pro", name: "gemini-pro", usedPct: 12, bindable: false)
        pro.detail = true
        var flash = CoreUsageWindow(key: "model-gemini-flash", name: "gemini-flash", usedPct: 3, bindable: false)
        flash.detail = true
        #expect(UsageSourceNotes.ringWindows([pro, flash]).count == 2)
        #expect(UsageSourceNotes.detailWindows([pro, flash]).isEmpty)
    }

    @Test func theDetailFlagDecodesAndDefaultsToARing() throws {
        let json = #"{"id":"go-monthly","name":"Monthly","used_pct":7,"bindable":false,"detail":true}"#
        #expect(try JSONDecoder().decode(CoreUsageWindow.self, from: Data(json.utf8)).detail)
        let older = #"{"id":"fable-only","name":"7d Fable","used_pct":30,"bindable":false}"#
        #expect(try JSONDecoder().decode(CoreUsageWindow.self, from: Data(older.utf8)).detail == false)
    }

    /// A CLIProxyAPI account is spent by whoever uses the proxy: this Mac's
    /// working Claude agents neither pace its card nor hold it idle.
    @Test @MainActor func aHubAccountIsNotPacedByThisMacsAgents() {
        let core = CoreModel(socketPath: "/nonexistent/jrbar-usage-notes.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(sessions: [CoreSession(id: "claude:a", provider: "claude", mode: "working")], asks: [])))
        let window = CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 42, resetsAt: Self.now.timeIntervalSince1970 + 3600)
        let local = CoreProviderUsage(id: "claude", windows: [window], state: "ready")
        let hub = CoreProviderUsage(id: "claude", windows: [window], state: "ready", instance: "cliproxy:3f2a9c1b0d4e")
        #expect(UsageCenterStore.forecast(for: local, window: window, core: core, now: Self.now).workingAgents == 1)
        #expect(UsageCenterStore.forecast(for: hub, window: window, core: core, now: Self.now).workingAgents == nil)
    }

    @Test @MainActor func aProviderWithNoQuotaSourceClaimsNoFidelity() {
        let none = CoreProviderUsage(id: "opencode", fidelity: "official", state: "unsupported", quotaSource: false)
        let metered = CoreProviderUsage(id: "opencode", fidelity: "official", state: "ready",
                                        account: UsageAccount(plan: "Go"))
        #expect(UsageCenterStore.accountLine(none, history: nil) == "")
        #expect(UsageCenterStore.accountLine(metered, history: nil) == "Go · Official")
    }

    @Test func aStandInSourceIsNamed() {
        var statusLine = CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 42)
        statusLine.source = "claude-statusline"
        let viaClaudeCode = CoreProviderUsage(id: "claude", windows: [statusLine], state: "ready")
        let hub = CoreProviderUsage(id: "claude", state: "ready", instance: "cliproxy:3f2a9c1b0d4e")
        let direct = CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 42)])
        #expect(UsageSourceNotes.sourceCaption(viaClaudeCode) == "via Claude Code")
        #expect(UsageSourceNotes.sourceCaption(hub) == "via CLIProxyAPI")
        // With the "CLIProxyAPI" badge in the header, the caption would say it twice.
        #expect(UsageSourceNotes.sourceCaption(hub, badgeShown: true) == nil)
        #expect(UsageSourceNotes.sourceCaption(viaClaudeCode, badgeShown: true) == "via Claude Code")
        #expect(UsageSourceNotes.sourceCaption(direct) == nil)
        #expect(UsageSourceNotes.instanceBadge("cliproxy:3f2a9c1b0d4e") == "CLIProxyAPI")
        #expect(UsageSourceNotes.instanceBadge("work") == "work")
        #expect(UsageSourceNotes.rowTag("cliproxy:3f2a9c1b0d4e") == "CLIProxyAPI")
        #expect(UsageSourceNotes.rowTag("default") == nil)
        #expect(UsageSourceNotes.rowTag(nil) == nil)
    }

    @Test func theWindowSourceDecodesAndIsOptional() throws {
        let json = #"{"id":"five-hour","name":"5h","used_pct":42,"source":"claude-statusline"}"#
        let window = try JSONDecoder().decode(CoreUsageWindow.self, from: Data(json.utf8))
        #expect(window.source == "claude-statusline")
        let old = try JSONDecoder().decode(CoreUsageWindow.self, from: Data(#"{"id":"weekly","name":"7d"}"#.utf8))
        #expect(old.source == nil)
    }

    @Test func resetCreditsAreACountNeverAButton() throws {
        #expect(UsageSourceNotes.resetCreditsText(nil) == nil)
        #expect(UsageSourceNotes.resetCreditsText(0) == nil)
        #expect(UsageSourceNotes.resetCreditsText(1) == "1 reset credit")
        #expect(UsageSourceNotes.resetCreditsText(3) == "3 reset credits")
        let json = #"{"id":"codex","windows":[],"reset_credits":2}"#
        let provider = try JSONDecoder().decode(CoreProviderUsage.self, from: Data(json.utf8))
        #expect(provider.resetCredits == 2)
        let older = try JSONDecoder().decode(CoreProviderUsage.self, from: Data(#"{"id":"codex"}"#.utf8))
        #expect(older.resetCredits == nil)
    }
}
