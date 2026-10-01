import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// A picture of the panel's session rows when a parent's workers are
/// waiting on a quiet request: the busiest line a row has (the model name,
/// the workers badge, the waiting count, then a long folder tail), the same
/// parent with an activity fact and none waiting, and, with sub-agent asks
/// on, the worker's ask as a row of its own. Off by default; set
/// `JRBAR_RENDER_PROOF=1` to write PNGs into `JRBAR_RENDER_PROOF_DIR`.
@Suite("Workers waiting render proof", .serialized)
@MainActor
struct PanelWorkersWaitingRenderProofTests {
    private static let t = WindowsRenderProofTests.t

    private static func parent(_ id: String, label: String, cwd: String, workers: Int, waiting: Int?,
                               tool: String? = "Bash") -> CoreSession {
        CoreSession(id: id, provider: "claude", label: label, cwd: cwd, mode: "working", since: t - 640,
                    workers: workers, workersWaiting: waiting, tool: tool)
    }

    private static func panel(_ sessions: [CoreSession], asks: [CoreAsk] = [], needsYou: Int = 0) throws -> PanelStore {
        let state = CoreState(now: t, aggregate: CoreAggregate(mode: needsYou > 0 ? "needs_you" : "working",
                                                               needsYou: needsYou, active: 1),
                              sessions: sessions, asks: asks, devices: [WindowsRenderProofTests.devices[2]],
                              usage: WindowsRenderProofTests.usage(heavy: false))
        return WindowsRenderProofTests.panelStore(state)
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func rowsWithAWaitingCountAtTheRealPanelWidth() throws {
        let sessions = [
            // The busiest line: an activity fact, a waiting count and a folder.
            Self.parent("claude:busy", label: "quality pass", cwd: "/Users/me/src/jr-bar/app", workers: 3, waiting: 1),
            // A long folder tail, many workers, several waiting.
            Self.parent("claude:long", label: "migration of the billing service", cwd: "/Users/me/src/platform/services/billing-ledger",
                        workers: 12, waiting: 4),
            // The same shape with nothing waiting: the fact is back.
            Self.parent("claude:calm", label: "docs refresh", cwd: "/Users/me/src/site", workers: 3, waiting: 0),
            // An older daemon that does not say: as it always was.
            Self.parent("claude:old", label: "flaky ci", cwd: "/Users/me/src/api", workers: 2, waiting: nil),
        ]
        let store = try Self.panel(sessions)
        try WindowsRenderProofTests.write("workers-waiting-panel", size: WindowsRenderProofTests.panelSize(store),
                                          plate: .glass) { WindowsRenderProofTests.panel(store) }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func aWorkersAskIsARowOfItsOwnWhenWorkerAsksAreOn() throws {
        let ask = CoreAsk(session: "claude:agent:ci-worker", kind: "permission", openedAt: Self.t - 40,
                          summary: "Run the migration against the staging database", answerable: true,
                          request: "r-worker", preview: "make migrate STAGE=staging")
        let worker = CoreSession(id: "claude:agent:ci-worker", provider: "claude", kind: "worker",
                                 parent: "claude:busy", label: "quality pass worker c1d2e3f4",
                                 cwd: "/Users/me/src/jr-bar/app", mode: "waiting", since: Self.t - 40, ask: ask)
        let sessions = [
            Self.parent("claude:busy", label: "quality pass", cwd: "/Users/me/src/jr-bar/app", workers: 3, waiting: 0),
            worker,
        ]
        let store = try Self.panel(sessions, asks: [ask], needsYou: 1)
        try WindowsRenderProofTests.write("workers-waiting-on", size: WindowsRenderProofTests.panelSize(store),
                                          plate: .glass) { WindowsRenderProofTests.panel(store) }
    }
}
