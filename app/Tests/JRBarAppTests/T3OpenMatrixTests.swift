import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Session Open origins and entry points", .timeLimit(.minutes(2)))
@MainActor
struct T3OpenMatrixTests {
    enum Origin: String, CaseIterable, Sendable {
        case codexCLI, codexApp, codexT3, claudeT3, t3Native, unprovenWorker, t3WithoutEnvironment

        var provider: String { self == .claudeT3 ? "claude" : "codex" }
        var target: String? {
            switch self {
            case .codexT3, .claudeT3, .t3Native: "t3code://threads/env-1/thread-1"
            case .t3WithoutEnvironment: "com.t3tools.t3code"
            default: nil
            }
        }
        var targetKind: String { self == .t3WithoutEnvironment ? "app" : "url" }
    }

    enum Surface: String, CaseIterable, Sendable {
        case notch, panel, statusMenu, notification, overview, history, streamDeck, jrbarLink
    }

    private func session(_ origin: Origin) throws -> CoreSession {
        var document: [String: Any] = [
            "id": "\(origin.provider):session:synthetic", "provider": origin.provider,
            "mode": "waiting", "label": "Synthetic task"
        ]
        if let target = origin.target {
            let reason = origin == .t3WithoutEnvironment ? "t3_environment_missing" : "t3_thread"
            document["open_target"] = ["kind": origin.targetKind, "value": target, "reason": reason]
            document["open_target_reason"] = reason
        } else {
            document["open_target_reason"] = origin == .unprovenWorker
                ? "unproven_worker_provider_route" : "provider_route"
        }
        return try JSONDecoder().decode(CoreSession.self, from: JSONSerialization.data(withJSONObject: document))
    }

    @Test("each UI entry point sends the same session command and retains the daemon's target",
          arguments: Origin.allCases, Surface.allCases)
    func opens(_ origin: Origin, _ surface: Surface) async throws {
        let row = try session(origin)
        let core = CoreModel()
        core.apply(.state(CoreState(sessions: [row])))
        var commands: [String] = []
        var targets: [String?] = []
        let sent = TestEvents<Void>()
        let wiring = SessionOpener.Wiring(send: { id in
            commands.append("open_session:\(id)")
            targets.append(row.openTarget?.value)
            sent.send(())
            return CoreReply(id: "synthetic", ok: true)
        }, sessions: { [row] }, raise: { _ in
            Issue.record("A successful Open must not raise another window")
            return false
        })
        let open: @MainActor (String) async -> String? = { await SessionOpener.open($0, via: wiring) }
        switch surface {
        case .notch:
            let presenter = NotchCardPresenter(model: makeTestCardModel())
            presenter.presentationEnabled = false
            presenter.openSession = open
            await presenter.open(row.id).value
        case .panel:
            let suite = ScratchDefaults.suiteName("t3-open-matrix")
            defer { ScratchDefaults.remove(suite) }
            let panel = PanelStore(core: core, draftsDefaults: ScratchDefaults.open(suite), screenBarShown: false)
            panel.opener = open
            panel.panelDidOpen()
            await withCheckedContinuation { continuation in
                panel.onClose = { continuation.resume() }
                panel.open(SessionRow(session: row, pinnedAsk: nil))
            }
            panel.panelDidClose()
        case .statusMenu:
            let buddy = NotchBuddyToy(core: core, notificationCenter: NotificationCenter(),
                                     workspaceCenter: NotificationCenter())
            defer { buddy.shutdown() }
            buddy.openSession = open
            #expect(buddy.openAskingSession(id: row.id))
            let pending = try #require(buddy.openInFlight)
            await pending.value
        case .notification:
            let coordinator = EventCoordinator(core: core, hudAnchor: { nil })
            coordinator.sessionOpener = open
            coordinator.notifications.onOpenSession?(row.id)
            _ = try await sent.next()
        case .overview:
            let overview = OverviewStore(core: core)
            overview.opener = open
            await overview.openSession(row.id)
        case .history:
            let history = HistoryStore(core: core, schedulingEnabled: false)
            history.opener = open
            await history.open(session: row.id)
        case .streamDeck:
            let deck = DeckStore(core: core)
            deck.opener = open
            await deck.openSession(row.id)
        case .jrbarLink:
            let router = AppCommandRouter()
            var pending: Task<Void, Never>?
            router.openSession = { id in
                pending = Task { _ = await open(id) }
                return nil
            }
            let command = try #require(AppCommand.parse(AppCommand.openSession(row.id).link))
            _ = await router.perform(command)
            await pending?.value
        }
        #expect(commands == ["open_session:\(row.id)"])
        #expect(targets.count == 1)
        #expect(targets.first == origin.target)
        #expect(row.openTarget?.kind == (origin.target == nil ? nil : origin.targetKind))
    }

    @Test("a T3 refusal cannot fall back to a provider window", arguments: Origin.allCases)
    func refusesWrongWindow(_ origin: Origin) async throws {
        let row = try session(origin)
        var raised = false
        let reply = CoreReply(id: "synthetic", ok: false,
                              error: CoreReplyError(code: "not_found", message: "Synthetic open refusal"))
        let wiring = SessionOpener.Wiring(send: { _ in reply }, sessions: { [row] }, raise: { _ in
            raised = true
            return false
        })
        #expect(await SessionOpener.open(row.id, via: wiring) == "Synthetic open refusal")
        #expect(raised == (origin.target == nil))
    }
}
