import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The right ear's claim: it is the menu handle's home while the
/// concealer runs — the ‹ glyph included, on-row status item or not.
/// The "right wing is hidden" bug was the ear collapsing to zero
/// width whenever the handle went nil and no slot filled the claim.
@Suite("Screen Bar ear claim")
@MainActor
struct ScreenBarEarTests {

    @Test func unchangedQuotaDoesNotRelayoutOnEveryLightingUpdate() async throws {
        let core = CoreModel()
        var state = CoreState(usage: CoreUsage(providers: [CoreProviderUsage(
            id: "codex", windows: [CoreUsageWindow(key: "5h", name: "5h", usedPct: 42,
                resetsAt: Date().timeIntervalSince1970 + 3600)])]))
        core.apply(.state(state))
        let store = PanelStore(core: core, screenBarShown: false)
        let first = store.screenBarWings
        #expect(first.right?.meter == 0.42)
        #expect(first.right?.text.contains("resets in") == true)
        try await Task.sleep(for: .milliseconds(10))
        #expect(store.screenBarWings == first,
                "subsecond clock changes must not invalidate an unchanged ring")
        state.usage?.providers[0].windows[0].usedPct = 50
        core.apply(.state(state))
        #expect(store.screenBarWings != first, "real usage changes must still update the ring")
    }

    /// A window-sized view with a measured right claim — the geometry a
    /// notched screen answers when the right flank has room.
    private func makeView() -> ScreenBarView {
        let view = ScreenBarView(frame: NSRect(x: 0, y: 0, width: 500, height: 48))
        view.wingGeometry = ScreenBarWingGeometry(
            notchWidth: 185, notchDepth: 32, bandSpan: 500,
            leftExtent: 0, rightExtent: 60)
        return view
    }

    @Test func lightSitsBelowTheWholeNotchAndWings() throws {
        let view = makeView()
        view.wings = ScreenBarWings(
            left: nil, right: ScreenBarWingSlot(text: "Working", provider: "codex"))
        view.islandFrame = CGRect(x: 157.5, y: 16, width: 185, height: 32)
        view.relayout()
        let tray = try #require(view.trayRect)
        #expect(view.bandRect.maxY <= tray.minY,
                "the wings must not cut through the light")
        #expect(view.bandRect.minX == tray.minX)
        #expect(view.bandRect.maxX == tray.maxX)
    }

    @Test func standaloneWingsDoNotCoverTheLight() throws {
        let view = makeView()
        view.wings = ScreenBarWings(
            left: nil, right: ScreenBarWingSlot(text: "Working", provider: "codex"))
        view.relayout()
        let tray = try #require(view.trayRect)
        #expect(view.bandRect.maxY <= tray.minY)
        #expect(view.bandRect.minX == tray.minX)
        #expect(view.bandRect.maxX == tray.maxX)
    }

    @Test func aGrownCardKeepsTheLightAtItsFoot() {
        let view = makeView()
        view.frame.size.height = 320
        view.wings = ScreenBarWings(
            left: nil, right: ScreenBarWingSlot(text: "Working", provider: "codex"))
        view.islandFrame = CGRect(x: 60, y: 20, width: 380, height: 300)
        view.relayout()
        #expect(view.bandRect.maxY == 20)
        #expect(view.bandRect.width == 380)
        #expect(view.bandRect.minY >= 0)
    }

    @Test func wideNotchWingsDoNotWidenAGrownCardFootlight() {
        let view = makeView()
        view.frame.size.height = 320
        view.wingGeometry = ScreenBarWingGeometry(
            notchWidth: 300, notchDepth: 32, bandSpan: 328,
            leftExtent: 100, rightExtent: 100)
        view.wings = ScreenBarWings(
            left: ScreenBarWingSlot(text: "Working", provider: "claude"),
            right: ScreenBarWingSlot(text: "Working", provider: "codex"))
        view.menuHandleRevealed = false
        view.islandFrame = CGRect(x: 90, y: 20, width: 320, height: 300)
        view.relayout()
        #expect(view.bandRect.minX == 90)
        #expect(view.bandRect.width == 320)
    }

    @Test func theEarStandsWhileTheHandleLives() {
        let view = makeView()
        view.menuHandleRevealed = false    // concealed — the ‹ is the ear's
        let rect = view.rightWingRect
        #expect(rect != nil, "the ear should stand while the handle lives")
        #expect(rect?.width == 16, "the handle ear keeps its slim width")
        #expect(view.menuHandleRect != nil, "the handle slice must be hittable")
    }

    @Test func theRevealedHandleStandsTheSameEar() {
        let view = makeView()
        view.menuHandleRevealed = true     // run is out — the › rehide mark
        #expect(view.rightWingRect?.width == 16)
        #expect(view.menuHandleRect != nil)
    }

    @Test func theEarCollapsesWithNoHandleAndNoSlot() {
        let view = makeView()
        view.menuHandleRevealed = nil      // no concealer, no content
        #expect(view.rightWingRect == nil,
                "no handle and no slot means no ear — the claim is honest")
        #expect(view.menuHandleRect == nil)
    }

    @Test func aContentSlotWidensPastTheHandle() {
        let view = makeView()
        var wings = ScreenBarWings()
        wings.right = ScreenBarWingSlot(text: "track", visualizer: true)
        view.wings = wings
        view.menuHandleRevealed = false
        let rect = view.rightWingRect
        #expect(rect?.width == 52, "content ear + handle slice = 36 + 16")
        // The mark cedes the handle's slice — the slot rect stops short.
        #expect(view.menuHandleRect != nil)
    }
}
