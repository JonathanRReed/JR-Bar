import CoreGraphics
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The session rows' shared trailing column: sized by the words the list
/// shows and whether a row has gone quiet, never by the clock.
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

    @Test("a working row is quiet after ten minutes, unless a tool is still running")
    func quietAfterTenMinutesWithNoToolOpen() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func row(minutesAgo: Double, mode: String = "working", event: String? = "PostToolUse") -> SessionRow {
            SessionRow(session: CoreSession(id: "claude:r", provider: "claude", label: "r", mode: mode,
                                            since: now.timeIntervalSince1970 - minutesAgo * 60, event: event),
                       pinnedAsk: nil)
        }
        #expect(!row(minutesAgo: 9).isQuiet(now: now))
        #expect(row(minutesAgo: 10).quietText(now: now) == "Quiet 10m")
        #expect(row(minutesAgo: 12).help(now: now)?.contains("with no tool running") == true)
        // A long build says nothing for an hour and is not a stuck agent.
        let building = row(minutesAgo: 60, mode: "tool_running", event: "PreToolUse")
        #expect(building.openToolCall)
        #expect(!building.isQuiet(now: now))
        #expect(building.elapsedText(now: now)?.hasPrefix("quiet") == false)
        // The finishing event hands the row back to the clock.
        #expect(row(minutesAgo: 60, event: "PostToolUse").isQuiet(now: now))
    }

    @Test("a quiet working row's elapsed time fits the column whole")
    func quietElapsedFits() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func workingRow(_ id: String, minutesAgo: Double) -> SessionRow {
            SessionRow(session: CoreSession(id: id, provider: "claude", label: id, cwd: "/Users/me/src/\(id)",
                                            mode: "working", since: now.timeIntervalSince1970 - minutesAgo * 60),
                       pinnedAsk: nil)
        }
        let fresh = workingRow("fresh", minutesAgo: 5)
        #expect(!fresh.isQuiet(now: now))
        let plain = SessionRowView.trailingWidth(rows: [fresh], now: now)
        #expect(plain == SessionRowView.trailingWidth(for: [.working]))
        // An hour and five, a minute short of a day, three days.
        let ages: [Double] = [65, 1439, 4320]
        for minutes in ages {
            let silent = workingRow("silent", minutesAgo: minutes)
            let text = silent.elapsedText(now: now) ?? ""
            #expect(text.hasPrefix("Quiet "))
            let column = SessionRowView.trailingWidth(rows: [fresh, silent], now: now)
            #expect(column >= SessionRowView.elapsedTextWidth(text), "\"\(text)\" is cut short")
            #expect(column > plain, "the column widens once, when a row goes quiet")
        }
    }
}
