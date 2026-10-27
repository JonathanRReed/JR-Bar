import Foundation
import Testing
@testable import JRBarCore

/// A nearly spent card names another provider's headroom in the same
/// window: a fact in numbers, from a real quota source, marked stale when
/// it is the last good reading.
@Suite("Headroom elsewhere")
struct HeadroomElsewhereTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func provider(
        _ id: String,
        used: Double?,
        window: String = "5h",
        state: String = "ready",
        quotaSource: Bool = true,
        resetsIn: Double? = 3600,
        readAt: Double? = nil
    ) -> CoreProviderUsage {
        let reset = resetsIn.map { 1_800_000_000 + $0 }
        let lane = CoreUsageWindow(key: nil, name: window, usedPct: used, resetsAt: reset)
        return CoreProviderUsage(
            id: id, windows: [lane], fidelity: state == "stale" ? "stale" : "official", state: state,
            quotaSource: quotaSource, observedAt: readAt, readAt: readAt
        )
    }

    @Test("a nearly spent window names the other provider's plenty, in numbers")
    func namesTheHeadroom() {
        let claude = provider("claude", used: 96)
        let codex = provider("codex", used: 18)
        let found = HeadroomElsewhere.find(for: claude, among: [claude, codex], now: now)
        #expect(found?.providerID == "codex")
        #expect(found?.remainingPercent == 82)
        #expect(found?.line(providerName: "Codex", ago: nil) == "Codex is at 18% used in this 5h window.")
    }

    @Test("nothing shows while the card still has room")
    func quietWhenRoomy() {
        let claude = provider("claude", used: 60)
        let codex = provider("codex", used: 5)
        #expect(HeadroomElsewhere.find(for: claude, among: [claude, codex], now: now) == nil)
    }

    @Test("the other provider needs plenty left, not merely less used")
    func needsPlenty() {
        let claude = provider("claude", used: 97)
        let codex = provider("codex", used: 70)
        #expect(HeadroomElsewhere.find(for: claude, among: [claude, codex], now: now) == nil)
    }

    @Test("a provider with no quota source never gets a lane invented for it")
    func noQuotaSource() {
        let claude = provider("claude", used: 97)
        let pi = provider("pi", used: 0, quotaSource: false)
        #expect(HeadroomElsewhere.find(for: claude, among: [claude, pi], now: now) == nil)
        let empty = CoreProviderUsage(id: "kiro", windows: [], state: "ready", quotaSource: true)
        #expect(HeadroomElsewhere.find(for: claude, among: [claude, empty], now: now) == nil)
    }

    @Test("only the same kind of window is compared")
    func sameWindowOnly() {
        let claude = provider("claude", used: 97, window: "5h")
        let codex = provider("codex", used: 10, window: "7d")
        #expect(HeadroomElsewhere.find(for: claude, among: [claude, codex], now: now) == nil)
    }

    @Test("a signed-out, switched-off or unmeasured provider is not quoted")
    func unusableStates() {
        let claude = provider("claude", used: 97)
        for state in ["needs_sign_in", "disabled", "error", "unsupported", "rate_limited"] {
            let other = provider("codex", used: 10, state: state)
            #expect(HeadroomElsewhere.find(for: claude, among: [claude, other], now: now) == nil)
        }
        let unmeasured = provider("codex", used: nil)
        #expect(HeadroomElsewhere.find(for: claude, among: [claude, unmeasured], now: now) == nil)
    }

    @Test("a window that already reset is over and is not quoted")
    func lapsedWindow() {
        let claude = provider("claude", used: 97)
        let codex = provider("codex", used: 5, resetsIn: -60)
        #expect(HeadroomElsewhere.find(for: claude, among: [claude, codex], now: now) == nil)
        let lapsedCard = provider("claude", used: 97, resetsIn: -60)
        #expect(HeadroomElsewhere.find(for: lapsedCard, among: [lapsedCard, provider("codex", used: 5)], now: now) == nil)
    }

    @Test("a stale reading is quoted as the last good one and says so")
    func staleReading() {
        let claude = provider("claude", used: 97)
        let codex = provider("codex", used: 20, state: "stale", readAt: 1_799_992_000)
        let found = HeadroomElsewhere.find(for: claude, among: [claude, codex], now: now)
        #expect(found?.stale == true)
        #expect(found?.line(providerName: "Codex", ago: "2h 13m") == "Codex was at 20% used in this 5h window (stale, read 2h 13m ago).")
        #expect(found?.line(providerName: "Codex", ago: nil) == "Codex was at 20% used in this 5h window (stale).")
    }

    @Test("a second account of the same provider is not another provider")
    func sameProviderIgnored() {
        let claude = provider("claude", used: 97)
        var second = provider("claude", used: 5)
        second.instance = "work"
        #expect(HeadroomElsewhere.find(for: claude, among: [claude, second], now: now) == nil)
    }

    @Test("the best of several is the one with the most left, a fresh one winning a tie")
    func bestOfSeveral() {
        let claude = provider("claude", used: 99)
        let codex = provider("codex", used: 40)
        let grok = provider("grok", used: 10)
        #expect(HeadroomElsewhere.find(for: claude, among: [claude, codex, grok], now: now)?.providerID == "grok")
        let staleTwin = provider("devin", used: 40, state: "stale")
        let freshTwin = provider("codex", used: 40)
        #expect(HeadroomElsewhere.find(for: claude, among: [claude, staleTwin, freshTwin], now: now)?.providerID == "codex")
    }

    @Test("a credit balance is not a window two providers share")
    func creditsNotComparable() {
        let claude = provider("claude", used: 99, window: "Credits")
        let codex = provider("codex", used: 5, window: "Credits")
        #expect(HeadroomElsewhere.find(for: claude, among: [claude, codex], now: now) == nil)
    }
}
