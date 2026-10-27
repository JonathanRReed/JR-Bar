import Foundation
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Burners use the panel's session titles", .serialized)
@MainActor
struct BurnerTitleTests {
    static let stamp = 1_800_000_000.0

    static func fixture() -> (CoreModel, UsageCenterStore, CoreProviderUsage) {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "burner-title-proof.sock")
        core.handle(.connected)
        let provider = CoreProviderUsage(id: "codex", windows: [CoreUsageWindow(name: "7d", usedPct: 63, resetsAt: stamp + 86400)],
                                         fidelity: "official", state: "ready", readAt: stamp)
        let heads = ["Sample app", "Sample service"].enumerated().map { index, label in
            CoreSession(id: "codex:session:aaaaaaaa-000\(index)-4000-8000-000000000000", provider: "codex", label: label,
                        mode: index == 1 ? "completed" : "working", groupId: "group-\(index)")
        }
        // Labels are daemon facts. The Python tests exercise their title and ordinal projection.
        let titles = ["Fix the notch caption", "Sample app worker 2", "Sample app worker 3", "Review the parser", "Sample service worker 2"]
        let workers = titles.enumerated().map { index, title in
            let group = index < 3 ? 0 : 1
            return CoreSession(id: "codex:session:bbbbbbb\(index)-0000-4000-8000-000000000000", provider: "codex", kind: "worker",
                               parent: heads[group].id, label: title, mode: "working", groupId: "group-\(group)")
        }
        let groups = heads.enumerated().map { index, head in
            CoreAgentGroup(id: "group-\(index)", rootWorkKey: head.id, rootProvider: "codex",
                           members: [head.id] + workers.filter { $0.parent == head.id }.map(\.id), lineageEvidence: [])
        }
        core.apply(.state(CoreState(sessions: heads + workers, usage: CoreUsage(refreshedAt: stamp, providers: [provider]), agentGroups: groups)))
        let store = UsageCenterStore(core: core)
        store.now = Date(timeIntervalSince1970: stamp)
        store.readBurnerUsage = { ids, _ in
            let readings = ids.filter { $0.contains("bbbbbbb") }.sorted().enumerated().map { index, id in
                (id, SessionUsage(tokensSince: [63_000_000, 49_000_000, 45_000_000, 42_000_000, 16_000_000][index]))
            }
            return SessionUsageDocument(sessions: Dictionary(uniqueKeysWithValues: readings))
        }
        return (core, store, provider)
    }

    @Test func titlesContextOrdinalsAndEndedHead() async throws {
        let (core, store, provider) = Self.fixture()
        await store.loadBurners(for: provider)?.value
        let burners = store.burners(for: provider)
        #expect(burners.count == 5)
        #expect(burners.map(\.label) == [
            "Fix the notch caption · under Sample app", "Sample app worker 2",
            "Sample app worker 3", "Review the parser · under Sample service",
            "Sample service worker 2",
        ])
        #expect(burners.map(\.tokens) == [63_000_000, 49_000_000, 45_000_000, 42_000_000, 16_000_000])
        #expect(abs(burners.reduce(0) { $0 + $1.share } - 1) < 0.000001)
        let panel = PanelStore(core: core, draftsDefaults: ScratchDefaults.open(ScratchDefaults.suiteName("burner-titles")), screenBarShown: false)
        let members = panel.panelAgents.flatMap(\.members)
        #expect(members.count == 5)
        for member in members {
            let burner = try #require(burners.first { $0.id == member.id })
            #expect(burner.label == member.label || burner.label.hasPrefix(member.label + " · under "))
            #expect(member.help(now: store.now)?.contains(member.id) == true)
        }
        for label in burners.map(\.label) + members.map(\.label) {
            #expect(label.range(of: #"\b[0-9a-fA-F]{8,}\b"#, options: .regularExpression) == nil)
        }
    }

    @Test func legacyIdsStayOutOfEveryAgentLabel() throws {
        let id = "codex:session:bbbbbbb0-0000-4000-8000-000000000000"
        for label in ["Sample worker bbbbbbb0", "Codex bbbbbbb0", "bbbbbbb0-0000-4000-8000-000000000000"] {
            let session = CoreSession(id: id, provider: "codex", label: label, shortId: "bbbbbbb0", mode: "working")
            let event = CoreEvent(id: "event", kind: "completed", session: id, label: label, provider: "codex")
            let notice = try #require(AlcoveEventPolicy.notice(for: event, session: session, kinds: AlcoveCapsuleKinds()))
            let row = SessionRow(session: session, pinnedAsk: nil)
            let notch = NotchIsland.summarize([session])
            let history = CoreHistoryRow(at: Self.stamp, kind: "completed", provider: "codex", session: id, label: label)
            let graph = OverviewGraphNode(CoreRosterEntry(session: session))
            let settings = SettingsDocument(.object(["completion_notification_enabled": .bool(true)]))
            let state = CoreState(sessions: [session])
            let delivery = EventPolicy.delivery(for: event, state: state, settings: settings)
            let banner = try #require(delivery.notification)
            let watched = try #require(AgentAlertRules.notifyWhenDone(.nothing, event: event, state: state).notification)
            let savedNotice = try #require(AlcoveEventPolicy.notice(for: event, session: nil, kinds: AlcoveCapsuleKinds()))
            let labels = [session.displayLabel, row.label, history.displayTitle, notice.title, savedNotice.title,
                          graph.label, LightLog.text(for: event), banner.title, watched.title] + notch.rows.map(\.label)
            for title in labels {
                #expect(title.range(of: #"\b[0-9a-fA-F]{8,}\b"#, options: .regularExpression) == nil)
            }
        }
    }

    @Test func burnerOpensItsExactSessionAndShowsRefusal() async throws {
        let (_, store, provider) = Self.fixture()
        await store.loadBurners(for: provider)?.value
        let burner = try #require(store.burners(for: provider).first)
        var opened: [String] = []
        store.openBurnerSession = { id in opened.append(id); return "Session has ended" }
        await store.openBurner(burner.id)?.value
        #expect(opened == [burner.id])
        #expect(store.burnerOpenNote == "Session has ended")
        #expect(store.openBurner("missing") == nil)
        store.openBurnerSession = { _ in nil }
        await store.openBurner(burner.id)?.value
        #expect(store.burnerOpenNote == nil)
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func codexDetailProof() async throws {
        let (_, store, provider) = Self.fixture()
        await store.loadBurners(for: provider)?.value
        #expect(store.burners(for: provider).count == 5)
        try WindowsRenderProofTests.write("codex-burner-titles", size: CGSize(width: 800, height: 1000), requiresKey: false) {
            UsageProviderDetail(provider: provider, store: store, showCost: false).padding(24)
        }
    }
}
