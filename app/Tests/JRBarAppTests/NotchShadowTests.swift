import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// The shadow's rules as numbers, and the island window's care of its
/// panel: cast once a grown shape has landed, let go as a fold begins,
/// never on the resting island, never a source of clicks.
@Suite("Notch shadow")
@MainActor
struct NotchShadowTests {
    private let idle = CGRect(x: 5663, y: 5950, width: 185, height: 32)
    private let card = CGRect(x: 5596, y: 5560, width: 320, height: 422)

    @Test("only a body hanging a clear stride below the notch casts one")
    func casting() {
        #expect(!NotchShadow.casts(height: 32, notchDepth: 32), "the resting island is the bezel")
        #expect(!NotchShadow.casts(height: 34, notchDepth: 32), "the hover swell is not a body")
        #expect(NotchShadow.casts(height: 54, notchDepth: 32), "a notice's lip is")
        #expect(NotchShadow.casts(height: 422, notchDepth: 32))
        #expect(!NotchShadow.casts(height: 24, notchDepth: 0), "a notch-less pill at rest casts none")
        #expect(NotchShadow.casts(height: 120, notchDepth: 0))
    }

    @Test("the panel holds the shadow's blur on the sides and below and none above")
    func frame() {
        let panel = NotchShadow.frame(for: card)
        #expect(panel.maxY == card.maxY, "nothing is cast up under the menu bar")
        #expect(panel.minX == card.minX - NotchShadow.margin && panel.maxX == card.maxX + NotchShadow.margin)
        #expect(panel.minY == card.minY - NotchShadow.margin)
        #expect(NotchShadow.margin >= NotchShadow.ambient.radius * 2 + NotchShadow.ambient.offset)
        let inView = NotchShadow.local(card)
        #expect(inView.minY == 0 && inView.size == card.size && inView.minX == NotchShadow.margin)
    }

    private func makeWindow() -> (NotchIslandWindow, ToysStore) {
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        let window = NotchIslandWindow(toy: toy)
        window.drivesSpringByHand = true
        window.surroundingsOverride = .init(bounds: CGRect(x: 0, y: 0, width: 10_000, height: 10_000), floor: nil)
        window.setFrame(idle, display: false)
        window.visibility = { true }
        #expect(!window.isVisible)
        return (window, store)
    }

    private func land(_ window: NotchIslandWindow, on frame: CGRect) {
        window.applyFrame(frame, animated: true)
        var ticks = 0
        while window.presentedFrame != frame || window.frame != frame, ticks < 600 {
            window.advanceSpring(by: 1.0 / 120)
            ticks += 1
        }
    }

    @Test("a grown shape casts once it has landed, not while it moves, and lets go as it folds")
    func followsTheShape() {
        let (window, store) = makeWindow()
        defer { window.shadowPanel?.lift(immediately: true); window.orderOut(nil); withExtendedLifetime(store) {} }
        #expect(window.shadowPanel?.isCast != true, "the resting island casts none")
        window.applyFrame(card, animated: true)
        for _ in 0..<10 { window.advanceSpring(by: 1.0 / 120) }
        #expect(window.shadowPanel?.isCast != true, "a move in flight casts none")
        land(window, on: card)
        let panel = window.shadowPanel
        #expect(panel?.isCast == true)
        #expect(panel?.frame == NotchShadow.frame(for: card))
        #expect(panel?.ignoresMouseEvents == true, "it never takes a click")
        window.applyFrame(idle, animated: true)
        #expect(panel?.isCast == false, "the fold lets it go as it begins")
        land(window, on: idle)
        #expect(panel?.isCast == false)
    }

    @Test("a landed island asks the display for nothing: no spring, no link, no stage")
    func restingIslandIsIdle() {
        let (window, store) = makeWindow()
        defer { window.shadowPanel?.lift(immediately: true); window.orderOut(nil); withExtendedLifetime(store) {} }
        #expect(!window.isAnimating)
        window.applyFrame(card, animated: true)
        #expect(window.isAnimating)
        land(window, on: card)
        #expect(!window.isAnimating, "landed on the card")
        window.applyFrame(idle, animated: true)
        land(window, on: idle)
        #expect(!window.isAnimating, "and back at the notch")
        // A cancel mid-move leaves nothing running either.
        window.applyFrame(card, animated: true)
        for _ in 0..<5 { window.advanceSpring(by: 1.0 / 120) }
        window.cancelSpring()
        #expect(!window.isAnimating)
    }

    @Test("ordering the island out takes the shadow with it")
    func parksWithTheIsland() {
        let (window, store) = makeWindow()
        defer { window.shadowPanel?.lift(immediately: true); withExtendedLifetime(store) {} }
        land(window, on: card)
        #expect(window.shadowPanel?.isCast == true)
        window.orderOut(nil)
        #expect(window.shadowPanel?.isCast == false)
        #expect(window.shadowPanel?.isVisible == false)
    }

    @Test("the defaults key takes the shadow away")
    func revertSwitch() {
        UserDefaults.standard.set(false, forKey: "jrbar.notchShadow")
        defer { UserDefaults.standard.removeObject(forKey: "jrbar.notchShadow") }
        let (window, store) = makeWindow()
        defer { window.orderOut(nil); withExtendedLifetime(store) {} }
        land(window, on: card)
        #expect(window.shadowPanel == nil)
    }
}

/// The shadow in a still frame, over a light and a dark desktop with a
/// white window behind, the grown card on top. Off by default; set
/// `JRBAR_RENDER_PROOF=1` to write `notch-shadow-*.png`.
@Suite("Notch shadow render proof")
@MainActor
struct NotchShadowRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func cardShadow() throws {
        let (toy, store, monitor) = NotchSurfaceRenderProofTests.makeToy()
        defer { withExtendedLifetime(store) {} }
        NotchSurfaceRenderProofTests.fill(toy.cardModel, monitor: monitor)
        let depth = max(toy.notchDepth, 32)
        let slot = NotchSurfaceRenderProofTests.slotWidth
        let width = NotchIslandLayout.expandedWidth(slotWidth: slot)
        let probe = NSHostingView(rootView: NotchCardView(model: toy.cardModel, style: .island, width: width))
        probe.layoutSubtreeIfNeeded()
        let height = toy.cardTopPad + ceil(probe.fittingSize.height)
        toy.expand(held: true)
        let shape = CGSize(width: width, height: height)
        let canvas = CGSize(width: width + 220, height: height + 90)
        for dark in [false, true] {
            for shadowOn in [false, true] {
                let model = NotchShadowModel()
                model.silhouette = NotchSilhouette(notchDepth: depth, restingRadius: 8, notchWidth: slot)
                model.size = shape
                let scene = ZStack(alignment: .top) {
                    ProofDesktop(dark: dark)
                    if !dark {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white)
                            .frame(width: canvas.width - 40, height: canvas.height - 40)
                            .padding(.top, 36)
                    }
                    if shadowOn {
                        NotchShadowView(model: model)
                            .frame(width: shape.width + 2 * NotchShadow.margin,
                                   height: shape.height + NotchShadow.margin)
                    }
                    NotchIslandView(toy: toy).frame(width: shape.width, height: shape.height)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(width: canvas.width, height: canvas.height, alignment: .top)
                try ProofRender.write(scene, size: canvas,
                                      name: "notch-shadow-\(dark ? "dark" : "light")-\(shadowOn ? "on" : "off")",
                                      dark: dark, scale: 1.5, settle: 0.1)
            }
        }
    }
}
