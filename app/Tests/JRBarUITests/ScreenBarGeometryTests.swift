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
        #expect(frame == CGRect(x: 649.5, y: 946, width: 213, height: 36))
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
        #expect(Self.frame(wingLength: 40) == CGRect(x: 623.5, y: 946, width: 265, height: 36))
        // Even on a screen reporting no menu-bar areas at all.
        #expect(Self.frame(wingLength: 40, auxiliaryLeft: 0, auxiliaryRight: 0)
            == CGRect(x: 623.5, y: 946, width: 265, height: 36))
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
        #expect(ScreenBarGeometry.windowHeight(notchDepth: 32) == 36)
        #expect(ScreenBarGeometry.windowHeight(notchDepth: 0) == ScreenBarDesign.bandHeight + ScreenBarDesign.glowHeight + 2)
    }

    @Test func bandRectIsCentredAndNeverAHairline() {
        let rect = ScreenBarGeometry.bandRect(in: NSSize(width: 213, height: 38))
        #expect(rect == NSRect(x: 8, y: 1, width: 197, height: 4))
        let empty = ScreenBarGeometry.bandRect(in: NSSize(width: 0, height: 0))
        #expect(empty.width == 0)
        #expect(empty.height == 1)
    }

    @Test func bandRectAnchorsToTheBezelNotTheWindowFloor() {
        // A window grown past the base height (for a housing, say) keeps
        // the strip at the bezel's bottom edge — the same seat it has at
        // the base height.
        let tall = ScreenBarGeometry.bandRect(in: NSSize(width: 213, height: 45),
                                              underBezel: 32)
        #expect(tall.minY == 10)
        #expect(tall.maxY == 14)
        // At the base height the anchor agrees with the floor's answer.
        #expect(ScreenBarGeometry.bandRect(in: NSSize(width: 213, height: 36),
                                           underBezel: 32)
                == ScreenBarGeometry.bandRect(in: NSSize(width: 213, height: 36)))
        // No bezel → the standalone band keeps its bottom seat.
        let notchless = ScreenBarGeometry.bandRect(in: NSSize(width: 213, height: 45),
                                                   underBezel: 0)
        #expect(notchless.minY == 1)
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

    @Test func coupledStripSeatsInsideTheIslandsFoot() {
        // The coupled window: 38 tall (coupledWindowHeight(islandBottom:
        // 32)), island 209 wide — slot 185 + 12 pt shoulders — centred.
        let size = NSSize(width: 213, height: 38)
        let coupling = ScreenBarGeometry.coupledBand(in: size, island: Self.islandRect(width: 209, height: 32, in: size),
                                                     cornerRadius: 8)
        // The strip rides the island's bottom edge — 32…36 below the
        // screen's top — across the island's width, its end caps tucked
        // 2.7 pt in so the 8 pt corner never cuts them.
        let inset = ScreenBarGeometry.stripEndInset(cornerRadius: 8)
        #expect(abs(inset - (6 - sqrt(11))) < 1e-9)
        #expect(coupling.band == CGRect(x: 2 + inset, y: 2, width: 209 - 2 * inset, height: 4))
        // The housing swallows the island's bottom corners (its top runs
        // to 32 - 8 = 24 below the top), spans the island's full width
        // and ends 1 pt under the strip, on the profile's own corner.
        #expect(coupling.housing == CGRect(x: 2, y: 1, width: 209, height: 13))
        #expect(coupling.cornerRadius == 8)
    }

    @Test func theStripsEndCapsStayOnBlackAtEveryCorner() {
        // Every corner the silhouette takes — the Notch profile's 0…16
        // slider, the resting 8, the grown card's 28 — keeps the whole
        // strip, rounded caps included, inside the housing's outline,
        // with the least inset that does it (the cap touches the arc).
        let cap = ScreenBarDesign.bandHeight / 2
        for radius: CGFloat in [0, 2, 3, 5, 8, 12, 16, 28] {
            let size = NSSize(width: 380, height: 310)
            let coupling = ScreenBarGeometry.coupledBand(
                in: size, island: Self.islandRect(width: 380, height: 300, in: size), cornerRadius: radius)
            let band = coupling.band, housing = coupling.housing
            let r = coupling.cornerRadius
            #expect(band.minX >= housing.minX && band.maxX <= housing.maxX)
            #expect(band.minY >= housing.minY && band.maxY <= housing.maxY)
            // The left cap's centre against the bottom-left arc's centre.
            let capCentre = CGPoint(x: band.minX + cap, y: band.minY + cap)
            let arcCentre = CGPoint(x: housing.minX + r, y: housing.minY + r)
            guard capCentre.x < arcCentre.x, capCentre.y < arcCentre.y else { continue }
            let gap = hypot(arcCentre.x - capCentre.x, arcCentre.y - capCentre.y)
            #expect(gap <= r - cap + 1e-9, "radius \(radius): the cap pokes past the corner")
            #expect(gap >= r - cap - 1e-9, "radius \(radius): the strip is shorter than it needs to be")
        }
        // A corner no deeper than the cap's seat costs the strip nothing.
        #expect(ScreenBarGeometry.stripEndInset(cornerRadius: 3) == 0)
        #expect(ScreenBarGeometry.stripEndInset(cornerRadius: 0) == 0)
    }

    @Test func aGrownCardKeepsItsRoundFootAndTheStripFitsInside() {
        // The grown card's 28 pt corner stays the silhouette's: clamping
        // it to the 5 pt lip would square the card's foot into a slab.
        // The housing still climbs the full corner so it fills the
        // island's curve, and the strip stops ~19 pt short of each side.
        let size = NSSize(width: 380, height: 310)
        let coupling = ScreenBarGeometry.coupledBand(in: size, island: Self.islandRect(width: 380, height: 300, in: size),
                                                     cornerRadius: 28)
        #expect(coupling.cornerRadius == 28)
        #expect(coupling.housing.maxY == size.height - (300 - 28))
        let inset = ScreenBarGeometry.stripEndInset(cornerRadius: 28)
        #expect(abs(inset - (26 - sqrt(51))) < 1e-9)
        #expect(coupling.band.minX == inset && abs(coupling.band.maxX - (380 - inset)) < 1e-9)
    }

    @Test func coupledStripRidesTheGrownIslandBottom() {
        // The grown card's bottom edge is the seat: the strip and its
        // seat hang under the island's lip — never a bar clipped across
        // the card's face.
        let size = NSSize(width: 380, height: 310)
        let coupling = ScreenBarGeometry.coupledBand(in: size, island: Self.islandRect(width: 380, height: 300, in: size),
                                                     cornerRadius: 8)
        let inset = ScreenBarGeometry.stripEndInset(cornerRadius: 8)
        #expect(coupling.band == CGRect(x: inset, y: 6, width: 380 - 2 * inset, height: 4))
        // Top at 300 - 8 = 292 below the top; bottom at 305 — the lip
        // whose only visible edge is the corner curve under the strip.
        #expect(coupling.housing == CGRect(x: 0, y: 5, width: 380, height: 13))
    }

    @Test func theNoticeLineClearsTheHousingOverTheIslandsCorners() {
        // The bar's panel sits above the island's, so the housing's black
        // — climbing up behind the island's bottom corners — draws over
        // the island's foot. A notice sized for the housing keeps the
        // whole 11.5 pt system line box between the bezel and the
        // housing's top edge at every corner the Notch profile allows.
        let font = NSFont.systemFont(ofSize: 11.5)
        let lineBox = font.ascender - font.descender + font.leading
        #expect(NotchIslandLayout.noticeLineRoom >= lineBox)
        func housingTop(notice: CGSize, restingRadius: CGFloat) -> CGFloat {
            let size = NSSize(width: notice.width + 4,
                              height: ScreenBarGeometry.coupledWindowHeight(islandBottom: notice.height))
            let island = Self.islandRect(width: notice.width, height: notice.height, in: size)
            let coupling = ScreenBarGeometry.coupledBand(
                in: size, island: island,
                cornerRadius: NotchSilhouetteGeometry.radius(size: island.size, notchDepth: 32,
                                                             restingRadius: restingRadius))
            return size.height - coupling.housing.maxY
        }
        for rest in stride(from: CGFloat(0), through: 16, by: 1) {
            let notice = NotchIslandLayout.noticeSize(slotWidth: 185, notchDepth: 32, underHousing: rest)
            let top = housingTop(notice: notice, restingRadius: rest)
            #expect(top - 32 >= NotchIslandLayout.noticeLineRoom, "corner \(rest)")
            // The island measures the housing the bar draws.
            let climb = NotchIslandLayout.housingClimb(size: notice, notchDepth: 32, restingRadius: rest)
            #expect(abs(top - (notice.height - climb)) < 1e-9, "corner \(rest)")
        }
        // Negative control: the bare 22 pt lip at the standard 8 pt
        // corner puts the housing's top edge 43.4 pt down, 11.4 under
        // the bezel — through the line's caps.
        let bare = NotchIslandLayout.noticeSize(slotWidth: 185, notchDepth: 32)
        #expect(housingTop(notice: bare, restingRadius: 8) - 32 < lineBox)
    }

    @Test func coupledIslandGrowsTheWindowTowardIt() {
        // A grown island (the expanded card's 380) widens the window to
        // its own edges and drops the strip's seat to its bottom edge;
        // the top stays pinned.
        let island = CGRect(x: 566, y: 682, width: 380, height: 300)
        let frame = ScreenBarGeometry.windowFrame(screenFrame: Self.screen, slotWidth: 185, notchDepth: 32,
                                                  auxiliaryLeft: 300, auxiliaryRight: 300,
                                                  hardwareSlot: 185, wrapMenuBar: true,
                                                  coupledIsland: island)
        #expect(frame == CGRect(x: 566, y: 982 - 306, width: 380, height: 306))
        #expect(ScreenBarGeometry.coupledWindowHeight(islandBottom: 300) == 306)
    }

    @Test func coupledIslandNeverShrinksTheWindow() {
        // The idle island is narrower than the classic wrap frame: only
        // the height grows to seat the housing.
        let island = CGRect(x: 651.5, y: 950, width: 209, height: 32)
        let frame = ScreenBarGeometry.windowFrame(screenFrame: Self.screen, slotWidth: 185, notchDepth: 32,
                                                  auxiliaryLeft: 300, auxiliaryRight: 300,
                                                  hardwareSlot: 185, wrapMenuBar: true,
                                                  coupledIsland: island)
        #expect(frame == CGRect(x: 649.5, y: 982 - 38, width: 213, height: 38))
        // And nil is the standalone frame, untouched.
        #expect(Self.frame().height == 36)
    }

    @Test func coupledWindowLeavesRoomForTheWingUnderlight() {
        let island = CGRect(x: 651.5, y: 950, width: 209, height: 32)
        let frame = ScreenBarGeometry.windowFrame(
            screenFrame: Self.screen, slotWidth: 185, notchDepth: 32,
            auxiliaryLeft: 300, auxiliaryRight: 300, hardwareSlot: 185,
            wrapMenuBar: true, contentExtent: 60, chin: ScreenBarGeometry.wingEarDrop,
            coupledIsland: island)
        #expect(frame.height == ScreenBarGeometry.coupledWindowHeight(islandBottom: 32))
    }

    @Test func standaloneWindowLeavesRoomForTheWingUnderlight() {
        // Island parked, a wing claimed: the tray still seats the strip
        // in a housing under the bezel, so the window grows for its chin
        // and the halo even though the tray itself drops nothing. A
        // `chin > 0` guard left it at 36 and clipped both.
        let frame = ScreenBarGeometry.windowFrame(
            screenFrame: Self.screen, slotWidth: 185, notchDepth: 32,
            auxiliaryLeft: 300, auxiliaryRight: 300, hardwareSlot: 185,
            wrapMenuBar: true, contentExtent: 60, chin: ScreenBarGeometry.wingEarDrop)
        #expect(frame.height == ScreenBarGeometry.coupledWindowHeight(islandBottom: 32))
        #expect(frame.height == 38)
        #expect(frame.maxY == 982)
        // No claim, no housing: the plain band keeps the classic height.
        #expect(Self.wingedFrame(contentExtent: 0).height == 36)
        // A dropped tray (should one come back) still grows past it.
        let dropped = ScreenBarGeometry.windowFrame(
            screenFrame: Self.screen, slotWidth: 185, notchDepth: 32,
            auxiliaryLeft: 300, auxiliaryRight: 300, hardwareSlot: 185,
            wrapMenuBar: true, contentExtent: 60, chin: 6)
        #expect(dropped.height == ScreenBarGeometry.coupledWindowHeight(islandBottom: 38))
    }

    @Test func theRestingWrapEndsFivePointsUnderTheBezel() {
        // The whole flush seat in one place: the tray ends at the bezel,
        // the strip runs 32…36 below the screen's top, the housing's
        // chin ends at 37 — not the 11 pt black tab the 6 pt drop hung
        // over app content (black to 37.5, strip 38–42, content at 44).
        #expect(ScreenBarGeometry.wingEarDrop == 0)
        let size = NSSize(width: 213, height: ScreenBarGeometry.coupledWindowHeight(islandBottom: 32))
        let tray = CGRect(x: 0, y: size.height - 32, width: 213, height: 32)
        let coupling = ScreenBarGeometry.coupledBand(in: size, island: tray, cornerRadius: 8)
        #expect(size.height - coupling.band.maxY == 32)
        #expect(size.height - coupling.band.minY == 36)
        #expect(size.height - coupling.housing.minY == 37)
        #expect(coupling.housing.minY >= 0, "the window holds the housing")
    }

    // MARK: Ear limits (status items and app menu titles)

    @Test func menuTitlesLimitTheEarsLikeStatusItems() {
        // A 1512 pt screen, notch 663.5…848.5. The app's menus run to
        // 640 on the left and spill past the notch from 852.
        let titles = [CGRect(x: 0, y: 949, width: 40, height: 33),
                      CGRect(x: 590, y: 949, width: 50, height: 33),
                      CGRect(x: 852, y: 949, width: 60, height: 33),
                      CGRect(x: 912, y: 949, width: 44, height: 33)]
        let limits = ScreenBarGeometry.earLimits(itemLeft: nil, itemRight: 1100, menuTitles: titles,
                                                 screen: Self.screen, notchMidX: 756)
        #expect(limits.left == 640, "the last title left of the notch")
        #expect(limits.right == 852, "the first spilled title beats the farther status item")
    }

    @Test func theNearerOfItemAndTitleWinsEachFlank() {
        let titles = [CGRect(x: 300, y: 949, width: 50, height: 33)]
        let limits = ScreenBarGeometry.earLimits(itemLeft: 620, itemRight: 900, menuTitles: titles,
                                                 screen: Self.screen, notchMidX: 756)
        #expect(limits.left == 620, "a status item nearer the notch than the menus keeps the limit")
        #expect(limits.right == 900)
        let none = ScreenBarGeometry.earLimits(itemLeft: nil, itemRight: nil, menuTitles: [],
                                               screen: Self.screen, notchMidX: 756)
        #expect(none.left == nil && none.right == nil)
    }

    @Test func titlesOnAnotherScreenDoNotLimitTheEars() {
        // An external above the built-in: same x range, different y.
        let external = [CGRect(x: 600, y: 2000, width: 60, height: 24)]
        let limits = ScreenBarGeometry.earLimits(itemLeft: nil, itemRight: nil, menuTitles: external,
                                                 screen: Self.screen, notchMidX: 756)
        #expect(limits.left == nil && limits.right == nil)
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

extension ScreenBarGeometryTests {
    @Test func aSimulatedNotchClaimsACenteredHousingAndDefersToTheRealOne() {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // No aux areas, simulate off → no slot (the floating pill).
        #expect(ScreenBarGeometry.islandSlot(auxLeft: nil, auxRight: nil,
                                             screenFrame: frame, simulated: false) == nil)
        // Simulate on → a centered synthetic band.
        let sim = ScreenBarGeometry.islandSlot(auxLeft: nil, auxRight: nil,
                                               screenFrame: frame, simulated: true)
        #expect(sim?.centerX == 720)
        #expect(sim?.width == ScreenBarGeometry.simulatedNotchWidth)
        // A real notch wins over the simulation.
        let left = CGRect(x: 0, y: 950, width: 600, height: 32)
        let right = CGRect(x: 800, y: 950, width: 640, height: 32)
        let real = ScreenBarGeometry.islandSlot(auxLeft: left, auxRight: right,
                                                screenFrame: frame, simulated: true)
        #expect(real?.centerX == 700 && real?.width == 200)
        // Depth: real wins, simulated falls back, off stays zero.
        #expect(ScreenBarGeometry.islandDepth(real: 34, simulated: true) == 34)
        #expect(ScreenBarGeometry.islandDepth(real: 0, simulated: true)
                == ScreenBarGeometry.fallbackNotchDepth)
        #expect(ScreenBarGeometry.islandDepth(real: 0, simulated: false) == 0)
    }
}
