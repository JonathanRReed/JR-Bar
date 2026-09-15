import AppKit
import JRBarCore
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

    // MARK: Content wings (`screen_bar_notch_wings`)

    static func wingedFrame(contentExtent: CGFloat, auxiliaryLeft: CGFloat = 300,
                            auxiliaryRight: CGFloat = 300) -> CGRect {
        ScreenBarGeometry.windowFrame(screenFrame: screen, slotWidth: 185, notchDepth: 32,
                                      auxiliaryLeft: auxiliaryLeft, auxiliaryRight: auxiliaryRight,
                                      hardwareSlot: 185, wrapMenuBar: true,
                                      contentExtent: contentExtent)
    }

    @Test func contentWingExtentMeasuresEachFlank() {
        // 300 pt area: 300 - 28 safety - 16 inner reserve - 6 outer inset
        // = 250 usable → capped at the 132 pt max extent.
        #expect(ScreenBarGeometry.contentWingExtent(auxiliaryWidth: 300, hardwareSlot: 185,
                                                    notchWidth: 185) == 132)
        // 70 pt of area leaves 70 - 28 - 22 = 20 usable — under the
        // minimum, so the wing collapses rather than overdraw the menu.
        #expect(ScreenBarGeometry.contentWingExtent(auxiliaryWidth: 70, hardwareSlot: 185,
                                                    notchWidth: 185) == 0)
        // 90 pt leaves 40 usable → extent 62.
        #expect(ScreenBarGeometry.contentWingExtent(auxiliaryWidth: 90, hardwareSlot: 185,
                                                    notchWidth: 185) == 62)
        // A gap set wider than the hardware slot eats into the room.
        #expect(ScreenBarGeometry.contentWingExtent(auxiliaryWidth: 300, hardwareSlot: 185,
                                                    notchWidth: 300) == 132)
        #expect(ScreenBarGeometry.contentWingExtent(auxiliaryWidth: 0, hardwareSlot: 185,
                                                    notchWidth: 185) == 0)
    }

    @Test func contentExtentWidensTheWindowNotTheBand() {
        let frame = Self.wingedFrame(contentExtent: 132)
        #expect(frame.width == 449)
        #expect(frame.midX == 756)
        // The band keeps the span it would have had without the claim.
        let band = ScreenBarGeometry.bandRect(in: frame.size, preferredSpan: 213)
        #expect(band.width == 197)
        // A followed capsule owns the flanks — the claim is ignored.
        let capsule = AlcoveCapsule(centerX: 756, width: 320, depth: 40)
        let followed = ScreenBarGeometry.windowFrame(screenFrame: Self.screen, slotWidth: 185, notchDepth: 32,
                                                     auxiliaryLeft: 300, auxiliaryRight: 300,
                                                     hardwareSlot: 185, wrapMenuBar: true,
                                                     capsule: capsule, contentExtent: 132)
        #expect(followed.width == 320)
    }

    @Test func wingSlotRectsSitAtMenuBarHeight() {
        let size = NSSize(width: 185 + 2 * 132, height: 38)
        let geometry = ScreenBarWingGeometry(notchWidth: 185, notchDepth: 32,
                                             leftExtent: 132, rightExtent: 132)
        let left = ScreenBarGeometry.wingSlotRect(.left, in: size, geometry: geometry)
        let right = ScreenBarGeometry.wingSlotRect(.right, in: size, geometry: geometry)
        // The claim anchors at the notch's edge (x 132) and reaches
        // outward through the measured room: 132 - 6 outer inset = 126,
        // and spans the notch's full 32 pt depth at the window's top —
        // the lobe is flush with the screen edge, like the bezel's ear.
        #expect(left == CGRect(x: 6, y: 6, width: 126, height: 32))
        #expect(right == CGRect(x: 449 - 132, y: 6, width: 126, height: 32))
        // Unclaimed sides draw nothing.
        let none = ScreenBarWingGeometry(notchWidth: 185, notchDepth: 32)
        #expect(ScreenBarGeometry.wingSlotRect(.left, in: size, geometry: none) == nil)
        // A claim too small for the minimum collapses.
        let tight = ScreenBarWingGeometry(notchWidth: 185, notchDepth: 32,
                                          leftExtent: 38)
        let tightSize = NSSize(width: 185 + 2 * 38, height: 38)
        #expect(ScreenBarGeometry.wingSlotRect(.left, in: tightSize, geometry: tight) == nil)
        // A manual wing length widening the window past the measured
        // claim does not widen the chip into unmeasured menu-bar room —
        // the claim still anchors at the notch edge (x 200) and reaches
        // 62 - 6 = 56 outward.
        let oversized = NSSize(width: 185 + 2 * 200, height: 38)
        let measured = ScreenBarWingGeometry(notchWidth: 185, notchDepth: 32,
                                             leftExtent: 62)
        #expect(ScreenBarGeometry.wingSlotRect(.left, in: oversized, geometry: measured)
            == CGRect(x: 144, y: 6, width: 56, height: 32))
    }

    // MARK: Island coupling (the band reads as part of the notch island)

    /// The island's frame in view coordinates: idle it is exactly the
    /// notch's depth, hanging from the window's top.
    static func islandRect(width: CGFloat, height: CGFloat, in size: NSSize) -> CGRect {
        CGRect(x: (size.width - width) / 2, y: size.height - height, width: width, height: height)
    }

    @Test func coupledStripKissesTheIslandEdges() {
        // The coupled window: 41 tall (coupledWindowHeight(32)), island
        // 209 wide — slot 185 + 12 pt shoulders — centred inside it.
        let size = NSSize(width: 213, height: 41)
        let coupling = ScreenBarGeometry.coupledBand(in: size, island: Self.islandRect(width: 209, height: 32, in: size),
                                                     notchDepth: 32, cornerRadius: 8)
        // The strip keeps its seat — 31…37 below the screen's top — but
        // runs the island's full width: end caps kissing its side edges.
        #expect(coupling.band == CGRect(x: 2, y: 4, width: 209, height: 6))
        // The housing swallows the island's bottom corners (its top runs
        // to 32 - 8 = 24 below the top) and ends 3 pt under the strip.
        #expect(coupling.housing == CGRect(x: 2, y: 1, width: 209, height: 16))
        #expect(coupling.cornerRadius == 8)
    }

    @Test func coupledHousingHidesInsideAGrownIsland() {
        // The grown card's bottom is far below the band — the housing's
        // lip only has to reach the strip, since the island's own black
        // face is already behind everything.
        let size = NSSize(width: 380, height: 41)
        let coupling = ScreenBarGeometry.coupledBand(in: size, island: Self.islandRect(width: 380, height: 300, in: size),
                                                     notchDepth: 32, cornerRadius: 8)
        #expect(coupling.band == CGRect(x: 0, y: 4, width: 380, height: 6))
        // Top at 31 - 4 = 27 below the top; bottom at 40 — a 13 pt lip
        // whose only visible edge is the corner curve under the strip.
        #expect(coupling.housing == CGRect(x: 0, y: 1, width: 380, height: 13))
    }

    @Test func coupledIslandGrowsTheWindowTowardIt() {
        // A grown island (the expanded card's 380) widens the window to
        // its own edges and seats the housing; the top stays pinned.
        let island = CGRect(x: 566, y: 682, width: 380, height: 300)
        let frame = ScreenBarGeometry.windowFrame(screenFrame: Self.screen, slotWidth: 185, notchDepth: 32,
                                                  auxiliaryLeft: 300, auxiliaryRight: 300,
                                                  hardwareSlot: 185, wrapMenuBar: true,
                                                  coupledIsland: island)
        #expect(frame == CGRect(x: 566, y: 982 - 41, width: 380, height: 41))
        #expect(ScreenBarGeometry.coupledWindowHeight(notchDepth: 32) == 41)
    }

    @Test func coupledIslandNeverShrinksTheWindow() {
        // The idle island is narrower than the classic wrap frame: only
        // the height grows to seat the housing.
        let island = CGRect(x: 651.5, y: 950, width: 209, height: 32)
        let frame = ScreenBarGeometry.windowFrame(screenFrame: Self.screen, slotWidth: 185, notchDepth: 32,
                                                  auxiliaryLeft: 300, auxiliaryRight: 300,
                                                  hardwareSlot: 185, wrapMenuBar: true,
                                                  coupledIsland: island)
        #expect(frame == CGRect(x: 649.5, y: 982 - 41, width: 213, height: 41))
        // And nil is the standalone frame, untouched.
        #expect(Self.frame().height == 38)
    }

    @Test func notchlessSlotsFlankTheBand() {
        // No notch: the window is the 260 pt fallback plus a fixed claim
        // per populated side, and the chips hug the band's ends.
        let geometry = ScreenBarWingGeometry(notchWidth: 260, notchDepth: 0, bandSpan: 260,
                                             leftExtent: 120, rightExtent: 120)
        let size = NSSize(width: 260 + 2 * 120, height: 22)
        let left = ScreenBarGeometry.wingSlotRect(.left, in: size, geometry: geometry)
        let right = ScreenBarGeometry.wingSlotRect(.right, in: size, geometry: geometry)
        // Band: 500 - 16 = 244 centred → x 128...372; chips 84 wide, 5 pt off its ends.
        #expect(left == CGRect(x: 39, y: 1, width: 84, height: 18))
        #expect(right == CGRect(x: 377, y: 1, width: 84, height: 18))
    }
}

@Suite struct NotchProfileTests {
    @Test func settingParsesAndAnythingUnknownIsAutomatic() {
        #expect(NotchProfile(setting: "auto") == .auto)
        #expect(NotchProfile(setting: "macbook_pro_14") == .macbookPro14)
        #expect(NotchProfile(setting: "custom") == .custom)
        #expect(NotchProfile(setting: nil) == .auto)
        #expect(NotchProfile(setting: "performa") == .auto)
    }

    @Test func everyBuiltInProfileResolvesTheMeasuredRadius() {
        // The hardware cutout's bottom corner is ~8 pt on every notched
        // MacBook — the named models agree; they exist so the override
        // is real, and so a future panel with a different cutout has a
        // place to land.
        for profile in [NotchProfile.auto, .macbookAir13, .macbookAir15, .macbookPro14, .macbookPro16] {
            #expect(profile.cornerRadius() == NotchProfile.standardCornerRadius)
        }
    }

    @Test func customRadiusIsTheSliderClampedToSanity() {
        #expect(NotchProfile.custom.cornerRadius(manual: 12) == 12)
        #expect(NotchProfile.custom.cornerRadius(manual: -3) == 0)
        #expect(NotchProfile.custom.cornerRadius(manual: 40) == 16)
        #expect(NotchProfile.custom.cornerRadius(manual: nil) == NotchProfile.standardCornerRadius,
                "a custom profile with no stored value still draws the standard corner")
    }

    @Test func machineModelReadsHwModel() {
        #expect(!NotchProfile.machineModel.isEmpty, "sysctl hw.model always answers on a Mac")
        #expect(!NotchProfile.machineFamily.isEmpty)
    }
}
