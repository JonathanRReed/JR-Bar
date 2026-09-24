import CoreGraphics
import Testing
import JRBarCore
@testable import JRBarApp

/// The session rows' shared trailing column: sized by the words the list
/// shows, never by the clock.
@Suite("Panel session rows")
@MainActor
struct PanelSessionRowTests {
    @Test("working rows give their titles the room a waiting row's word would take")
    func workingRowsLeaveTheTitleRoom() {
        let working = SessionRowView.trailingWidth(for: [.working, .working])
        let waiting = SessionRowView.trailingWidth(for: [.working, .waiting])
        #expect(working < 96, "the old fixed column held back room for \"Waiting on you\"")
        #expect(waiting > working)
        let waitingWord = SessionRowView.wordWidths[.waiting] ?? 0
        #expect(waiting >= waitingWord + SessionRowView.markRoom)
    }

    @Test("the column always fits the longest elapsed time, so it never moves as the clock ticks")
    func elapsedAlwaysFits() {
        for activity in SessionActivity.allCases {
            #expect(SessionRowView.trailingWidth(for: [activity]) >= SessionRowView.elapsedWidth)
        }
        #expect(SessionRowView.trailingWidth(for: []) >= SessionRowView.elapsedWidth)
        #expect(SessionRowView.trailingWidth(for: [.done, .idle]) == SessionRowView.trailingWidth(for: [.idle]),
                "short words all rest on the elapsed floor")
    }
}
