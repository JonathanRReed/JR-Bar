import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// A panel row for a view-only agent's waiting ask carries the app to
/// answer in, and its ask offers no verb at all.
@Suite("View-only ask rows")
@MainActor
struct ViewOnlyAskRowTests {
    @Test("a Gemini row with an unanswerable ask names its terminal and takes no verb")
    func geminiRow() throws {
        let json = #"{"id":"gemini:s1","provider":"gemini","terminal":{"app":"Ghostty"},"ask":{"kind":"permission","summary":"Run ls","answerable":false,"replyable":false}}"#
        let session = try JSONDecoder().decode(CoreSession.self, from: Data(json.utf8))
        let row = SessionRow(session: session, pinnedAsk: nil)
        #expect(row.answerHost == "Ghostty")
        let ask = try #require(row.ask)
        #expect(!AskVerbs.approves(ask))
        #expect(!AskVerbs.denies(ask))
        #expect(!AskVerbs.alwaysAllows(ask))
        #expect(!AskVerbs.any(ask))
        #expect(AskAnswerHost.line(host: row.answerHost) == "Answer this in Ghostty")
    }

    @Test("an orphan ask has no host to name")
    func orphanRow() {
        let ask = CoreAsk(session: "devin:s9", summary: "Run ls", answerable: false)
        let row = SessionRow(orphanAsk: ask)
        #expect(row.answerHost == nil)
        #expect(AskAnswerHost.buttonTitle(host: row.answerHost) == "Open session")
    }
}
