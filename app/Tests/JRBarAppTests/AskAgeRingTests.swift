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

    @Test("the ear's next step: the ring's next twelfth or the next whole minute, whichever is sooner")
    func nextTick() {
        #expect(PanelStore.nextAskAgeTick(opened: 100, now: 124, finalSeconds: 300) == 125)
        #expect(PanelStore.nextAskAgeTick(opened: 100, now: 125, finalSeconds: 300) == 150)
        // A slow ring (twelfths of 20 min are 100 s) ticks on the minute.
        #expect(PanelStore.nextAskAgeTick(opened: 0, now: 30, finalSeconds: 1_200) == 60)
        #expect(PanelStore.nextAskAgeTick(opened: 0, now: 70, finalSeconds: 1_200) == 100)
        // A full ring still counts minutes for the words, past an hour too.
        #expect(PanelStore.nextAskAgeTick(opened: 0, now: 3_725, finalSeconds: 300) == 3_780)
        // A clock that ran backwards waits for the first step.
        #expect(PanelStore.nextAskAgeTick(opened: 100, now: 50, finalSeconds: 300) == 125)
        #expect(PanelStore.nextAskAgeTick(opened: nil, now: 50, finalSeconds: 300) == nil)
    }

    @Test("a held ask's lapse is a boundary too, while it is still ahead")
    func nextTickAtHoldLapse() {
        #expect(PanelStore.nextAskAgeTick(opened: 100, now: 110, finalSeconds: 300, holdUntil: 118) == 118)
        #expect(PanelStore.nextAskAgeTick(opened: 100, now: 110, finalSeconds: 300, holdUntil: 145) == 125,
                "the ring's step comes first")
        #expect(PanelStore.nextAskAgeTick(opened: 100, now: 120, finalSeconds: 300, holdUntil: 118) == 125,
                "a lapse already past marks nothing")
    }

    @Test("each tick lands on a boundary the ring or the words actually cross")
    func ticksChangeTheSlot() {
        let opened: Double = 1_000
        let asking = SessionRow(session: CoreSession(
            id: "claude:session:a", provider: "claude", mode: "waiting", lifecycle: "active",
            ask: CoreAsk(session: "claude:session:a", kind: "permission", openedAt: opened, summary: "Run tests?")),
            pinnedAsk: nil)
        var now = opened
        for _ in 0..<20 {
            guard let next = PanelStore.nextAskAgeTick(opened: opened, now: now, finalSeconds: 300) else { break }
            let before = PanelStore.activitySlot(for: asking, askCount: 1, now: now, finalSeconds: 300)
            let after = PanelStore.activitySlot(for: asking, askCount: 1, now: next + 0.05, finalSeconds: 300)
            #expect(before != after)
            now = next + 0.05
        }
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

/// "Quiet This Run": the mailbox snooze offered on a run you have seen.
@Suite("Quiet a working run")
@MainActor
struct QuietRunTests {
    private func row(_ mode: String, lifecycle: String = "active", ask: CoreAsk? = nil, id: String = "claude:session:q") -> SessionRow {
        SessionRow(session: CoreSession(id: id, provider: "claude", mode: mode, lifecycle: lifecycle, ask: ask), pinnedAsk: nil)
    }

    @Test("working and idle runs can be quieted; asks, finished and remote rows cannot")
    func offers() {
        #expect(PanelStore.canQuietRun(row("working")))
        #expect(PanelStore.canQuietRun(row("idle")))
        #expect(!PanelStore.canQuietRun(row("completed", lifecycle: "completed")))
        #expect(!PanelStore.canQuietRun(row("waiting", ask: CoreAsk(session: "claude:session:q", kind: "permission"))))
        #expect(!PanelStore.canQuietRun(row("working", id: "remote:studio:claude:session:q")))
    }
}
