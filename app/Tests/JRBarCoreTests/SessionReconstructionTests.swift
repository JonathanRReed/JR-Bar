import Foundation
import Testing
@testable import JRBarCore

/// The FailureStory derived from reconstructed items. All fixtures are
/// synthetic.
@Suite("Session reconstruction")
struct SessionReconstructionTests {

    @Test("failure lookup keeps the first tool use even when its name is missing")
    func firstToolUseWins() {
        let items = [
            ReconstructedItem(seq: 0, kind: .toolUse, toolUseID: "duplicate"),
            ReconstructedItem(seq: 1, kind: .toolUse, name: "later name", toolUseID: "duplicate"),
            ReconstructedItem(seq: 2, kind: .toolUse, name: "first", toolUseID: "a"),
            ReconstructedItem(seq: 3, kind: .toolUse, name: "second", toolUseID: "b"),
            ReconstructedItem(seq: 4, kind: .toolResult, toolUseID: "b", isError: true),
            ReconstructedItem(seq: 5, kind: .toolResult, toolUseID: "a", isError: true),
            ReconstructedItem(seq: 6, kind: .toolResult, toolUseID: "b", isError: true),
            ReconstructedItem(seq: 7, kind: .toolResult, toolUseID: "duplicate", isError: true),
        ]
        let result = SessionReconstructor.story(for: items)
        #expect(result.failedToolNames == ["second", "first"])
        #expect(result.lastErrorSummary == "tool call failed")
        #expect(result.errorCount == 4)
    }

    @Test("a clean session reports failed=false")
    func cleanStory() {
        let items = [
            ReconstructedItem(seq: 0, kind: .message, role: "user", text: "do the work"),
            ReconstructedItem(seq: 1, kind: .message, role: "assistant", text: "done"),
            ReconstructedItem(seq: 2, kind: .turnEnd, name: "end_turn"),
        ]
        let story = SessionReconstructor.story(for: items)
        #expect(story.failed == false)
        #expect(story.errorCount == 0)
        #expect(story.diedMidTurn == false)
        #expect(story.lastErrorSummary == nil)
        #expect(story.failedToolNames.isEmpty)
        #expect(story.lastUserIntent == "do the work")
    }

    @Test("a transcript ending on tool_use died mid-turn")
    func diedMidTurn() {
        let items = [
            ReconstructedItem(seq: 0, kind: .message, role: "user", text: "run it"),
            ReconstructedItem(seq: 1, kind: .toolUse, name: "Bash", toolUseID: "t1"),
        ]
        let story = SessionReconstructor.story(for: items)
        #expect(story.failed)
        #expect(story.diedMidTurn)
        #expect(story.errorCount == 0)
        #expect(SessionReconstructor.story(for: items, running: true).failed == false)
    }
}
