import Foundation
import Testing
@testable import JRBarApp

/// The band's click state machine (W10): a click pins the peek card as
/// the deliberate-focus surface; while pinned, inside clicks belong to
/// the card's buttons and outside clicks dismiss. Nothing click-through
/// under the band ever opens a session on its own.
@Suite struct ScreenBarInteractionTests {

    @Test func aBandClickPinsThePeek() {
        #expect(ScreenBarInteraction.clickOutcome(pinned: false, inside: true) == .pin)
    }

    @Test func aClickOutsideDoesNothingWhenUnpinned() {
        #expect(ScreenBarInteraction.clickOutcome(pinned: false, inside: false) == .none)
    }

    @Test func pinnedInsideClicksAreTheCards() {
        #expect(ScreenBarInteraction.clickOutcome(pinned: true, inside: true) == .cardButton)
    }

    @Test func pinnedOutsideClicksDismiss() {
        #expect(ScreenBarInteraction.clickOutcome(pinned: true, inside: false) == .unpin)
    }

    // MARK: Swipe (Alcove-style band gestures)

    @Test func aSwipeDownOnTheBandExpands() {
        #expect(ScreenBarInteraction.swipeOutcome(pinnedAtDown: false,
                                                  deltaY: -ScreenBarInteraction.swipeThreshold - 1) == .expand)
    }

    @Test func aSwipeUpOnAPinnedCardCollapses() {
        #expect(ScreenBarInteraction.swipeOutcome(pinnedAtDown: true,
                                                  deltaY: ScreenBarInteraction.swipeThreshold + 1) == .collapse)
    }

    @Test func aSwipeDownOnAPinnedCardIsAlreadyExpanded() {
        #expect(ScreenBarInteraction.swipeOutcome(pinnedAtDown: true, deltaY: -30) == .none)
    }

    @Test func aSwipeUpWithNothingPinnedIsNothing() {
        #expect(ScreenBarInteraction.swipeOutcome(pinnedAtDown: false, deltaY: 30) == .none)
    }

    @Test func aJitterInsideTheThresholdStaysAClick() {
        for delta in stride(from: -13.0, through: 13.0, by: 1.0) {
            #expect(ScreenBarInteraction.swipeOutcome(pinnedAtDown: false, deltaY: delta) == .none,
                    "deltaY \(delta) should not fire")
            #expect(ScreenBarInteraction.swipeOutcome(pinnedAtDown: true, deltaY: delta) == .none,
                    "pinned deltaY \(delta) should not fire")
        }
    }

    // MARK: Wing swipe (dismiss / summon the notch lobes)

    @Test func anOutwardFlickDismissesTheLeftWing() {
        #expect(ScreenBarInteraction.wingSwipeOutcome(
            region: .wing(.left),
            deltaX: -ScreenBarInteraction.swipeThreshold - 1) == .dismiss(.left))
    }

    @Test func anOutwardFlickDismissesTheRightWing() {
        #expect(ScreenBarInteraction.wingSwipeOutcome(
            region: .wing(.right),
            deltaX: ScreenBarInteraction.swipeThreshold + 1) == .dismiss(.right))
    }

    @Test func anInwardFlickOnAWingIsNothing() {
        // Pushing the left ear toward the notch does not summon; the
        // band's own swipe is the summon gesture.
        #expect(ScreenBarInteraction.wingSwipeOutcome(region: .wing(.left), deltaX: 30) == .none)
        #expect(ScreenBarInteraction.wingSwipeOutcome(region: .wing(.right), deltaX: -30) == .none)
    }

    @Test func aHorizontalSwipeOnTheBandSummons() {
        for delta: CGFloat in [-40, 40] {
            #expect(ScreenBarInteraction.wingSwipeOutcome(region: .band, deltaX: delta) == .restore)
        }
    }

    @Test func aSubThresholdHorizontalMoveIsNothing() {
        for region in [ScreenBarInteraction.SwipeRegion.wing(.left), .wing(.right), .band] {
            #expect(ScreenBarInteraction.wingSwipeOutcome(region: region, deltaX: 8) == .none)
            #expect(ScreenBarInteraction.wingSwipeOutcome(region: region, deltaX: -8) == .none)
        }
    }
}
