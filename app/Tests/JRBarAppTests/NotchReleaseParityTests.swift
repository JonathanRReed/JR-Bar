import JRBarTestSupport
import AppKit
import JRBarCore
import JRBarLEDS
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("0.9.17.2 notch parity", .temporaryDirectory)
@MainActor
struct NotchReleaseParityTests {
    nonisolated private static let render = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"
    private let slot: CGFloat = 185
    private let depth: CGFloat = 32

    private func fixture() -> (NotchToy, ToysStore) {
        let core = CoreModel(socketPath: (TestTemporaryDirectory.currentURL.path + "/") + "jrbar-notch-parity.sock")
        core.apply(.state(CoreState(sessions: [
            CoreSession(id: "claude:sample", provider: "claude", label: "Sample task", mode: "working"),
            CoreSession(id: "codex:sample", provider: "codex", label: "Sample check", mode: "working"),
        ])))
        let defaults = UserDefaults(suiteName: "jrbar-notch-parity-\(UUID().uuidString)")!
        let tray = ShelfTrayModel(defaults: defaults)
        let timers = ShelfTimerModel(storeURL: TestTemporaryDirectory.currentURL
            .appendingPathComponent("jrbar-notch-parity-\(UUID().uuidString).json"), schedulingEnabled: false)
        let power = AlcovePowerState(hasBattery: true, onAC: true, charging: false, percent: 100, fullyCharged: true)
        let model = NotchCardModel(timers: timers, tray: tray, utility: ShelfUtilityModel(power: power), runtimeEnabled: false)
        model.focus = ScreenBarFocus(style: ProviderStyle.style(for: "claude"), label: "Sample task", word: "Working", clickSession: nil)
        model.rows = NotchIsland.summarize(core.sessions).rows
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let owner = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: model, notchRuntimeEnabled: false)
        let toy = owner.notch!
        toy.islandVisible = true
        toy.capsuleTimer = { _, _ in }
        return (toy, owner)
    }

    @Test func closedAndHoverWidths() {
        let (toy, owner) = fixture()
        defer { withExtendedLifetime(owner) {} }
        let layout = toy.idleLayout
        let closed = NotchIslandLayout.idleSize(slotWidth: slot, notchDepth: depth,
            leftShoulder: layout.windowShoulder, rightShoulder: layout.windowShoulder)
        // Measured at 740c1b92 using this same fixture.
        #expect(abs(closed.width - 277) <= 2)
        #expect(closed.height == 32)
        let hover = NotchIslandLayout.peekAdjusted(closed, bare: false)
        #expect(abs(hover.width - 283) <= 2)
        #expect(abs(hover.height - 36) <= 2)
        let wing = ScreenBarWingSlot(text: "Working", provider: "codex")
        #expect(wing.preferredEarWidth == 32)
        #expect(wing.minimumMarkWidth == 13)
        #expect(NotchCardView.width == 320)
        #expect(NotchIslandLayout.expandedWidth(slotWidth: 185) == 320)
        #expect(NotchIslandLayout.expandedWidth(slotWidth: 1000) == 380)
    }

    @Test func cardAndNativeWindowFrames() throws {
        let (toy, owner) = fixture()
        defer { withExtendedLifetime(owner) {} }
        let window = NotchIslandWindow(toy: toy)
        toy.cardModel.pinned = true
        toy.stage.noteFace(expanded: true, settled: true)
        defer { window.contentView = nil; window.close(); toy.cardModel.pinned = false }
        for page in [NotchCardModel.Page.now, .shelf] {
            toy.cardModel.show(page)
            let card = NotchCardView(model: toy.cardModel, style: .island, width: 320, pinnedLayout: true)
            let probe = NSHostingView(rootView: card)
            probe.layoutSubtreeIfNeeded()
            let measured = window.expandedCardHeight(width: 320)
            #expect(abs(probe.fittingSize.width - 320) <= 2)
            #expect(abs(measured - probe.fittingSize.height) <= 2)
            let baselineHeight: CGFloat = page == .now ? 181 : 176
            #expect(abs(measured - baselineHeight) <= 2)
            let size = CGSize(width: 320, height: 36 + ceil(measured))
            toy.stage.cardWidth = size.width
            toy.stage.cardHeight = size.height
            let target = CGRect(x: 5000, y: 6000 - size.height, width: size.width, height: size.height)
            window.applyFrame(target, animated: false)
            #expect(window.frame == target)
            #expect(window.presentedFrame == target)
            #expect(toy.stage.shape == nil)
            #expect(window.contentView?.bounds.size == size)
            #expect(!window.isOpaque && window.backgroundColor == .clear)
            if Self.render {
                try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
                let name = page == .now ? "now" : "shelf"
                let values = ["width": Double(size.width), "cardHeight": Double(measured), "islandHeight": Double(size.height)]
                let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: ProofRender.directory.appendingPathComponent("frame-\(name).json"))
            }
        }
        #expect(window.level == .statusBar)
        if ProcessInfo.processInfo.environment["JRBAR_CAPTURE_CARD"] == nil {
            #expect(window.sharingType == .none)
        }
    }

    @Test(.enabled(if: render))
    func releaseMatrix() throws {
        for dark in [false, true] {
            let (toy, owner) = fixture()
            defer { withExtendedLifetime(owner) {} }
            let look = dark ? "dark" : "light"
            let bar = ScreenBarView(frame: CGRect(x: 0, y: 0, width: 520, height: 100))
            bar.earRecoveryReduceMotionOverride = true
            bar.wingGeometry = ScreenBarWingGeometry(notchWidth: slot, notchDepth: depth,
                bandSpan: 520, leftExtent: 132, rightExtent: 132)
            bar.wings = ScreenBarWings(left: ScreenBarWingSlot(text: "Working", provider: "codex"),
                right: ScreenBarWingSlot(text: "Idle"))
            bar.relayout()
            #expect(bar.leftWingRect?.width == 19)
            #expect(bar.rightWingRect?.width == 19)
            let background = (dark ? Color(white: 0.18) : Color(white: 0.87))
            try ProofRender.write(background.frame(width: 520, height: 100), size: CGSize(width: 520, height: 100),
                name: "parity-closed-wings-\(look)", dark: dark, scale: 2, overlay: bar)
            let closed = NotchIslandLayout.idleSize(slotWidth: slot, notchDepth: depth,
                leftShoulder: toy.idleLayout.windowShoulder, rightShoulder: toy.idleLayout.windowShoulder)
            try capture(NotchIslandView(toy: toy), size: closed, name: "closed-\(look)", dark: dark)
            toy.islandHoverPeek = true
            try capture(NotchIslandView(toy: toy), size: NotchIslandLayout.peekAdjusted(closed, bare: false),
                        name: "hover-\(look)", dark: dark)
            toy.islandHoverPeek = false
            toy.cardModel.pinned = true
            defer { toy.cardModel.pinned = false }
            for page in [NotchCardModel.Page.now, .shelf] {
                toy.cardModel.show(page)
                let card = NotchCardView(model: toy.cardModel, style: .island, width: 320, stillTurn: 1, stillReduced: true)
                let probe = NSHostingView(rootView: card)
                probe.layoutSubtreeIfNeeded()
                let size = CGSize(width: 320, height: 36 + ceil(probe.fittingSize.height))
                let face = ZStack(alignment: .top) {
                    NotchSilhouette(notchDepth: depth, restingRadius: 8, notchWidth: slot).fill(.black)
                    card.padding(.top, 36)
                }
                try capture(face, size: size, name: "open-\(page == .now ? "now" : "shelf")-\(look)", dark: dark)
                toy.stage.noteFace(expanded: true, settled: true)
                toy.stage.cardWidth = size.width
                toy.stage.cardHeight = size.height
                try capture(NotchIslandView(toy: toy), size: size,
                    name: "island-\(page == .now ? "now" : "shelf")-\(look)", dark: dark)
            }
            // 0.9.17.2 had these optional quota glances on Now.
            toy.cardModel.show(.now)
            toy.cardModel.meters = [NotchIslandMeter(id: "claude", provider: "claude", window: "5h", percent: 42)]
            let glance = NotchCardView(model: toy.cardModel, style: .island, width: 320, stillTurn: 1, stillReduced: true)
            let probe = NSHostingView(rootView: glance)
            probe.layoutSubtreeIfNeeded()
            let face = glance.padding(.top, 36).background(.black)
            try capture(face, size: CGSize(width: 320, height: 36 + ceil(probe.fittingSize.height)), name: "quota-glance-\(look)", dark: dark)
            toy.cardModel.pinned = false
            toy.stage.noteFace(expanded: false, settled: true)
            let ask = CoreAsk(session: "claude:sample", summary: "Run the checks?", answerable: true, request: "fixture")
            toy.core.apply(.state(CoreState(sessions: [
                CoreSession(id: "claude:sample", provider: "claude", label: "Sample task", ask: ask),
            ], asks: [ask])))
            let desk = AskAnswerDesk(send: { _, _, _ in CoreReply(id: "fixture", ok: true) })
            toy.cardModel.askDesk = { desk }
            for takeover in [false, true] {
                toy.activeCapsule = AlcoveNotice(id: "sample", kind: .ask, title: "Claude · Sample task",
                    subtitle: "Run the checks?", provider: "claude", session: "claude:sample", key: "ask:sample",
                    ask: ask, takeover: takeover)
                let size = NotchIslandLayout.askSize(slotWidth: slot, notchDepth: depth, summaryLines: 1,
                                                    takeover: takeover, underHousing: nil)
                try capture(NotchIslandView(toy: toy), size: size, name: "ask-\(takeover ? "takeover" : "ordinary")-\(look)", dark: dark)
            }
        }
    }

    private func capture<V: View>(_ face: V, size: CGSize, name: String, dark: Bool) throws {
        let canvas = CGSize(width: 520, height: size.height + 40)
        let scene = ZStack(alignment: .top) {
            (dark ? Color(white: 0.18) : Color(white: 0.87))
            Rectangle().fill(dark ? Color.black.opacity(0.2) : Color.white.opacity(0.3)).frame(height: depth)
            face.frame(width: size.width, height: size.height)
        }.frame(width: canvas.width, height: canvas.height)
        try ProofRender.write(scene, size: canvas, name: "parity-\(name)", dark: dark, scale: 2)
    }
}
