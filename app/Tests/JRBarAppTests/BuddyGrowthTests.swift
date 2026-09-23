import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The buddy grows up on the crumbs finished sessions feed it —
/// hatchling, grown, elder — and never shrinks back.
@Suite("Buddy growth")
@MainActor
struct BuddyGrowthTests {
    @Test("the stages follow lifetime crumbs")
    func stages() {
        #expect(BuddyStage.of(crumbs: 0) == .hatchling)
        #expect(BuddyStage.of(crumbs: BuddyStage.grownAt - 1) == .hatchling)
        #expect(BuddyStage.of(crumbs: BuddyStage.grownAt) == .grown)
        #expect(BuddyStage.of(crumbs: BuddyStage.elderAt - 1) == .grown)
        #expect(BuddyStage.of(crumbs: BuddyStage.elderAt) == .elder)
        #expect(BuddyStage.hatchling < .grown && .grown < .elder)
    }

    @Test("the pal card says where it is and how far to go")
    func palCardLine() {
        #expect(BuddyStage.line(crumbs: 0) == "Hatchling · 30 crumbs to grown")
        #expect(BuddyStage.line(crumbs: 29) == "Hatchling · 1 crumb to grown")
        #expect(BuddyStage.line(crumbs: 212) == "Grown · 188 crumbs to elder")
        #expect(BuddyStage.line(crumbs: 4_000) == "Elder")
        var care = BuddyCare()
        care.eat(at: Date(timeIntervalSince1970: 1_700_000_000), count: 31)
        let card = BuddyPalCard.make(care: care)
        #expect(card.stage == .grown)
        #expect(card.growth == "Grown · 369 crumbs to elder")
    }

    private func fixture(crumbs: Int) -> (CoreModel, ToysStore, NotchBuddyToy) {
        let core = CoreModel()
        var state = ToysState()
        state.notchBuddy.enabled = true
        state.notchBuddy.care.crumbsEaten = crumbs
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        return (core, store, store.notchBuddy)
    }

    @Test("the crumb that grows it up throws the hearts; an ordinary one doesn't")
    func growingUpCelebrates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (_, _, ordinary) = fixture(crumbs: 10)
        ordinary.noteEvent(CoreEvent(id: "c1", kind: "completed", session: "s"), at: now)
        #expect(ordinary.treatBurstAt == nil)
        let (_, store, buddy) = fixture(crumbs: BuddyStage.grownAt - 1)
        #expect(buddy.stage == .hatchling)
        buddy.noteEvent(CoreEvent(id: "c2", kind: "completed", session: "s"), at: now)
        #expect(buddy.stage == .grown)
        #expect(buddy.treatBurstAt == now)
        _ = store
    }

    @Test("hushed, it still grows, quietly")
    func growingUpHushed() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (_, store, buddy) = fixture(crumbs: BuddyStage.elderAt - 1)
        store.noteCallPresence(true)
        buddy.noteEvent(CoreEvent(id: "c3", kind: "completed", session: "s"), at: now)
        #expect(buddy.stage == .elder)
        #expect(buddy.treatBurstAt == nil)
    }
}
