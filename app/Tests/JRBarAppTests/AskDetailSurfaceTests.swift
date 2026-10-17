import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// An ask the person can expand: the command, an edit's size or a plan.
/// It is shut until a click, the window grows by one fixed well when it
/// opens, and opening it never answers anything.
@Suite("Ask detail surfaces", .serialized)
@MainActor
struct AskDetailSurfaceTests {
    static let t = WindowsRenderProofTests.t

    static let command = CoreAsk(
        session: "claude:fix", kind: "permission", openedAt: t - 40,
        summary: "Run the cleanup script", answerable: true, request: "r-command",
        decision: CoreAskDecision(holdUntil: t + 30, always: true),
        preview: "set -e cd packages/web rm -rf build dist npm ci",
        risk: "destructive",
        detail: CoreAskDetail(command: "set -e\ncd packages/web\nrm -rf build dist\nnpm ci && npm run build"))

    static let edit = CoreAsk(
        session: "codex:site", kind: "permission", openedAt: t - 20,
        summary: "Edit 2 files", answerable: true, request: "r-edit", preview: "/src/parser.py +1",
        detail: CoreAskDetail(edit: CoreAskEdit(verb: "edit", files: 2, added: 14, removed: 3,
                                                paths: ["/src/parser.py", "/src/lexer.py"])))

    static let plan = CoreAsk(
        session: "claude:plan", kind: "approval", openedAt: t - 90,
        summary: "Ready to start coding?", answerable: false, request: "r-plan",
        detail: CoreAskDetail(plan: "1. Read the parser\n2. Add the failing test\n3. Fix the off-by-one\n4. Run the suite"))

    static func state(_ asks: [CoreAsk]) -> CoreState {
        let sessions = asks.map { ask in
            CoreSession(id: ask.session ?? "", provider: (ask.session ?? "").split(separator: ":").first.map(String.init) ?? "claude",
                        label: "demo \(ask.request ?? "")", cwd: "/demo/project", mode: "waiting",
                        since: ask.openedAt, ask: ask)
        }
        return CoreState(now: t, aggregate: CoreAggregate(mode: "waiting", needsYou: asks.count),
                         sessions: sessions, asks: asks)
    }

    @Test("an ask is shut until the person opens it, and opening is a toggle")
    func neverOpensItself() {
        let expansion = AskExpansion()
        #expect(!expansion.isShowing(Self.command))
        expansion.toggle(Self.command)
        #expect(expansion.isShowing(Self.command))
        #expect(!expansion.isShowing(Self.edit), "another ask stays shut")
        expansion.toggle(Self.command)
        #expect(!expansion.isShowing(Self.command))
        // An ask with nothing to show never reads as open.
        let plain = CoreAsk(session: "s", request: "r-plain", preview: "npm test")
        expansion.toggle(plain)
        #expect(!expansion.isShowing(plain))
    }

    @Test("the keys are bounded, so a long day does not grow them without end")
    func boundedKeys() {
        let expansion = AskExpansion()
        for index in 0..<(AskExpansion.keyLimit + 5) {
            var ask = Self.command
            ask.request = "r-\(index)"
            expansion.toggle(ask)
        }
        #expect(expansion.expanded.count <= AskExpansion.keyLimit)
    }

    @Test("the panel gets taller by one well for each ask the person opened")
    func panelGrows() {
        defer {
            AskExpansion.shared.collapse(Self.command)
            AskExpansion.shared.collapse(Self.plan)
        }
        let store = WindowsRenderProofTests.panelStore(Self.state([Self.command, Self.plan]))
        let shut = store.layout
        #expect(store.layoutContent.expandedAsks == 0)
        AskExpansion.shared.toggle(Self.plan)
        #expect(store.layoutContent.expandedAsks == 1)
        #expect(store.layout.totalHeight == shut.totalHeight + PanelLayout.askDetailHeight)
        AskExpansion.shared.toggle(Self.command)
        #expect(store.layoutContent.expandedAsks == 2)
        AskExpansion.shared.toggle(Self.command)
        AskExpansion.shared.toggle(Self.plan)
        #expect(store.layout.totalHeight == shut.totalHeight)
    }

    @Test("expanding and reading never send a word to the daemon")
    func readingAnswersNothing() async {
        let log = DecidedAskFixture.SentLog()
        let desk = DecidedAskFixture.loggingDesk(log)
        let expansion = AskExpansion()
        expansion.toggle(Self.plan)
        expansion.toggle(Self.command)
        expansion.toggle(Self.command)
        #expect(log.answers.isEmpty)
        #expect(desk.pending.isEmpty)
    }

    @Test("the plan's action is the session")
    func planActionIsTheSession() {
        #expect(AskDetailCopy.sessionActionTitle == "Answer in the session")
        #expect(Self.plan.isPlanApproval)
        #expect(!Self.command.isPlanApproval)
    }
}

/// Pictures of the expanded ask in the panel, the notch card and the
/// Overview inspector. Off by default; `JRBAR_RENDER_PROOF=1` writes
/// `ask-detail-*.png` into `JRBAR_RENDER_PROOF_DIR`.
@Suite("Ask detail render proof", .serialized)
@MainActor
struct AskDetailRenderProofTests {
    private typealias Surface = AskDetailSurfaceTests

    /// The notch's grown card with one ask shut and one opened.
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func notchCard() throws {
        let asks = [Surface.command, Surface.plan]
        let (toy, store, _) = NotchSurfaceRenderProofTests.makeToy(state: Surface.state(asks))
        defer {
            withExtendedLifetime(store) {}
            for ask in asks { AskExpansion.shared.collapse(ask) }
        }
        let model = toy.cardModel
        model.rows = toy.islandSummary.rows
        model.pinned = true
        let depth = max(toy.notchDepth, 32)
        let width = NotchIslandLayout.expandedWidth(slotWidth: NotchSurfaceRenderProofTests.slotWidth)
        for (name, open) in [("shut", false), ("open", true)] {
            if open { for ask in asks { AskExpansion.shared.toggle(ask) } }
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
                                  size: canvas, name: "ask-detail-notch-card-\(name)")
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func panelShutAndOpen() throws {
        let asks = [Surface.command, Surface.edit, Surface.plan]
        let store = WindowsRenderProofTests.panelStore(Surface.state(asks))
        try WindowsRenderProofTests.write("ask-detail-panel-shut", size: WindowsRenderProofTests.panelSize(store),
                                          plate: .glass) { WindowsRenderProofTests.panel(store) }
        defer { for ask in asks { AskExpansion.shared.collapse(ask) } }
        AskExpansion.shared.toggle(Surface.command)
        try WindowsRenderProofTests.write("ask-detail-panel-command", size: WindowsRenderProofTests.panelSize(store),
                                          plate: .glass) { WindowsRenderProofTests.panel(store) }
        AskExpansion.shared.toggle(Surface.edit)
        AskExpansion.shared.toggle(Surface.plan)
        try WindowsRenderProofTests.write("ask-detail-panel-open", size: WindowsRenderProofTests.panelSize(store),
                                          plate: .glass) { WindowsRenderProofTests.panel(store) }
    }
}
