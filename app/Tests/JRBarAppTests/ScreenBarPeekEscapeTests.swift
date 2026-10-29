import JRBarTestSupport
import AppKit
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

/// A pinned Screen Bar peek folds on Esc, but its local monitor took every
/// Esc in the app, so Esc pressed in a Settings sheet or a text field folded
/// the peek and never reached the sheet. It reads the same rule as the notch
/// card (`CardEscapeWatch`): an Esc the peek's own window or no window owns
/// is taken, and any other JR-Bar window keeps its own. The keyboard is a
/// fake and nothing is shown.
@Suite("Screen Bar peek Esc", .renderProofAppearance)
@MainActor
struct ScreenBarPeekEscapeTests {
    @Test(.enabled(if: NotchSurfaceRenderProofTests.enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func attachedMenuRender() throws {
        let (toy, store, monitor) = NotchSurfaceRenderProofTests.makeToy()
        defer { withExtendedLifetime(store) {} }
        NotchSurfaceRenderProofTests.fill(toy.cardModel, monitor: monitor)
        defer { NotchSurfaceRenderProofTests.clearTray(toy.cardModel) }
        let depth = max(toy.notchDepth, 32)
        let width = NotchIslandLayout.expandedWidth(slotWidth: NotchSurfaceRenderProofTests.slotWidth)
        let card = NotchCardView(model: toy.cardModel, style: .island, width: width)
        let probe = NSHostingView(rootView: card)
        probe.layoutSubtreeIfNeeded()
        let height = toy.cardTopPad + ceil(probe.fittingSize.height)
        let canvas = CGSize(width: width + 240, height: height + 120)
        let island = ZStack(alignment: .top) {
            NotchSilhouette(notchDepth: depth, restingRadius: 8).fill(.black)
            card.padding(.top, toy.cardTopPad)
        }
        let model = ScreenBarPeekModel()
        for (index, symbol) in ["wifi", "headphones", "externaldrive"].enumerated() {
            let glyph = try #require(NSImage(systemSymbolName: symbol, accessibilityDescription: nil))
            let item = MenuBarItem(id: "proof-\(index)", ownerPID: 0, ownerName: "Example",
                                   bounds: CGRect(x: 100, y: 0, width: 24, height: 24),
                                   title: nil, windowID: 0, bundleID: "com.example.app")
            model.tiles.append(.init(item: item, face: .init(image: glyph, width: 24, template: true)))
        }
        model.width = ScreenBarPeekLayout.width(tileWidths: model.tiles.map(\.width), hasWords: false)
        let parent = CGRect(x: (canvas.width - width) / 2, y: canvas.height - height, width: width, height: height)
        let band = ScreenBarGeometry.coupledBand(in: canvas, island: parent, cornerRadius: 14).band
        let ear = CGRect(x: canvas.width / 2 + NotchSurfaceRenderProofTests.slotWidth / 2,
                         y: canvas.height - depth, width: 36, height: depth)
        let popup = ScreenBarPeekLayout.frame(size: CGSize(width: model.width, height: 48),
                                              ear: ear, band: band, screen: CGRect(origin: .zero, size: canvas))
        for (name, shown) in [("before", false), ("open", true), ("closed", false)] {
            let scene = ZStack(alignment: .topLeading) {
                NotchSurfaceRenderProofTests.scene(island, size: parent.size, depth: depth, canvas: canvas)
                Rectangle().fill(Color.cyan.opacity(0.6))
                    .frame(width: band.width, height: band.height)
                    .offset(x: band.minX, y: canvas.height - band.maxY)
                if shown {
                    ScreenBarPeekView(model: model)
                        .frame(width: popup.width, height: popup.height)
                        .offset(x: popup.minX, y: canvas.height - popup.maxY)
                }
            }
            try ProofRender.write(scene, size: canvas, name: "notch-menu-child-\(name)", settle: 0)
        }
    }

    @Test("Esc closes an attached menu before its expanded notch parent")
    func attachedMenuHasEscapePriority() {
        let keys = CardEscapeWatchTests.FakeKeys()
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        toy.cardKeysLive = { true }
        toy.cardKeySource = keys.source
        toy.expand(held: true)
        #expect(toy.listensForEscape)
        toy.shelfKeyboardEngaged = true
        toy.syncCardKeyMonitors()
        let peek = ScreenBarPeek()
        peek.keySource = keys.source
        peek.onVisibilityChange = { [weak toy] in toy?.menuPopupShown = $0 }
        peek.anchor = {
            ScreenBarPeekAnchor(ear: CGRect(x: 5100, y: 5950, width: 32, height: 32),
                               band: CGRect(x: 5000, y: 5600, width: 200, height: 2),
                               screen: CGRect(x: 4000, y: 4000, width: 2000, height: 2000))
        }
        let panel = peek.makePanel()
        defer { peek.hide(); toy.collapseFromBand(); panel.orderOut(nil); withExtendedLifetime(store) {} }
        peek.show(pinned: true)
        #expect(!toy.shelfKeyboardEngaged)
        #expect(!toy.listensForEscape)
        #expect(keys.liveGlobal == 1)
        keys.pressElsewhere()
        #expect(!peek.isShown)
        #expect(toy.islandExpanded)
        #expect(toy.listensForEscape)
        #expect(keys.liveGlobal == 1)
        keys.pressElsewhere()
        #expect(!toy.islandExpanded)
        #expect(keys.liveGlobal == 0)
    }

    @Test("a pinned peek ignores an Esc meant for another window and folds on Esc in none")
    func peekTakesOnlyItsOwnEscape() {
        let keys = CardEscapeWatchTests.FakeKeys()
        let peek = ScreenBarPeek()
        peek.keySource = keys.source
        peek.installKeyMonitors()
        #expect(peek.listensForEscape)

        #expect(!keys.press(in: NSObject()), "a Settings sheet's Esc is the sheet's")
        #expect(peek.listensForEscape, "the peek is still pinned")

        #expect(keys.press(in: nil), "an Esc nobody else owns folds it")
        #expect(!peek.listensForEscape)
        #expect(keys.liveLocal == 0 && keys.liveGlobal == 0)
    }

    @Test("an Esc delivered to the peek's own window is taken")
    func peekTakesEscapeInItsOwnWindow() {
        let keys = CardEscapeWatchTests.FakeKeys()
        let peek = ScreenBarPeek()
        peek.keySource = keys.source
        // The panel exists but is never ordered in.
        let panel = peek.makePanel()
        defer { panel.close() }
        peek.installKeyMonitors()
        #expect(!keys.press(in: NSObject()))
        #expect(keys.press(in: panel))
        #expect(!peek.listensForEscape)
    }

    @Test("a pinned peek still folds on an Esc pressed in another app, and no other key is taken")
    func peekGoesOnGlobalEscape() {
        let keys = CardEscapeWatchTests.FakeKeys()
        let peek = ScreenBarPeek()
        peek.keySource = keys.source
        peek.installKeyMonitors()
        #expect(!keys.press(36, in: nil), "Return is never taken")
        #expect(peek.listensForEscape)
        keys.pressElsewhere()
        #expect(!peek.listensForEscape)
    }

    @Test("a peek that was never pinned listens for nothing")
    func unpinnedPeekListensForNothing() {
        let peek = ScreenBarPeek()
        #expect(!peek.listensForEscape)
    }
}
