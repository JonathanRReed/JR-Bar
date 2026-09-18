import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The capsule queue against the grown card. A capsule promoted into
/// its show-gap used to wedge: `showCurrentCapsule` early-returns while
/// the island is expanded, so a `current` parked by a mid-gap grow sat
/// there forever and every later offer queued behind a ghost.
@Suite("Notch capsule lifecycle")
@MainActor
struct NotchCapsuleTests {
    private func notice(_ kind: AlcoveNoticeKind, key: String,
                        id: String) -> AlcoveNotice {
        AlcoveNotice(id: id, kind: kind, title: "Claude · t-\(id)",
                     subtitle: kind.verb, key: key)
    }

    /// A toy whose island the settings say is ours; `islandVisible`
    /// stands in for `reconcile`, which needs a real notched screen.
    private func makeToy() -> (NotchToy, ToysStore) {
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar,
                                    islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: state, cardModel: makeTestCardModel())
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        return (toy, store)
    }

    /// Poll for a capsule's draw — every hop in its lifecycle rides a
    /// main-queue `asyncAfter` whose deadline slides under a parallel
    /// suite, so the tests sample a window, not one slept instant.
    private func waitForCapsule(_ toy: NotchToy, id: String,
                              timeout: Duration = .seconds(8)) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if toy.activeCapsule?.id == id { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("a grow mid-gap shelves the capsule; the fold replays it and the queue unwedges")
    func expandDuringGapShelvesAndCollapseRestores() async throws {
        let (toy, store) = makeToy()
        _ = store   // the toy holds it weakly — keep it alive

        // A is up; B waits behind it.
        toy.offer(notice(.ask, key: "ask:a", id: "a"))
        toy.offer(notice(.failed, key: "failed:b", id: "b"))
        #expect(toy.activeCapsule?.id == "a")
        #expect(toy.capsuleQueue.pending?.id == "b")

        // A's run ends inside the minimum gap — B promotes to `current`
        // and arms its gap timer. This is the window that used to wedge.
        toy.finishCapsule()
        #expect(toy.capsuleQueue.current?.id == "b")
        #expect(toy.activeCapsule == nil)

        // The band grows the island inside that gap: B shelves, its gap
        // timer dies, but the queue keeps the notice for the fold.
        toy.expandFromBand()
        #expect(toy.islandExpanded)
        #expect(toy.shelvedCapsule?.notice.id == "b")

        // The fold replays the still-fresh capsule instead of leaving
        // `current` parked behind the card.
        toy.collapseFromBand()
        #expect(toy.activeCapsule?.id == "b")
        #expect(toy.shelvedCapsule == nil)

        // A new offer queues behind the replayed capsule, then draws —
        // the slot is not wedged. B's replay ends after its `life`, C
        // promotes past the gap: every hop is a timer that slides, so
        // the test waits for the draw itself.
        toy.offer(notice(.completed, key: "completed:c", id: "c"))
        #expect(toy.capsuleQueue.pending?.id == "c")
        // The longest chain in the file — B's replay `life` plus the
        // minimum gap plus C's promotion, every hop a main-queue
        // `asyncAfter`. Under the parallel suite the main queue itself
        // backlogs (a blocked main thread starves every queued block,
        // not just timers), so the bound outlasts the suite's whole
        // congestion window, not just slide. The claim is still "the
        // queued capsule draws" — a real wedge still fails, slowly.
        #expect(await waitForCapsule(toy, id: "c", timeout: .seconds(60)),
                "the queued capsule draws after the replay")
    }

    @Test("the utility switched off owns no surface — the island read and the glass card agree")
    func disabledDrawsNothing() {
        var state = ToysState()
        state.notch = NotchSettings(enabled: false, provider: .jrbar,
                                    islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: state, cardModel: makeTestCardModel())
        let toy: NotchToy = store.notch
        _ = store
        // Even a stale "visible" flag — the read a crashed park could
        // leave — must not resurrect the island: `enabled` gates all.
        toy.islandVisible = true
        #expect(toy.notchSurface == .none)
        #expect(!toy.isDrawingIsland)
        #expect(toy.islandScreenRect == nil)
    }

    @Test("the glass card presents only on the glass surface — island ownership and off both stay dark")
    func presenterHonoursTheSurface() {
        var surface = NotchSurface.glass
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        presenter.surface = { surface }
        presenter.focus = { ScreenBarFocus(style: nil, label: "JR-Bar",
                                           word: "Working", clickSession: nil) }
        presenter.anchor = { NSRect(x: 0, y: 0, width: 180, height: 6) }

        // Island owns the notch: a stray peek/pin draws nothing and
        // leaves no pinned state behind.
        surface = .island
        presenter.peek()
        #expect(!presenter.isShown)
        presenter.pin()
        #expect(!presenter.isShown)
        #expect(!presenter.isPinned)

        // The utility off is the same answer — nothing notch-related.
        surface = .none
        presenter.peek()
        #expect(!presenter.isShown)
    }

    @Test("a shelf that outlives its capsule's freshness is dropped, not replayed")
    func staleShelfDropsOnCollapse() async throws {
        let (toy, store) = makeToy()
        _ = store

        toy.offer(notice(.ask, key: "ask:a", id: "a"))
        toy.offer(notice(.failed, key: "failed:b", id: "b"))
        toy.finishCapsule()
        toy.expandFromBand()
        #expect(toy.shelvedCapsule?.notice.id == "b")

        // Held past the capsule's own TTL the fold lets it go — and
        // clears the slot so the queue still answers new offers.
        try await Task.sleep(for: .seconds(AlcoveCapsuleQueue.life + 0.4))
        toy.collapseFromBand()
        #expect(toy.activeCapsule == nil)
        #expect(toy.capsuleQueue.current == nil)

        toy.offer(notice(.completed, key: "completed:c", id: "c"))
        #expect(toy.activeCapsule?.id == "c")
    }

    @Test("a swipe down on the grown card folds it and takes the shelved capsule with it")
    func swipeDownOnExpandedFoldsCardAndShelf() {
        let (toy, store) = makeToy()
        _ = store

        // A up, B behind it; B promotes into its gap, then the band
        // grows the island and B shelves beneath the card.
        toy.offer(notice(.ask, key: "ask:a", id: "a"))
        toy.offer(notice(.failed, key: "failed:b", id: "b"))
        toy.finishCapsule()
        toy.expandFromBand()
        #expect(toy.islandExpanded)
        #expect(toy.shelvedCapsule?.notice.id == "b")

        // A shelved capsule kept `capsuleQueue.current` set — the old
        // routing read that as "a capsule is up" and dismissed the
        // shelf while the card stayed open. The swipe is "fold the
        // card away": it collapses, and the shelf goes with it rather
        // than replaying where the card just was.
        toy.islandSwipe(.down)
        #expect(!toy.islandExpanded)
        #expect(toy.shelvedCapsule == nil)
        #expect(toy.capsuleQueue.current == nil)
        #expect(toy.activeCapsule == nil)
    }

    @Test("a swipe-down dismissal eats a band click's pending expand")
    func swipeDismissEatsPendingBandExpand() {
        let (toy, store) = makeToy()
        _ = store

        toy.offer(notice(.ask, key: "ask:a", id: "a"))
        #expect(toy.activeCapsule?.id == "a")
        // The click lands mid-capsule — remembered, not grown yet.
        toy.expandFromBand()
        #expect(!toy.islandExpanded)

        // The flick-away is a dismissal of everything pending: without
        // clearing the remembered click the settle grows the card off
        // the back of a "go away" gesture.
        toy.islandSwipe(.down)
        #expect(!toy.islandExpanded)
        #expect(toy.activeCapsule == nil)
        #expect(toy.capsuleQueue.current == nil)
    }

    @Test("a folded card stays folded when a later capsule steps down")
    func collapsedCardStaysDownAfterCapsule() async throws {
        let (toy, store) = makeToy()
        _ = store

        // A HELD hover grows the card — the intent debounce has to land
        // first (a passing cursor only ever earns the wink). The swipe
        // folds it while the cursor still sits on the island — the
        // remembered hover used to survive, so the next capsule's
        // settle re-grew a card the user had just let go.
        toy.setHovered(true)
        #expect(toy.islandHoverPeek)
        #expect(!toy.islandExpanded, "hover alone never grows the card")
        try await Task.sleep(for: .seconds(0.55))
        #expect(toy.islandExpanded, "a hover that stayed earned the card")
        toy.islandSwipe(.down)
        #expect(!toy.islandExpanded)

        toy.offer(notice(.ask, key: "ask:a", id: "a"))
        #expect(toy.activeCapsule?.id == "a")
        toy.finishCapsule()
        #expect(!toy.islandExpanded, "a card let go stays let go")
    }
}
