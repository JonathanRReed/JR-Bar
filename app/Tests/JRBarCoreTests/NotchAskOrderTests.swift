import Foundation
import Testing
@testable import JRBarCore

/// The notch card lists the ask that has waited longest first, as the
/// panel does, so "show the waiting ask" opens onto the oldest one.
@Suite("Notch ask order")
struct NotchAskOrderTests {
    private func waiting(_ id: String, label: String, openedAt: Double?) -> CoreSession {
        let ask = CoreAsk(session: id, kind: "permission", openedAt: openedAt, summary: "Run it",
                          answerable: true, request: "r-\(id)")
        return CoreSession(id: id, provider: "claude", label: label, mode: "waiting", since: openedAt, ask: ask)
    }

    @Test("waiting rows lead with the longest wait, then by name; an undated ask goes last")
    func oldestFirst() {
        let sessions = [
            waiting("claude:a", label: "alpha", openedAt: 300),
            waiting("claude:b", label: "bravo", openedAt: 100),
            waiting("claude:c", label: "charlie", openedAt: 200),
            waiting("claude:d", label: "delta", openedAt: nil),
            CoreSession(id: "claude:w", provider: "claude", label: "working one", mode: "working"),
        ]
        let summary = NotchIsland.summarize(sessions)
        #expect(summary.rows.map(\.label) == ["bravo", "charlie", "alpha", "delta", "working one"])
        #expect(summary.oldestWaiting == "claude:b")
    }

    @Test("equal waits still read by name, and working rows keep their name order")
    func ties() {
        let sessions = [
            waiting("claude:z", label: "zulu", openedAt: 100),
            waiting("claude:y", label: "yankee", openedAt: 100),
            CoreSession(id: "claude:2", provider: "claude", label: "two", mode: "working"),
            CoreSession(id: "claude:1", provider: "claude", label: "one", mode: "working"),
        ]
        #expect(NotchIsland.summarize(sessions).rows.map(\.label) == ["yankee", "zulu", "one", "two"])
    }
}
