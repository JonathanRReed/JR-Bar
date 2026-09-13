import AppKit
import Testing
@testable import JRBarUI

/// The Screen Bar's pure geometry: the `screen_bar_gap_width` /
/// `screen_bar_wing_length` overrides and the frame the panel takes.
/// The numbers are a notched MacBook's: 1512×982, a 32 pt notch, a
/// 185 pt slot and 300 pt menu-bar areas either side of it.
@Suite struct ScreenBarGeometryTests {
    static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    static func frame(gapWidth: CGFloat? = nil, wingLength: CGFloat? = nil, wrapMenuBar: Bool = true,
                      auxiliaryLeft: CGFloat = 300, auxiliaryRight: CGFloat = 300,
                      hardwareSlot: CGFloat = 185, slotWidth: CGFloat = 185) -> CGRect {
        ScreenBarGeometry.windowFrame(screenFrame: screen, slotWidth: slotWidth, notchDepth: 32,
                                      auxiliaryLeft: auxiliaryLeft, auxiliaryRight: auxiliaryRight,
                                      hardwareSlot: hardwareSlot, wrapMenuBar: wrapMenuBar,
                                      gapWidth: gapWidth, wingLength: wingLength)
    }

    @Test func automaticFrameMatchesTheClassicNumbers() {
        // No overrides: the same frame the pre-settings build computed.
        let frame = Self.frame()
        #expect(frame == CGRect(x: 649.5, y: 944, width: 213, height: 38))
    }

    @Test func noWrapMeansNoWings() {
        // The band is exactly the notch gap wide.
        let frame = Self.frame(wrapMenuBar: false)
        #expect(frame.width == 185)
        #expect(frame.midX == 756)
    }

    @Test func manualGapWidthReplacesTheMeasuredSlot() {
        let frame = Self.frame(gapWidth: 300)
        // notchWidth 300; the overhang (300 - 185) / 2 still leaves room
        // for the 14 pt auto wings: width = 300 + 28.
        #expect(frame.width == 328)
        #expect(frame.midX == 756)
    }

    @Test func gapWidthNilOrZeroMeasuresTheSlot() {
        #expect(Self.frame(gapWidth: 0) == Self.frame())
        #expect(Self.frame(gapWidth: nil) == Self.frame())
    }

    @Test func manualWingLengthWins() {
        #expect(Self.frame(wingLength: 40) == CGRect(x: 623.5, y: 944, width: 265, height: 38))
        // Even on a screen reporting no menu-bar areas at all.
        #expect(Self.frame(wingLength: 40, auxiliaryLeft: 0, auxiliaryRight: 0)
            == CGRect(x: 623.5, y: 944, width: 265, height: 38))
    }

    @Test func wingLengthNilOrZeroIsAutomatic() {
        #expect(Self.frame(wingLength: 0) == Self.frame())
        #expect(Self.frame(wingLength: nil) == Self.frame())
    }

    @Test func automaticWingNeedsUsableRoom() {
        // room = 300 - 28 - 0 = 272 → capped at the 14 pt auto length.
        #expect(ScreenBarGeometry.wingWidth(auxiliaryLeft: 300, auxiliaryRight: 300,
                                            hardwareSlot: 185, notchWidth: 185) == 14)
        // 50 - 28 = 22 < wingMinUsable (24) → no wing at all.
        #expect(ScreenBarGeometry.wingWidth(auxiliaryLeft: 50, auxiliaryRight: 300,
                                            hardwareSlot: 185, notchWidth: 185) == 0)
    }

    @Test func aWiderNotchGapEatsIntoTheWingRoom() {
        // notchWidth 300 on a 200 pt hardware slot: 50 pt of overhang per
        // side; 100 pt areas leave 100 - 28 - 50 = 22 < 24 → no wing.
        #expect(ScreenBarGeometry.wingWidth(auxiliaryLeft: 100, auxiliaryRight: 100,
                                            hardwareSlot: 200, notchWidth: 300) == 0)
        // notchWidth matching the slot has no overhang.
        #expect(ScreenBarGeometry.wingWidth(auxiliaryLeft: 100, auxiliaryRight: 100,
                                            hardwareSlot: 200, notchWidth: 200) == 14)
    }

    @Test func windowHeightFollowsTheNotchDepth() {
        #expect(ScreenBarGeometry.windowHeight(notchDepth: 32) == 38)
        #expect(ScreenBarGeometry.windowHeight(notchDepth: 0) == ScreenBarDesign.bandHeight + ScreenBarDesign.glowHeight + 2)
    }

    @Test func bandRectIsCentredAndNeverAHairline() {
        let rect = ScreenBarGeometry.bandRect(in: NSSize(width: 213, height: 38))
        #expect(rect == NSRect(x: 8, y: 1, width: 197, height: 6))
        let empty = ScreenBarGeometry.bandRect(in: NSSize(width: 0, height: 0))
        #expect(empty.width == 0)
        #expect(empty.height == 1)
    }
}
