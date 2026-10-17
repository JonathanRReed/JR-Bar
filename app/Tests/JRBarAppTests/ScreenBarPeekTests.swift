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
    @Test("an unpinned menu begins closing within 130 ms after leaving")
    func menuLeaveClosesPromptly() {
        let timers = ManualTimers()
        var point = CGPoint(x: 120, y: 120)
        var shown = true
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        presenter.presentationEnabled = false
        let interaction = ScreenBarInteraction(card: presenter, hitRects: { [] }, focus: { nil })
        interaction.pointerLocation = { point }
        interaction.peekState = { (shown: shown, pinned: false) }
        interaction.peekZoneAt = { CGRect(x: 100, y: 100, width: 40, height: 40).contains($0) }
        interaction.peekHoverTimer = { delay, work in timers.arm(delay, work) }
        interaction.onPeek = { if $0 == .close || $0 == .leave { shown = false } }
        defer { interaction.stop() }
        interaction.pointerMoved()
        point = CGPoint(x: 300, y: 300)
        interaction.pointerMoved()
        timers.advance(by: 0.11)
        #expect(shown)
        timers.advance(by: 0.02)
        #expect(!shown)
    }

    @Test("returning within the menu grace cancels closing and a pinned menu stays open")
    func menuReturnAndPinKeepItOpen() {
        let timers = ManualTimers()
        var point = CGPoint(x: 120, y: 120)
        var pinned = false
        var closes = 0
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        presenter.presentationEnabled = false
        let interaction = ScreenBarInteraction(card: presenter, hitRects: { [] }, focus: { nil })
        interaction.pointerLocation = { point }
        interaction.peekState = { (shown: true, pinned: pinned) }
        interaction.peekZoneAt = { CGRect(x: 100, y: 100, width: 40, height: 40).contains($0) }
        interaction.peekHoverTimer = { delay, work in timers.arm(delay, work) }
        interaction.onPeek = { if $0 == .close || $0 == .leave { closes += 1 } }
        defer { interaction.stop() }
        interaction.pointerMoved()
        point = CGPoint(x: 300, y: 300)
        interaction.pointerMoved()
        timers.advance(by: 0.10)
        point = CGPoint(x: 120, y: 120)
        interaction.pointerMoved()
        timers.advance(by: 1)
        #expect(closes == 0)
        point = CGPoint(x: 300, y: 300)
        interaction.pointerMoved()
        pinned = true
        timers.advance(by: 1)
        #expect(closes == 0)
    }

    @Test("returning during automatic dismissal resumes without a new dwell")
    func hoverReturnResumesImmediately() {
        let timers = ManualTimers()
        var point = CGPoint(x: 120, y: 120)
        var shown = true
        var resumable = false
        var intents: [ScreenBarPeekIntent] = []
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        presenter.presentationEnabled = false
        let interaction = ScreenBarInteraction(card: presenter, hitRects: { [] }, focus: { nil })
        interaction.pointerLocation = { point }
        interaction.peekState = { (shown: shown, pinned: false) }
        interaction.peekCanResume = { resumable }
        interaction.peekZoneAt = { CGRect(x: 100, y: 100, width: 40, height: 40).contains($0) }
        interaction.peekHoverTimer = { delay, work in timers.arm(delay, work) }
        interaction.onPeek = {
            intents.append($0)
            switch $0 {
            case .leave: shown = false; resumable = true
            case .resumeHover: shown = true; resumable = false
            case .close: shown = false; resumable = false
            default: break
            }
        }
        defer { interaction.stop() }
        interaction.pointerMoved()
        point = CGPoint(x: 300, y: 300)
        interaction.pointerMoved()
        timers.advance(by: 0.13)
        #expect(!shown && resumable)
        point = CGPoint(x: 120, y: 120)
        interaction.pointerMoved()
        #expect(shown && !resumable)
        #expect(intents == [.leave, .resumeHover])
    }

    @Test("geometry changes cannot resume a fading menu and deliberate presses retire it")
    func resumeNeedsMovementAndNoPress() {
        var resumable = true
        var intents: [ScreenBarPeekIntent] = []
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        presenter.presentationEnabled = false
        let interaction = ScreenBarInteraction(card: presenter, hitRects: { [] }, focus: { nil })
        interaction.pointerLocation = { CGPoint(x: 120, y: 120) }
        interaction.peekState = { (shown: false, pinned: false) }
        interaction.peekCanResume = { resumable }
        interaction.peekCorridorAt = { _ in true }
        interaction.onPeek = {
            intents.append($0)
            if $0 == .close { resumable = false }
        }
        defer { interaction.stop() }
        interaction.pointerMoved(geometryOnly: true)
        #expect(intents.isEmpty && resumable)
        interaction.pointerDown(at: CGPoint(x: 300, y: 300), time: 0)
        #expect(intents == [.close] && !resumable)
        resumable = true
        interaction.pointerSecondaryDown(at: CGPoint(x: 300, y: 300))
        #expect(intents == [.close, .close] && !resumable)
    }

    @Test("hover resume preserves an expanded island and cannot replace pinned glass")
    func resumeKeepsItsParent() {
        let island = ScreenBarInteraction.peekGesture(intent: .resumeHover, cardPinned: true, expandedIsland: true)
        #expect(island.open && !island.unpinFirst)
        let glass = ScreenBarInteraction.peekGesture(intent: .resumeHover, cardPinned: true)
        #expect(!glass.open && !glass.unpinFirst)
    }

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

    @Test("a menu below a tall parent flips inside the display and caps oversized content")
    func tallParentMenuStaysOnScreen() {
        let screen = CGRect(x: 1000, y: 2000, width: 800, height: 400)
        let ear = CGRect(x: 1500, y: 2368, width: 32, height: 32)
        let band = CGRect(x: 1250, y: 2008, width: 320, height: 4)
        let frame = ScreenBarPeekLayout.frame(size: CGSize(width: 270, height: 120),
                                              ear: ear, band: band, screen: screen)
        #expect(frame.minY >= band.maxY)
        #expect(frame.maxY <= ear.minY)
        #expect(screen.contains(frame))
        let tall = ScreenBarPeekLayout.frame(size: CGSize(width: 270, height: 500),
                                             ear: ear, band: band, screen: screen)
        #expect(tall.height == ear.minY - screen.minY - ScreenBarPeekLayout.edgeMargin)
        #expect(screen.contains(tall))
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
        // hangs nothing. Only a deliberate press opens another surface.
        let scroll = ScreenBarInteraction.peekGesture(intent: .hover, cardPinned: true)
        #expect(!scroll.open && !scroll.unpinFirst, "a scroll leaves the pinned card standing, alone")
        // A pull folds the card first, then pins the peek; so does a click.
        let pull = ScreenBarInteraction.peekGesture(intent: .pin, cardPinned: true)
        #expect(pull.unpinFirst && pull.open, "one pinned surface at a time")
        let click = ScreenBarInteraction.peekGesture(intent: .toggle, cardPinned: true)
        #expect(click.unpinFirst && click.open)
        for intent: ScreenBarPeekIntent in [.pin, .toggle] {
            let attached = ScreenBarInteraction.peekGesture(intent: intent, cardPinned: true, expandedIsland: true)
            #expect(attached.open && !attached.unpinFirst)
        }
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

    @Test func aChangedTileWearsTheOneUnseenDot() throws {
        // The fixed blue dot History and the Overview draw, not the
        // accent colour: with a red accent a changed glyph read as a
        // failure.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp/ScreenBarPeek.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("UnseenDot()"))
        #expect(!text.contains("Circle().fill(Color.accentColor)"))
    }

    @Test func anAgentThatStartsAskingRevivesAFlickedAwayEar() {
        let working = ScreenBarWingSlot(text: "Working", provider: "claude", tone: .neutral)
        let asking = ScreenBarWingSlot(text: "Needs you", provider: "claude", tone: .attention)
        let failed = ScreenBarWingSlot(text: "Failed", provider: "claude", tone: .alert)
        // Dismissed while working: asking or failing is news.
        #expect(!ScreenBarController.sameWingSubject(asking, working))
        #expect(!ScreenBarController.sameWingSubject(failed, working))
        #expect(!ScreenBarController.sameWingSubject(failed, asking))
        // Dismissed while asking: calming down does not bring it back, and
        // the same agent's words churning is still one ear.
        #expect(ScreenBarController.sameWingSubject(working, asking))
        #expect(ScreenBarController.sameWingSubject(asking, ScreenBarWingSlot(text: "Needs you ·2", provider: "claude", tone: .attention)))
    }

    @Test func aGhostFromAnotherDisplayIsNotKept() {
        let here = CGRect(x: 0, y: 900, width: 1440, height: 40)
        let rects: [ScreenBarWingSide: CGRect] = [.left: CGRect(x: 500, y: 910, width: 120, height: 24),
                                                 .right: CGRect(x: 3000, y: 910, width: 120, height: 24)]
        let kept = ScreenBarController.ghostRectsKept(rects, onWindow: here)
        #expect(Set(kept.keys) == [.left])
    }

    @Test func workingProviderTurnsKeepAWingDismissed() {
        var dismissed = ScreenBarWingSlot(text: "Working", provider: "claude")
        dismissed.workingActivity = true
        var next = ScreenBarWingSlot(text: "Working", provider: "codex")
        next.workingActivity = true
        #expect(ScreenBarController.sameWingSubject(next, dismissed))
        #expect(ScreenBarController.sameWingSubject(dismissed, next))
        #expect(!ScreenBarController.sameWingSubject(
            ScreenBarWingSlot(text: "Needs you", provider: "codex", tone: .attention), dismissed))
        #expect(!ScreenBarController.sameWingSubject(
            ScreenBarWingSlot(text: "Failed", provider: "codex", tone: .alert), dismissed))
        #expect(!ScreenBarController.sameWingSubject(
            ScreenBarWingSlot(text: "Done", provider: "codex"), dismissed))
        #expect(!ScreenBarController.sameWingSubject(
            ScreenBarWingSlot(text: "Working", provider: "codex"), dismissed))
        #expect(!ScreenBarController.sameWingSubject(
            ScreenBarWingSlot(text: "42%", provider: "codex", meter: 0.42), dismissed))
        #expect(!ScreenBarController.sameWingSubject(
            ScreenBarWingSlot(text: "Working", provider: "codex", symbol: "bolt.fill"), dismissed))
        var changedMark = next
        changedMark.markID = "fixture-new-mark"
        #expect(!ScreenBarController.sameWingSubject(changedMark, dismissed))
        #expect(!ScreenBarController.sameWingSubject(
            ScreenBarWingSlot(text: "Working"), dismissed))
    }
}
