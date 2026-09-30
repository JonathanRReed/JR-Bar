import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// An ask JR-Bar already answered through the agent's own hook stays
/// "decided" until the agent's own events close the request. The daemon
/// publishes it `answerable: false`, keeps its command preview and
/// destructive mark, and the panel draws no Approve or Deny for it: it
/// says the agent is being waited for. Nothing here answers anything.
@Suite("Panel decided ask")
@MainActor
struct PanelDecidedAskTests {
    private static let decidedSession = "claude:session:decided"
    private static let openSession = "claude:session:open"

    /// The ask as the daemon publishes it once the answer went out.
    static func decidedAsk(_ session: String = decidedSession) -> CoreAsk {
        CoreAsk(session: session, kind: "permission", openedAt: 1_789_999_900, summary: "Run the cleanup",
                answerable: false, replyable: false, request: "r-decided",
                decision: CoreAskDecision(holdUntil: 2e9, always: false, decided: true),
                preview: "rm -rf build", risk: "destructive")
    }

    static func openAsk(_ session: String = openSession) -> CoreAsk {
        CoreAsk(session: session, kind: "permission", openedAt: 1_789_999_950, summary: "Run the tests",
                answerable: true, request: "r-open",
                decision: CoreAskDecision(holdUntil: 2e9, always: true), preview: "npm test")
    }

    private static func liveStore(_ asks: [CoreAsk]) -> PanelStore {
        let sessions = asks.map { ask in
            CoreSession(id: ask.session ?? "", provider: "claude", mode: "waiting", lifecycle: "active", ask: ask)
        }
        let (_, store) = PanelRowsMemoTests.liveStore(sessions)
        return store
    }

    @Test("no verb is offered for a decided ask, on any surface that reads AskVerbs")
    func noVerbIsOffered() {
        let decided = Self.decidedAsk()
        #expect(!AskVerbs.approves(decided))
        #expect(!AskVerbs.denies(decided))
        #expect(!AskVerbs.alwaysAllows(decided))
        #expect(!AskVerbs.chooses(decided))
        #expect(!AskVerbs.any(decided))
        for verdict in [AskVerdict.approve, .deny, .always, .reply("yes")] {
            #expect(!AskVerbs.allows(verdict, on: decided))
        }
        // The ask beside it still offers what it did.
        let open = Self.openAsk()
        #expect(AskVerbs.approves(open) && AskVerbs.denies(open) && AskVerbs.alwaysAllows(open))
        #expect(open.decidedLine == nil)
    }

    @Test("a decided ask keeps its card: still listed, still what it runs, still marked destructive")
    func cardIsKept() {
        let store = Self.liveStore([Self.decidedAsk(), Self.openAsk()])
        #expect(store.visibleAskRows.count == 2, "how many asks are shown is not changed here")
        let card = store.visibleAskRows.first { $0.id == Self.decidedSession }?.ask
        #expect(card?.previewLine == "rm -rf build")
        #expect(card?.isDestructive == true)
        #expect(card?.decidedLine == "Answered, waiting for the agent")
    }

    @Test("a chord with no selection never lands on a decided ask, so its key is left to others")
    func chordSkipsADecidedAsk() {
        let store = Self.liveStore([Self.decidedAsk()])
        #expect(store.visibleAskRows.count == 1)
        #expect(!store.approveSelectedAsk(), "nothing here can take a verdict")
        #expect(!store.denySelectedAsk())
        #expect(store.toast == nil)
    }

    @Test("a chord on a selected decided card says it is waiting, and sends nothing")
    func chordOnASelectedDecidedCard() {
        let store = Self.liveStore([Self.decidedAsk()])
        for _ in 0..<3 where store.selectedID != Self.decidedSession { store.moveSelection(by: 1) }
        #expect(store.selectedID == Self.decidedSession)
        let handled = store.approveSelectedAsk()
        #expect(handled, "the key is swallowed and explained")
        #expect(store.toast == "Answered, waiting for the agent")
        #expect(!store.isAnswerPending(Self.decidedAsk()), "no answer went on the wire")
        store.show(toast: "cleared")
        #expect(store.denySelectedAsk())
        #expect(store.toast == "Answered, waiting for the agent")
        #expect(!store.isAnswerPending(Self.decidedAsk()))
    }

    @Test("an older daemon that still calls a decided ask answerable is never sent a second verdict")
    func olderDaemonIsNotSentASecondVerdict() {
        var stale = Self.decidedAsk()
        stale.answerable = true
        #expect(stale.canAnswer && stale.isDecided)
        let store = Self.liveStore([stale])
        store.approve(stale)
        #expect(store.toast == "Answered, waiting for the agent")
        #expect(!store.isAnswerPending(stale))
        store.show(toast: "cleared")
        store.alwaysAllow(stale)
        #expect(store.toast == "Answered, waiting for the agent")
        #expect(!store.isAnswerPending(stale))
    }
}

/// A picture of the panel with a decided ask beside an open one. Off by
/// default; set `JRBAR_RENDER_PROOF=1` to write PNGs into
/// `JRBAR_RENDER_PROOF_DIR`.
@Suite("Panel decided ask render proof", .serialized)
@MainActor
struct PanelDecidedAskRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func decidedCardBesideAnOpenOne() throws {
        let now = WindowsRenderProofTests.t
        let decided = CoreAsk(session: "claude:cleanup", kind: "permission", openedAt: now - 95,
                              summary: "Clear the build folder before the release",
                              answerable: false, replyable: false, request: "r-decided",
                              decision: CoreAskDecision(holdUntil: now + 20, always: false, decided: true),
                              preview: "rm -rf build dist", risk: "destructive")
        let open = CoreAsk(session: "codex:tests", kind: "permission", openedAt: now - 12,
                           summary: "Run the test suite before the merge", answerable: true, request: "r-open",
                           decision: CoreAskDecision(holdUntil: now + 35, always: true),
                           preview: "npm test -- --runInBand")
        let sessions = [
            CoreSession(id: "claude:cleanup", provider: "claude", label: "release cleanup", cwd: "/demo/release",
                        mode: "waiting", since: now - 95, ask: decided),
            CoreSession(id: "codex:tests", provider: "codex", label: "merge check", cwd: "/demo/site",
                        mode: "waiting", since: now - 12, ask: open),
        ]
        let state = CoreState(now: now, aggregate: CoreAggregate(mode: "waiting", needsYou: 2),
                              sessions: sessions, asks: [decided, open],
                              devices: [WindowsRenderProofTests.devices[2]],
                              usage: WindowsRenderProofTests.usage(heavy: false))
        let store = WindowsRenderProofTests.panelStore(state)
        try WindowsRenderProofTests.write("panel-decided-ask", size: WindowsRenderProofTests.panelSize(store),
                                          plate: .glass) { WindowsRenderProofTests.panel(store) }
    }
}
