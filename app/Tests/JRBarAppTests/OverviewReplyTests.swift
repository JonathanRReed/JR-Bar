import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

@Suite("Overview replies")
@MainActor
struct OverviewReplyTests {
    private typealias Gate = OverviewLoadOrderTests.Gate<CoreReply>
    private static let session = "claude:session:reply"

    private func entry() -> CoreRosterEntry {
        CoreRosterEntry(session: CoreSession(
            id: Self.session, provider: "claude", label: "Branch notes", mode: "waiting",
            ask: CoreAsk(summary: "Which branch?", answerable: true, replyable: true, request: "reply-1")))
    }

    @Test("a reply uses the shared pending guard and keeps its request pin", .timeLimit(.minutes(10)))
    func sharedPendingReply() async {
        let gate = Gate()
        var sent: [(String, AskVerdict, String?)] = []
        let desk = AskAnswerDesk(send: { session, verdict, request in
            sent.append((session, verdict, request))
            return try await gate.request()
        })
        let store = OverviewStore(core: CoreModel(), desk: desk)
        store.fetchRoster = { throw CoreClientError.notConnected }
        let row = entry()
        let first = Task { await store.reply(entry: row, text: "  main  ") }
        await gate.untilRequests(1)
        #expect(desk.isPending(Self.session))
        let duplicate = await store.reply(entry: row, text: "another branch")
        #expect(!duplicate)
        #expect(store.actionStatus == "An answer is already on its way")
        #expect(sent.count == 1)
        #expect(sent.first?.0 == Self.session)
        #expect(sent.first?.1 == .reply("main"))
        #expect(sent.first?.2 == "reply-1")
        gate.answer(1, with: CoreReply(id: "reply", ok: true))
        #expect(await first.value)
        #expect(!desk.isPending(Self.session))
    }

    @Test("a blank reply sends nothing and returns a refusal")
    func blankReply() async {
        var sends = 0
        let desk = AskAnswerDesk(send: { _, _, _ in
            sends += 1
            return CoreReply(id: "reply", ok: true)
        })
        let store = OverviewStore(core: CoreModel(), desk: desk)
        let confirmed = await store.reply(entry: entry(), text: "  \n")
        #expect(!confirmed)
        #expect(sends == 0)
        #expect(store.actionIsError)
        #expect(store.actionStatus == "Type a reply first")
    }

    @Test("a disconnected reply stays unconfirmed and returns false")
    func disconnectedReply() async {
        let desk = AskAnswerDesk(send: { _, _, _ in throw CoreClientError.disconnected })
        let store = OverviewStore(core: CoreModel(), desk: desk)
        let confirmed = await store.reply(entry: entry(), text: "main")
        #expect(!confirmed)
        #expect(store.actionIsError)
        #expect(store.actionStatus == AskAnswerDesk.unconfirmedLine)
    }

    @Test("a confirmed reply returns its own result after another action changes the status")
    func replyResultSurvivesStatusChange() async {
        let desk = AskAnswerDesk(send: { _, _, _ in CoreReply(id: "reply", ok: true) })
        let store = OverviewStore(core: CoreModel(), desk: desk)
        store.fetchRoster = {
            store.actionIsError = true
            store.actionStatus = "Another action was refused"
            throw CoreClientError.notConnected
        }
        let confirmed = await store.reply(entry: entry(), text: "main")
        #expect(confirmed)
        #expect(store.actionIsError)
        #expect(store.actionStatus == "Another action was refused")
    }

    @Test("a reply outcome keeps its refusal after the roster status changes")
    func refusalOutcomeSurvivesStatusChange() async {
        let refusal = CoreReplyError(code: "stale_request", message: "The question changed")
        var sends = 0
        let desk = AskAnswerDesk(send: { _, _, _ in
            sends += 1
            return CoreReply(id: "reply", ok: false, error: refusal)
        })
        let store = OverviewStore(core: CoreModel(), desk: desk)
        let outcome = await store.replyOutcome(entry: entry(), text: "main")
        store.actionStatus = "Another action finished"

        #expect(!outcome.ok)
        #expect(outcome.code == "stale_request")
        #expect(outcome.line == NotchAskRefusal.line(for: refusal))
        #expect(ReplyPromptForm.failureText(for: outcome) == outcome.line)
        #expect(sends == 1)
    }

    @Test("an unconfirmed reply warns that it may have landed without sending again")
    func unconfirmedOutcome() async {
        var sends = 0
        let desk = AskAnswerDesk(send: { _, _, _ in
            sends += 1
            throw CoreClientError.disconnected
        })
        let store = OverviewStore(core: CoreModel(), desk: desk)
        let outcome = await store.replyOutcome(entry: entry(), text: "main")

        #expect(!outcome.ok)
        #expect(outcome.line == AskAnswerDesk.unconfirmedLine)
        #expect(ReplyPromptForm.failureText(for: outcome)
            == "Not confirmed. Your reply may have landed. Check the session before answering again.")
        #expect(sends == 1)
        #expect(!desk.isPending(Self.session))
    }

    @Test("a confirmed outcome survives a status change during the roster reload")
    func confirmedOutcomeSurvivesStatusChange() async {
        let desk = AskAnswerDesk(send: { _, _, _ in CoreReply(id: "reply", ok: true) })
        let store = OverviewStore(core: CoreModel(), desk: desk)
        store.fetchRoster = {
            store.actionIsError = true
            store.actionStatus = "Another action was refused"
            throw CoreClientError.notConnected
        }
        let outcome = await store.replyOutcome(entry: entry(), text: "main")

        #expect(outcome.ok)
        #expect(outcome.line != store.actionStatus)
        #expect(ReplyPromptForm.failureText(for: outcome) == nil)
    }
}
