import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// What the island does with a pointer, on a hand-cranked clock: the
/// swell answers in the first frame, a short dwell opens the card, a
/// pointer that leaves first cancels it, a click on the swollen notch
/// opens at once, and a card is not folded under a hand that strays a
/// few points off its edge. Nothing here moves a real pointer: the
/// pointer's place is a seam.
@Suite("Notch hover intent")
@MainActor
struct NotchHoverIntentTests {
    /// A pointer's place a closure can read and a test can move.
    private final class Pointer: @unchecked Sendable {
        var value: CGPoint
        init(_ value: CGPoint) { self.value = value }
    }

    private func makeToy(reduceMotion: Bool = false) -> (toy: NotchToy, store: ToysStore, timers: ManualTimers) {
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        toy.menuBarHidden = { false }
        toy.reduceMotion = { reduceMotion }
        let timers = ManualTimers()
        toy.hoverTimer = { delay, work in timers.arm(delay, work) }
        return (toy, store, timers)
    }

    @Test("repeated leave events keep the original collapse deadline")
    func repeatedLeavesDoNotPostponeCollapse() {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.pointerLocation = { CGPoint(x: -10000, y: -10000) }
        toy.expand(held: false)
        toy.setHovered(false)
        timers.advance(by: NotchMotion.collapseDelay * 0.6)
        toy.setHovered(false)
        timers.advance(by: NotchMotion.collapseDelay * 0.5)
        #expect(!toy.islandExpanded)
        #expect(timers.live == 0)
    }

    @Test("native stage hover cannot rearm a card while the band owns menu hover")
    func bandIsSoleHoverOwner() {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.bandHandlesHover = true
        toy.setHovered(true)
        timers.advance(by: 1)
        #expect(!toy.hoverHeld)
        #expect(!toy.islandExpanded)
        toy.bandHover(true)
        toy.setHovered(false)
        #expect(toy.hoverHeld)
        toy.bandHover(false)
        toy.setHovered(true)
        timers.advance(by: 1)
        #expect(!toy.hoverHeld)
        #expect(!toy.islandExpanded)
        #expect(timers.live == 0)
    }

    @Test("native hover resumes when the band is hidden")
    func standaloneHoverStillWorks() {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.bandHandlesHover = true
        toy.setHovered(true)
        #expect(!toy.hoverHeld)
        toy.bandHandlesHover = false
        toy.setHovered(true)
        timers.advance(by: 1)
        #expect(toy.islandExpanded)
    }

    @Test("band appearance cancels a native dwell before a stationary menu reveal")
    func bandAppearanceRetiresNativeDwell() {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.setHovered(true)
        #expect(toy.hoverHeld)
        toy.bandHandlesHover = true
        #expect(!toy.hoverHeld)
        timers.advance(by: 1)
        #expect(!toy.islandExpanded)
        #expect(timers.live == 0)
    }

    @Test("live content holds height until a page turn or the next open")
    func expandedHeightStaysPut() {
        let (toy, store, _) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.expand(held: false)
        var measured: CGFloat = 240
        let measure = { measured }
        let first = toy.expandedContentHeight(width: 321, measure: measure)
        measured = 440
        #expect(toy.expandedContentHeight(width: 321, measure: measure) == first)
        toy.cardModel.show(.shelf)
        #expect(toy.expandedContentHeight(width: 321, measure: measure) == 440)
        measured = 180
        #expect(toy.expandedContentHeight(width: 321, measure: measure) == 440)
        toy.collapseIsland()
        toy.expand(held: false)
        #expect(toy.expandedContentHeight(width: 321, measure: measure) == 180)
    }

    @Test("the first frame of a hover already answers: the swell is there before any timer runs")
    func swellIsImmediate() {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.setHovered(true)
        #expect(toy.islandHoverPeek)
        #expect(!toy.islandExpanded, "the swell is a tell, not the card")
        #expect(timers.now == 0)
    }

    @Test("hover-to-open has one shape transition instead of a preliminary size bump")
    func dwellKeepsRestingShape() throws {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        let resting = try #require(toy.islandFrame(face: .idle))
        toy.setHovered(true)
        #expect(toy.islandHoverPeek)
        #expect(toy.islandFrame(face: .idle) == resting)
        timers.advance(by: 0.05)
        #expect(!toy.islandExpanded)
        #expect(toy.islandFrame(face: .idle) == resting)
        timers.advance(by: 0.2)
        #expect(toy.islandExpanded)
    }

    @Test("a short dwell opens the card, and a pointer that leaves first cancels it")
    func dwellOpensAndLeavingCancels() {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.setHovered(true)
        timers.advance(by: 0.05)
        toy.setHovered(false)
        timers.advance(by: 1)
        #expect(!toy.islandExpanded, "a graze on the notch is not an open")
        #expect(!toy.islandHoverPeek, "and the swell has settled")
        #expect(timers.live == 0)
        toy.setHovered(true)
        timers.advance(by: NotchSettings.defaultHoverOpenDelay + 0.001)
        #expect(toy.islandExpanded, "resting past the dwell opens it")
    }

    @Test("a click on the swollen notch opens at once, with nothing left armed")
    func clickOpensImmediately() {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.setHovered(true)
        #expect(toy.islandHoverPeek)
        toy.islandTapped()
        #expect(toy.islandExpanded, "no waiting out the dwell")
        #expect(toy.expandHeld, "a click is a deliberate open")
        timers.advance(by: 1)
        #expect(toy.islandExpanded, "the dwell that was armed does nothing more")
        #expect(timers.live == 0)
    }

    @Test("a pointer riding the notch's edge does not shiver the swell")
    func edgeJitterKeepsTheSwell() {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        store.state.notch.expandOnHover = false
        toy.setHovered(true)
        let frame = toy.desiredFrame
        for _ in 0..<6 {
            toy.setHovered(false)
            timers.advance(by: NotchMotion.swellGrace * 0.4)
            #expect(toy.islandHoverPeek, "off the edge for less than the grace is not a leave")
            toy.setHovered(true)
            timers.advance(by: NotchMotion.swellGrace * 0.4)
        }
        #expect(toy.islandHoverPeek)
        #expect(toy.desiredFrame == frame, "the frame never moved")
        toy.setHovered(false)
        timers.advance(by: NotchMotion.swellGrace + 0.001)
        #expect(!toy.islandHoverPeek, "a real leave lets it settle after the grace")
        #expect(timers.live == 0)
    }

    @Test("a hand that strays a few points off the card does not fold it; one that leaves does")
    func leaveSlopHoldsTheCard() {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.setHovered(true)
        timers.advance(by: 0.2)
        #expect(toy.islandExpanded)
        let card = CGRect(x: 600, y: 560, width: 320, height: 422)
        toy.desiredFrame = card
        let pointer = Pointer(CGPoint(x: card.midX, y: card.minY - NotchMotion.leaveSlop * 0.5))
        toy.pointerLocation = { pointer.value }
        toy.setHovered(false)
        timers.advance(by: NotchMotion.collapseDelay + 0.001)
        #expect(toy.islandExpanded, "a few points under the foot is still on the card")
        timers.advance(by: NotchMotion.collapseDelay + 0.001)
        #expect(toy.islandExpanded, "and it keeps looking, rather than giving up")
        pointer.value = CGPoint(x: card.midX, y: card.minY - NotchMotion.leaveSlop * 3)
        timers.advance(by: NotchMotion.collapseDelay + 0.001)
        #expect(!toy.islandExpanded, "well clear of it, the card folds")
        #expect(timers.live == 0)
    }

    @Test("coming back onto a card inside the slop cancels the fold")
    func comingBackCancelsTheFold() {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.setHovered(true)
        timers.advance(by: 0.2)
        toy.desiredFrame = CGRect(x: 600, y: 560, width: 320, height: 422)
        toy.pointerLocation = { CGPoint(x: 100, y: 100) }
        toy.setHovered(false)
        timers.advance(by: NotchMotion.collapseDelay * 0.5)
        toy.setHovered(true)
        timers.advance(by: 1)
        #expect(toy.islandExpanded)
    }

    @Test("Reduce Motion: no swell, but a click still opens at once")
    func reduceMotionKeepsStill() {
        let (toy, store, timers) = makeToy(reduceMotion: true)
        defer { withExtendedLifetime(store) {} }
        toy.setHovered(true)
        #expect(!toy.islandHoverPeek)
        timers.advance(by: 0.01)
        toy.islandTapped()
        #expect(toy.islandExpanded)
        #expect(toy.stage.openness == 1, "no travel: the card is simply there")
    }

    @Test("the hover band: arriving is exact, staying is a few points generous")
    func hoverBand() {
        let card = CGRect(x: 600, y: 560, width: 320, height: 422)
        #expect(NotchHoverBand.holds(pointer: CGPoint(x: card.midX, y: card.midY), card: card))
        #expect(NotchHoverBand.holds(pointer: CGPoint(x: card.minX - 7, y: card.midY), card: card))
        #expect(NotchHoverBand.holds(pointer: CGPoint(x: card.midX, y: card.minY - 7), card: card))
        #expect(!NotchHoverBand.holds(pointer: CGPoint(x: card.minX - 9, y: card.midY), card: card))
        #expect(!NotchHoverBand.holds(pointer: CGPoint(x: card.midX, y: card.minY - 9), card: card))
        #expect(NotchMotion.leaveSlop <= 12, "a band wide enough to forgive, never wide enough to trap")
    }

    @Test("the swell never paints sideways over the bare housing, so no menu-bar click lands on it")
    func bareSwellStaysUnderTheNotch() {
        let idle = CGSize(width: 185, height: 32)
        let bare = NotchIslandLayout.peekAdjusted(idle, bare: true)
        #expect(bare.width == idle.width, "the bare housing leans straight down")
        #expect(bare.height - idle.height == NotchMotion.hoverGrowHeight)
        let drawn = NotchIslandLayout.peekAdjusted(idle, bare: false)
        #expect(drawn.width - idle.width == NotchMotion.hoverGrowWidth)
        #expect(NotchMotion.hoverGrowHeight <= 4 && NotchMotion.hoverGrowWidth <= 8, "a lean, never a pop")
    }

    @Test("the stage a swell runs on holds it, hangs from the top and reaches only a few points past the notch")
    func swellStageStaysSmall() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let idle = CGRect(x: 663.5, y: screen.maxY - 32, width: 185, height: 32)
        let size = NotchIslandLayout.peekAdjusted(idle.size, bare: true)
        let swell = CGRect(x: idle.minX, y: screen.maxY - size.height, width: size.width, height: size.height)
        let motion = NotchMotion.frameMotion(from: idle, to: swell)
        #expect(motion == NotchMotion.hover)
        let stage = NotchStage.frame(presented: idle, target: swell, motion: motion, within: screen, scale: 2)
        #expect(NotchStage.holds(stage, idle) && NotchStage.holds(stage, swell))
        #expect(stage.maxY == screen.maxY, "hung from the screen's top edge")
        let air = NotchStage.margin(travel: 4, motion: motion)
        #expect(air <= 6, "a swell's stage is a few points of air, not a panel")
        #expect(stage.width <= idle.width + 2 * (air + 1))
        #expect(stage.height <= swell.height + air + 1)
    }
}
