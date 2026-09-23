import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The right ear as the menu bar's surface: the resting mark that gives
/// the peek a home, where the peek hangs, and how the pointer reaches it
/// — hover and scroll hang it, a click pins it, the ‹ keeps its own.
@Suite("Screen Bar right-ear peek")
@MainActor
struct ScreenBarPeekTests {
    private func item(_ id: String, owner: String = "Example", title: String? = nil,
                      bundle: String? = "com.example.app") -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: 1, ownerName: owner,
                    bounds: CGRect(x: 100, y: 0, width: 16, height: 24), title: title,
                    windowID: 1, bundleID: bundle)
    }

    // MARK: The ear's marks

    @Test func theRestingMarkIsOneMarkNeverAMeter() {
        let few = ScreenBarMenuBarMarks.apply(ScreenBarMenuBarMarks(hiddenCount: 2), to: .empty).right
        let many = ScreenBarMenuBarMarks.apply(ScreenBarMenuBarMarks(hiddenCount: 40), to: .empty).right
        #expect(few?.symbol == ScreenBarMenuBarMarks.restingSymbol)
        #expect(few?.symbol == many?.symbol && few?.meter == nil && many?.meter == nil,
                "two items or forty draw the same mark — no segments, no fill")
    }

    @Test func tuckedAwayItemsGiveTheEmptyEarItsRestingMark() throws {
        let marks = ScreenBarMenuBarMarks(hiddenCount: 5)
        let dressed = ScreenBarMenuBarMarks.apply(marks, to: .empty)
        let right = try #require(dressed.right)
        #expect(right.symbol == ScreenBarMenuBarMarks.restingSymbol)
        #expect(right.hasMark)
        #expect(right.provider == nil && right.meter == nil, "a mark, never a number or a word")
        #expect(right.text == "5 menu bar items tucked away", "VoiceOver gets the count")
        #expect(dressed.left == nil)
        // Nothing hidden: no ear is conjured.
        #expect(ScreenBarMenuBarMarks.apply(ScreenBarMenuBarMarks(), to: .empty).right == nil)
    }

    @Test func theMeterKeepsItsEarAndTheRestingMarkNeverDisplacesIt() {
        let meter = ScreenBarWingSlot(text: "42%", provider: "codex", meter: 0.42)
        let dressed = ScreenBarMenuBarMarks.apply(ScreenBarMenuBarMarks(hiddenCount: 9),
                                                  to: ScreenBarWings(left: nil, right: meter))
        #expect(dressed.right == meter)
    }

    @Test func theKeepAwakeCupRidesTheRestingMark() throws {
        var marks = ScreenBarEarMarks()
        marks.awake = .init(symbol: ScreenBarEarMarks.leaseSymbol, text: "Held awake")
        let dressed = ScreenBarEarMarks.apply(marks, to: ScreenBarMenuBarMarks.apply(
            ScreenBarMenuBarMarks(hiddenCount: 2), to: .empty))
        let right = try #require(dressed.right)
        #expect(right.symbol == ScreenBarMenuBarMarks.restingSymbol)
        #expect(right.accessory?.symbol == ScreenBarEarMarks.leaseSymbol)
    }

    @Test func theRestingMarkIsItsOwnSubjectForADismissal() {
        let resting = ScreenBarMenuBarMarks.apply(ScreenBarMenuBarMarks(hiddenCount: 2), to: .empty).right!
        let grown = ScreenBarMenuBarMarks.apply(ScreenBarMenuBarMarks(hiddenCount: 9), to: .empty).right!
        let sensorsOnly = ScreenBarWingSlot(text: "Microphone in use")
        #expect(!ScreenBarController.sameWingSubject(resting, sensorsOnly))
        #expect(ScreenBarController.sameWingSubject(resting, grown),
                "the run growing is the same ear still dismissed")
    }

    // MARK: When hiding stops

    @Test func onlyARealFailureIsAnAlert() throws {
        let failing = try #require(MenuBarEarFeed.failure(for: .concealerFailing, osMajor: 27))
        #expect(failing == MenuBarEngineHealth.concealerFailing.line(), "the card's own reason, in the peek")
        #expect(MenuBarEarFeed.failure(for: .spacer(.frameworkMissing), osMajor: 27)?
                    .contains("spacer engine") == true, "a 27 point release that lost the framework")
        #expect(MenuBarEarFeed.failure(for: .spacer(.frameworkMissing), osMajor: 26) == nil,
                "on macOS 26 the spacer engine is simply the engine")
        for calm: MenuBarEngineHealth in [.parked, .concealer(hidden: 3), .concealer(hidden: 0), .concealerStarting,
                                          .spacer(.forced), .spacer(.notNotarized), .spacer(.pending)] {
            #expect(MenuBarEarFeed.failure(for: calm, osMajor: 27) == nil, "\(calm) is no failure")
        }
    }

    @Test func aFailureTakesTheEarInTheAlertTone() throws {
        let meter = ScreenBarWingSlot(text: "42%", provider: "codex", meter: 0.42)
        let marks = ScreenBarMenuBarMarks(hiddenCount: 4, failure: "The concealer is failing")
        let dressed = ScreenBarMenuBarMarks.apply(marks, to: ScreenBarWings(left: nil, right: meter))
        let right = try #require(dressed.right)
        #expect(right.symbol == ScreenBarMenuBarMarks.failureSymbol, "the menu bar's own mark")
        #expect(right.tone == .alert)
        #expect(right.meter == nil && right.provider == nil, "one mark, not a stack of them")
        #expect(right.text == "The concealer is failing", "the reason is VoiceOver's and the peek's")
        #expect(!ScreenBarController.sameWingSubject(right, meter), "a failure revives a dismissed meter ear")
        #expect(right.symbol != "exclamationmark.triangle.fill", "never mistaken for the band's refused program")
        // With the reason alone, the ear still opens a peek to say it.
        #expect(!MenuBarEarFeed(failure: "why").isEmpty)
        #expect(ScreenBarMenuBarMarks(feed: MenuBarEarFeed(failure: "why")).failure == "why")
    }

    // MARK: The feed

    @Test func theFeedTilesTheItemBarsItemsWithTheirFaces() {
        let face = MenuBarGlyphCache.Face(image: NSImage(), width: 64, template: true)
        let tiles = MenuBarEarFeed.tiles([item("a", title: "Connected"), item("b")],
                                         face: { $0.id == "a" ? face : nil }, changed: ["b"])
        #expect(tiles.map(\.id) == ["a", "b"])
        #expect(tiles[0].width == 64, "a glyph takes its own width")
        #expect(tiles[1].width == MenuBarBarLayout.tileSize, "an app icon stays square")
        #expect(tiles[0].name == "Example · Connected")
        #expect(tiles[1].name == "Example")
        #expect(!tiles[0].changed && tiles[1].changed)
        #expect(MenuBarEarFeed().isEmpty)
        #expect(!MenuBarEarFeed(hidden: tiles).isEmpty)
    }

    @Test func aParkedUtilityPublishesNoFeed() {
        let utility = MenuBarUtility()
        utility.refreshEarFeed()
        #expect(utility.earFeed == nil, "a stopped utility lends the ear nothing")
        // An id it does not list opens nothing.
        utility.openFromEar(itemID: "nobody")
    }

    // MARK: Where it hangs

    @Test func thePeekIsAsWideAsItsRowWithinBounds() {
        let tile = MenuBarBarLayout.tileSize
        let pad = 2 * ScreenBarPeekLayout.padding
        #expect(ScreenBarPeekLayout.width(tileWidths: [tile, tile], hasWords: false)
                == MenuBarBarLayout.rowWidth(widths: [tile, tile]) + pad)
        #expect(ScreenBarPeekLayout.width(tileWidths: [22], hasWords: false)
                == ScreenBarPeekLayout.minContentWidth + pad, "a lone tile still reads as a lobe")
        #expect(ScreenBarPeekLayout.width(tileWidths: [22], hasWords: true)
                == ScreenBarPeekLayout.wordsWidth + pad, "sentences get room to read")
        #expect(ScreenBarPeekLayout.width(tileWidths: Array(repeating: tile, count: 40), hasWords: false)
                == ScreenBarPeekLayout.maxContentWidth + pad, "a long row scrolls instead")
    }

    @Test func itHangsBelowTheBandRightEdgeOnTheEar() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // The right ear on a 14-inch notch: 32 pt deep, flush with the top.
        let ear = CGRect(x: 850, y: 950, width: 36, height: 32)
        let band = CGRect(x: 640, y: 944, width: 250, height: 4)
        let frame = ScreenBarPeekLayout.frame(size: CGSize(width: 160, height: 48), ear: ear,
                                              band: band, screen: screen)
        #expect(frame.maxY == band.minY - ScreenBarPeekLayout.gapBelowBand,
                "below the light, never over it — the band stays one strip")
        #expect(frame.maxX == ear.maxX, "the ear's lobe grown down")
        #expect(frame.width == 160 && frame.height == 48)
        // No band under the ear: it hangs from the ear itself.
        let bare = ScreenBarPeekLayout.frame(size: CGSize(width: 160, height: 48), ear: ear,
                                             band: nil, screen: screen)
        #expect(bare.maxY == ear.minY)
    }

    @Test func itNeverLeavesTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let nearEdge = CGRect(x: 1500, y: 950, width: 36, height: 32)
        let right = ScreenBarPeekLayout.frame(size: CGSize(width: 200, height: 40), ear: nearEdge,
                                              band: nil, screen: screen)
        #expect(right.maxX == screen.maxX - ScreenBarPeekLayout.edgeMargin)
        let tooWide = ScreenBarPeekLayout.frame(size: CGSize(width: 1400, height: 40),
                                                ear: CGRect(x: 800, y: 950, width: 36, height: 32),
                                                band: nil, screen: screen)
        #expect(tooWide.minX == screen.minX + ScreenBarPeekLayout.edgeMargin)
    }

    @Test func theZoneStopsShortOfTheHandleSliceSlackIncluded() throws {
        let ear = CGRect(x: 300, y: 0, width: 52, height: 32)
        let handle = CGRect(x: 336, y: 0, width: 16, height: 32)
        let zone = try #require(ScreenBarController.peekZoneRect(ear: ear, handle: handle))
        #expect(zone.minX == ear.minX)
        // Both hit tests widen by 2 pt: they still never share a point.
        #expect(zone.insetBy(dx: -2, dy: 0).maxX <= handle.insetBy(dx: -2, dy: 0).minX)
        #expect(ScreenBarController.peekZoneRect(ear: ear, handle: nil) == ear)
        #expect(ScreenBarController.peekZoneRect(ear: CGRect(x: 0, y: 0, width: 16, height: 32),
                                                 handle: CGRect(x: 0, y: 0, width: 16, height: 32)) == nil,
                "a handle-only ear is the handle's")
    }

    // MARK: The pointer

    @Test func theEarZoneIsThePeeksAndNeverTheCards() {
        #expect(ScreenBarInteraction.pointerRegion(onPeekZone: true, onPeek: false, inHitRegion: true) == .peek)
        #expect(ScreenBarInteraction.pointerRegion(onPeekZone: false, onPeek: true, inHitRegion: true) == .peek,
                "crossing the band to a glyph is still the peek's corridor")
        #expect(ScreenBarInteraction.pointerRegion(onPeekZone: false, onPeek: false, inHitRegion: true) == .band)
        #expect(ScreenBarInteraction.pointerRegion(onPeekZone: false, onPeek: false, inHitRegion: false) == .outside)
    }

    @Test func aPressOnThePeekIsItsOwnAndAPressElsewhereFoldsIt() {
        #expect(ScreenBarInteraction.peekPress(onPanel: true, onZone: false, peekShown: true) == .panel)
        #expect(ScreenBarInteraction.peekPress(onPanel: false, onZone: true, peekShown: true) == .ear)
        #expect(ScreenBarInteraction.peekPress(onPanel: false, onZone: true, peekShown: false) == .ear)
        #expect(ScreenBarInteraction.peekPress(onPanel: false, onZone: false, peekShown: true) == .foldAndContinue)
        #expect(ScreenBarInteraction.peekPress(onPanel: false, onZone: false, peekShown: false) == .none)
    }

    @Test func onlyAClickOrAPullTradesAPinnedCardForThePeek() {
        // Nothing pinned: every ask hangs the peek, and no card is folded.
        for intent: ScreenBarPeekIntent in [.hover, .pin, .toggle] {
            let free = ScreenBarInteraction.peekGesture(intent: intent, cardPinned: false)
            #expect(free.open && !free.unpinFirst, "\(intent) with nothing pinned")
        }
        // A rest, a wheel notch or a trackpad scroll over a pinned card
        // (or the grown island) hangs nothing — never a second surface.
        let scroll = ScreenBarInteraction.peekGesture(intent: .hover, cardPinned: true)
        #expect(!scroll.open && !scroll.unpinFirst, "a scroll leaves the pinned card standing, alone")
        // A pull folds the card first, then pins the peek; so does a click.
        let pull = ScreenBarInteraction.peekGesture(intent: .pin, cardPinned: true)
        #expect(pull.unpinFirst && pull.open, "one pinned surface at a time")
        let click = ScreenBarInteraction.peekGesture(intent: .toggle, cardPinned: true)
        #expect(click.unpinFirst && click.open)
        // Folding the peek never touches the card.
        let close = ScreenBarInteraction.peekGesture(intent: .close, cardPinned: true)
        #expect(!close.unpinFirst)
    }

    @Test func aScrollOnTheEarHangsThePeek() {
        // A wheel's notch answers at once, but only on the ear.
        #expect(ScreenBarInteraction.scrollOpensPeek(precise: false, beganOnPeek: false, onPeekZone: true,
                                                     accumX: 0, accumY: 0))
        #expect(!ScreenBarInteraction.scrollOpensPeek(precise: false, beganOnPeek: false, onPeekZone: false,
                                                      accumX: 0, accumY: 0))
        // A trackpad's vertical travel, either way, past the threshold.
        let t = ScreenBarInteraction.peekScrollThreshold
        #expect(ScreenBarInteraction.scrollOpensPeek(precise: true, beganOnPeek: true, onPeekZone: true,
                                                     accumX: 0, accumY: -t))
        #expect(ScreenBarInteraction.scrollOpensPeek(precise: true, beganOnPeek: true, onPeekZone: false,
                                                     accumX: 2, accumY: t + 4))
        #expect(!ScreenBarInteraction.scrollOpensPeek(precise: true, beganOnPeek: true, onPeekZone: true,
                                                      accumX: 0, accumY: t - 1))
        // Sideways is still the ear's dismiss flick.
        #expect(!ScreenBarInteraction.scrollOpensPeek(precise: true, beganOnPeek: true, onPeekZone: true,
                                                      accumX: 30, accumY: 12))
        // A gesture that began on the band never becomes the peek's.
        #expect(!ScreenBarInteraction.scrollOpensPeek(precise: true, beganOnPeek: false, onPeekZone: true,
                                                      accumX: 0, accumY: 30))
    }
}
