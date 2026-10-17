import Foundation
import Testing
@testable import JRBarCore

/// The "Try it" ask (`DemoAsk`): made inside the app, labelled as a demo,
/// and never sent to the daemon.
@Suite("Demo ask")
struct DemoAskTests {
    @Test("it says it is a demo, offers the verbs, and has something to expand")
    func looksLikeTheRealThing() {
        let ask = DemoAsk.make(now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(ask.isDemo)
        #expect(ask.summary == "Demo — this answers nothing")
        #expect(ask.canAnswer && !ask.wantsTextReply)
        #expect(ask.isDestructive, "the risk mark is part of what it teaches")
        #expect(ask.preview?.isEmpty == false)
        #expect(ask.hasDetail && !ask.isPlanApproval)
        #expect(ask.detail?.command?.contains("\n") == true, "multi-line, so the chevron has something to open")
        #expect(ask.openedAt == 1_790_000_000)
    }

    @Test("a real ask is never mistaken for it")
    func realAsksAreNotDemos() {
        #expect(!CoreAsk(session: "claude:session:abc", request: "request:v1:x").isDemo)
        #expect(!CoreAsk(session: nil).isDemo)
        #expect(CoreAsk(session: "other", request: DemoAsk.requestID).isDemo)
        #expect(DemoAsk.isDemo(session: DemoAsk.sessionID))
        #expect(!DemoAsk.isDemo(session: "claude:session:abc"))
        #expect(!DemoAsk.isDemo(session: nil))
    }

    @Test("the model refuses to put an answer for it on the socket")
    @MainActor
    func theModelNeverSendsIt() async throws {
        // Not connected: a real session would throw `notConnected`. The
        // demo is refused before the socket is ever looked at.
        let core = CoreModel()
        let approve = try await core.answerAskNow(session: DemoAsk.sessionID, approve: true,
                                                  request: DemoAsk.requestID)
        #expect(!approve.ok)
        #expect(approve.error?.code == "demo")
        let always = try await core.answerAskNow(session: DemoAsk.sessionID, decision: "always",
                                                 request: DemoAsk.requestID)
        #expect(always.error?.code == "demo")
        await #expect(throws: (any Error).self) {
            _ = try await core.answerAskNow(session: "claude:session:abc", approve: true)
        }
    }
}
