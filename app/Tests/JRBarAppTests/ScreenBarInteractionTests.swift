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
}
