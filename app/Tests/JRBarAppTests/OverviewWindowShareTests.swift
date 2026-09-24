import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The Overview inspector's "5 h window share": derived from the
/// daemon's per-session `window_tokens`, marked ≈, and gone entirely while
/// the daemon gives none — so an older daemon never shows a made-up share.
@Suite("Overview window share")
struct OverviewWindowShareTests {
    private func usage(_ provider: String, window: Int?) -> SessionUsage {
        var reading = SessionUsage(provider: provider)
        reading.windowTokens = window
        return reading
    }

    @Test func windowTokensDecodeTolerantly() throws {
        let decoded = try JSONDecoder().decode(SessionUsage.self, from: Data(#"{"window_tokens": 1200}"#.utf8))
        #expect(decoded.windowTokens == 1200)
        let missing = try JSONDecoder().decode(SessionUsage.self, from: Data(#"{"turns": 3}"#.utf8))
        #expect(missing.windowTokens == nil)
        let null = try JSONDecoder().decode(SessionUsage.self, from: Data(#"{"window_tokens": null}"#.utf8))
        #expect(null.windowTokens == nil)
        let mistyped = try JSONDecoder().decode(SessionUsage.self, from: Data(#"{"window_tokens": "lots", "turns": 2}"#.utf8))
        #expect(mistyped.windowTokens == nil && mistyped.turns == 2)
    }

    @Test func theShareHidesWithoutWindowTokens() {
        let mine = usage("claude", window: nil)
        #expect(OverviewWindowShare.fact(for: mine, provider: "claude",
                                         readings: [mine, usage("claude", window: 500)]) == nil)
        // Nothing spent in the window is no share either.
        let idle = usage("claude", window: 0)
        #expect(OverviewWindowShare.fact(for: idle, provider: "claude", readings: [idle]) == nil)
    }

    @Test func theShareIsThisSessionsPartOfItsProvidersWindow() throws {
        let mine = usage("claude", window: 340_000)
        let readings = [mine, usage("claude", window: 660_000), usage("codex", window: 9_000_000),
                        usage("claude", window: nil)]
        let fact = try #require(OverviewWindowShare.fact(for: mine, provider: "claude", readings: readings))
        #expect(fact.name == "5\u{00A0}h window share")
        #expect(fact.value == "≈ 34%")
        // Another provider's window is named without a length.
        let gemini = usage("gemini", window: 10)
        let other = try #require(OverviewWindowShare.fact(for: gemini, provider: "gemini",
                                                          readings: [gemini, usage("gemini", window: 3000)]))
        #expect(other.name == "Window share")
        #expect(other.value == "≈ <1%")
        // Its own reading missing from the list still reads as all of it.
        #expect(OverviewWindowShare.share(tokens: 50, provider: "codex", readings: []) == 1)
    }
}
