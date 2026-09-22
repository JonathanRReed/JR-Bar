import Foundation
import Testing
@testable import JRBarCore

/// The live transcript's `session_timeline` items feed the same
/// reconstruction the archive does, so one view draws both.
@Suite("Live timeline reconstruction")
struct LiveTimelineReconstructionTests {
    static let items: [CoreTimelineItem] = [
        CoreTimelineItem(seq: 0, at: 100, kind: "message", role: "user", text: "fix the flake"),
        CoreTimelineItem(seq: 1, at: 101, kind: "tool_use", role: "assistant", name: "Bash", toolUseId: "t1", untrusted: false),
        CoreTimelineItem(seq: 2, at: 102, kind: "tool_result", text: "1 failed", toolUseId: "t1", isError: true, untrusted: true),
        CoreTimelineItem(seq: 3, at: 103, kind: "mystery"),
        CoreTimelineItem(seq: 4, at: 104, kind: "message", role: "assistant", text: "looking", sidechain: true, model: "claude-x"),
    ]

    @Test("kinds map one to one, unknown kinds drop out, fields carry over")
    func maps() {
        let reconstruction = SessionReconstructor.reconstruction(from: Self.items, gaps: ["timeline_item_cap:5000"], running: false)
        #expect(reconstruction.items.map(\.kind) == [.message, .toolUse, .toolResult, .message])
        #expect(reconstruction.items.map(\.seq) == [0, 1, 2, 4])
        #expect(reconstruction.items[2].isError)
        #expect(reconstruction.items[2].untrusted)
        #expect(reconstruction.items[3].sidechain)
        #expect(reconstruction.items[3].model == "claude-x")
        #expect(reconstruction.gaps == ["timeline_item_cap:5000"])
    }

    @Test("a finished transcript that stops mid-turn reads as a failure; a running one does not")
    func runningWithholdsTheMidTurnVerdict() {
        let quiet = [CoreTimelineItem(seq: 0, at: 1, kind: "message", role: "user", text: "go"),
                     CoreTimelineItem(seq: 1, at: 2, kind: "tool_use", name: "Edit", toolUseId: "e")]
        let ended = SessionReconstructor.reconstruction(from: quiet, running: false)
        #expect(ended.story.diedMidTurn)
        #expect(ended.story.failed)

        let running = SessionReconstructor.reconstruction(from: quiet, running: true)
        #expect(!running.story.diedMidTurn)
        #expect(!running.story.failed)
    }

    @Test("a real error still reads as a failure while the run goes on, and names the tool")
    func errorsStillCount() {
        let reconstruction = SessionReconstructor.reconstruction(from: Self.items, running: true)
        #expect(reconstruction.story.failed)
        #expect(reconstruction.story.failedToolNames == ["Bash"])
        #expect(reconstruction.story.lastUserIntent == "fix the flake")
    }
}
