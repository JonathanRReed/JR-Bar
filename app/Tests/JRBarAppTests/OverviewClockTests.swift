import Foundation
import JRBarCore
import Observation
import Testing
@testable import JRBarApp

/// The Overview's one-second clock re-renders the cells that draw it and
/// nothing else: the connections strip, and the window root that asks
/// for the selected link, move only when a chip's words would.
@Suite("Overview clock")
@MainActor
struct OverviewClockTests {
    final class Tripped: @unchecked Sendable { var fired = false }

    func wakes(_ read: () -> Void, when change: () -> Void) -> Bool {
        let tripped = Tripped()
        withObservationTracking(read) { tripped.fired = true }
        change()
        return tripped.fired
    }

    /// A minute's first second, so a one-second step stays inside it.
    static let start = Date(timeIntervalSince1970: 1_790_000_040)

    static func tick(_ store: OverviewStore, to date: Date) {
        store.now = date
        store.advanceLinksClock(to: date)
    }

    @Test("a tick inside the minute leaves the links alone")
    func tickLeavesLinks() {
        let store = OverviewStore(core: CoreModel(socketPath: "/tmp/jrbar-test-none.sock"))
        Self.tick(store, to: Self.start)
        #expect(!wakes({ _ = store.links; _ = store.selectedLink },
                       when: { Self.tick(store, to: Self.start.addingTimeInterval(1)) }))
        #expect(wakes({ _ = store.links },
                      when: { Self.tick(store, to: Self.start.addingTimeInterval(60)) }),
                "a new minute can change a chip's age")
    }

    @Test("the table's clock cells are the tick's readers")
    func cellsReadTheClock() {
        let session = CoreSession(id: "claude:s1", provider: "claude", label: "synthetic",
                                  mode: "working", since: Self.start.timeIntervalSince1970 - 30)
        let entry = CoreRosterEntry(session: session)
        #expect(OverviewQuietCell.text(entry, now: Self.start) == "30s")
        #expect(OverviewQuietCell.text(entry, now: Self.start.addingTimeInterval(1)) == "31s")
    }
}
