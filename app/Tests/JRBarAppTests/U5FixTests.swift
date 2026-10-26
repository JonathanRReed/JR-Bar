import Foundation
@testable import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite struct U5FixTests {
    @Test func chartPreparationSurvivesSelectionAndClockTicks() {
        let store = UsageCenterStore(core: CoreModel())
        let history = UsageHistory(provider: "claude", range: "30d", days: [
            UsageHistoryDay(date: "2026-10-01", tokensIn: 100, tokensOut: 20, cacheRead: 500),
            UsageHistoryDay(date: "2026-10-03", tokensIn: 200, tokensOut: 30, cacheRead: 900),
        ])
        let cache = store.chartCache
        let prepared = cache.history(history, range: .month, metric: .tokens, hidden: ["Cache reads"])
        #expect(prepared.visible.count == 4)
        #expect(prepared.totals["Cache reads"] == 1400)
        for tick in 0..<100 {
            store.now = Date(timeIntervalSince1970: Double(tick))
            let data = cache.history(history, range: .month, metric: .tokens, hidden: ["Cache reads"])
            #expect(data.nearest(to: prepared.dates[0].addingTimeInterval(Double(tick))) == prepared.dates[0])
            #expect(data.axis == prepared.axis)
        }
        #expect(cache.historyPreparations == 1)
        #expect(prepared.nearest(to: .distantPast) == prepared.dates.first)
        #expect(prepared.nearest(to: .distantFuture) == prepared.dates.last)
        #expect(prepared.nearest(to: prepared.dates.last) == prepared.dates.last)
        _ = cache.history(history, range: .month, metric: .tokens, hidden: [])
        #expect(cache.historyPreparations == 2)
        #expect(cache.historyPointPreparations == 1, "changing visibility reuses parsed points")
        _ = cache.history(history, range: .month, metric: .cost, hidden: [])
        #expect(cache.historyPreparations == 3)
        var changed = history
        changed.days[0].tokensIn = 300
        _ = cache.history(changed, range: .month, metric: .tokens, hidden: [])
        #expect(cache.historyPreparations == 4)

        var graph = CoreUsageGraph()
        graph.series = [.init(providerId: "claude", values: [10, 20, -1, 30])]
        for tick in 0..<100 {
            store.now = Date(timeIntervalSince1970: Double(tick))
            let data = cache.overview(graph, hidden: [])
            #expect(data.totals["claude"] == 60)
            #expect(data.byDay[2] == nil)
        }
        #expect(cache.overviewPreparations == 1)
        _ = cache.overview(graph, hidden: ["claude"])
        #expect(cache.overviewPreparations == 2)
        #expect(cache.overviewPointPreparations == 1)
    }

    @Test func overviewContinuesPartialReadsAtAPacedSingleRequest() async throws {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-u5-continuation.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        let store = UsageCenterStore(core: core)
        store.readProviderRows = { [] }
        store.readResetStatus = { _ in CoreReply(id: "fixture", ok: true) }
        var scheduled: [@MainActor () -> Void] = []
        store.scheduleOverviewContinuation = { scheduled.append($0) }
        var reads = 0
        var active = 0
        store.readOverviewGraph = {
            reads += 1
            active += 1
            #expect(active == 1)
            defer { active -= 1 }
            var graph = CoreUsageGraph()
            graph.readingFiles = reads < 3 ? 2 : 0
            return CoreUsageGraphDocument(graph: graph, summary: "")
        }
        store.windowDidOpen()
        defer { store.windowDidClose() }
        await store.loadOverviewGraph()?.value
        #expect(reads == 1)
        #expect(scheduled.count == 1)
        scheduled.removeFirst()()
        await store.loadOverviewGraph()?.value
        #expect(reads == 2)
        #expect(scheduled.count == 1)
        store.windowDidClose()
        scheduled.removeFirst()()
        #expect(reads == 2, "closing retires the pending continuation")
        store.windowDidOpen()
        await store.loadOverviewGraph()?.value
        #expect(reads == 3)
        #expect(scheduled.isEmpty)
    }

    @Test(arguments: [false, true])
    func keyboardFromOpenCardStartsAtFirstAskAndTabsWithoutTakeoverSpeech(hasCapsule: Bool) {
        let first = CoreAsk(session: "claude:first", openedAt: 1, summary: "Run tests?", answerable: true, request: "one")
        let second = CoreAsk(session: "codex:second", openedAt: 2, summary: "Run checks?", answerable: true, request: "two")
        let state = CoreState(sessions: [
            CoreSession(id: "claude:first", provider: "claude", ask: first),
            CoreSession(id: "codex:second", provider: "codex", ask: second),
        ], asks: [first, second])
        let (toy, owner, _) = NotchSurfaceRenderProofTests.makeToy(state: state)
        defer { withExtendedLifetime(owner) {} }
        var spoken: [String] = []
        if hasCapsule {
            toy.offer(AlcoveNotice(id: "old", kind: .ask, title: "Old ask", subtitle: "Run tests?", session: first.session,
                key: "old", ask: first, takeover: true))
        }
        toy.speak = { spoken.append($0) }
        toy.expand(held: true)
        #expect(toy.engageAskKeyboard())
        #expect(toy.activeCapsule?.session == first.session)
        toy.askKey(.tab)
        #expect(toy.activeCapsule?.session == second.session)
        #expect(toy.capsuleQueue.current?.session == second.session)
        #expect(toy.activeCapsule?.takeover == false)
        #expect(spoken.count == 2)
        #expect(spoken.allSatisfy { !$0.contains("needs you") })
        toy.askKey(.backTab)
        #expect(toy.activeCapsule?.session == first.session)
    }

    @Test func incompleteDetectionNeverCommitsOrAnnounces() {
        var commits = 0
        var found: [String] = []
        let store = SetupStore(load: { SetupState(finishedAt: 1) }, persist: { _ in commits += 1 })
        store.onNewProvider = { found.append($0.id) }
        let claude = SetupAgent(id: "claude", name: "Claude", detected: true, hookStatus: nil)
        var codex = SetupAgent(id: "codex", name: "Codex", detected: nil, hookStatus: nil)
        store.reconcileInstalledProviders([claude, codex])
        #expect(commits == 0)
        codex.detected = true
        store.reconcileInstalledProviders([claude, codex])
        #expect(commits == 1)
        #expect(found.isEmpty)
        var gemini = SetupAgent(id: "gemini", name: "Gemini", detected: nil, hookStatus: nil)
        store.reconcileInstalledProviders([claude, codex, gemini])
        #expect(commits == 1)
        gemini.detected = true
        store.reconcileInstalledProviders([claude, codex, gemini])
        #expect(found == ["gemini"])
    }

    @Test func defaultHoverMigrationPreservesCustomDelays() throws {
        for (saved, expected) in [(0.12, 0.15), (0.0, 0.0), (0.24, 0.24), (0.15, 0.15)] {
            let data = Data("{\"hoverOpenDelay\":\(saved)}".utf8)
            let settings = try JSONDecoder().decode(NotchSettings.self, from: data)
            #expect(settings.hoverOpenDelay == expected)
        }
    }

    @Test func failedMembersStayInsideTheirGroup() throws {
        let group = try JSONDecoder().decode(CoreAgentGroup.self, from: Data(#"{"id":"fixture","root_work_key":"claude:root","root_provider":"claude","members":["claude:root","codex:worker"],"lineage_evidence":[]}"#.utf8))
        let root = CoreSession(id: "claude:root", provider: "claude", mode: "working")
        let failed = CoreSession(id: "codex:worker", provider: "codex", parent: root.id, lifecycle: "failed")
        let summary = NotchIsland.summarize([root, failed], groups: [group], allSessions: [root, failed])
        #expect(summary.rows.count == 1)
        #expect(summary.rows[0].members.map(\.activity) == [.working, .failed])
        #expect(summary.rows[0].members.map(\.role) == ["Lead", "Worker"])
        #expect(NotchCardView.memberState(.failed) == .failed)
        for activity in [SessionActivity.done, .idle, .ended] {
            #expect(NotchCardView.memberState(activity) == .done)
        }
    }

    @Test func honestOverviewCostsAndActionableLimits() {
        #expect(UsageOverviewTable.costLabel(UsageHistoryDay(date: "2026-10-01", tokensIn: 20)) == "No price")
        #expect(UsageOverviewTable.costLabel(UsageHistoryDay(date: "2026-10-01")) == "$0.00")
        #expect(UsageOverviewTable.costLabel(UsageHistoryDay(date: "2026-10-01", tokensIn: 20, costUsd: 1)) == "$1.00")
        for state in ["disk_full", "over_cap"] {
            var provider = CoreProviderUsage(id: "claude")
            provider.tokenHistoryState = state
            let presentation = UsageHistoryPresentation.state(provider: provider, history: nil, disabled: false,
                loading: false, scanning: false, error: nil)
            #expect(presentation?.retry == false)
        }
    }

    @Test func setupPreviewHasFixedPowerAndEmptyShelf() {
        let preview = SetupAsksStep.makePreview()
        #expect(preview.tray.items.isEmpty)
        #expect(preview.timers.entries.isEmpty)
        #expect(preview.utility.power.percent == 100)
        #expect(preview.utility.power.onAC)
    }

    @Test func appSurfacesAcceptOneSessionUsageStore() {
        let core = CoreModel()
        let sessions = SessionUsageStore(core: core)
        let usage = UsageCenterStore(core: core, sessionUsage: sessions)
        let overview = OverviewStore(core: core, sessionUsage: sessions)
        #expect(usage.sessionUsage === sessions)
        #expect(overview.sessionUsage === sessions)
    }
}
