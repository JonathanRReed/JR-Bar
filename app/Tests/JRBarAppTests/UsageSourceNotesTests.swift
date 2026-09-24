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
        let windows = [
            CoreUsageWindow(key: "go-rolling", name: "5h", usedPct: 42, resetsAt: Self.now.timeIntervalSince1970 + 3600),
            CoreUsageWindow(key: "go-weekly", name: "7d", usedPct: 18),
            CoreUsageWindow(key: "go-monthly", name: "Monthly", usedPct: 7, bindable: false),
        ]
        #expect(UsageSourceNotes.ringWindows(windows).map(\.id) == ["go-rolling", "go-weekly"])
        #expect(UsageSourceNotes.detailWindows(windows).map(\.id) == ["go-monthly"])
        let detail = UsageSourceNotes.detailText(windows[2], now: Self.now, fix: nil)
        #expect(detail == "Monthly 7% used")
    }

    @Test func aProviderWhoseWindowsAreAllDetailKeepsItsRings() {
        let pools = [
            CoreUsageWindow(key: "model-gemini-pro", name: "gemini-pro", usedPct: 12, bindable: false),
            CoreUsageWindow(key: "model-gemini-flash", name: "gemini-flash", usedPct: 3, bindable: false),
        ]
        #expect(UsageSourceNotes.ringWindows(pools).count == 2)
        #expect(UsageSourceNotes.detailWindows(pools).isEmpty)
    }

    @Test func aStandInSourceIsNamed() {
        var statusLine = CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 42)
        statusLine.source = "claude-statusline"
        let viaClaudeCode = CoreProviderUsage(id: "claude", windows: [statusLine], state: "ready")
        let hub = CoreProviderUsage(id: "claude", state: "ready", instance: "cliproxy:3f2a9c1b0d4e")
        let direct = CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 42)])
        #expect(UsageSourceNotes.sourceCaption(viaClaudeCode) == "via Claude Code")
        #expect(UsageSourceNotes.sourceCaption(hub) == "via CLIProxyAPI")
        #expect(UsageSourceNotes.sourceCaption(direct) == nil)
        #expect(UsageSourceNotes.instanceBadge("cliproxy:3f2a9c1b0d4e") == "CLIProxyAPI")
        #expect(UsageSourceNotes.instanceBadge("work") == "work")
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
