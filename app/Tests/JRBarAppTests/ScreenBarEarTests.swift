import AppKit
import Foundation
import Testing
@testable import JRBarApp

/// The right ear's claim: it is the menu handle's home while the
/// concealer runs — the ‹ glyph included, on-row status item or not.
/// The "right wing is hidden" bug was the ear collapsing to zero
/// width whenever the handle went nil and no slot filled the claim.
@Suite("Screen Bar ear claim")
@MainActor
struct ScreenBarEarTests {

    /// A window-sized view with a measured right claim — the geometry a
    /// notched screen answers when the right flank has room.
    private func makeView() -> ScreenBarView {
        let view = ScreenBarView(frame: NSRect(x: 0, y: 0, width: 500, height: 48))
        view.wingGeometry = ScreenBarWingGeometry(
            notchWidth: 185, notchDepth: 32, bandSpan: 500,
            leftExtent: 0, rightExtent: 60)
        return view
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
