import Foundation
import JRBarCore
@testable import JRBarApp

/// The asks and the notch the decided-ask suites share. Synthetic
/// throughout: a session id, a summary and a command that mean nothing.
enum DecidedAskFixture {
    static let session = "claude:session:cleanup"
    /// What every surface says where the verbs were.
    static let words = "Answered, waiting for the agent"

    /// The ask as the daemon publishes it once the answer went out; the
    /// arguments say what an older daemon would still claim.
    static func decidedAsk(answerable: Bool? = false, replyable: Bool? = false,
                           always: Bool = false, choices: [CoreAskChoice] = []) -> CoreAsk {
        CoreAsk(session: session, kind: "permission", openedAt: 1_789_999_900, summary: "Run the cleanup",
                answerable: answerable, replyable: replyable, request: "r-decided",
                decision: CoreAskDecision(holdUntil: 2e9, always: always, decided: true, choices: choices),
                preview: "rm -rf build", risk: "destructive")
    }

    /// The decided ask from a daemon that predates the flag: it still
    /// says answerable, and the Always rule is still on offer.
    static func olderDaemonDecidedAsk() -> CoreAsk {
        decidedAsk(answerable: true, replyable: nil, always: true)
    }

    static func openAsk(always: Bool = true) -> CoreAsk {
        CoreAsk(session: session, kind: "permission", openedAt: 1_789_999_950, summary: "Run the tests",
                answerable: true, request: "r-open",
                decision: CoreAskDecision(holdUntil: 2e9, always: always), preview: "npm test")
    }

    static let pick = CoreAskChoice(question: "Which database?", options: ["Postgres", "SQLite"])

    /// A held question with choices: answered by an option, declined by Deny.
    static func heldQuestion() -> CoreAsk {
        CoreAsk(session: session, kind: "permission", summary: "AskUserQuestion", answerable: false,
                request: "r-question",
                decision: CoreAskDecision(holdUntil: 2e9, always: false, decided: false, choices: [pick]))
    }

    /// What a staged desk was asked to send: session, verdict, request pin.
    final class SentLog {
        var answers: [(String, AskVerdict, String?)] = []
    }

    /// A desk that records every send and answers ok. Its notes never
    /// arm a wall-clock timer.
    @MainActor
    static func desk(logging log: SentLog) -> AskAnswerDesk {
        let desk = AskAnswerDesk(send: { session, verdict, request in
            log.answers.append((session, verdict, request))
            return CoreReply(id: "1", ok: true)
        })
        desk.noteTimer = { _, _ in }
        return desk
    }

    /// A state with the session waiting and `ask` pinned in `state.asks`,
    /// the way the daemon carries it.
    static func state(holding ask: CoreAsk) -> CoreState {
        CoreState(sessions: [CoreSession(id: session, provider: "claude", label: "release cleanup",
                                         mode: "waiting", ask: CoreAsk(summary: ask.summary))],
                  asks: [ask])
    }

    /// The ask capsule the notch would latch for `ask`.
    static func capsule(_ ask: CoreAsk) -> AlcoveNotice {
        AlcoveNotice(id: "a", kind: .ask, title: "Claude · release cleanup", subtitle: "Run the cleanup",
                     session: session, key: "ask:\(session)|\(ask.request ?? "")",
                     ask: CoreAsk(session: session, summary: ask.summary, request: ask.request))
    }

    /// A notch toy over `state`, its desk staged so nothing leaves the
    /// process. The store is returned to keep it alive.
    @MainActor
    static func makeToy(state: CoreState) -> (NotchToy, ToysStore, AskAnswerDesk, SentLog) {
        var toys = ToysState()
        toys.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        core.apply(.state(state))
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: toys, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        let log = SentLog()
        let desk = desk(logging: log)
        toy.cardModel.askDesk = { desk }
        return (toy, store, desk, log)
    }
}
