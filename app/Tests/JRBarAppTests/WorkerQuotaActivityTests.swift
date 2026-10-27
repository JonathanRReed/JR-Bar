import Foundation
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Workers spend their own provider quota", .serialized)
@MainActor
struct WorkerQuotaActivityTests {
    static let stamp = UsageForecastSurfaceTests.stamp
    static let rootID = "claude:session:orchestrator"
    static let groupID = "group:" + rootID

    static func fixture(rootPresent: Bool = true, workerMode: String = "working", stale: Bool = false,
                        remote: Bool = false, linked: Bool = true) -> (PanelStore, UsageCenterStore, CoreProviderUsage) {
        let (panel, usage, provider) = UsageForecastSurfaceTests.fixture("runs out", providerID: "codex")
        let workers = (0..<4).map {
            CoreSession(id: (remote ? "remote:fixture:" : "") + "codex:session:worker-\($0)", provider: "codex", kind: "worker",
                        parent: linked ? rootID : nil, label: "Worker \($0)", mode: workerMode,
                        stale: stale, remote: remote, groupId: linked ? groupID : nil, unlinkedWorker: !linked)
        }
        let root = CoreSession(id: rootID, provider: "claude", label: "Orchestrator", mode: "working",
                               workers: 4, groupId: groupID)
        let sessions = (rootPresent ? [root] : []) + workers
        let groups = rootPresent && linked ? [CoreAgentGroup(id: groupID, rootWorkKey: rootID, rootProvider: "claude",
                                                            members: sessions.map(\.id), lineageEvidence: [])] : []
        panel.core.apply(.state(CoreState(aggregate: CoreAggregate(mode: "working", active: rootPresent ? 1 : 0),
                                          sessions: sessions, usage: CoreUsage(refreshedAt: stamp, providers: [provider]),
                                          agentGroups: groups)))
        return (panel, usage, provider)
    }

    @Test(arguments: [true, false])
    func workersKeepEveryQuotaSurfaceBurning(_ rootPresent: Bool) throws {
        let (panel, usage, provider) = Self.fixture(rootPresent: rootPresent)
        #expect(panel.core.sessions.allSatisfy { $0.provider != "codex" })
        #expect(UsageCenterStore.workingAgents(provider: "codex", core: panel.core) == 4)
        #expect(UsageCenterStore.workingAgents(provider: "claude", core: panel.core) == (rootPresent ? 1 : 0))
        let window = try #require(provider.windows.first)
        let reading = PanelProviderSection(store: panel, composition: PanelComposition(store: panel)).gauge(provider).reading(for: window)
        let inspection = UsageProviderDetail(provider: provider, store: usage, showCost: true).inspection(for: window)
        for forecast in [try #require(reading.forecast), inspection.displayForecast] {
            #expect(!forecast.heldIdle)
            #expect(forecast.isCritical)
            #expect(forecast.workingAgents == 4)
            #expect(forecast.projectedAtReset(now: Self.stamp) == 130)
            #expect(SessionAwarePace.roomForOneMore(forecast, now: Self.stamp) == false)
            #expect(UsageResetBudget.make(provider: provider, window: window, forecast: forecast,
                                         isLive: true, now: Self.stamp)?.exceedsBudget == true)
        }
        #expect(reading.footnote.hasPrefix("Runs out "))
        #expect(inspection.verdictText.hasPrefix("Runs out "))
        #expect(inspection.projectedText == "At this pace 130% by the reset")
        #expect(inspection.budget != nil)
        let meter = AppDelegate.statusMeter(for: provider, core: panel.core, now: Self.stamp)
        #expect(meter.paceVerdict == .runsOut)
        #expect(meter.fraction == 0.7)
        let notchMeters = NotchIsland.meters(panel.core.state?.usage)
        let notch = try #require(notchMeters.first)
        #expect(notch.percent == 70)
        #expect(notch.resetsAt == window.resetsAt)
        // Burners includes every local worker even without a main on this provider.
        #expect(UsageCenterStore.localQuotaSessions(provider: "codex", core: panel.core).count == 4)
        if rootPresent {
            #expect(panel.panelAgents.count == 1)
            #expect(panel.panelAgents.first?.members.count == 4)
            #expect(panel.panelAgents.first?.workerCount == 4)
        }
    }

    @Test(arguments: ["working", "completed", "ended", "idle", "stale", "remote", "unlinked"])
    func activityMatrix(_ state: String) throws {
        let mode = ["stale", "remote", "unlinked"].contains(state) ? "working" : state
        let (panel, usage, provider) = Self.fixture(workerMode: mode, stale: state == "stale",
                                                   remote: state == "remote", linked: state != "unlinked")
        let burns = ["working", "unlinked"].contains(state)
        let forecast = usage.forecast(for: provider, window: provider.windows[0])
        #expect(forecast.workingAgents == (burns ? 4 : 0))
        #expect(forecast.heldIdle == !burns)
        let window = provider.windows[0]
        let panelForecast = PanelProviderSection(store: panel, composition: PanelComposition(store: panel)).gauge(provider).reading(for: window).forecast
        let inspection = UsageProviderDetail(provider: provider, store: usage, showCost: true).inspection(for: window)
        #expect(panelForecast == forecast)
        #expect(inspection.displayForecast == forecast)
        #expect((inspection.projectedText != nil) == burns)
        #expect((inspection.budget != nil) == burns)
        #expect(AppDelegate.statusMeter(for: provider, core: panel.core, now: Self.stamp).paceVerdict == (burns ? .runsOut : .comfortable))
        #expect(UsageCenterStore.localQuotaSessions(provider: "codex", core: panel.core).count == (state == "remote" ? 0 : 4))
    }

    @Test(arguments: [true, false])
    func burnersRequestAndRankWorkers(_ rootPresent: Bool) async throws {
        let (panel, usage, provider) = Self.fixture(rootPresent: rootPresent, workerMode: "completed", stale: true)
        let expected = Set(panel.core.allSessions.filter { $0.provider == "codex" }.map(\.id))
        var requested: Set<String> = []
        var since: Double?
        usage.readBurnerUsage = { ids, start in
            requested = Set(ids)
            since = start
            let sessions = ids.map { ($0, SessionUsage(tokensSince: 100)) }
            return SessionUsageDocument(sessions: Dictionary(uniqueKeysWithValues: sessions))
        }
        let task = try #require(usage.loadBurners(for: provider))
        await task.value
        #expect(requested == expected)
        #expect(since == provider.windows[0].resetsAt.map { $0 - 5 * 3600 })
        let burners = usage.burners(for: provider)
        #expect(Set(burners.map(\.id)) == expected)
        #expect(burners.allSatisfy { $0.tokens == 100 && $0.share == 0.25 })
    }

    @Test func roomForAnotherAgentUsesEveryWorker() {
        let (panel, usage, original) = Self.fixture()
        var provider = original
        provider.forecast = CoreUsageForecast(pace: "under", ratePctPerHour: 6)
        let window = provider.windows[0]
        let forecast = usage.forecast(for: provider, window: window)
        #expect(forecast.workingAgents == 4)
        #expect(SessionAwarePace.roomForOneMore(forecast, now: Self.stamp) == true)
        let panelReading = PanelProviderSection(store: panel, composition: PanelComposition(store: panel)).gauge(provider).reading(for: window)
        #expect(panelReading.forecastHelp.contains("Room for one more agent"))
    }

    @Test func groupActivityDoesNotSpendTheIdleRootsQuota() throws {
        let (panel, _, codex) = Self.fixture()
        var sessions = panel.core.allSessions
        sessions[0].quotaWorking = false
        let claude = CoreProviderUsage(id: "claude", windows: codex.windows, fidelity: codex.fidelity,
                                       state: codex.state, forecast: codex.forecast, readAt: codex.readAt)
        let encoded = try JSONEncoder().encode(sessions[0])
        sessions[0] = try JSONDecoder().decode(CoreSession.self, from: encoded)
        panel.core.apply(.state(CoreState(sessions: sessions, usage: CoreUsage(providers: [claude, codex]),
                                          agentGroups: panel.core.state?.agentGroups ?? [])))
        #expect(UsageCenterStore.workingAgents(provider: "claude", core: panel.core) == 0)
        #expect(UsageCenterStore.workingAgents(provider: "codex", core: panel.core) == 4)
        #expect(AppDelegate.statusMeter(for: claude, core: panel.core, now: Self.stamp).paceVerdict == .comfortable)
        #expect(panel.panelAgents.count == 1)
        #expect(panel.panelHasRunningAgents)
        #expect(AgentUtility.snapshot(of: panel.core).reporting == ["claude", "codex"])
        #expect(SettingsCoreFacts(state: panel.core.state, lights: nil, live: true).runningProviders == ["claude", "codex"])
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func workerForecastRenderProof() throws {
        let (panel, usage, provider) = Self.fixture()
        try WindowsRenderProofTests.write("worker-quota-panel", size: CGSize(width: 372, height: 320), plate: .glass, requiresKey: false) {
            PanelView(store: panel, panelWidth: 372)
        }
        try WindowsRenderProofTests.write("worker-quota-usage", size: CGSize(width: 800, height: 820), requiresKey: false) {
            UsageProviderDetail(provider: provider, store: usage, showCost: true).padding(24)
        }
    }
}
