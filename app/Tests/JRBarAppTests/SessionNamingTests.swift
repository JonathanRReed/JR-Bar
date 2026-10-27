import AppKit
import Foundation
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Session names across every output", .serialized)
@MainActor
struct SessionNamingTests {
    static let stamp = Date().timeIntervalSince1970
    static let cwd = "/synthetic/.t3/worktrees/Sample/t3-cafebabe"

    static var sessions: [CoreSession] {
        [
            CoreSession(id: "claude:session:aaaaaaaa-0000-4000-8000-000000000000", provider: "claude",
                        label: "Improve the panel", cwd: cwd, mode: "ended", since: stamp - 900, workers: 2, groupId: "sample-group"),
            CoreSession(id: "codex:session:bbbbbbbb-0000-4000-8000-000000000000", provider: "codex", kind: "worker",
                        parent: "claude:session:aaaaaaaa-0000-4000-8000-000000000000", label: "Install the sample build",
                        cwd: cwd, mode: "working", since: stamp - 600, groupId: "sample-group"),
            CoreSession(id: "codex:session:cccccccc-0000-4000-8000-000000000000", provider: "codex", kind: "worker",
                        parent: "claude:session:aaaaaaaa-0000-4000-8000-000000000000", label: "Improve the panel worker 2",
                        cwd: cwd, mode: "working", since: stamp - 500, groupId: "sample-group"),
            CoreSession(id: "factory:session:dddddddd-0000-4000-8000-000000000000", provider: "factory",
                        label: "Review the parser", cwd: "/synthetic/Sample/.worktrees/check", mode: "working", since: stamp - 400),
            CoreSession(id: "devin:session:sample-session", provider: "devin", label: "Check the keyboard flow",
                        cwd: "/synthetic/Sample/.claude/worktrees/check", mode: "working", since: stamp - 300),
            CoreSession(id: "t3code:session:eeeeeeee-0000-4000-8000-000000000000", provider: "t3code", label: "t3-",
                        cwd: "/synthetic/.t3/worktrees/Companion/t3-feedface", mode: "working", since: stamp - 200),
            CoreSession(id: "codex:session:ffffffff-0000-4000-8000-000000000000", provider: "codex", label: "Session",
                        cwd: "/synthetic/arbitrary-worktree", mode: "working", since: stamp - 100, project: "Sample"),
        ]
    }

    static var groups: [CoreAgentGroup] {
        [CoreAgentGroup(id: "sample-group", rootWorkKey: sessions[0].id, rootProvider: "claude",
                        members: Array(sessions.prefix(3)).map(\.id), lineageEvidence: [])]
    }

    static func fixture() -> (CoreModel, UsageCenterStore, CoreProviderUsage) {
        let provider = CoreProviderUsage(id: "codex", windows: [CoreUsageWindow(key: "7d", name: "7d", usedPct: 64, resetsAt: stamp + 86400)],
                                         fidelity: "official", state: "ready", account: UsageAccount(plan: "Pro", label: "sample@example.test"), readAt: stamp)
        let core = CoreModel(socketPath: "/nonexistent-names-proof.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(now: stamp, aggregate: CoreAggregate(mode: "working", active: 6), sessions: sessions,
                                   usage: CoreUsage(refreshedAt: stamp, providers: [provider]), agentGroups: groups)))
        let usage = UsageCenterStore(core: core)
        usage.now = Date(timeIntervalSince1970: stamp)
        usage.readBurnerUsage = { ids, _ in
            SessionUsageDocument(sessions: Dictionary(uniqueKeysWithValues: ids.map { ($0, SessionUsage(tokensSince: 120_000)) }))
        }
        return (core, usage, provider)
    }

    static func assertHuman(_ text: String, source: SourceLocation = #_sourceLocation) {
        #expect(!text.isEmpty, sourceLocation: source)
        #expect(text.range(of: #"\b[0-9a-fA-F]{8,}\b|^t3-|^session$|unknown project|/worktrees/|arbitrary-worktree"#,
                           options: [.regularExpression, .caseInsensitive]) == nil, sourceLocation: source)
    }

    @Test func missingProjectsNeverAppearInCurrentOrSavedLabels() {
        for label in [nil, "Session", "Codex session in Unknown project", "Codex session · 09:30"] {
            let name = SessionLabel.display(label: label, shortId: nil, id: "codex:session:synthetic", provider: "codex")
            Self.assertHuman(name)
            #expect(name == (label == "Codex session · 09:30" ? "Codex session · 09:30" : "Codex session"))
            let row = CoreHistoryRow(at: Self.stamp, kind: "completed", provider: "codex",
                                     session: "codex:session:synthetic", label: label)
            #expect(row.displayTitle == name)
        }
    }

    @Test func everyOutputUsesTheSharedTitle() async throws {
        let (core, usage, provider) = Self.fixture()
        await usage.loadBurners(for: provider)?.value
        let settings = SettingsDocument(.object(["completion_notification_enabled": .bool(true)]))
        for session in Self.sessions {
            let event = CoreEvent(id: "event", kind: "completed", session: session.id, label: session.label, provider: session.provider)
            let panel = SessionRow(session: session, pinnedAsk: nil)
            let history = CoreHistoryRow(at: Self.stamp, kind: "completed", provider: session.provider, session: session.id, label: session.displayLabel)
            let graph = OverviewGraphNode(CoreRosterEntry(session: session))
            let notice = try #require(AlcoveEventPolicy.notice(for: event, session: session, kinds: AlcoveCapsuleKinds()))
            let banner = try #require(EventPolicy.delivery(for: event, state: core.state!, settings: settings).notification)
            let watched = try #require(AgentAlertRules.notifyWhenDone(.nothing, event: event, state: core.state!).notification)
            var working = session
            working.mode = "working"
            let buddy = try #require(BuddyFocus.pick(from: [working]))
            let fish = try #require(AquariumModel.reduce(sessions: [working], previous: [], now: usage.now).first)
            let deck = DeckSlot(index: 0, identity: "synthetic", session: session.id, label: session.displayLabel, provider: session.provider)
            let surface = CoreLightSurface(program: "synthetic", why: "working",
                                           whyDetail: CoreWhyDetail(session: session.id, label: session.displayLabel, provider: session.provider))
            let light = try #require(LightExplainer.explain(lights: CoreLights(surfaces: ["screen_bar": surface]),
                                                          state: CoreState(sessions: [working]), settings: nil, now: usage.now))
            let labels = [session.displayLabel, panel.label, history.displayTitle, graph.label, notice.title,
                          banner.title, watched.title, buddy.session, fish.label, LightLog.text(for: event), deck.title, light.headline]
                + NotchIsland.summarize([working]).rows.map(\.label)
            for label in labels { Self.assertHuman(label) }
            #expect(panel.label == session.displayLabel)
            #expect(graph.label == session.displayLabel)
            #expect(history.displayTitle == session.displayLabel)
            #expect(buddy.session == session.displayLabel)
            #expect(fish.label == session.displayLabel)
            #expect(panel.help(now: usage.now)?.contains(session.id) == false)
        }
        for burner in usage.burners(for: provider) {
            Self.assertHuman(burner.label)
            #expect(burner.label == core.allSessions.first { $0.id == burner.id }?.displayLabel)
        }
        let overview = OverviewStore(core: core)
        overview.roster = Self.sessions.map { CoreRosterEntry(session: $0) }
        #expect(overview.projects == ["Companion", "Sample"])
        for label in ["Session", "session", "t3-", "t3-deadbeef", "Codex deadbeef"] {
            Self.assertHuman(SessionLabel.display(label: label, shortId: "deadbeef", id: "codex:session:deadbeef", provider: "codex", cwd: Self.cwd))
        }
    }

    @Test func savedHistoryDetailsCannotReintroduceIdsOrWorktreeNames() {
        for detail in ["Codex deadbeef", "t3-cafebabe", "Sample/t3-cafebabe"] {
            let row = CoreHistoryRow(at: Self.stamp, kind: "completed", provider: "codex",
                                     session: "codex:session:deadbeef", label: "Session", detail: detail)
            Self.assertHuman(row.displayTitle)
            #expect(row.displayDetail == nil)
        }
    }

    @Test func accountCaptionsShowPeopleAndKeepIdsOut() {
        var provider = Self.fixture().2
        #expect(UsageCenterStore.accountLine(provider, history: nil).contains("sample@example.test"))
        provider.account?.id = "synthetic-account-id"
        let facts = UsageProviderFacts(provider: provider, history: nil, providers: [provider], isLive: true, now: Date())
        #expect(facts.accountHelp == "synthetic-account-id")
        #expect(!facts.account.contains("synthetic-account-id"))
        provider.account?.label = "deadbeef-0000-4000-8000-000000000000"
        #expect(UsageCenterStore.accountLine(provider, history: nil) == "Pro · Official reading")
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func renderMissingProjectHistory() throws {
        let history = HistoryStore(core: CoreModel(socketPath: "/nonexistent-history-proof.sock"), schedulingEnabled: false)
        history.now = Date(timeIntervalSince1970: Self.stamp)
        history.loadedAt = history.now
        history.rows = ["Codex session in Unknown project", "Codex session · 09:30:00", "Codex session · 09:30:20"]
            .enumerated().map { index, label in
                CoreHistoryRow(at: Self.stamp - Double(index * 20), kind: "completed", provider: "codex",
                               session: "codex:session:synthetic-\(index)", label: label, duration: 30)
            }
        try WindowsRenderProofTests.write("missing-project-history", size: CGSize(width: 820, height: 760)) {
            HistoryView(store: history)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func renderNamesWithoutOpeningWindows() async throws {
        let (core, usage, provider) = Self.fixture()
        await usage.loadBurners(for: provider)?.value
        let history = HistoryStore(core: core, schedulingEnabled: false)
        history.now = usage.now
        history.loadedAt = usage.now
        history.rows = Self.sessions.enumerated().map { index, session in
            CoreHistoryRow(at: Self.stamp - Double(index * 65), kind: "completed", provider: session.provider,
                           session: session.id, label: session.displayLabel, duration: 90)
        }
        history.rows.insert(CoreHistoryRow(at: Self.stamp, kind: "completed", provider: "codex",
                                           session: "codex:session:synthetic", label: "Codex session in Unknown project"), at: 0)
        try WindowsRenderProofTests.write("names-history", size: CGSize(width: 820, height: 760)) { HistoryView(store: history) }
        try WindowsRenderProofTests.write("names-burners", size: CGSize(width: 760, height: 520)) {
            VStack(alignment: .leading, spacing: 24) {
                UsageProviderFactsView(facts: UsageProviderFacts(provider: provider, history: nil, providers: [provider], isLive: true, now: usage.now), showCost: false)
                UsageBurnersView(window: provider.windows[0], burners: usage.burners(for: provider))
            }.padding(24)
        }
        let overview = OverviewStore(core: core)
        overview.roster = Self.sessions.map { CoreRosterEntry(session: $0) }
        try WindowsRenderProofTests.write("names-projects", size: CGSize(width: 1120, height: 760)) { OverviewView(store: overview) }
        let panel = WindowsRenderProofTests.panelStore(core.state!)
        panel.now = usage.now
        panel.expandedAgentGroups = Set(panel.panelAgents.map(\.id))
        try WindowsRenderProofTests.write("names-panel", size: WindowsRenderProofTests.panelSize(panel), plate: .glass) {
            WindowsRenderProofTests.panel(panel)
        }
        var workerState = core.state!
        workerState.sessions = Array(Self.sessions.prefix(3))
        workerState.aggregate = CoreAggregate(mode: "working", active: 2)
        let workerPanel = WindowsRenderProofTests.panelStore(workerState)
        workerPanel.now = usage.now
        workerPanel.expandedAgentGroups = Set(workerPanel.panelAgents.map(\.id))
        try WindowsRenderProofTests.write("names-panel-workers", size: WindowsRenderProofTests.panelSize(workerPanel), plate: .glass) {
            WindowsRenderProofTests.panel(workerPanel)
        }
    }
}
