import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Overview reply render proof")
@MainActor
struct OverviewReplyRenderProofTests {
    private static let draft = "Use the main branch. Keep the local changes."

    private func entry() -> CoreRosterEntry {
        CoreRosterEntry(session: CoreSession(
            id: "claude:session:reply-proof", provider: "claude", label: "Branch notes", mode: "waiting",
            ask: CoreAsk(summary: "Which branch should I use?", answerable: true,
                         replyable: true, request: "reply-proof-1")))
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func refusedDraft() async throws {
        let desk = AskAnswerDesk(send: { _, _, _ in
            CoreReply(id: "reply", ok: false,
                      error: CoreReplyError(code: "stale_request", message: "The question changed"))
        })
        let store = OverviewStore(core: CoreModel(), desk: desk)
        let row = entry()
        let outcome = await store.replyOutcome(entry: row, text: Self.draft)
        #expect(!outcome.ok)
        try write("overview-reply-refused", row: row, outcome: outcome)
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func unconfirmedDraft() async throws {
        let desk = AskAnswerDesk(send: { _, _, _ in throw CoreClientError.disconnected })
        let store = OverviewStore(core: CoreModel(), desk: desk)
        let row = entry()
        let outcome = await store.replyOutcome(entry: row, text: Self.draft)
        #expect(outcome.line == AskAnswerDesk.unconfirmedLine)
        try write("overview-reply-unconfirmed", row: row, outcome: outcome)
    }

    private func write(_ name: String, row: CoreRosterEntry,
                       outcome: AskAnswerDesk.Outcome) throws {
        try WindowsRenderProofTests.write(name, size: CGSize(width: 420, height: 340)) {
            ReplyPromptForm(entry: row, text: .constant(Self.draft), sending: false, outcome: outcome,
                            onCancel: {}, onSend: {}, snapshot: true)
        }
    }
}
