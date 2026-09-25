import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Enhance mode's pure machinery (the hover debounce, the AX↔AppKit
/// geometry, the thumbnail match), the icon rasterizer, and
/// `AppleDockControl`'s `autohide-delay` restore from the crash-safe
/// keys an old Replace build's hide left — kept because a Mac that bar
/// left hidden must still get Apple's Dock back.
@MainActor
@Suite struct DockEnhanceTests {

    // MARK: Hover debounce

    @Test func aRestedIconOpensThePanel() {
        var tracker = DockHoverTracker()
        #expect(tracker.note(hovered: "Safari", pointerInPanel: false,
                             now: 0, delay: 0.25) == .none)
        #expect(tracker.note(hovered: "Safari", pointerInPanel: false,
                             now: 0.24, delay: 0.25) == .none)
        #expect(tracker.note(hovered: "Safari", pointerInPanel: false,
                             now: 0.26, delay: 0.25) == .show("Safari"))
        #expect(tracker.shown == "Safari")
    }

    @Test func aQuickPassDoesNotOpen() {
        var tracker = DockHoverTracker()
        #expect(tracker.note(hovered: "Safari", pointerInPanel: false,
                             now: 0, delay: 0.25) == .none)
        #expect(tracker.note(hovered: "Mail", pointerInPanel: false,
                             now: 0.1, delay: 0.25) == .none)
        #expect(tracker.shown == nil, "each icon restarts the rest clock")
    }

    @Test func leavingPastTheGraceCloses() {
        var tracker = DockHoverTracker()
        _ = tracker.note(hovered: "Safari", pointerInPanel: false, now: 0, delay: 0.1)
        _ = tracker.note(hovered: "Safari", pointerInPanel: false, now: 0.2, delay: 0.1)
        #expect(tracker.shown == "Safari")
        #expect(tracker.note(hovered: nil, pointerInPanel: false,
                             now: 0.3, delay: 0.1) == .none,
                "inside the grace, the panel holds")
        #expect(tracker.note(hovered: nil, pointerInPanel: false,
                             now: 0.3 + DockHoverTracker.grace + 0.01, delay: 0.1) == .hide)
        #expect(tracker.shown == nil)
    }

    @Test func thePointerOnThePanelKeepsItOpen() {
        var tracker = DockHoverTracker()
        _ = tracker.note(hovered: "Safari", pointerInPanel: false, now: 0, delay: 0.1)
        _ = tracker.note(hovered: "Safari", pointerInPanel: false, now: 0.2, delay: 0.1)
        #expect(tracker.note(hovered: nil, pointerInPanel: true,
                             now: 1.0, delay: 0.1) == .none,
                "hovering the preview is not leaving")
        #expect(tracker.shown == "Safari")
    }

    @Test func movingToAnotherIconRetargets() {
        var tracker = DockHoverTracker()
        _ = tracker.note(hovered: "Safari", pointerInPanel: false, now: 0, delay: 0.1)
        _ = tracker.note(hovered: "Safari", pointerInPanel: false, now: 0.2, delay: 0.1)
        #expect(tracker.note(hovered: "Mail", pointerInPanel: false,
                             now: 0.3, delay: 0.1) == .none)
        #expect(tracker.note(hovered: "Mail", pointerInPanel: false,
                             now: 0.41, delay: 0.1) == .show("Mail"),
                "the rested new icon takes the panel over — no flicker")
    }

    @Test("a middle click or an upward scroll opens the panel at once; the rest's grace still closes it")
    func summonSkipsTheRest() {
        var tracker = DockHoverTracker()
        #expect(tracker.summon("Safari", now: 0) == .show("Safari"), "no delay for a deliberate summon")
        #expect(tracker.summon("Safari", now: 0.1) == .none, "the same tile again is no second show")
        #expect(tracker.note(hovered: "Safari", pointerInPanel: false, now: 0.2, delay: 0.25) == .none)
        _ = tracker.note(hovered: nil, pointerInPanel: false, now: 0.3, delay: 0.25)
        #expect(tracker.note(hovered: nil, pointerInPanel: false,
                             now: 0.3 + DockHoverTracker.grace + 0.01, delay: 0.25) == .hide)
    }

    @Test("trigger modes: ⌥ gates a rest, Middle Click never rests one open, the shown tile always holds")
    func triggerModesGateTheRest() {
        typealias T = DockHoverTracker
        #expect(T.trackedItem("Safari", shown: nil, trigger: .hover, optionHeld: false) == "Safari")
        #expect(T.trackedItem("Safari", shown: nil, trigger: .optionHover, optionHeld: false) == nil)
        #expect(T.trackedItem("Safari", shown: nil, trigger: .optionHover, optionHeld: true) == "Safari")
        #expect(T.trackedItem("Safari", shown: nil, trigger: .middleClick, optionHeld: true) == nil)
        #expect(T.trackedItem("Safari", shown: "Safari", trigger: .middleClick, optionHeld: false) == "Safari",
                "the summoned tile under the pointer keeps its panel")
        #expect(T.trackedItem("Safari", shown: "Safari", trigger: .optionHover, optionHeld: false) == "Safari",
                "letting go of ⌥ doesn't close the panel under the pointer")
        #expect(T.trackedItem("Mail", shown: "Safari", trigger: .optionHover, optionHeld: false) == nil,
                "a retarget needs ⌥ too")
        #expect(T.trackedItem(nil, shown: "Safari", trigger: .hover, optionHeld: true) == nil)
    }

    @Test("only a click on the app already in front minimizes it")
    func clickToMinimizeNeedsTheFrontApp() {
        #expect(DockEnhanceMath.clickMinimizes(appPID: 7, frontmostPID: 7,
                                               lastActivation: (7, 10), clickAt: 20))
        #expect(!DockEnhanceMath.clickMinimizes(appPID: 7, frontmostPID: 7,
                                                lastActivation: (7, 20.05), clickAt: 20),
                "an activation stamped after the click is the click's own — the Dock just brought it forward")
        #expect(!DockEnhanceMath.clickMinimizes(appPID: 7, frontmostPID: 3,
                                                lastActivation: (3, 10), clickAt: 20))
        #expect(DockEnhanceMath.clickMinimizes(appPID: 7, frontmostPID: 7,
                                               lastActivation: (3, 10), clickAt: 20),
                "front since before we watched — judged by the front app alone")
        #expect(DockEnhanceMath.clickMinimizes(appPID: 7, frontmostPID: 7, lastActivation: nil, clickAt: 20))
    }

    @Test("a wheel's notches and a trackpad's points meet one flick threshold")
    func scrollUnits() {
        #expect(DockEnhanceMath.scrollAmount(12, precise: true) == 12)
        #expect(DockEnhanceMath.scrollAmount(1, precise: false) == 20)
        var flick = DockEnhanceMath.SwipeAccumulator()
        let notch = DockEnhanceMath.scrollAmount(1, precise: false)
        #expect(flick.note(deltaY: notch, inverted: false, now: 0) == nil)
        #expect(flick.note(deltaY: notch, inverted: false, now: 0.05) == nil)
        #expect(flick.note(deltaY: notch, inverted: false, now: 0.1) == .up,
                "three wheel-up notches are a deliberate scroll up")
    }

    // MARK: Geometry

    @Test func axAndAppKitCoordinatesFlip() {
        #expect(DockEnhanceMath.axPoint(CGPoint(x: 100, y: 50), mainScreenHeight: 1000)
                == CGPoint(x: 100, y: 950))
        #expect(DockEnhanceMath.appKitRect(CGRect(x: 10, y: 900, width: 20, height: 30),
                                           mainScreenHeight: 1000)
                == CGRect(x: 10, y: 70, width: 20, height: 30))
    }

    @Test func theDockEdgeIsTheNearestScreenEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(DockEnhanceMath.dockEdge(listFrame: CGRect(x: 200, y: 0, width: 1000, height: 70),
                                         screen: screen) == .bottom)
        #expect(DockEnhanceMath.dockEdge(listFrame: CGRect(x: 0, y: 200, width: 70, height: 500),
                                         screen: screen) == .left)
        #expect(DockEnhanceMath.dockEdge(listFrame: CGRect(x: 1370, y: 200, width: 70, height: 500),
                                         screen: screen) == .right)
    }

    @Test func tilesCarveTheVisibleFrameInQuartzSpace() {
        // Quartz: minY is the screen's TOP, so "top" tiles pin at minY.
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        #expect(DockEnhanceMath.tileFrame(.leftHalf, in: visible)
                == CGRect(x: 0, y: 25, width: 720, height: 875))
        #expect(DockEnhanceMath.tileFrame(.rightHalf, in: visible)
                == CGRect(x: 720, y: 25, width: 720, height: 875))
        #expect(DockEnhanceMath.tileFrame(.topHalf, in: visible)
                == CGRect(x: 0, y: 25, width: 1440, height: 437.5))
        #expect(DockEnhanceMath.tileFrame(.bottomHalf, in: visible)
                == CGRect(x: 0, y: 462.5, width: 1440, height: 437.5))
        #expect(DockEnhanceMath.tileFrame(.topLeft, in: visible)
                == CGRect(x: 0, y: 25, width: 720, height: 437.5))
        #expect(DockEnhanceMath.tileFrame(.bottomRight, in: visible)
                == CGRect(x: 720, y: 462.5, width: 720, height: 437.5))
        // A second screen's offset frame tiles inside itself.
        let side = CGRect(x: -1440, y: 25, width: 1440, height: 875)
        #expect(DockEnhanceMath.tileFrame(.topRight, in: side)
                == CGRect(x: -720, y: 25, width: 720, height: 437.5))
    }

    @Test func thePanelOpensOffTheDockTowardTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let item = CGRect(x: 700, y: 0, width: 40, height: 40)
        let size = CGSize(width: 200, height: 100)
        let bottom = DockEnhanceMath.panelFrame(anchor: item, edge: .bottom,
                                                size: size, screen: screen, gap: 10)
        #expect(bottom == CGRect(x: 620, y: 84, width: 200, height: 100),
                "centred on the tile (mid 720), floating off the dock")
        let right = DockEnhanceMath.panelFrame(
            anchor: CGRect(x: 1400, y: 400, width: 40, height: 40), edge: .right,
            size: size, screen: screen, gap: 10)
        #expect(right.origin.x == 1156, "a right-edge dock opens left of it")
    }

    @Test func coveringTheLabelTheGlassSitsTheCardsDistanceOffTheIcon() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 200, height: 100)
        let covering = DockPlacement(gap: 4, coversLabel: true)
        let bottomItem = CGRect(x: 700, y: 0, width: 55, height: 62)
        let bottom = covering.frame(anchor: bottomItem, edge: .bottom, size: size, screen: screen,
                                    title: "Ghostty")
        #expect(bottom.minY - bottomItem.maxY == 4, "the glass sits 4 pt above the icon, over the name bubble")
        let leftItem = CGRect(x: 0, y: 400, width: 62, height: 55)
        let left = covering.frame(anchor: leftItem, edge: .left, size: size, screen: screen,
                                  title: "T3 Code (Nightly)")
        #expect(left.minX - leftItem.maxX == 4, "a side Dock's long name keeps no band either")
        let rightItem = CGRect(x: 1378, y: 400, width: 62, height: 55)
        let right = covering.frame(anchor: rightItem, edge: .right, size: size, screen: screen,
                                   title: "Visual Studio Code")
        #expect(rightItem.minX - right.maxX == 4)
        for gap in [CGFloat(0), 12, 40] {
            let place = DockPlacement(gap: gap, coversLabel: true)
            let frame = place.frame(anchor: bottomItem, edge: .bottom, size: size, screen: screen, title: "Safari")
            #expect(frame.minY - bottomItem.maxY == max(DockEnhanceMath.minimumGap, gap),
                    "gap \(gap) lands as asked, never under the corridor's floor")
        }
    }

    @Test func notCoveringTheLabelThePanelLeavesTheBubblesBand() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 200, height: 100)
        let classic = DockPlacement(gap: 4, coversLabel: false)
        let bottomItem = CGRect(x: 700, y: 0, width: 40, height: 40)
        let bottom = classic.frame(anchor: bottomItem, edge: .bottom, size: size, screen: screen, title: "Safari")
        #expect(bottom.minY - bottomItem.maxY >= 4 + DockEnhanceMath.nativeLabelHeight,
                "the native app-name bubble fits between a bottom Dock icon and the preview")

        let sideClearance = DockEnhanceMath.nativeLabelClearance(title: "T3 Code (Nightly)", edge: .left)
        #expect(sideClearance > DockEnhanceMath.nativeLabelHeight)
        #expect(sideClearance <= DockEnhanceMath.nativeSideLabelLimit)
        let leftItem = CGRect(x: 0, y: 400, width: 40, height: 40)
        let left = classic.frame(anchor: leftItem, edge: .left, size: size, screen: screen,
                                 title: "T3 Code (Nightly)")
        #expect(left.minX - leftItem.maxX >= 4 + sideClearance,
                "the native app-name bubble fits beside a left Dock icon")
        let rightItem = CGRect(x: 1400, y: 400, width: 40, height: 40)
        let right = classic.frame(anchor: rightItem, edge: .right, size: size, screen: screen,
                                  title: "T3 Code (Nightly)")
        #expect(rightItem.minX - right.maxX >= 4 + sideClearance,
                "the native app-name bubble fits beside a right Dock icon")
        #expect(classic.reach(anchor: bottomItem, edge: .bottom) == 0)
        #expect(DockPlacement(gap: 4, coversLabel: false, magnifying: true, largesize: 128)
            .reach(anchor: bottomItem, edge: .bottom) == 0,
                "under the Dock's level a magnified icon draws over the panel anyway")
    }

    @Test func coveringUnderMagnificationTheGlassClearsTheSwollenIcon() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 200, height: 100)
        let tile = CGRect(x: 700, y: 0, width: 55, height: 62)
        let set = DockPlacement(gap: 4, coversLabel: true, magnifying: true, largesize: 96)
        let frame = set.frame(anchor: tile, edge: .bottom, size: size, screen: screen, title: "Ghostty")
        let setReach: CGFloat = 96 - 62
        #expect(frame.minY - tile.maxY == 4 + setReach, "the gap plus largesize less the tile")
        let unset = DockPlacement(gap: 4, coversLabel: true, magnifying: true, largesize: nil)
        let far = unset.frame(anchor: tile, edge: .bottom, size: size, screen: screen, title: "Ghostty")
        let defaultReach: CGFloat = 128 - 62
        #expect(far.minY - tile.maxY == 4 + defaultReach, "an unset largesize is the Dock's own 128")
        let side = CGRect(x: 0, y: 400, width: 62, height: 55)
        let left = unset.frame(anchor: side, edge: .left, size: size, screen: screen, title: "Ghostty")
        #expect(left.minX - side.maxX == 4 + defaultReach, "a side Dock swells across its width")
        #expect(DockEnhanceMath.magnifiedReach(tileExtent: 140, largesize: 128) == 0,
                "a tile already bigger than the magnified size reaches nothing")
    }

    @Test func aToastOverAPinnedPreviewStillClearsTheSwollenIcon() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 160, height: 28)
        let tile = CGRect(x: 700, y: 0, width: 55, height: 62)
        // A ⌥`-pinned preview's placement magnifies nothing; a ⌘-right-
        // click on a tile while it is up still swells that tile.
        let pinned = DockPlacement(gap: 4, coversLabel: true, magnifying: false, largesize: 96)
        let toastPlace = pinned.onDock(magnifying: true)
        let frame = toastPlace.frame(anchor: tile, edge: .bottom, size: size, screen: screen, title: "Ghostty")
        let lift: CGFloat = 96 - 62
        #expect(frame.minY - tile.maxY == 4 + lift, "the toast rides above the magnified icon")
        #expect(toastPlace.gap == pinned.gap && toastPlace.coversLabel && toastPlace.largesize == 96,
                "only the magnifying flag changes")
        let flat = pinned.onDock(magnifying: false)
            .frame(anchor: tile, edge: .bottom, size: size, screen: screen, title: "Ghostty")
        #expect(flat.minY - tile.maxY == 4, "a Dock that doesn't magnify gets the plain gap")
    }

    @Test func coveringTheGlassNeverDriftsAcrossTheIcon() {
        #expect(DockPlacement(gap: 4, coversLabel: true).openingDrift == 3, "a point short of the 4 pt gap")
        #expect(DockPlacement(gap: 0, coversLabel: true).openingDrift == 1, "the corridor's 2 pt floor, less one")
        #expect(DockPlacement(gap: 40, coversLabel: true).openingDrift == 10, "a far panel drifts the full 10")
        #expect(DockPlacement(gap: 4, coversLabel: false).openingDrift == 10, "under the Dock the Dock draws on top")
    }

    @Test func thePanelsLevelFollowsTheCoverWhileItIsUp() {
        let panel = DockPreviewPanel(content: DockPreviewContent())
        panel.hold(DockPlacement(gap: 4, coversLabel: true))
        #expect(panel.level == .statusBar, "covering, it rides over the Dock's window")
        panel.hold(DockPlacement(gap: 4, coversLabel: false))
        #expect(panel.level == DockPreviewPanel.level(coversLabel: false))
        #expect(panel.level.rawValue == Int(CGWindowLevelForKey(.dockWindow)) - 1, "just under the Dock")
    }

    @Test func aCardThatHugsItsWindowTakesItsShapeWithinBounds() {
        let small = DockEnhanceMath.cardSize(large: false)
        #expect(DockEnhanceMath.cardSize(large: false, aspect: nil) == small, "no aspect keeps the 16:10 box")
        #expect(DockEnhanceMath.cardSize(large: false, aspect: .nan) == small)
        #expect(DockEnhanceMath.cardSize(large: false, aspect: 1.6) == CGSize(width: 144, height: 90))
        #expect(DockEnhanceMath.cardSize(large: false, aspect: 300.0 / 520) == CGSize(width: 54, height: 90),
                "a phone-tall window: a narrow card at 0.6 of the height")
        #expect(DockEnhanceMath.cardSize(large: false, aspect: 4) == CGSize(width: 171, height: 90),
                "a ribbon-wide window stops at 1.9 of the height")
        #expect(DockEnhanceMath.cardSize(large: false, aspect: 1) == CGSize(width: 90, height: 90))
        #expect(DockEnhanceMath.cardSize(large: true, aspect: 0.75) == CGSize(width: 98, height: 130))
        let framed = DockPreviewWindow(id: 1, title: "", minimized: false, fullScreen: nil,
                                       frame: CGRect(x: 0, y: 0, width: 400, height: 800), thumbnail: nil,
                                       element: nil)
        #expect(DockEnhanceMath.aspect(of: framed) == 0.5, "the frame answers before any still lands")
        let bare = DockPreviewWindow(id: 2, title: "", minimized: false, fullScreen: nil, frame: nil,
                                     thumbnail: nil, element: nil)
        #expect(DockEnhanceMath.aspect(of: bare) == nil)
    }

    @Test func theRoadToTheCardsHoldsAtEveryDistance() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 300, height: 120)
        for gap in [CGFloat(0), 40] {
            let place = DockPlacement(gap: gap, coversLabel: true)
            let bottomItem = CGRect(x: 700, y: 0, width: 55, height: 62)
            let bottom = place.frame(anchor: bottomItem, edge: .bottom, size: size, screen: screen, title: "Safari")
            let up = CGPoint(x: bottomItem.midX, y: (bottomItem.maxY + bottom.minY) / 2)
            #expect(DockEnhanceMath.inCorridor(item: bottomItem, panel: bottom, edge: .bottom, point: up, slop: 6),
                    "halfway up at gap \(gap)")
            let leftItem = CGRect(x: 0, y: 400, width: 62, height: 55)
            let left = place.frame(anchor: leftItem, edge: .left, size: size, screen: screen, title: "Safari")
            let across = CGPoint(x: (leftItem.maxX + left.minX) / 2, y: leftItem.midY)
            #expect(DockEnhanceMath.inCorridor(item: leftItem, panel: left, edge: .left, point: across, slop: 6),
                    "halfway across at gap \(gap)")
        }
    }

    @Test func thePanelCentresOnTheTileClampedToTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 200, height: 100)
        // The panel sits over its app — the DockDoor read — and only
        // leaves the tile's axis when the screen's edge demands it.
        let middle = DockEnhanceMath.panelFrame(
            anchor: CGRect(x: 700, y: 0, width: 40, height: 40), edge: .bottom,
            size: size, screen: screen, gap: 10)
        #expect(middle.midX == 720, "mid-screen tile: panel centred on it")
        let leftTile = DockEnhanceMath.panelFrame(
            anchor: CGRect(x: 0, y: 0, width: 40, height: 40), edge: .bottom,
            size: size, screen: screen, gap: 10)
        #expect(leftTile.minX == 8, "edge tile: clamped inside, still over it")
        #expect(leftTile.minX <= 20 && leftTile.maxX >= 20,
                "the tile's mid stays under the panel")
        let rightTile = DockEnhanceMath.panelFrame(
            anchor: CGRect(x: 1400, y: 0, width: 40, height: 40), edge: .bottom,
            size: size, screen: screen, gap: 10)
        #expect(rightTile.maxX == 1432, "right-edge tile: clamped inside")
        #expect(rightTile.minX <= 1420 && rightTile.maxX >= 1420)
        // A mid-list tile off-centre centres the panel on it, not on
        // the screen.
        let offCentre = DockEnhanceMath.panelFrame(
            anchor: CGRect(x: 200, y: 0, width: 40, height: 40), edge: .bottom,
            size: size, screen: screen, gap: 10)
        #expect(offCentre.midX == 220, "tile mid 220, not screen mid 720")
        for y in [CGFloat(430), CGFloat(860)] {
            let left = DockEnhanceMath.panelFrame(
                anchor: CGRect(x: 0, y: y, width: 40, height: 40), edge: .left,
                size: size, screen: screen, gap: 10)
            #expect(left.midY == min(max(y + 20, 8 + 50), 900 - 8 - 50),
                    "left dock: panel on the tile's axis at \(y)")
            let right = DockEnhanceMath.panelFrame(
                anchor: CGRect(x: 1400, y: y, width: 40, height: 40), edge: .right,
                size: size, screen: screen, gap: 10)
            #expect(right.midY == left.midY, "right dock mirrors it")
        }
    }

    @Test func thePanelStaysOnScreenAtTheEdges() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // A panel wider than the screen clamps its origin inside — it
        // cannot fit, but it must not start off-screen.
        let frame = DockEnhanceMath.panelFrame(
            anchor: CGRect(x: 0, y: 0, width: 40, height: 40), edge: .bottom,
            size: CGSize(width: 2000, height: 100), screen: screen, gap: 10)
        #expect(frame.minX >= screen.minX, "an oversize panel clamps inside")
        // A hidden Dock's tile reports below the screen; the panel does
        // not follow it off.
        let sliding = DockEnhanceMath.panelFrame(
            anchor: CGRect(x: 700, y: -60, width: 40, height: 40), edge: .bottom,
            size: CGSize(width: 300, height: 100), screen: screen, gap: 10)
        #expect(sliding.minY >= screen.minY)
    }

    @Test func magnificationAnchorsOnTheDocksRunAxis() {
        // Bottom dock: the magnified icon rides the pointer's x, its
        // base stays pinned to the edge.
        let bottomTile = CGRect(x: 700, y: 0, width: 40, height: 40)
        let bottom = DockEnhanceMath.magnifiedAnchor(
            tile: bottomTile, edge: .bottom, pointer: CGPoint(x: 542, y: 20))
        #expect(bottom == CGRect(x: 522, y: 0, width: 40, height: 40),
                "bottom Dock: re-centred on the pointer's x")
        // Side docks run vertically — the icon rides the pointer's y
        // and its x stays at the screen edge. Centring a side tile on
        // the pointer's x was the defect: the panel drifted sideways.
        let leftTile = CGRect(x: 0, y: 400, width: 40, height: 40)
        let left = DockEnhanceMath.magnifiedAnchor(
            tile: leftTile, edge: .left, pointer: CGPoint(x: 542, y: 700))
        #expect(left == CGRect(x: 0, y: 680, width: 40, height: 40),
                "left Dock: re-centred on the pointer's y, x untouched")
        let rightTile = CGRect(x: 1400, y: 400, width: 40, height: 40)
        let right = DockEnhanceMath.magnifiedAnchor(
            tile: rightTile, edge: .right, pointer: CGPoint(x: 542, y: 700))
        #expect(right == CGRect(x: 1400, y: 680, width: 40, height: 40),
                "right Dock: same y-tracking, edge x preserved")
    }

    @Test func theDockReachInflatesTheListFrame() {
        // (100,850,400,50) inflated by the 20/96 slop → (80,754,440,242).
        let reach = DockEnhanceController.listReach(
            of: CGRect(x: 100, y: 850, width: 400, height: 50))
        #expect(reach.contains(CGPoint(x: 300, y: 800)),
                "above the dock's tiles still counts as over it")
        #expect(!reach.contains(CGPoint(x: 300, y: 750)))
        #expect(!reach.contains(CGPoint(x: 50, y: 900)))
    }

    // MARK: The corridor

    @Test func theCorridorCoversTheRoadToThePanel() {
        // Bottom dock, tile at the screen's left, panel centred: the
        // road between them is the funnel from tile to panel.
        let item = CGRect(x: 40, y: 0, width: 48, height: 48)
        let panel = CGRect(x: 520, y: 58, width: 400, height: 120)
        // Straight run from the tile's centre to the panel's centre —
        // every step of it is inside.
        for t in stride(from: 0.1, through: 0.9, by: 0.2) {
            let point = CGPoint(x: 64 + (720 - 64) * t, y: 48 + (58 - 48) * t)
            #expect(DockEnhanceMath.inCorridor(item: item, panel: panel, edge: .bottom,
                                               point: point, slop: 6),
                    "t=\(t) on the tile→panel line is travelling")
        }
        // Off the funnel — far right of the panel's reach — is leaving.
        #expect(!DockEnhanceMath.inCorridor(
            item: item, panel: panel, edge: .bottom,
            point: CGPoint(x: 1100, y: 53), slop: 6))
        // Below the ramp, moving away along the desk — not the road.
        #expect(!DockEnhanceMath.inCorridor(
            item: item, panel: panel, edge: .bottom,
            point: CGPoint(x: 900, y: 20), slop: 6))
    }

    @Test func theCorridorFollowsTheDockEdge() {
        // Left dock: the funnel runs horizontally, tile → panel right.
        let item = CGRect(x: 0, y: 800, width: 48, height: 48)
        let panel = CGRect(x: 58, y: 350, width: 200, height: 200)
        #expect(DockEnhanceMath.inCorridor(item: item, panel: panel, edge: .left,
                                           point: CGPoint(x: 53, y: 700), slop: 6))
        #expect(!DockEnhanceMath.inCorridor(item: item, panel: panel, edge: .left,
                                            point: CGPoint(x: 53, y: 100), slop: 6))
        // Right dock: panel sits left of the tile.
        let rItem = CGRect(x: 1392, y: 100, width: 48, height: 48)
        let rPanel = CGRect(x: 992, y: 350, width: 200, height: 200)
        #expect(DockEnhanceMath.inCorridor(item: rItem, panel: rPanel, edge: .right,
                                           point: CGPoint(x: 1387, y: 200), slop: 6))
        #expect(!DockEnhanceMath.inCorridor(item: rItem, panel: rPanel, edge: .right,
                                            point: CGPoint(x: 1300, y: 800), slop: 6))
    }

    @Test func aSeamBetweenTilesDoesNotRestartTheRestClock() {
        var tracker = DockHoverTracker()
        _ = tracker.note(hovered: "Safari", pointerInPanel: false, now: 0, delay: 0.25)
        // One tick reads nothing at the seam, then the same tile again.
        _ = tracker.note(hovered: nil, pointerInPanel: false, now: 0.1, delay: 0.25)
        #expect(tracker.note(hovered: "Safari", pointerInPanel: false,
                             now: 0.26, delay: 0.25) == .show("Safari"),
                "the rest clock started at 0, not at the return")
        // A longer absence does start over.
        var fresh = DockHoverTracker()
        _ = fresh.note(hovered: "Safari", pointerInPanel: false, now: 0, delay: 0.25)
        _ = fresh.note(hovered: nil, pointerInPanel: false, now: 0.1, delay: 0.25)
        _ = fresh.note(hovered: nil, pointerInPanel: false, now: 0.1 + DockHoverTracker.seamGrace + 0.01, delay: 0.25)
        #expect(fresh.note(hovered: "Safari", pointerInPanel: false,
                           now: 0.3, delay: 0.25) == .none)
    }

    // MARK: autohide-delay restore

    /// The full-fidelity fake — the delay verbs exist so a bool-only
    /// fake can't fake the restore.
    private final class FakeDefaults: AppleDockDefaults {
        var bools: [String: Bool] = [:]
        var doubles: [String: Double] = [:]
        var removed: [String] = []
        func setBool(_ value: Bool, forKey key: String) { bools[key] = value }
        func setDouble(_ value: Double, forKey key: String) { doubles[key] = value }
        func removeValue(forKey key: String) {
            bools[key] = nil
            doubles[key] = nil
            removed.append(key)
        }
        func synchronize() {}
    }

    private func freshPersistence(_ name: String) -> UserDefaults {
        let suite = "DockEnhanceTests.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    /// What an old Replace build's hide left in our defaults: the
    /// `autohide` it found, and the `autohide-delay` it found — a value,
    /// or its "absent" marker.
    private func leftByAnOldHide(_ name: String, autohide: Bool?, delay: Double?,
                                 delayWasAbsent: Bool = false) -> UserDefaults {
        let suite = freshPersistence(name)
        if let autohide { suite.set(autohide, forKey: "JRBarDock.savedAutohide") }
        if let delay { suite.set(delay, forKey: "JRBarDock.savedAutohideDelay") }
        if delayWasAbsent { suite.set("absent", forKey: "JRBarDock.savedAutohideDelay") }
        return suite
    }

    @Test func restoreHandsBackASavedDelay() {
        let defaults = FakeDefaults()
        defaults.doubles["autohide-delay"] = 1000   // the old bar's pin
        let control = AppleDockControl(defaults: defaults,
                                       persistence: leftByAnOldHide("delayValue", autohide: false, delay: 0.4))
        control.restartDock = {}

        #expect(control.savedDelay == .value(0.4))
        #expect(control.restore() == true)

        #expect(defaults.doubles["autohide-delay"] == 0.4)
        #expect(defaults.removed.isEmpty, "a real value restores as a write, not a removal")
    }

    @Test func restoreRemovesADelayThatWasAbsent() {
        let defaults = FakeDefaults()
        defaults.doubles["autohide-delay"] = 1000
        let control = AppleDockControl(defaults: defaults,
                                       persistence: leftByAnOldHide("delayAbsent", autohide: false, delay: nil,
                                                                    delayWasAbsent: true))
        control.restartDock = {}

        #expect(control.savedDelay == .absent)
        #expect(control.restore() == true)

        #expect(defaults.doubles["autohide-delay"] == nil)
        #expect(defaults.removed == ["autohide-delay"],
                "absent restores as absent — we don't leave a 0 behind")
    }

    @Test func aCrashCantStrandTheDockHidden() {
        // An old build hid the Dock, then died before its restore ran.
        let suite = leftByAnOldHide("crashSafe", autohide: false, delay: nil, delayWasAbsent: true)
        let defaults = FakeDefaults()
        defaults.bools["autohide"] = true

        let next = AppleDockControl(defaults: defaults, persistence: suite)
        next.restartDock = {}
        #expect(next.savedAutohide == false,
                "the saved value survives into the next launch")
        #expect(next.restore() == true)
        #expect(defaults.bools["autohide"] == false)

        let after = AppleDockControl(defaults: defaults, persistence: suite)
        #expect(after.savedAutohide == nil && after.savedDelay == .nothing,
                "once restored, a later launch has nothing to hand back")
    }

    @Test func restoreHandsBackTheUsersOwnAutohideAndDelay() {
        let defaults = FakeDefaults()
        defaults.bools["autohide"] = true
        defaults.doubles["autohide-delay"] = 1000
        let control = AppleDockControl(defaults: defaults,
                                       persistence: leftByAnOldHide("ownValues", autohide: true, delay: 0.4))
        control.restartDock = {}

        #expect(control.restore() == true)

        #expect(defaults.bools["autohide"] == true)
        #expect(defaults.doubles["autohide-delay"] == 0.4,
                "restore means THEIR values, not the old pin")
    }

    // MARK: Icon resolution

    private func solidImage(pixels: Int) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return NSImage() }
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.addRepresentation(rep)
        return image
    }

    @Test func rasterizeHitsRetinaPixelsWhenTheSourceCan() {
        let image = DockIconResolver.rasterized(solidImage(pixels: 512),
                                                pointSize: 56, scale: 2)
        #expect(image.size == NSSize(width: 56, height: 56),
                "the asset is sized in points…")
        #expect(image.representations.map(\.pixelsWide).max() == 112,
                "…and its bitmap is the full 2×")
    }

    @Test func rasterizeNeverUpscalesASmallRep() {
        let image = DockIconResolver.rasterized(solidImage(pixels: 32),
                                                pointSize: 56, scale: 2)
        #expect(image.representations.map(\.pixelsWide).max() == 32,
                "a 32 px icon stays a 32 px asset — no smear")
    }

    // MARK: Enhance preferences

    @Test func enhancePrefsRideTheSettings() {
        var settings = DockEnhanceSettings()
        let prefs = DockEnhancePreferences()
        prefs.read = { settings }
        prefs.write = { settings = $0 }
        #expect(prefs.previewDelay == DockEnhancePreferences.defaultDelay)
        #expect(prefs.showThumbnails == true)
        prefs.previewDelay = 0.6
        prefs.showThumbnails = false
        #expect(settings.previewDelay == 0.6)
        #expect(settings.showThumbnails == false,
                "a card write lands in the persisted settings struct")
        prefs.previewDelay = 99
        #expect(settings.previewDelay == DockEnhanceSettings.delayRange.upperBound,
                "an out-of-range delay clamps through the settings write")
    }

    @Test func legacyEnhanceDefaultsMigrateIntoTheSettings() {
        // The migration reads `.standard`, so plant the keys there and
        // always clean up after.
        defer {
            UserDefaults.standard.removeObject(forKey: DockEnhancePreferences.legacyDelayKey)
            UserDefaults.standard.removeObject(forKey: DockEnhancePreferences.legacyThumbnailsKey)
        }
        UserDefaults.standard.set(0.7, forKey: DockEnhancePreferences.legacyDelayKey)
        UserDefaults.standard.set(false, forKey: DockEnhancePreferences.legacyThumbnailsKey)
        var stored = DockSettings()
        let utility = DockUtility()
        utility.settings = { stored }
        utility.onSettingsChange = { stored = $0 }
        utility.applySettings()
        #expect(stored.enhance.previewDelay == 0.7)
        #expect(stored.enhance.showThumbnails == false)
        #expect(UserDefaults.standard.object(forKey: DockEnhancePreferences.legacyDelayKey) == nil,
                "the legacy key is removed after the fold")
    }

    @Test func legacyMigrationLeavesCleanSettingsAlone() {
        UserDefaults.standard.removeObject(forKey: DockEnhancePreferences.legacyDelayKey)
        UserDefaults.standard.removeObject(forKey: DockEnhancePreferences.legacyThumbnailsKey)
        var stored = DockSettings()
        var writes = 0
        let utility = DockUtility()
        utility.settings = { stored }
        utility.onSettingsChange = { stored = $0; writes += 1 }
        utility.applySettings()
        #expect(writes == 0, "no legacy keys, no write")
    }

    // MARK: Thumbnail matching

    @Test func thumbnailsMatchByFrameFirstThenTitle() {
        let rows: [(frame: CGRect?, title: String)] = [
            (CGRect(x: 100, y: 100, width: 800, height: 600), "Untitled window"),
            (CGRect(x: 100, y: 100, width: 800, height: 600), "Untitled window"),
            (nil, "Notes — Groceries"),
        ]
        // Indistinguishable rows cannot safely claim a captured image.
        #expect(DockEnhanceMath.matchRow(
            scFrame: CGRect(x: 101, y: 99, width: 800, height: 601), scTitle: nil, rows: rows) == nil)
        // No frame match → title.
        #expect(DockEnhanceMath.matchRow(
            scFrame: CGRect(x: 0, y: 0, width: 300, height: 300),
            scTitle: "Notes — Groceries", rows: rows) == 2)
        // Neither → nothing, never a guess.
        #expect(DockEnhanceMath.matchRow(
            scFrame: CGRect(x: 0, y: 0, width: 300, height: 300), scTitle: "", rows: rows) == nil)
    }

    @Test func cardSizesAreSixteenByTen() {
        let small = DockEnhanceMath.cardSize(large: false)
        let large = DockEnhanceMath.cardSize(large: true)
        #expect(small.width / small.height == 1.6)
        #expect(large.width / large.height == 1.6)
        #expect(large.width > small.width)
    }

    @Test func hoverIdentityPrefersTheTileURL() {
        let element = AXUIElementCreateSystemWide()
        let byURL = DockAXItem(element: element, frame: CGRect(x: 10, y: 0, width: 50, height: 50),
                               title: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let byTitle = DockAXItem(element: element, frame: CGRect(x: 10, y: 0, width: 50, height: 50),
                                 title: "Safari", url: nil)
        let bySlot = DockAXItem(element: element, frame: CGRect(x: 10, y: 0, width: 50, height: 50),
                                title: nil, url: nil)
        #expect(byURL.hoverID == "/Applications/Safari.app")
        #expect(byTitle.hoverID == "Safari")
        #expect(bySlot.hoverID == "dock-item@10")
    }

    @Test("the preview tick parks while sleep, a lock or a switched session holds, and resumes when the last lifts")
    func tickParks() {
        var park = DockTickPark()
        #expect(park.note(.displaysSlept) == .park)
        #expect(park.note(.locked) == nil, "already parked")
        #expect(park.note(.displaysWoke) == nil, "still locked")
        #expect(park.parked)
        #expect(park.note(.unlocked) == .resume)
        #expect(!park.parked)
        #expect(park.note(.displaysWoke) == nil, "a wake with nothing parked changes nothing")
        #expect(park.note(.sessionLeft) == .park)
        #expect(park.note(.sessionReturned) == .resume)
    }

    @Test("a watcher that isn't running never arms its tick on a wake")
    func stoppedWatcherStaysParked() {
        let controller = DockEnhanceController()
        controller.notePresence(.displaysSlept)
        #expect(controller.presence.parked)
        controller.notePresence(.displaysWoke)
        #expect(!controller.isTicking)
    }

    @Test("the Dock's pid is kept between reads; its launch and exit move it, a failed read asks again")
    func dockPIDIsKept() {
        var asked = 0
        var running: pid_t? = 400
        let cache = DockPIDCache(center: NotificationCenter(), lookUp: {
            asked += 1
            return running
        })
        for _ in 0..<20 { _ = cache.pid }
        #expect(cache.pid == 400 && asked == 1, "twenty reads, one workspace query")
        cache.noteWorkspace(launched: true, bundleID: "com.apple.Safari", pid: 999)
        #expect(cache.pid == 400, "another app's launch is no news")
        cache.noteWorkspace(launched: false, bundleID: AppleDockReader.dockBundleID, pid: 400)
        running = nil
        #expect(cache.pid == nil && asked == 2, "the Dock quit: asked again, and it isn't running")
        cache.noteWorkspace(launched: true, bundleID: AppleDockReader.dockBundleID, pid: 512)
        #expect(cache.pid == 512 && asked == 2, "its relaunch brings the new pid")
        running = 640
        cache.forget()
        #expect(cache.pid == 640 && asked == 3, "a read that failed at the kept pid asks the workspace")
    }

    @Test func tileKindsMapTheDocksSubroles() {
        #expect(DockAXItem.kind(forSubrole: "AXApplicationDockItem") == .app)
        #expect(DockAXItem.kind(forSubrole: "AXFolderDockItem") == .folder)
        #expect(DockAXItem.kind(forSubrole: "AXMinimizedWindowDockItem") == .minimizedWindow)
        #expect(DockAXItem.kind(forSubrole: "AXSeparatorDockItem") == nil)
        #expect(DockAXItem.kind(forSubrole: "AXTrashDockItem") == nil)
        #expect(DockAXItem.kind(forSubrole: nil) == nil)
    }

    @Test func minimizedTilesWithOneTitleStillRetarget() {
        // Two minimized "Untitled" windows carry no URL and share a
        // title — the slot in the hover id keeps them distinct.
        let element = AXUIElementCreateSystemWide()
        let first = DockAXItem(element: element, frame: CGRect(x: 10, y: 0, width: 50, height: 50),
                               title: "Untitled", url: nil, kind: .minimizedWindow)
        let second = DockAXItem(element: element, frame: CGRect(x: 70, y: 0, width: 50, height: 50),
                                title: "Untitled", url: nil, kind: .minimizedWindow)
        #expect(first.hoverID != second.hoverID)
    }

    @Test func permissionsAreCachedNotPolled() {
        let controller = DockEnhanceController()
        controller.refreshPermissions(force: true)
        let first = controller.accessibilityTrusted
        controller.refreshPermissions()
        #expect(controller.accessibilityTrusted == first)
        #expect(DockEnhanceController.permissionTTL >= 1,
                "a TCC probe is an IPC round trip; the tick must not pay it 20× a second")
        // The Screen Recording answer is the shared 30 s cache's — the
        // forced read seeded it, so the two can never disagree.
        #expect(controller.screenCaptureGranted == FoldCapturePermission.granted)
        #expect(FoldCapturePermission.recheckAfter >= 30,
                "the preflight is a tccd round trip on every call")
    }

    // MARK: Dock hold-out

    /// The in-memory driver — the CoreDock verbs as a fake so the hold
    /// state machine is what gets pinned, not the Dock.
    private final class FakeAutohideDriver: DockAutohideDriver {
        var enabled = true
        var writes: [Bool] = []
        var isAutohideEnabled: Bool { enabled }
        func setAutohideEnabled(_ newValue: Bool) {
            writes.append(newValue)
            enabled = newValue
        }
    }

    @Test func aHoldPinsAutohideOffUntilThePanelCloses() {
        let driver = FakeAutohideDriver()
        let hold = DockAutohideHold(driver: driver,
                                    persistence: freshPersistence("hold"))
        hold.fallbackWrite = { _ in }

        hold.hold()
        #expect(hold.holding)
        #expect(driver.writes == [false])
        hold.hold()
        #expect(driver.writes == [false], "a second preview in the same hold doesn't re-write")

        hold.release()
        #expect(!hold.holding)
        #expect(driver.writes == [false, true],
                "release hands the user's own value back")
    }

    @Test func aDockThatNeverHidesNeedsNoHolding() {
        let driver = FakeAutohideDriver()
        driver.enabled = false
        let hold = DockAutohideHold(driver: driver,
                                    persistence: freshPersistence("alwaysOut"))
        hold.hold()
        #expect(!hold.holding)
        #expect(driver.writes.isEmpty, "autohide already off — nothing to hold")
    }

    @Test func aMissingDriverMeansNoHold() {
        let hold = DockAutohideHold(driver: nil,
                                    persistence: freshPersistence("noDriver"))
        hold.hold()
        #expect(!hold.holding)
        hold.release() // must not throw or write
    }

    @Test func aCrashMidHoldIsRecoveredOnTheNextLaunch() {
        let suite = freshPersistence("crashHold")
        let driver = FakeAutohideDriver()
        let first = DockAutohideHold(driver: driver, persistence: suite)
        first.hold()
        #expect(driver.writes == [false])
        // …process dies before release runs.

        let second = DockAutohideHold(driver: driver, persistence: suite)
        #expect(second.savedAutohide == true,
                "the marker survives into the next launch")
        second.recoverIfNeeded()
        #expect(driver.writes == [false, true],
                "recovery hands autohide back even though release never ran")
    }

    @Test func recoverySkipsALiveHold() {
        let driver = FakeAutohideDriver()
        let hold = DockAutohideHold(driver: driver,
                                    persistence: freshPersistence("liveHold"))
        hold.hold()
        // `applySettings()` reaches `recoverIfNeeded()` on every card
        // edit — a live preview's hold must survive it.
        hold.recoverIfNeeded()
        #expect(hold.holding)
        #expect(driver.writes == [false], "still held — recovery is not a release")
    }

    @Test func recoveryWithoutADriverUsesTheFallback() {
        let suite = freshPersistence("fallback")
        let first = DockAutohideHold(driver: FakeAutohideDriver(), persistence: suite)
        first.hold()
        // The next life boots where the CoreDock verbs don't resolve.
        var fallbackWrites: [Bool] = []
        let second = DockAutohideHold(driver: nil, persistence: suite,
                                      fallbackWrite: { fallbackWrites.append($0) })
        second.recoverIfNeeded()
        #expect(fallbackWrites == [true],
                "a stranded hold is worth one defaults write + Dock bounce")
    }

    @Test func aRecoveredHoldSaysSoOnTheCardAndAMissingDriverIsNamed() {
        let suite = freshPersistence("recoveredNote")
        let driver = FakeAutohideDriver()
        DockAutohideHold(driver: driver, persistence: suite).hold()
        // …the next life boots with the marker still set.
        let hold = DockAutohideHold(driver: driver, persistence: suite)
        let utility = DockUtility(autohideHold: hold)
        var stored = DockSettings()
        utility.settings = { stored }
        utility.onSettingsChange = { stored = $0 }
        utility.applySettings()
        #expect(utility.recoveredHoldNote == DockUtility.recoveredHoldLine)
        utility.applySettings()
        #expect(utility.recoveredHoldNote == DockUtility.recoveredHoldLine, "the note waits to be read")
        utility.dismissRecoveredHoldNote()
        #expect(utility.recoveredHoldNote == nil)
        #expect(!hold.recoverIfNeeded(), "nothing stranded — nothing to report")
        #expect(hold.available)
        #expect(!DockAutohideHold(driver: nil, persistence: freshPersistence("noDriverCard")).available)
    }

    // MARK: Compact list

    @Test func theCompactListTurnsOnPastTheLimit() {
        #expect(!DockEnhanceMath.compactList(windowCount: 5, limit: 6))
        #expect(DockEnhanceMath.compactList(windowCount: 6, limit: 6),
                "at the limit counts as past it — a 6-window app gets the list")
        #expect(DockEnhanceMath.compactList(windowCount: 20, limit: 6))
        #expect(!DockEnhanceMath.compactList(windowCount: 20, limit: 0),
                "0 is never — thumbnails no matter the count")
    }

    @Test func compactAndHoldSettingsDecodeTolerantly() throws {
        // A file from before these knobs existed decodes to defaults.
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(DockEnhanceSettings.self, from: data)
        #expect(decoded.holdDockOpen == true)
        #expect(decoded.compactListLimit == DockEnhanceSettings.defaultCompactLimit)

        var clamped = DockEnhanceSettings()
        clamped.compactListLimit = 99
        #expect(clamped.compactListLimit == DockEnhanceSettings.compactLimitRange.upperBound)
        clamped.compactListLimit = -3
        #expect(clamped.compactListLimit == 0)
    }

    // MARK: Folder pop

    @Test func aFolderPopListsDirectoriesFirstThenFinderNameOrder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-pop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("b.txt").path, contents: nil)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.txt").path, contents: nil)
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".hidden").path, contents: nil)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("c-sub"), withIntermediateDirectories: false)

        let entries = DockEnhanceController.folderEntries(of: dir)
        #expect(entries.map(\.name) == ["c-sub", "a.txt", "b.txt"],
                "directories lead, then Finder's name order — hidden files never list")
        #expect(entries.first?.isDirectory == true)
    }

    @Test func aMissingFolderPopsEmptyAndAnUnreadableOneToo() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-pop-\(UUID().uuidString)")
        #expect(DockEnhanceController.folderEntries(of: missing).isEmpty)
    }

    @Test func aForbiddenFolderReadsDeniedNotEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-pop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let listing = DockEnhanceController.folderListing(of: dir)
        #expect(listing.entries.isEmpty)
        #expect(listing.denied, "EACCES is a consent problem, not an empty folder")
    }

    @Test("a folder pop reads the tile's own Sort By from the Dock's list")
    func folderSortReadsTheTile() {
        let others: [Any] = [
            ["tile-data": ["arrangement": 2,
                           "file-data": ["_CFURLString": "file:///Users/me/Downloads/", "_CFURLStringType": 15]],
             "tile-type": "directory-tile"],
            ["tile-data": ["arrangement": 5,
                           "file-data": ["_CFURLString": "file:///Users/me/Documents/", "_CFURLStringType": 15]]],
            ["tile-data": ["arrangement": 42,
                           "file-data": ["_CFURLString": "file:///Users/me/Odd/", "_CFURLStringType": 15]]],
        ]
        #expect(DockFolderSort.of(folder: URL(fileURLWithPath: "/Users/me/Downloads"), persistentOthers: others)
                == .dateAdded)
        #expect(DockFolderSort.of(folder: URL(string: "file:///Users/me/Documents/")!, persistentOthers: others)
                == .kind)
        #expect(DockFolderSort.of(folder: URL(fileURLWithPath: "/Users/me/Odd"), persistentOthers: others) == .name,
                "an arrangement the Dock never wrote reads as Name")
        #expect(DockFolderSort.of(folder: URL(fileURLWithPath: "/Users/me/Elsewhere"), persistentOthers: others)
                == .name)
        #expect(DockFolderSort.of(folder: URL(fileURLWithPath: "/x"), persistentOthers: nil) == .name)
    }

    @Test("date sorts run newest first; kind groups; undated entries sink")
    func folderSortArranges() {
        let base = URL(fileURLWithPath: "/tmp/pop")
        func row(_ name: String, dir: Bool = false) -> DockFolderSort.Row {
            .init(name: name, url: base.appendingPathComponent(name), isDir: dir)
        }
        let rows = [row("old.txt"), row("sub", dir: true), row("new.png"), row("mystery")]
        let dates: [String: Date] = ["old.txt": Date(timeIntervalSince1970: 100),
                                     "sub": Date(timeIntervalSince1970: 200),
                                     "new.png": Date(timeIntervalSince1970: 300)]
        let byDate = DockFolderSort.dateAdded.arrange(
            rows, date: { dates[$0.lastPathComponent] }, kind: { _ in nil })
        #expect(byDate.map(\.name) == ["new.png", "sub", "old.txt", "mystery"],
                "today's download leads, folders take their date's place, the undated sink")
        let byName = DockFolderSort.name.arrange(rows, date: { _ in nil }, kind: { _ in nil })
        #expect(byName.map(\.name) == ["sub", "mystery", "new.png", "old.txt"])
        let kinds = ["old.txt": "Plain Text", "new.png": "PNG image", "mystery": "Document", "sub": "Folder"]
        let byKind = DockFolderSort.kind.arrange(rows, date: { _ in nil }, kind: { kinds[$0.lastPathComponent] })
        #expect(byKind.map(\.name) == ["mystery", "sub", "old.txt", "new.png"])
    }

    @Test("the pop drills only into a subfolder of the folder showing, and grids five across")
    func folderDrillAndGrid() {
        let root = URL(fileURLWithPath: "/Users/me/Downloads/")
        let sub = root.appendingPathComponent("Invoices")
        let deeper = sub.appendingPathComponent("2026")
        let trail = DockEnhanceMath.drilledTrail([], root: root, into: sub)
        #expect(trail == [sub])
        #expect(DockEnhanceMath.drilledTrail(trail ?? [], root: root, into: deeper) == [sub, deeper])
        #expect(DockEnhanceMath.drilledTrail([], root: root, into: deeper) == nil,
                "a chip from a listing the pop has left can't jump the trail")
        #expect(DockEnhanceMath.drilledTrail([], root: root, into: URL(fileURLWithPath: "/tmp/x")) == nil)
        #expect(DockEnhanceMath.folderGrid(count: 0) == (0, 0))
        #expect(DockEnhanceMath.folderGrid(count: 3) == (3, 1), "a few entries stay one row, no dead columns")
        #expect(DockEnhanceMath.folderGrid(count: 12) == (5, 3))
        #expect(DockEnhanceMath.folderGrid(count: 60) == (5, 4), "past four rows the grid scrolls")
    }

    @Test func aModifiedSortedPopListsTheLatestFileFirst() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-pop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, age) in [("a.txt", 300.0), ("b.txt", 10.0), ("c.txt", 100.0)] {
            let path = dir.appendingPathComponent(name).path
            FileManager.default.createFile(atPath: path, contents: nil)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
        }
        let listing = DockEnhanceController.folderListing(of: dir, sort: .dateModified)
        #expect(listing.entries.map(\.name) == ["b.txt", "c.txt", "a.txt"])
    }
}


// MARK: - Card gestures

extension DockEnhanceTests {
    @Test("a shake minimises the siblings still up, or brings them all back once they're all down")
    func shakePlans() {
        func card(_ id: Int, _ minimized: Bool) -> DockPreviewWindow {
            DockPreviewWindow(id: id, title: "w\(id)", minimized: minimized, fullScreen: nil,
                              frame: nil, thumbnail: nil, element: nil)
        }
        let mixed = DockEnhanceMath.shakePlan([card(1, false), card(2, false), card(3, true)], shaken: 1)
        #expect(mixed?.minimize == true)
        #expect(mixed?.targets.map(\.id) == [2], "an already-minimised sibling isn't touched — and doesn't pulse")
        let down = DockEnhanceMath.shakePlan([card(1, false), card(2, true), card(3, true)], shaken: 1)
        #expect(down?.minimize == false)
        #expect(down?.targets.map(\.id) == [2, 3])
        #expect(DockEnhanceMath.shakePlan([card(1, false)], shaken: 1) == nil)
    }

    @Test("a fast left-right-left wiggle is one shake; a slow drift is not")
    func shakeDetects() {
        var shake = DockEnhanceMath.ShakeDetector()
        // note() mutates — bind the answers, then expect on them.
        var fired = [shake.note(x: 0, now: 0),
                     shake.note(x: 10, now: 0.05),
                     shake.note(x: 0, now: 0.10),   // first reversal
                     shake.note(x: 10, now: 0.15),  // second reversal
                     shake.note(x: 0, now: 0.20)]   // third reversal is the shake
        #expect(fired == [false, false, false, false, true])
        fired = [shake.note(x: 10, now: 0.25)]
        #expect(fired == [false], "one shake per rest — no machine-gun")
        shake.reset()
        #expect(shake.note(x: 0, now: 2.0) == false, "a re-armed detector starts cold")
    }

    @Test("small wiggles and stale reversals never reach the shake")
    func shakeIgnoresDrift() {
        var shake = DockEnhanceMath.ShakeDetector()
        // Steps under 6 pt are pointer noise, not reversals.
        var fired = false
        for i in 0..<8 {
            fired = fired || shake.note(x: CGFloat(i % 2 == 0 ? 2 : -2), now: Double(i) * 0.05)
        }
        #expect(!fired)
        // Reversals spaced past the window restart the count.
        shake.reset()
        _ = shake.note(x: 0, now: 0)
        _ = shake.note(x: 10, now: 0.1)
        _ = shake.note(x: 0, now: 1.2)
        #expect(shake.note(x: 10, now: 1.3) == false, "0.9 s later the window closed")
    }

    @Test("a downward flick past the threshold minimizes; up restores; a pause restarts")
    func swipeAccumulates() {
        var acc = DockEnhanceMath.SwipeAccumulator()
        // Natural scrolling: fingers down → +deltaY is a down-flick.
        let flicks = [acc.note(deltaY: 20, inverted: true, now: 0),
                      acc.note(deltaY: 20, inverted: true, now: 0.1),
                      acc.note(deltaY: 20, inverted: true, now: 0.2)]
        #expect(flicks == [nil, nil, .down])
        // The counter reset at the fire — an up-flick earns its own run.
        #expect(acc.note(deltaY: -60, inverted: true, now: 1.0) == .up)
        // A long pause is a new flick, not a stacked one.
        #expect(acc.note(deltaY: 20, inverted: true, now: 5.0) == nil)
        // A reversal restarts the count mid-flick.
        #expect(acc.note(deltaY: -30, inverted: true, now: 5.1) == nil)
        #expect(acc.note(deltaY: 30, inverted: true, now: 5.2) == nil,
                "the direction flip discarded the −30")
    }
}

/// A purged backing store reads as a fully transparent CGImage — the
/// thumbnailer must reject it; a black window is still a real capture.
@Test("fullyTransparent rejects purged captures, keeps dark windows")
func transparentCaptureCheck() throws {
    func makeImage(alpha: UInt8) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = alpha }
        let context = CGContext(data: &pixels, width: 16, height: 16,
                                bitsPerComponent: 8, bytesPerRow: 64,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return try #require(context.makeImage())
    }
    #expect(DockThumbnailer.fullyTransparent(try makeImage(alpha: 0)) == true)
    #expect(DockThumbnailer.fullyTransparent(try makeImage(alpha: 255)) == false)
}

/// A capture whose content hugs one edge — purged margin or shadow
/// inset — gets cropped to its alpha bounds so the thumbnail centres
/// in the card.
@Test("trimmed crops transparent margins, keeps full captures")
func trimmedCropCheck() throws {
    // Opaque only in the left quarter of a 64×32 image.
    var pixels = [UInt8](repeating: 0, count: 64 * 32 * 4)
    for y in 0..<32 { for x in 0..<16 {
        pixels[(y * 64 + x) * 4 + 3] = 255
    } }
    let context = CGContext(data: &pixels, width: 64, height: 32,
                            bitsPerComponent: 8, bytesPerRow: 256,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = try #require(context.makeImage())
    let trimmed = DockThumbnailer.trimmed(image)
    #expect(trimmed.width < image.width, "the transparent right half is cropped")
    #expect(trimmed.width >= 12, "the kept cells hold the opaque quarter plus the one-cell margin")
    #expect(trimmed.height <= image.height)
}

// MARK: App-name channels

/// Long channel-tagged names lay out slim: "T3 Code (Nightly)" renders
/// as "T3 Code" with the tag in its own chip, so the preview header
/// reads like any other app's.
@Test("channel tags split off the product name")
func channelSplits() {
    #expect(AppNameChannel.split("T3 Code (Nightly)") == ("T3 Code", "Nightly"))
    #expect(AppNameChannel.split("Visual Studio Code - Insiders") == ("Visual Studio Code", "Insiders"))
    #expect(AppNameChannel.split("Xcode-beta") == ("Xcode", "beta"))
    #expect(AppNameChannel.split("Firefox Developer Edition") == ("Firefox", "Developer Edition"))
    #expect(AppNameChannel.split("Safari Technology Preview") == ("Safari", "Technology Preview"))
    #expect(AppNameChannel.split("Discord PTB") == ("Discord", "PTB"))
}

@Test("plain names and lookalikes never split")
func channelKeeps() {
    #expect(AppNameChannel.split("Safari") == ("Safari", nil))
    #expect(AppNameChannel.split("Preview") == ("Preview", nil))
    #expect(AppNameChannel.split("Code") == ("Code", nil))
    #expect(AppNameChannel.split("Affinity Designer 2") == ("Affinity Designer 2", nil))
    // A parenthesised tail that is not a channel word stays whole.
    #expect(AppNameChannel.split("Notes (Shared)") == ("Notes (Shared)", nil))
    // A hyphenated product name is not a channel split.
    #expect(AppNameChannel.split("Day-One") == ("Day-One", nil))
}
