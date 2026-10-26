import Foundation
import SwiftUI
@testable import JRBarCore
import JRBarUI
import Testing
@testable import JRBarApp

@MainActor
@Suite struct U5BehaviorTests {
    @Test func contentIsOpaqueOnTheFirstFrame() throws {
        let stage = NotchStageModel()
        stage.noteFace(expanded: true, settled: false)
        let renderer = ImageRenderer(content: Color.white.frame(width: 20, height: 20)
            .modifier(NotchSheetReveal()).environment(\.notchStage, stage))
        let image = try #require(renderer.cgImage)
        let data = try #require(image.dataProvider?.data)
        #expect(CFDataGetBytePtr(data)[0] > 250)
    }

    @Test func tabChangesAsksAndReturnAnswersTheDisplayedRequest() async {
        let first = CoreAsk(session: "claude:first", openedAt: 1, summary: "Run tests?", answerable: true, request: "first")
        let next = CoreAsk(session: "codex:next", openedAt: 2, summary: "Run checks?", answerable: true, request: "next")
        let state = CoreState(sessions: [
            CoreSession(id: "claude:first", provider: "claude", label: "Sample A", ask: first),
            CoreSession(id: "codex:next", provider: "codex", label: "Sample B", ask: next),
        ], asks: [first, next])
        let (toy, owner, _) = NotchSurfaceRenderProofTests.makeToy(state: state)
        defer { withExtendedLifetime(owner) {} }
        var sent: [String] = []
        let desk = AskAnswerDesk(send: { session, _, request in
            sent.append(session + "|" + (request ?? ""))
            return CoreReply(id: "fixture", ok: true)
        })
        desk.onAnswered = { [weak toy] session, request in toy?.resolveAsk(session: session, request: request) }
        toy.cardModel.askDesk = { desk }
        toy.offer(AlcoveNotice(id: "first", kind: .ask, title: "Sample A", subtitle: "Run tests?", provider: "claude",
            session: first.session, key: "first", ask: first, takeover: true))
        #expect(toy.engageAskKeyboard())
        toy.askKey(.tab)
        #expect(toy.activeCapsule?.session == next.session)
        #expect(toy.capsuleQueue.current?.session == next.session)
        #expect(sent.isEmpty)
        await toy.askKey(.activate)?.value
        #expect(sent == ["codex:next|next"])
        #expect(toy.activeCapsule?.session != next.session)
    }

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

    @Test func completionNoticeRequiresMoreThanTwoMinutes() {
        for duration in [nil, -1, 0, 119, 120, 121, 300] as [Double?] {
            let event = CoreEvent(id: "fixture", kind: "completed", duration: duration)
            let notice = AlcoveEventPolicy.notice(for: event, session: nil, kinds: AlcoveCapsuleKinds())
            #expect((notice != nil) == (duration.map { $0 > 120 } ?? false))
        }
    }

    @Test func nativeNotchMotionLandsAtItsDurationAndRetargetsFromCurrentFrame() {
        let rest = CGRect(x: 100, y: 100, width: 180, height: 32)
        let open = CGRect(x: 20, y: 0, width: 400, height: 240)
        var motion = NotchFrameTransition(at: rest)
        motion.retarget(open)
        #expect(motion.token == .notchSettle)
        for _ in 0..<24 {
            let moving = motion.integrate(dt: 0.01)
            #expect(moving)
            #expect(motion.frame.width >= rest.width && motion.frame.width <= open.width)
        }
        let openingContinues = motion.integrate(dt: 0.011)
        #expect(!openingContinues)
        #expect(motion.frame == open)
        motion.retarget(rest)
        #expect(motion.token == .notchClose)
        motion.integrate(dt: 0.09)
        let middle = motion.frame
        motion.retarget(open)
        #expect(motion.frame == middle)
        let retargetContinues = motion.integrate(dt: 0.25)
        #expect(!retargetContinues)
        #expect(motion.frame == open)
        motion.retarget(rest)
        let closingContinues = motion.integrate(dt: 0.18)
        #expect(!closingContinues)
        #expect(motion.frame == rest)
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
