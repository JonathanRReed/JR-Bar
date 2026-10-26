import Foundation
import SwiftUI
@testable import JRBarCore
import JRBarUI
import Testing
@testable import JRBarApp

@MainActor
@Suite struct U5BehaviorTests {
    @Test func historyCompletionDuringAChartReadLoadsTheNewestChart() async throws {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-u5-graph.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        let store = UsageCenterStore(core: core)
        store.readProviderRows = { [] }
        store.readResetStatus = { _ in CoreReply(id: "fixture", ok: true) }
        var first: CheckedContinuation<CoreUsageGraphDocument, Never>?
        var calls = 0
        store.readOverviewGraph = {
            calls += 1
            if calls == 1 { return await withCheckedContinuation { first = $0 } }
            var newest = CoreUsageGraph()
            newest.periodLabel = "newest"
            return CoreUsageGraphDocument(graph: newest, summary: "")
        }
        store.windowDidOpen()
        defer { store.windowDidClose() }
        let job = try #require(store.loadOverviewGraph())
        for _ in 0..<50 {
            if first != nil { break }
            await Task.yield()
        }
        let reply = try #require(first)
        store.loadOverviewGraph(force: true)
        var previous = CoreUsageGraph()
        previous.periodLabel = "previous"
        reply.resume(returning: CoreUsageGraphDocument(graph: previous, summary: ""))
        await job.value
        #expect(calls == 2)
        #expect(store.overviewGraph?.periodLabel == "newest")
    }

    @Test func chartAxesUseOneTwoFiveStepsAndTooltipStaysInside() {
        for maximum in [0.0, 1, 19, 1250, 50000, 999999] {
            let axis = UsageChartAxis(maximum: maximum)
            let order = pow(10, floor(log10(axis.step)))
            #expect([1.0, 2, 5].contains(axis.step / order))
            #expect(axis.maximum >= maximum)
            #expect(axis.ticks.first == 0)
        }
        #expect(UsageChartAxis.tooltipCenter(x: -100, width: 200, bounds: 10...510) == 110)
        #expect(UsageChartAxis.tooltipCenter(x: 900, width: 200, bounds: 10...510) == 410)
        #expect(UsageChartAxis.tooltipCenter(x: 20, width: 200, bounds: 10...110) == 60)
    }

    @Test func provenGroupsCountOnceAndWorkerAsksStayIndividual() throws {
        let group = try JSONDecoder().decode(CoreAgentGroup.self, from: Data(#"{"id":"fixture-group","root_work_key":"claude:root","root_provider":"claude","members":["claude:root","codex:worker"],"lineage_evidence":[]}"#.utf8))
        let root = CoreSession(id: "claude:root", provider: "claude", label: "Sample project", mode: "working")
        let worker = CoreSession(id: "codex:worker", provider: "codex", kind: "worker", parent: root.id, mode: "working")
        let unlinked = CoreSession(id: "codex:unlinked", provider: "codex", mode: "working", unlinkedWorker: true)
        let summary = NotchIsland.summarize([root, unlinked], groups: [group], allSessions: [root, worker, unlinked])
        #expect(summary.working == 1)
        #expect(summary.workingProviders == ["claude"])
        #expect(summary.rows.first(where: { $0.id == root.id })?.workerCount == 1)
        #expect(summary.rows.first(where: { $0.id == unlinked.id })?.unlinked == true)
        let ask = CoreAsk(session: worker.id, openedAt: 1, summary: "Run tests?", answerable: true)
        var asking = worker
        asking.ask = ask
        asking.mode = "waiting"
        let waiting = NotchIsland.summarize([root, asking], asks: [ask], groups: [group], allSessions: [root, asking])
        #expect(waiting.working == 1)
        #expect(waiting.waiting == 1)
        #expect(waiting.rows.contains { $0.id == worker.id && $0.ask == ask })
    }

    @Test func newProvidersGetANoticeWithoutReopeningSetupOrGrantingConsent() {
        let store = SetupStore(load: { SetupState(finishedAt: 1) }, persist: { _ in })
        var found: [String] = []
        store.onNewProvider = { found.append($0.id) }
        let claude = SetupAgent(id: "claude", name: "Claude", detected: true, hookStatus: nil)
        let codex = SetupAgent(id: "codex", name: "Codex", detected: true, hookStatus: nil)
        store.reconcileInstalledProviders([claude])
        #expect(found.isEmpty)
        store.reconcileInstalledProviders([claude, codex])
        store.reconcileInstalledProviders([claude, codex])
        #expect(found == ["codex"])
        #expect(!store.shouldPresentOnLaunch)
        #expect(store.usageChoices.isEmpty)
    }

    @Test func localHistoryFailuresStaySeparateFromQuota() {
        var provider = CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(name: "5h", usedPct: 42)])
        for state in ["building", "stale", "failed", "disk_full", "damaged", "over_cap"] {
            provider.tokenHistoryState = state
            let presentation = UsageHistoryPresentation.state(provider: provider, history: nil, disabled: false,
                loading: false, scanning: false, error: nil)
            #expect(presentation != nil)
            #expect(provider.windows.first?.usedPct == 42)
        }
        #expect(UsageHistoryPresentation.state(provider: provider, history: nil, disabled: true,
            loading: false, scanning: false, error: nil)?.title == "Token history is off")
    }

    @Test func whatsNewWaitsForAsksAndLeadsWithMix() {
        #expect(WhatsNewCatalog.entries.map(\.id) == ["mix", "agent-groups", "claude-sign-in", "lighter", "studio"])
        #expect(WhatsNewCatalog.measurementTODO.hasPrefix("TODO:"))
        #expect(!WhatsNewGate.isRight(.init(coreLive: true, locked: false, fullScreenInFront: false, asksWaiting: true)))
    }
}
