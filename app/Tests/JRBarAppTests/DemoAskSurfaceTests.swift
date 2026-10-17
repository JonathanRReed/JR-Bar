import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// "Try it": a made-up ask in the real ask card. It answers nothing, goes
/// to no agent, is not in the daemon's state, and goes away when answered
/// or put away.
@Suite("Demo ask surfaces", .serialized)
@MainActor
struct DemoAskSurfaceTests {
    private static let t = WindowsRenderProofTests.t

    /// A desk that fails the test if anything is sent.
    private func desk(_ log: DecidedAskFixture.SentLog, demo: DemoAskStore) -> AskAnswerDesk {
        let desk = DecidedAskFixture.loggingDesk(log)
        desk.demo = demo
        return desk
    }

    @Test("answering the demo sends no answer command, whatever the verdict, and puts it away")
    func answeringSendsNothing() async throws {
        for verdict in [AskVerdict.approve, .deny, .always, .reply("yes"),
                        .choose(["Which?": .string("A")])] {
            let log = DecidedAskFixture.SentLog()
            let demo = DemoAskStore()
            demo.show()
            let ask = try #require(demo.current(at: Date()))
            let outcome = await desk(log, demo: demo).answer(ask, verdict)
            #expect(log.answers.isEmpty, "nothing reaches the daemon for \(verdict)")
            #expect(outcome.ok)
            #expect(outcome.line == DemoAsk.answeredLine)
            #expect(demo.ask == nil, "it is gone once answered")
        }
    }

    @Test("a real ask still goes through the desk beside it")
    func realAsksStillSend() async {
        let log = DecidedAskFixture.SentLog()
        let demo = DemoAskStore()
        demo.show()
        let outcome = await desk(log, demo: demo).answer(DecidedAskFixture.openAsk(), .approve)
        #expect(outcome.ok)
        #expect(log.answers.count == 1)
        #expect(demo.ask != nil, "answering a real ask leaves the demo up")
    }

    @Test("the panel's own buttons answer the demo locally too")
    func panelButtons() async throws {
        let store = WindowsRenderProofTests.panelStore(CoreState(now: Self.t))
        let log = DecidedAskFixture.SentLog()
        let demo = DemoAskStore()
        store.askDesk.send = { session, verdict, request in
            log.answers.append((session, verdict, request))
            return CoreReply(id: "1", ok: true)
        }
        store.askDesk.demo = demo
        demo.show()
        let ask = try #require(demo.ask)
        store.approve(ask)
        // The desk's answer is a Task on the main actor: wait on the
        // condition, with a bound, not a sleep.
        let deadline = Date().addingTimeInterval(5)
        while demo.ask != nil, Date() < deadline { await Task.yield() }
        #expect(demo.ask == nil)
        #expect(log.answers.isEmpty)
    }

    @Test("it lives in memory only: not in the daemon's asks, not in the rows the header counts")
    func notARealAsk() {
        let shared = DemoAskStore.shared
        defer { shared.dismiss() }
        let core = WindowsRenderProofTests.liveCore(CoreState(now: Self.t))
        let store = PanelStore(core: core, draftsDefaults: UserDefaults(suiteName: ScratchDefaults.suiteName("jrbar.demo"))!,
                               screenBarShown: true)
        store.now = Date()
        shared.show()
        #expect(core.asks.isEmpty)
        #expect(store.rows.isEmpty, "the header, the Screen Bar and the icon read rows")
        #expect(store.demoRow != nil)
        #expect(store.askCardCount == 1)
        #expect(store.layoutContent.asks == 1)
        shared.dismiss()
        #expect(store.demoRow == nil)
        #expect(store.askCardCount == 0)
    }

    @Test("it is put away by Put Away, and by its own lifetime")
    func goesAway() {
        let demo = DemoAskStore()
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        demo.clock = { now }
        demo.show()
        #expect(demo.current(at: now) != nil)
        #expect(demo.current(at: now.addingTimeInterval(DemoAsk.lifetime - 1)) != nil)
        #expect(demo.current(at: now.addingTimeInterval(DemoAsk.lifetime + 1)) == nil)
        demo.dismiss()
        #expect(demo.current(at: now) == nil)
        // A new one starts its clock again.
        now = now.addingTimeInterval(5_000)
        demo.show()
        #expect(demo.current(at: now.addingTimeInterval(30)) != nil)
    }

    @Test("an opened demo is closed when the demo goes")
    func expansionIsForgotten() throws {
        let demo = DemoAskStore()
        demo.show()
        let ask = try #require(demo.ask)
        AskExpansion.shared.toggle(ask)
        #expect(AskExpansion.shared.isShowing(ask))
        demo.dismiss()
        #expect(!AskExpansion.shared.isShowing(ask))
    }

    @Test("Try it shows the demo and opens the surface; Setup and Settings share the one button")
    func tryItOpensTheSurface() {
        let demo = DemoAskStore()
        var presented = 0
        demo.presenter = { presented += 1 }
        demo.tryIt()
        #expect(demo.ask != nil)
        #expect(presented == 1)

        var tried = 0
        let setup = SetupStore(model: SetupModel(), load: { SetupState() }, persist: { _ in })
        setup.onTryDemoAsk = { tried += 1 }
        setup.tryDemoAsk()
        #expect(tried == 1)
    }

    @Test("the panel's demo card says Demo, wears violet and opens no session")
    func panelCard() throws {
        let shared = DemoAskStore.shared
        defer { shared.dismiss() }
        let store = WindowsRenderProofTests.panelStore(CoreState(now: Self.t))
        shared.show()
        let row = try #require(store.demoRow)
        #expect(row.ask?.isDemo == true)
        #expect(row.ask?.summary == "Demo — this answers nothing")
        store.open(row)
        #expect(store.toast == DemoAsk.summary, "a tap says it is a demo; no session was asked to open")
    }
}

/// Pictures of the demo in the panel (alone, and beside a real ask) and on
/// the notch card. `JRBAR_RENDER_PROOF=1` writes `demo-ask-*.png`.
@Suite("Demo ask render proof", .serialized)
@MainActor
struct DemoAskRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func panel() throws {
        let shared = DemoAskStore.shared
        defer { shared.dismiss(); AskExpansion.shared.collapse(AskDetailSurfaceTests.command) }
        let quiet = WindowsRenderProofTests.panelStore(CoreState(now: WindowsRenderProofTests.t))
        shared.show()
        try WindowsRenderProofTests.write("demo-ask-panel-alone", size: WindowsRenderProofTests.panelSize(quiet),
                                          plate: .glass) { WindowsRenderProofTests.panel(quiet) }
        if let demo = shared.ask { AskExpansion.shared.toggle(demo) }
        try WindowsRenderProofTests.write("demo-ask-panel-expanded", size: WindowsRenderProofTests.panelSize(quiet),
                                          plate: .glass) { WindowsRenderProofTests.panel(quiet) }
        shared.dismiss()
        let real = [AskDetailSurfaceTests.command]
        let busy = WindowsRenderProofTests.panelStore(AskDetailSurfaceTests.state(real))
        shared.show()
        try WindowsRenderProofTests.write("demo-ask-panel-beside-real", size: WindowsRenderProofTests.panelSize(busy),
                                          plate: .glass) { WindowsRenderProofTests.panel(busy) }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func setupDoneStep() throws {
        let store = SetupStore(model: SetupModel(), load: { SetupState() }, persist: { _ in })
        store.jump(to: .done)
        try WindowsRenderProofTests.write("demo-ask-setup-done", size: SetupWindowController.contentSize) {
            SetupView(store: store)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func notchCard() throws {
        let shared = DemoAskStore.shared
        defer { shared.dismiss() }
        let (toy, store, _) = NotchSurfaceRenderProofTests.makeToy(state: AskDetailSurfaceTests.state([AskDetailSurfaceTests.command]))
        defer { withExtendedLifetime(store) {} }
        shared.show()
        let model = toy.cardModel
        let demoRow = NotchIslandRow(id: DemoAsk.sessionID, label: DemoAsk.label, provider: "jrbar-demo",
                                     activity: .waiting, ask: shared.ask)
        model.rows = [demoRow] + toy.islandSummary.rows
        model.pinned = true
        let depth = max(toy.notchDepth, 32)
        let width = NotchIslandLayout.expandedWidth(slotWidth: NotchSurfaceRenderProofTests.slotWidth)
        let card = NotchCardView(model: model, style: .island, width: width)
        let probe = NSHostingView(rootView: card)
        probe.layoutSubtreeIfNeeded()
        let height = toy.cardTopPad + ceil(probe.fittingSize.height)
        let island = ZStack(alignment: .top) {
            NotchSilhouette(notchDepth: depth, restingRadius: 8).fill(.black)
            card.padding(.top, toy.cardTopPad)
        }
        let canvas = CGSize(width: width + 140, height: height + 40)
        try ProofRender.write(NotchSurfaceRenderProofTests.scene(island, size: CGSize(width: width, height: height),
                                                                depth: depth, canvas: canvas),
                              size: canvas, name: "demo-ask-notch-card")
    }
}
