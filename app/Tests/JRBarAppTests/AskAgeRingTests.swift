import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The left ear's ask-age ring: how long an agent has waited, as a mark.
@Suite("Ask-age ring on the left ear")
@MainActor
struct AskAgeRingTests {
    @Test("the fill steps in twelfths toward the final stage and closes there")
    func fraction() {
        #expect(PanelStore.askAgeFraction(opened: 100, now: 100, finalSeconds: 300) == 0)
        #expect(PanelStore.askAgeFraction(opened: 100, now: 124, finalSeconds: 300) == 0)
        #expect(PanelStore.askAgeFraction(opened: 100, now: 125, finalSeconds: 300) == 1.0 / 12)
        #expect(PanelStore.askAgeFraction(opened: 100, now: 250, finalSeconds: 300) == 0.5)
        #expect(PanelStore.askAgeFraction(opened: 100, now: 400, finalSeconds: 300) == 1)
        #expect(PanelStore.askAgeFraction(opened: 100, now: 9_000, finalSeconds: 300) == 1)
        // A clock that ran backwards reads as a fresh ask, not a negative ring.
        #expect(PanelStore.askAgeFraction(opened: 100, now: 50, finalSeconds: 300) == 0)
    }

    @Test("the peek says minutes, never seconds")
    func words() {
        #expect(PanelStore.askWaitWords(opened: 0, now: 59) == nil)
        #expect(PanelStore.askWaitWords(opened: 0, now: 60) == "1 min")
        #expect(PanelStore.askWaitWords(opened: 0, now: 3_725) == "1 h 2 min")
    }

    @Test("an asking focus rings; a working one keeps its bare glyph")
    func ear() {
        let opened: Double = 1_000
        let asking = SessionRow(session: CoreSession(
            id: "claude:session:a", provider: "claude", mode: "waiting", lifecycle: "active",
            ask: CoreAsk(session: "claude:session:a", kind: "permission", openedAt: opened, summary: "Run tests?")),
            pinnedAsk: nil)
        let slot = PanelStore.activitySlot(for: asking, askCount: 2, now: opened + 150, finalSeconds: 300)
        #expect(slot.meter == 0.5)
        #expect(slot.tone == .attention)
        #expect(slot.provider == "claude")
        #expect(slot.text == "Needs you ·2 · 2 min")
        // The same minute and twelfth: the same slot, so no relayout.
        #expect(PanelStore.activitySlot(for: asking, askCount: 2, now: opened + 160, finalSeconds: 300) == slot)

        let working = SessionRow(session: CoreSession(
            id: "claude:session:b", provider: "claude", mode: "working", lifecycle: "active"), pinnedAsk: nil)
        let bare = PanelStore.activitySlot(for: working, askCount: 0, now: opened, finalSeconds: 300)
        #expect(bare.meter == nil)
        #expect(bare.tone == .neutral)
    }
}
