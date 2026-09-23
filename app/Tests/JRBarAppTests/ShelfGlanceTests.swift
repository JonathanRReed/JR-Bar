import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The card's glances without EventKit: which events the calendar row
/// lists, and the switches that keep the rows (and their permission
/// asks) out of the card.
@Suite("Shelf glances")
@MainActor
struct ShelfGlanceTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func event(_ title: String, startIn minutes: Double, lasting: Double = 30) -> ShelfCalendarModel.Event {
        let start = now.addingTimeInterval(minutes * 60)
        return ShelfCalendarModel.Event(title: title, start: start,
                                        end: start.addingTimeInterval(lasting * 60), url: nil)
    }

    @Test("the next three timed events, soonest first; a running meeting stays, a finished one goes")
    func upcoming() {
        let list = [event("Later", startIn: 240), event("Standup", startIn: 10),
                    event("Running", startIn: -10, lasting: 30), event("Over", startIn: -60, lasting: 30),
                    event("Lunch", startIn: 120)]
        let picked = ShelfCalendarModel.upcoming(list, now: now, limit: ShelfCalendarModel.eventLimit)
        #expect(picked.map(\.title) == ["Running", "Standup", "Lunch"])
        #expect(ShelfCalendarModel.upcoming([], now: now, limit: 3).isEmpty)
    }

    @Test("a switched-off glance hides without ever asking")
    func switchedOff() {
        let calendar = ShelfCalendarModel()
        calendar.sync(enabled: false)
        #expect(calendar.state == .hidden)
        let reminders = ShelfRemindersModel()
        reminders.sync(enabled: false)
        #expect(reminders.state == .hidden)
    }

    @Test("the Mirror opens only when summoned and folds away with the card")
    func mirrorOnDemand() {
        var toys = ToysState()
        toys.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true, mirror: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: toys,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        defer { withExtendedLifetime(store) {} }
        let toy: NotchToy = store.notch
        toy.islandVisible = true

        toy.expandFromBand()
        #expect(!toy.cardModel.mirrorSummoned, "a plain open never starts the camera")
        toy.collapseFromBand()

        toy.summonMirror()
        #expect(toy.islandExpanded)
        #expect(toy.cardModel.mirrorSummoned)
        toy.collapseFromBand()
        #expect(!toy.cardModel.mirrorSummoned, "the lens folds away with the card")

        toy.expandFromBand()
        toy.cardModel.toggleMirror()
        #expect(toy.cardModel.mirrorSummoned, "the header's camera button opens it in place")
        toy.cardModel.toggleMirror()
        #expect(!toy.cardModel.mirrorSummoned)

        // The setting off: nothing can summon it.
        store.state.notch.mirror = false
        toy.cardModel.toggleMirror()
        #expect(!toy.cardModel.mirrorSummoned)
    }

    @Test("both glance switches default on and round-trip")
    func settings() throws {
        let fresh = NotchSettings()
        #expect(fresh.calendar)
        #expect(fresh.reminders)
        let old = try JSONDecoder().decode(NotchSettings.self, from: Data("{}".utf8))
        #expect(old.calendar && old.reminders, "a file from before the switches keeps its rows")
        var off = NotchSettings()
        off.calendar = false
        off.reminders = false
        let round = try JSONDecoder().decode(NotchSettings.self, from: JSONEncoder().encode(off))
        #expect(!round.calendar)
        #expect(!round.reminders)
    }
}
