import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The band's click state machine (W10): a click pins the peek card as
/// the deliberate-focus surface; while pinned, inside clicks belong to
/// the card's buttons and outside clicks dismiss. Nothing click-through
/// under the band ever opens a session on its own.
@Suite struct ScreenBarInteractionTests {

    @MainActor
    @Test func accessibilityUsesTheExistingBandAndEarActions() {
        let card = NotchCardPresenter(model: makeTestCardModel())
        let focus = ScreenBarFocus(style: nil, label: "Codex", word: "Working", clickSession: "codex:1")
        let interaction = ScreenBarInteraction(card: card, hitRects: { [] }, focus: { focus })
        var ears: [ScreenBarWingSide] = []
        var peekIntents: [ScreenBarPeekIntent] = []
        var handleToggles = 0
        var expanded = false
        interaction.islandOwnsNotch = { true }
        interaction.onIslandExpand = { expanded = true }
        interaction.onWingActivate = { ears.append($0); return true }
        interaction.onPeek = { peekIntents.append($0) }
        interaction.rightWingOpensPeek = { true }
        interaction.onMenuHandle = { handleToggles += 1 }

        #expect(interaction.accessibilityPress())
        #expect(expanded)
        #expect(interaction.accessibilityActivateWing(.left))
        #expect(ears == [.left])
        #expect(interaction.accessibilityActivateWing(.right))
        #expect(peekIntents == [.toggle])
        #expect(interaction.accessibilityToggleMenuHandle())
        #expect(handleToggles == 1)
    }

    @MainActor
    @Test func aRightEarWithoutAPeekUsesItsOrdinaryWingAction() {
        let focus = ScreenBarFocus(style: nil, label: "Codex", word: "Working", clickSession: "codex:1")
        let interaction = ScreenBarInteraction(
            card: NotchCardPresenter(model: makeTestCardModel()), hitRects: { [] }, focus: { focus })
        var ears: [ScreenBarWingSide] = []
        var peeked = false
        interaction.onWingActivate = { ears.append($0); return true }
        interaction.onPeek = { _ in peeked = true }

        #expect(interaction.accessibilityActivateWing(.right))
        #expect(ears == [.right])
        #expect(!peeked)
    }

    @MainActor
    @Test func aParkedBandRejectsEveryAccessibilityAction() {
        let interaction = ScreenBarInteraction(
            card: NotchCardPresenter(model: makeTestCardModel()),
            hitRects: { [] }, focus: { ScreenBarFocus(style: nil, label: "Codex", word: "Idle", clickSession: nil) })
        var acted = false
        interaction.onWingActivate = { _ in acted = true; return true }
        interaction.onMenuHandle = { acted = true }
        interaction.setParked(true)

        #expect(!interaction.accessibilityPress())
        #expect(!interaction.accessibilityActivateWing(.left))
        #expect(!interaction.accessibilityActivateWing(.right))
        #expect(!interaction.accessibilityToggleMenuHandle())
        #expect(!acted)
    }

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

    // MARK: The flick — release speed is the other commit

    @Test func aFastDownwardReleaseExpandsEvenReleasedShort() {
        // The pull never crossed the travel threshold — the release
        // speed carries the swipe over the line.
        #expect(ScreenBarInteraction.flickOutcome(
            pinnedAtDown: false,
            velocityY: -NotchPullGesture.flickVelocity - 50) == .expand)
    }

    @Test func aFastUpwardReleaseCollapsesAPinnedCard() {
        #expect(ScreenBarInteraction.flickOutcome(
            pinnedAtDown: true,
            velocityY: NotchPullGesture.flickVelocity + 50) == .collapse)
    }

    @Test func aSlowReleaseIsNothing() {
        for v in stride(from: -500.0, through: 500.0, by: 100.0) {
            #expect(ScreenBarInteraction.flickOutcome(pinnedAtDown: false, velocityY: v) == .none)
            #expect(ScreenBarInteraction.flickOutcome(pinnedAtDown: true, velocityY: v) == .none)
        }
    }

    @Test func aFastFlickStillAnswersOnlyWhatTheSwipeWould() {
        // Speed commits the swipe's own verdict — a flick down on a
        // pinned card is already expanded, a flick up on nothing is
        // nothing.
        #expect(ScreenBarInteraction.flickOutcome(
            pinnedAtDown: true, velocityY: -1200) == .none)
        #expect(ScreenBarInteraction.flickOutcome(
            pinnedAtDown: false, velocityY: 1200) == .none)
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

    @Test func anInwardFlickDismissesToo() {
        // The island's rule: any sideways flick on the pill dismisses —
        // only the band's own swipe is the summon gesture.
        #expect(ScreenBarInteraction.wingSwipeOutcome(region: .wing(.left), deltaX: 30) == .dismiss(.left))
        #expect(ScreenBarInteraction.wingSwipeOutcome(region: .wing(.right), deltaX: -30) == .dismiss(.right))
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

    // MARK: Trackpad deltas (finger direction, not scroll direction)

    @Test func naturalScrollingNegatesTheDeltaBackToTheFinger() {
        // Natural scrolling reports scroll-direction deltas — fingers
        // down yield a positive delta — so the finger's travel is its
        // negation. Without this a pull-down read as a push-up and the
        // gestures fired the wrong branch.
        #expect(ScreenBarInteraction.scrollFingerDelta(12, inverted: true) == -12)
        #expect(ScreenBarInteraction.scrollFingerDelta(-12, inverted: true) == 12)
    }

    @Test func legacyScrollingReportsFingerDirectionAlready() {
        #expect(ScreenBarInteraction.scrollFingerDelta(12, inverted: false) == 12)
        #expect(ScreenBarInteraction.scrollFingerDelta(-12, inverted: false) == -12)
    }
}
