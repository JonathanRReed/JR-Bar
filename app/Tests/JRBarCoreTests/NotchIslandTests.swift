import Foundation
import Testing
@testable import JRBarCore

/// The island's pure half: the settings' tolerant decode, the session
/// summary the capsule draws from, and the frame math that hangs the
/// panel under the notch. Screen numbers are the same MacBook Pro's the
/// geometry tests use: 1512×982, 32 pt notch, 185 pt slot.
@Suite("Notch island")
struct NotchIslandTests {
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
        let s = try decode(NotchSettings.self, "{}")
        #expect(s.enabled == false)
        #expect(s.provider == .jrbar)
        #expect(s.islandEnabled == true)
        #expect(s.showUsage == true)
        #expect(s.expandOnHover == true)
    }

    @Test("provider round-trips and a file from before it existed reads as JR-Bar")
    func providerDecode() throws {
        let chosen = try decode(NotchSettings.self, #"{"enabled": true, "provider": "boringNotch"}"#)
        #expect(chosen.provider == .boringNotch)
        #expect(chosen.enabled == true)
        let mistyped = try decode(NotchSettings.self, #"{"provider": "someone"}"#)
        #expect(mistyped.provider == .jrbar, "an unknown renderer is jrbar")
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .alcove, islandEnabled: false,
                                    showUsage: false, expandOnHover: false)
        let decoded = try decode(ToysState.self,
                                 String(decoding: JSONEncoder().encode(state), as: UTF8.self))
        #expect(decoded.notch == state.notch)
        #expect(try decode(ToysState.self, "{}").notch == NotchSettings())
    }

    @Test("a file written before the rename still lands its `alcove` key, and saves always write `notch`")
    func legacyAlcoveKey() throws {
        let decoded = try decode(ToysState.self,
                                 #"{"alcove": {"enabled": true, "provider": "alcove"}}"#)
        #expect(decoded.notch.enabled == true)
        #expect(decoded.notch.provider == .alcove)
        // Both keys in one file: `notch` wins — the new name is canonical.
        let both = try decode(ToysState.self,
                              #"{"alcove": {"enabled": true}, "notch": {"enabled": true, "provider": "boringNotch"}}"#)
        #expect(both.notch.provider == .boringNotch)
        var state = ToysState()
        state.notch.enabled = true
        let written = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(written.contains("\"notch\""))
        #expect(!written.contains("\"alcove\""))
    }

    // MARK: Summary

    @Test("the counts, the dots and the rows come out of one reduce")
    func summarize() {
        let summary = NotchIsland.summarize([
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
        #expect(NotchIsland.summarize([]).statusLine == "Nothing on the clock")
    }

    @Test("the busiest provider's dot leads; a split house ties on the id")
    func providerOrder() {
        let summary = NotchIsland.summarize([
            session("a", provider: "codex"),
            session("b", provider: "claude"),
            session("c", provider: "claude"),
            session("d", provider: "gemini"),
        ])
        #expect(summary.workingProviders == ["claude", "codex", "gemini"])
    }

    @Test("each provider's headline window becomes its meter; empty ones drop out")
    func meters() {
        let usage = CoreUsage(providers: [
            CoreProviderUsage(id: "claude", windows: [
                CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 62),
                CoreUsageWindow(key: "weekly", name: "7d", usedPct: 30),
            ]),
            CoreProviderUsage(id: "pi"),                                  // no windows
            CoreProviderUsage(id: "codex", windows: [CoreUsageWindow(name: "Daily", usedPct: nil)]),
        ])
        let meters = NotchIsland.meters(usage)
        #expect(meters.map(\.provider) == ["claude", "codex"])
        #expect(meters[0].window == "5h")
        #expect(meters[0].percentText == "62%")
        #expect(meters[1].percent == nil)
        #expect(meters[1].percentText == "—", "a stated unknown is a dash, never zero")
        #expect(NotchIsland.meters(nil).isEmpty)
    }

    @Test("the meter carries the reset clock and the incident flag the ear draws")
    func metersCarryResetAndIncident() {
        let resetsAt = Date().timeIntervalSince1970 + 2 * 3600
        let usage = CoreUsage(providers: [
            CoreProviderUsage(id: "claude", windows: [
                CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 62, resetsAt: resetsAt),
            ], incident: "Anthropic: Elevated errors"),
            CoreProviderUsage(id: "codex", windows: [
                CoreUsageWindow(key: "credits", name: "Credits", usedPct: 40),
            ]),
        ])
        let meters = NotchIsland.meters(usage)
        #expect(meters[0].incident)
        #expect(meters[0].resetsAt == resetsAt)
        #expect(meters[0].windowSpan == 18000)
        // 2h left of a 5h window drains to 0.4.
        #expect(meters[0].resetFraction(now: Date())! > 0.35)
        #expect(meters[0].resetFraction(now: Date())! < 0.45)
        // A credits lane has no clock: no span, no arc.
        #expect(meters[1].windowSpan == nil)
        #expect(meters[1].resetFraction(now: Date()) == nil)
        #expect(!meters[1].incident)
    }

    @Test("the drain fraction clamps: a past reset is 0, a far-future one is 1")
    func resetFractionBounds() {
        var meter = NotchIslandMeter(id: "claude", provider: "claude", window: "5h", percent: 50,
                                     resetsAt: nil, windowSpan: 5 * 3600)
        let now = Date()
        meter.resetsAt = now.timeIntervalSince1970 - 10
        #expect(meter.resetFraction(now: now) == 0)
        meter.resetsAt = now.timeIntervalSince1970 + 10 * 3600
        #expect(meter.resetFraction(now: now) == 1)
        meter.resetsAt = nil
        #expect(meter.resetFraction(now: now) == nil, "no reset time draws no arc")
    }

    @Test("the meter is the tightest lane — a weekly at 100 % outranks a calm 5h, the menu bar's own rule")
    func metersLeadWithTheConstrainedLane() {
        let exhausted = CoreProviderUsage(id: "claude", windows: [
            CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 12),
            CoreUsageWindow(key: "weekly", name: "7d", usedPct: 100),
        ])
        #expect(exhausted.headlineWindow?.name == "7d")
        #expect(NotchIsland.meters(CoreUsage(providers: [exhausted]))[0].window == "7d")
        // The daemon's own constrained pick wins over the local rule.
        var named = exhausted
        named.constrained = CoreConstrainedLane(name: "5h", usedPct: 12, reason: "test")
        #expect(named.headlineWindow?.name == "5h")
        // Nothing measured: the 5h convention, else the first window.
        let unmeasured = CoreProviderUsage(id: "codex", windows: [
            CoreUsageWindow(key: "daily", name: "Daily", usedPct: nil),
            CoreUsageWindow(key: "five-hour", name: "5h", usedPct: nil),
        ])
        #expect(unmeasured.headlineWindow?.name == "5h")
        #expect(CoreProviderUsage(id: "pi").headlineWindow == nil)
    }

    // MARK: Layout

    @Test("the slot is the gap between the menu-bar areas")
    func slotMath() {
        let left = CGRect(x: 0, y: 0, width: 663, height: 32)
        let right = CGRect(x: 848, y: 0, width: 664, height: 32)
        let slot = NotchIslandLayout.slot(left: left, right: right)
        #expect(slot?.centerX == 755.5)
        #expect(slot?.width == 185)
        #expect(NotchIslandLayout.slot(left: nil, right: right) == nil)
        #expect(NotchIslandLayout.slot(left: left, right: CGRect(x: 500, y: 0, width: 100, height: 32)) == nil)
    }

    @Test("the idle capsule is the notch plus each shoulder's own width, tucked to its depth")
    func idleSize() {
        // A bare housing is exactly the notch: no black past the
        // hardware, no menu-bar click landing on it.
        var bare = NotchIdleLayout()
        bare.bare = true
        #expect(bare.leftShoulder == 0 && bare.rightShoulder == 0)
        let housing = NotchIslandLayout.idleSize(slotWidth: 185, notchDepth: 32,
                                                 leftShoulder: 0, rightShoulder: 0)
        #expect(housing.width == 185)
        // Tucked into the notch's own depth — nothing hangs below it.
        #expect(housing.height == 32)
        // Content lives in the shoulders, never under the notch: each
        // shoulder is its own content plus its air, independent of the
        // other side.
        var uneven = NotchIdleLayout()
        uneven.leftWidth = 30
        #expect(uneven.leftShoulder == 30 + 2 * NotchIslandLayout.shoulderPad)
        #expect(uneven.rightShoulder == NotchIslandLayout.shoulder, "the resting shoulder, not a mirror")
        let size = NotchIslandLayout.idleSize(slotWidth: 185, notchDepth: 32,
                                              leftShoulder: uneven.leftShoulder,
                                              rightShoulder: uneven.rightShoulder)
        #expect(size.width == 241)
        #expect(NotchIslandLayout.shoulderWidth(contentWidth: 0) == NotchIslandLayout.shoulder)
        #expect(NotchIslandLayout.shoulderWidth(contentWidth: 2) == 2 + 2 * NotchIslandLayout.shoulderPad,
                "any content earns its air; the bare shoulder is only the floor")
        // The window takes the wider shoulder on both sides and stays
        // centred on the notch — every face shares one centre, so a
        // morph never travels sideways.
        #expect(uneven.windowShoulder == 44)
        #expect(NotchIslandLayout.idleCenterX(slotCenterX: 756, leftShoulder: 44, rightShoulder: 12) == 756)
        // No notch: a floating pill sized to the content.
        let floating = NotchIslandLayout.floatingSize(contentWidth: 30)
        #expect(floating.height == 24)
        #expect(floating.width == 96)
    }

    @Test("the frame hangs from the screen's top edge, centred and clamped")
    func frame() {
        let frame = NotchIslandLayout.frame(screenFrame: Self.screen, centerX: 756,
                                            size: CGSize(width: 209, height: 48))
        #expect(frame == CGRect(x: 651.5, y: 934, width: 209, height: 48))
        // Off-centre islands clamp inside the screen with a margin.
        let clamped = NotchIslandLayout.frame(screenFrame: Self.screen, centerX: 4,
                                              size: CGSize(width: 200, height: 48))
        #expect(clamped.minX == NotchIslandLayout.edgeMargin)
        // A notch-less floating pill sits a few points under the edge.
        let floating = NotchIslandLayout.frame(screenFrame: Self.screen, centerX: 756,
                                               size: CGSize(width: 96, height: 24),
                                               topInset: NotchIslandLayout.floatingTopInset)
        #expect(floating.maxY == 982 - NotchIslandLayout.floatingTopInset)
    }

    @Test("the resting shoulders: agents left, attention or media right, bare under the Screen Bar's ears")
    func idleLayout() {
        var s = NotchIslandSummary()
        #expect(NotchIsland.idleLayout(s, media: nil, earsDrawn: false) == NotchIdleLayout(),
                "nothing live, nothing playing: both shoulders empty")
        s.working = 2
        s.workingProviders = ["claude", "codex"]
        var layout = NotchIsland.idleLayout(s, media: nil, earsDrawn: false)
        #expect(layout.leftWidth == 32, "\(layout)")
        #expect(layout.right == .nothing)
        #expect(layout.contentWidth == layout.leftWidth)
        // An ask takes the right shoulder, in amber, with its count.
        s.waiting = 3
        layout = NotchIsland.idleLayout(s, media: nil, earsDrawn: false)
        #expect(layout.right == .attention(count: 3))
        #expect(layout.rightWidth == 22, "\(layout)")
        // Failures show only when no ask is open.
        s.waiting = 0
        s.failed = 1
        #expect(NotchIsland.idleLayout(s, media: nil, earsDrawn: false).right == .failed(count: 1))
        // Media takes the right shoulder only when nothing needs a hand.
        let media = AlcoveMedia(title: "Papillon", playing: true)
        #expect(NotchIsland.idleLayout(s, media: media, earsDrawn: false).right == .failed(count: 1))
        s.failed = 0
        layout = NotchIsland.idleLayout(s, media: media, earsDrawn: false)
        #expect(layout.right == .media)
        #expect(layout.rightWidth == NotchIsland.mediaContentWidth)
        #expect(layout.rightShoulder == NotchIsland.mediaContentWidth + 2 * NotchIslandLayout.shoulderPad)
        #expect(layout.leftShoulder == 46,
                "the left is its own two dots and count plus air")
        #expect(layout.windowShoulder == NotchIsland.mediaContentWidth + 2 * NotchIslandLayout.shoulderPad,
                "the window's shoulder is the wider side, both sides — centred on the notch")
        // The Screen Bar's ears over the same shoulders: bare, whatever
        // is live — and a bare housing has no shoulders at all.
        let bare = NotchIsland.idleLayout(s, media: media, earsDrawn: true)
        #expect(bare.bare)
        #expect(bare.contentWidth == 0)
        #expect(bare.leftShoulder == 0 && bare.rightShoulder == 0)
    }

    @Test("the idle content width follows the dots and the count")
    func idleContentWidth() {
        #expect(NotchIsland.idleContentWidth(NotchIslandSummary()) == 4)
        var s = NotchIslandSummary()
        s.working = 2
        s.workingProviders = ["claude", "codex"]
        #expect(NotchIsland.idleContentWidth(s) == 32)
        s.waiting = 1
        #expect(NotchIsland.idleContentWidth(s) == 41)
    }

    @Test("the grown card is the slot plus modest wings — the notch swelling, not a panel")
    func expandedWidth() {
        // 185 + 30 a side is under the card's 320-point floor — the
        // rows are designed at 320, so the floor wins on this notch.
        #expect(NotchIslandLayout.expandedWidth(slotWidth: 185) == NotchIslandLayout.expandedMinWidth)
        #expect(NotchIslandLayout.expandedWidth(slotWidth: 300) == 360)
        // A tiny or absent slot still earns the card's floor.
        #expect(NotchIslandLayout.expandedWidth(slotWidth: 0)
                == NotchIslandLayout.expandedMinWidth)
        // A huge slot caps before it reads as a panel.
        #expect(NotchIslandLayout.expandedWidth(slotWidth: 400)
                == NotchIslandLayout.expandedMaxWidth)
    }

    // MARK: The one-surface rule

    private func settings(_ body: (inout NotchSettings) -> Void) -> NotchSettings {
        var s = NotchSettings()
        body(&s)
        return s
    }

    @Test("the utility switched off draws nothing — no island, no glass fallback")
    func surfaceOff() {
        for visible in [true, false] {
            #expect(NotchIsland.surface(NotchSettings(), islandVisible: visible) == .none)
            #expect(NotchIsland.surface(settings { $0.islandEnabled = true },
                                        islandVisible: visible) == .none)
        }
    }

    @Test("the drawn island is the surface; the glass card is its fallback only")
    func surfaceOn() {
        let on = settings { $0.enabled = true }
        // Our island up: it IS the card — the glass stays dark.
        #expect(NotchIsland.surface(on, islandVisible: true) == .island)
        // Island hidden or not yet drawn: the band's card is the glass fallback.
        #expect(NotchIsland.surface(on, islandVisible: false) == .glass)
        #expect(NotchIsland.surface(settings { $0.enabled = true; $0.islandEnabled = false },
                                    islandVisible: false) == .glass)
        // An external renderer owns the notch: ours never draws the
        // island, so the glass card is the band's answer.
        #expect(NotchIsland.surface(settings { $0.enabled = true; $0.provider = .alcove },
                                    islandVisible: false) == .glass)
        #expect(NotchIsland.surface(settings { $0.enabled = true; $0.provider = .boringNotch },
                                    islandVisible: false) == .glass)
    }

    @Test("the grow keeps its centre on the notch every tick — it swells down, never in from a side")
    func growStaysCentred() {
        let idle = CGRect(x: 656, y: 945, width: 200, height: 37)
        let grown = CGRect(x: 596, y: 682, width: 320, height: 300)
        var spring = NotchFrameSpring(at: idle)
        spring.retarget(grown, motion: NotchFrameSpring.expandMotion)
        var ticks = 0
        while spring.integrate(dt: 1.0 / 120), ticks < 600 {
            ticks += 1
            #expect(abs(spring.frame.midX - 756) < 0.5, "tick \(ticks): \(spring.frame)")
            #expect(abs(spring.frame.maxY - 982) < 0.5, "the top edge stays on the screen's edge")
        }
        #expect(ticks > 10 && ticks < 600)
    }

    @Test("the grown card's content clears the notch, its inset and a live band")
    func expandedTopInset() {
        #expect(NotchIslandLayout.expandedTopInset(notchDepth: 32, ledClearance: 0)
                == 32 + NotchIslandLayout.expandedNotchInset)
        #expect(NotchIslandLayout.expandedTopInset(notchDepth: 32, ledClearance: 12)
                == 32 + NotchIslandLayout.expandedNotchInset + 12)
        // Notch-less: just the inset — the window already floats.
        #expect(NotchIslandLayout.expandedTopInset(notchDepth: 0, ledClearance: 0)
                == NotchIslandLayout.expandedNotchInset)
    }
}
