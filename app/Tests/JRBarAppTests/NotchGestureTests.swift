import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The island's own gestures against the toy: the tap that toggles the
/// card, the press-and-pull whose verdicts are the swipe's truth, the
/// queue's door-side priority, and the settings switch that turns the
/// touch gestures off. No screen is needed — `islandVisible` stands in
/// for `reconcile`, the same trick `NotchCapsuleTests` runs.
@Suite("Notch island gestures")
@MainActor
struct NotchGestureTests {
    private func notice(_ kind: AlcoveNoticeKind, key: String,
                        id: String) -> AlcoveNotice {
        AlcoveNotice(id: id, kind: kind, title: "Claude · t-\(id)",
                     subtitle: kind.verb, key: key)
    }

    private func makeToy() -> (NotchToy, ToysStore) {
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar,
                                    islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: state, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        return (toy, store)
    }

    // MARK: Tap

    @Test("a tap grows the card; the next tap folds it")
    func tapToggles() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.islandTapped()
        #expect(toy.islandExpanded)
        toy.islandTapped()
        #expect(!toy.islandExpanded)
    }

    @Test("a tap on a capsule puts it away — it never re-opens it")
    func tapDismissesCapsule() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.offer(notice(.ask, key: "ask:a", id: "a"))
        #expect(toy.activeCapsule?.id == "a")
        toy.islandTapped()
        #expect(toy.activeCapsule == nil)
        #expect(toy.capsuleQueue.current == nil)
        #expect(!toy.islandExpanded, "a dismissed capsule never pops the card open")
    }

    // MARK: Pull

    @Test("a pull's commit on the resting island is the pull-open")
    func pullCommitOpens() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.islandPullBegan()
        #expect(toy.pullActive)
        toy.islandPullEnded(.commit)
        #expect(!toy.pullActive)
        #expect(toy.islandExpanded)
    }

    @Test("a pull's commit on the grown card folds it")
    func pullCommitFolds() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.expandFromBand()
        #expect(toy.islandExpanded)
        toy.islandPullBegan()
        toy.islandPullEnded(.commit)
        #expect(!toy.islandExpanded)
    }

    @Test("a pull's commit on a capsule dismisses it")
    func pullCommitDismissesCapsule() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.offer(notice(.ask, key: "ask:a", id: "a"))
        #expect(toy.activeCapsule?.id == "a")
        toy.islandPullBegan()
        toy.islandPullEnded(.commit)
        #expect(toy.activeCapsule == nil)
        #expect(!toy.islandExpanded)
    }

    @Test("a retreat lets go where the face wants it — nothing expands")
    func pullRetreatIsHarmless() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.islandPullBegan()
        toy.islandPullEnded(.retreat)
        #expect(!toy.pullActive)
        #expect(!toy.islandExpanded)
    }

    // MARK: Swipe up

    @Test("a swipe up on the grown card folds it — Alcove's tuck-away")
    func swipeUpFolds() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.expandFromBand()
        #expect(toy.islandExpanded)
        toy.islandSwipe(.up)
        #expect(!toy.islandExpanded)
    }

    @Test("a swipe up on the resting island means nothing — no push into the screen")
    func swipeUpOnRestIsInert() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.islandSwipe(.up)
        #expect(!toy.islandExpanded)
    }

    @Test("the gestures switch turns pull and swipe off; the tap stays")
    func pullGesturesOff() {
        let (toy, store) = makeToy()
        store.state.notch.pullGestures = false
        toy.islandPullBegan()
        toy.islandPullEnded(.commit)
        #expect(!toy.islandExpanded, "gestures off: the pull is inert")
        toy.islandSwipe(.down)
        #expect(!toy.islandExpanded, "gestures off: the swipe is inert")
        // The click was never a gesture's business.
        toy.islandTapped()
        #expect(toy.islandExpanded)
    }

    // MARK: The queue's door — priority

    @Test("a waiting ask is never displaced by an ambient offer")
    func pendingAskSurvivesAmbient() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.offer(notice(.completed, key: "completed:a", id: "a"))
        #expect(toy.activeCapsule?.id == "a")
        toy.offer(notice(.ask, key: "ask:b", id: "b"))
        #expect(toy.capsuleQueue.pending?.id == "b")
        // A power blip and a quota note arrive behind it — both are
        // lower rank, so neither ever enters.
        toy.offer(notice(.charging, key: "power", id: "c"))
        toy.offer(notice(.quotaReset, key: "quota:d", id: "d"))
        #expect(toy.capsuleQueue.pending?.id == "b")
    }

    @Test("a waiting ambient capsule still yields to a newer ask")
    func pendingAmbientYieldsToAsk() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.offer(notice(.completed, key: "completed:a", id: "a"))
        toy.offer(notice(.charging, key: "power", id: "c"))
        #expect(toy.capsuleQueue.pending?.id == "c")
        // The ask outranks the waiting blip — newest-wins keeps working
        // inside the rank gate.
        toy.offer(notice(.ask, key: "ask:b", id: "b"))
        #expect(toy.capsuleQueue.pending?.id == "b")
        // …and nothing outranks the ask back: even a failure waits.
        toy.offer(notice(.failed, key: "failed:d", id: "d"))
        #expect(toy.capsuleQueue.pending?.id == "b",
                "nothing displaces a waiting ask")
    }

    @Test("a refused offer spends nothing — its key can still arrive later")
    func refusedOfferKeepsItsKey() async throws {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.offer(notice(.completed, key: "completed:a", id: "a"))
        toy.offer(notice(.ask, key: "ask:b", id: "b"))
        // Refused at the door — never queued, never cooled down.
        toy.offer(notice(.charging, key: "power", id: "c"))
        #expect(toy.capsuleQueue.pending?.id == "b")
        // Once the queue drains, the same key offers cleanly.
        toy.finishCapsule()
        #expect(toy.activeCapsule == nil)
        try await Task.sleep(for: .seconds(AlcoveCapsuleQueue.minGap + 0.2))
        // The ask draws after its gap; then the refused key is fresh.
        // Where it lands depends on timing — queued behind the ask
        // still living its `life`, or straight into `current` if the
        // sleep slid past that run — either way, it arrived.
        toy.offer(notice(.charging, key: "power", id: "c"))
        #expect(toy.capsuleQueue.pending?.id == "c"
                || toy.capsuleQueue.current?.id == "c")
    }
}
