import Foundation
import Testing
@testable import JRBarCore

/// The island's pure half: the settings' tolerant decode, the session
/// summary the capsule draws from, and the frame math that hangs the
/// panel under the notch. Screen numbers are the same MacBook Pro's the
/// geometry tests use: 1512×982, 32 pt notch, 185 pt slot.
@Suite("Alcove island")
struct AlcoveIslandTests {
    static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func session(_ id: String, provider: String = "claude",
                         mode: String? = "working", label: String? = nil) -> CoreSession {
        CoreSession(id: id, provider: provider, label: label, mode: mode)
    }

    // MARK: Settings

    @Test("provider defaults to JR-Bar and the island knobs default on")
    func settingsDefaults() throws {
        let s = try decode(AlcoveSettings.self, "{}")
        #expect(s.enabled == false)
        #expect(s.provider == .jrbar)
        #expect(s.islandEnabled == true)
        #expect(s.showUsage == true)
        #expect(s.expandOnHover == true)
    }

    @Test("provider round-trips and a file from before it existed reads as JR-Bar")
    func providerDecode() throws {
        let chosen = try decode(AlcoveSettings.self, #"{"enabled": true, "provider": "boringNotch"}"#)
        #expect(chosen.provider == .boringNotch)
        #expect(chosen.enabled == true)
        let mistyped = try decode(AlcoveSettings.self, #"{"provider": "someone"}"#)
        #expect(mistyped.provider == .jrbar, "an unknown renderer is jrbar")
        var state = ToysState()
        state.alcove = AlcoveSettings(enabled: true, provider: .alcove, islandEnabled: false,
                                      showUsage: false, expandOnHover: false)
        let decoded = try decode(ToysState.self,
                                 String(decoding: JSONEncoder().encode(state), as: UTF8.self))
        #expect(decoded.alcove == state.alcove)
        #expect(try decode(ToysState.self, "{}").alcove == AlcoveSettings())
    }

    // MARK: Summary

    @Test("the counts, the dots and the rows come out of one reduce")
    func summarize() {
        let summary = AlcoveIsland.summarize([
            session("a", provider: "claude", label: "jr-bar-1"),
            session("b", provider: "claude", label: "jr-bar-2"),
            session("c", provider: "codex", mode: "waiting", label: "Codex 0a1b"),
            session("d", provider: "gemini", mode: "failed", label: "gemini-run"),
            session("e", provider: "pi", mode: "idle"),
            session("f", provider: "codex", mode: "completed", label: "done one"),
        ])
        #expect(summary.working == 2)
        #expect(summary.waiting == 1)
        #expect(summary.failed == 1)
        #expect(summary.workingProviders == ["claude"])
        // Live rows only, in the panel's precedence: waiting first.
        #expect(summary.rows.map(\.activity) == [.waiting, .failed, .working, .working])
        #expect(summary.rows.first?.label == "0a1b")
        #expect(summary.statusLine == "2 working · 1 waiting · 1 failed")
        #expect(AlcoveIsland.summarize([]).statusLine == "Nothing on the clock")
    }

    @Test("the busiest provider's dot leads; a split house ties on the id")
    func providerOrder() {
        let summary = AlcoveIsland.summarize([
            session("a", provider: "codex"),
            session("b", provider: "claude"),
            session("c", provider: "claude"),
            session("d", provider: "gemini"),
        ])
        #expect(summary.workingProviders == ["claude", "codex", "gemini"])
    }

    @Test("each provider's first window becomes its meter; empty ones drop out")
    func meters() {
        let usage = CoreUsage(providers: [
            CoreProviderUsage(id: "claude", windows: [
                CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 62),
                CoreUsageWindow(key: "weekly", name: "7d", usedPct: 30),
            ]),
            CoreProviderUsage(id: "pi"),                                  // no windows
            CoreProviderUsage(id: "codex", windows: [CoreUsageWindow(name: "Daily", usedPct: nil)]),
        ])
        let meters = AlcoveIsland.meters(usage)
        #expect(meters.map(\.provider) == ["claude", "codex"])
        #expect(meters[0].window == "5h")
        #expect(meters[0].percentText == "62%")
        #expect(meters[1].percent == nil)
        #expect(meters[1].percentText == "—", "a stated unknown is a dash, never zero")
        #expect(AlcoveIsland.meters(nil).isEmpty)
    }

    // MARK: Layout

    @Test("the slot is the gap between the menu-bar areas")
    func slotMath() {
        let left = CGRect(x: 0, y: 0, width: 663, height: 32)
        let right = CGRect(x: 848, y: 0, width: 664, height: 32)
        let slot = AlcoveIslandLayout.slot(left: left, right: right)
        #expect(slot?.centerX == 755.5)
        #expect(slot?.width == 185)
        #expect(AlcoveIslandLayout.slot(left: nil, right: right) == nil)
        #expect(AlcoveIslandLayout.slot(left: left, right: CGRect(x: 500, y: 0, width: 100, height: 32)) == nil)
    }

    @Test("the idle capsule is the notch plus shoulders and a lip")
    func idleSize() {
        let size = AlcoveIslandLayout.idleSize(slotWidth: 185, notchDepth: 32, contentWidth: 30)
        #expect(size.width == 185 + 2 * AlcoveIslandLayout.shoulder)
        #expect(size.height == 48)
        // Wide content widens the capsule past the shoulders.
        let busy = AlcoveIslandLayout.idleSize(slotWidth: 185, notchDepth: 32, contentWidth: 300)
        #expect(busy.width == 328)
        // No notch: a floating pill sized to the content.
        let floating = AlcoveIslandLayout.idleSize(slotWidth: 0, notchDepth: 0, contentWidth: 30)
        #expect(floating.height == 24)
        #expect(floating.width == 96)
    }

    @Test("the frame hangs from the screen's top edge, centred and clamped")
    func frame() {
        let frame = AlcoveIslandLayout.frame(screenFrame: Self.screen, centerX: 756,
                                             size: CGSize(width: 209, height: 48))
        #expect(frame == CGRect(x: 651.5, y: 934, width: 209, height: 48))
        // Off-centre islands clamp inside the screen with a margin.
        let clamped = AlcoveIslandLayout.frame(screenFrame: Self.screen, centerX: 4,
                                               size: CGSize(width: 200, height: 48))
        #expect(clamped.minX == AlcoveIslandLayout.edgeMargin)
        // A notch-less floating pill sits a few points under the edge.
        let floating = AlcoveIslandLayout.frame(screenFrame: Self.screen, centerX: 756,
                                                size: CGSize(width: 96, height: 24),
                                                topInset: AlcoveIslandLayout.floatingTopInset)
        #expect(floating.maxY == 982 - AlcoveIslandLayout.floatingTopInset)
    }

    @Test("the expanded card clears the notch and grows with its rows")
    func expandedHeight() {
        let empty = AlcoveIslandLayout.expandedHeight(notchDepth: 32, rows: 0, meters: 0, overflow: false)
        #expect(empty == 72)
        let taller = AlcoveIslandLayout.expandedHeight(notchDepth: 32, rows: 5, meters: 2, overflow: true)
        #expect(taller == 246)
        #expect(taller > empty)
        let notchless = AlcoveIslandLayout.expandedHeight(notchDepth: 0, rows: 1, meters: 0, overflow: false)
        #expect(notchless == 62)
    }

    @Test("the idle content width follows the dots and the count")
    func idleContentWidth() {
        #expect(AlcoveIsland.idleContentWidth(AlcoveIslandSummary()) == 4)
        var s = AlcoveIslandSummary()
        s.working = 2
        s.workingProviders = ["claude", "codex"]
        #expect(AlcoveIsland.idleContentWidth(s) == 32)
        s.waiting = 1
        #expect(AlcoveIsland.idleContentWidth(s) == 41)
    }
}
