import AppKit
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
    @Test func localScrollMonitorAdmitsRestorationBeforeNativeDispatch() throws {
        let interaction = ScreenBarInteraction(
            card: NotchCardPresenter(model: makeTestCardModel()), hitRects: { [] }, focus: { nil })
        interaction.setParked(true)
        var localScroll: ((NSEvent) -> Void)?
        interaction.installMonitor = { global, mask, callback in
            if !global, mask.contains(.scrollWheel) { localScroll = callback }
            return NSObject()
        }
        interaction.removeMonitor = { _ in }
        interaction.extraHitTest = { _ in true }
        var eligible = true
        var admissions = 0
        interaction.canRestoreIslandWings = { _ in admissions += 1; return eligible }
        var restores = 0
        interaction.onWingRestore = { restores += 1; eligible = false }
        let host = makeMouseHost()
        host.canRestoreIslandWings = { _ in eligible }
        var mediaSwipes: [NotchIslandSwipe] = []
        host.onSwipe = { mediaSwipes.append($0) }
        interaction.start()
        defer { interaction.stop() }
        let callback = try #require(localScroll)
        func event(_ phase: NSEvent.Phase, dx: Int32) throws -> NSEvent {
            let raw = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                          wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0))
            raw.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            raw.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            return try #require(NSEvent(cgEvent: raw))
        }
        let began = try event(.began, dx: 0)
        #expect(began.hasPreciseScrollingDeltas && began.phase.contains(.began))
        callback(began)
        #expect(admissions == 1)
        let point = NSPoint(x: 700, y: 960)
        host.handleScroll(precise: true, phase: .began, deltaX: 0, deltaY: 0,
                          inverted: false, at: point)
        eligible = false
        let changed = try event(.changed, dx: 60)
        #expect(abs(changed.scrollingDeltaX) >= 40)
        callback(changed)
        host.handleScroll(precise: true, phase: .changed, deltaX: 60, deltaY: 0,
                          inverted: false, at: point)
        callback(try event(.ended, dx: 0))
        host.handleScroll(precise: true, phase: .ended, deltaX: 0, deltaY: 0,
                          inverted: false, at: point)
        #expect(restores == 1)
        #expect(mediaSwipes.isEmpty)
    }

    @MainActor
    @Test func restorationIncludesReleaseTravelButNeverCancellationOrMomentum() {
        let point = NSPoint(x: 700, y: 960)
        let interaction = ScreenBarInteraction(
            card: NotchCardPresenter(model: makeTestCardModel()), hitRects: { [] }, focus: { nil })
        interaction.extraHitTest = { _ in true }
        interaction.canRestoreIslandWings = { _ in true }
        var restores = 0
        interaction.onWingRestore = { restores += 1 }
        for terminal in [NSEvent.Phase.cancelled, .ended] {
            interaction.pointerScrolled(precise: true, phase: .began, deltaX: 0, deltaY: 0,
                                        inverted: false, at: point)
            interaction.pointerScrolled(precise: true, phase: .changed, deltaX: 20, deltaY: 0,
                                        inverted: false, at: point)
            interaction.pointerScrolled(precise: true, phase: terminal, deltaX: 5, deltaY: 0,
                                        inverted: false, at: point)
            #expect(restores == (terminal == .ended ? 1 : 0))
        }
        interaction.pointerScrolled(precise: true, phase: [], deltaX: 60, deltaY: 0,
                                    inverted: false, at: point)
        interaction.pointerScrolled(precise: true, phase: .ended, deltaX: 60, deltaY: 0,
                                    inverted: false, at: point)
        #expect(restores == 1)
    }

    @MainActor
    @Test func hostingIncludesReleaseTravelWithoutCommittingCancellation() {
        let host = makeMouseHost()
        let point = NSPoint(x: 700, y: 960)
        var swipes: [NotchIslandSwipe] = []
        host.onSwipe = { swipes.append($0) }
        for terminal in [NSEvent.Phase.cancelled, .ended] {
            host.handleScroll(precise: true, phase: .began, deltaX: 0, deltaY: 0, inverted: false, at: point)
            host.handleScroll(precise: true, phase: .changed, deltaX: 24, deltaY: 0, inverted: false, at: point)
            host.handleScroll(precise: true, phase: terminal, deltaX: 5, deltaY: 0, inverted: false, at: point)
            #expect(swipes.count == (terminal == .ended ? 1 : 0))
        }
        host.handleScroll(precise: true, phase: [], deltaX: 60, deltaY: 0, inverted: false, at: point)
        host.handleScroll(precise: true, phase: .ended, deltaX: 60, deltaY: 0, inverted: false, at: point)
        #expect(swipes.count == 1)
    }

    @Test func wingGestureOwnershipPrecedesIslandShoulderContainment() {
        for side in [ScreenBarWingSide.left, .right] {
            #expect(!ScreenBarInteraction.islandOwnsGesture(wing: side, onIsland: true))
            #expect(!ScreenBarInteraction.islandOwnsGesture(wing: side, onIsland: false))
        }
        #expect(ScreenBarInteraction.islandOwnsGesture(wing: nil, onIsland: true))
        #expect(!ScreenBarInteraction.islandOwnsGesture(wing: nil, onIsland: false))
    }

    @MainActor
    @Test func mouseDragRestoresWingsFromTheSameIslandHeader() {
        let point = NSPoint(x: 700, y: 960)
        let interaction = ScreenBarInteraction(
            card: NotchCardPresenter(model: makeTestCardModel()),
            hitRects: { [] }, focus: { nil })
        interaction.extraHitTest = { _ in true }
        interaction.canRestoreIslandWings = { _ in true }
        var restores = 0
        interaction.onWingRestore = { restores += 1 }
        interaction.pointerDown(at: point, time: 1)
        interaction.pointerDragged(to: NSPoint(x: 760, y: 960), at: 1.1)
        interaction.pointerReleased(at: 1.2)
        #expect(restores == 1)
    }

    @MainActor
    @Test func mouseHeaderRestorationIsLatchedAndNeverPinsOnRelease() {
        let point = NSPoint(x: 700, y: 960)
        let interaction = ScreenBarInteraction(
            card: NotchCardPresenter(model: makeTestCardModel()), hitRects: { [] }, focus: { nil })
        var eligible = true
        var restores = 0
        var expands = 0
        var collapses = 0
        interaction.extraHitTest = { _ in true }
        interaction.islandOwnsNotch = { true }
        interaction.canRestoreIslandWings = { _ in eligible }
        interaction.onWingRestore = { restores += 1; eligible = false }
        interaction.onIslandExpand = { expands += 1 }
        interaction.onIslandCollapse = { collapses += 1 }
        interaction.pointerDown(at: point, time: 1)
        interaction.pointerDragged(to: NSPoint(x: 760, y: 960), at: 1.1)
        interaction.pointerDragged(to: NSPoint(x: 800, y: 900), at: 1.2)
        interaction.pointerReleased(at: 1.3)
        #expect(restores == 1 && expands == 0 && collapses == 0)
        eligible = true
        interaction.pointerDown(at: point, time: 2)
        interaction.pointerReleased(at: 2.1)
        interaction.pointerDown(at: point, time: 3)
        interaction.pointerDragged(to: NSPoint(x: 700, y: 920), at: 3.1)
        interaction.pointerDragged(to: NSPoint(x: 780, y: 920), at: 3.2)
        interaction.pointerReleased(at: 3.3)
        interaction.pointerDown(at: point, time: 4, command: true)
        interaction.pointerDragged(to: NSPoint(x: 780, y: 960), at: 4.1)
        interaction.pointerReleased(at: 4.2)
        #expect(restores == 1 && expands == 0 && collapses == 0)
    }

    @MainActor
    private func makeMouseHost() -> NotchIslandHostingView {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        return NotchIslandHostingView(rootView: NotchIslandView(toy: store.notch))
    }

    @MainActor
    @Test func hostingConsumesRestorationDragAndReleaseAfterHeaderEligibilityChanges() {
        let host = makeMouseHost()
        let point = NSPoint(x: 700, y: 960)
        var eligible = true
        var pulls = 0
        var swipes: [NotchIslandSwipe] = []
        host.canRestoreIslandWings = { _ in eligible }
        host.onPullBegan = { pulls += 1 }
        host.onPullChanged = { _ in pulls += 1 }
        host.onPullEnded = { _ in pulls += 1 }
        host.onSwipe = { swipes.append($0) }
        #expect(host.handleMouseDown(at: point, time: 1))
        #expect(!host.handleMouseDragged(to: NSPoint(x: 760, y: 960), time: 1.1))
        eligible = false
        #expect(!host.handleMouseDragged(to: NSPoint(x: 760, y: 900), time: 1.2))
        #expect(!host.handleMouseUp(at: NSPoint(x: 760, y: 900), time: 1.3))
        #expect(pulls == 0 && swipes.isEmpty)
    }

    @MainActor
    @Test func hostingHeaderTapAndVerticalPullRemainNativeAndCommandDragKeepsTimerPriority() {
        let host = makeMouseHost()
        let point = NSPoint(x: 700, y: 960)
        host.canRestoreIslandWings = { _ in true }
        #expect(host.handleMouseDown(at: point, time: 1))
        #expect(host.handleMouseUp(at: point, time: 1.1))
        var pulls = 0
        host.onPullBegan = { pulls += 1 }
        #expect(host.handleMouseDown(at: point, time: 2))
        #expect(host.handleMouseDragged(to: NSPoint(x: 700, y: 920), time: 2.1))
        #expect(host.handleMouseDragged(to: NSPoint(x: 760, y: 920), time: 2.2))
        #expect(host.handleMouseUp(at: NSPoint(x: 760, y: 920), time: 2.3))
        #expect(pulls == 1)
        var timerTravel: [CGFloat] = []
        var timerEnd: CGFloat?
        host.timerDragAllowed = { true }
        host.onTimerDrag = { timerTravel.append($0) }
        host.onTimerDragEnd = { timerEnd = $0 }
        #expect(!host.handleMouseDown(at: point, time: 3, command: true))
        #expect(!host.handleMouseDragged(to: NSPoint(x: 760, y: 960), time: 3.1))
        #expect(!host.handleMouseUp(at: NSPoint(x: 760, y: 960), time: 3.2))
        #expect(timerTravel == [0, 60] && timerEnd == 60)
        #expect(pulls == 1)
    }

    @MainActor
    @Test func aSensorOnlyWingCanBeDismissed() {
        let controller = ScreenBarController(nativeNoticesEnabled: false)
        controller.sensors = NotchSensorState(microphoneInUse: true, cameraInUse: false)
        controller.dismissWing(.right)
        #expect(controller.hasDismissedWings)
        controller.restoreWings()
        #expect(!controller.hasDismissedWings)
    }

    @MainActor
    @Test func wingDismissalRequiresExplicitRestoration() {
        let controller = ScreenBarController(nativeNoticesEnabled: false)
        let working = ScreenBarWingSlot(text: "Working", provider: "codex")
        controller.wings = ScreenBarWings(left: working)
        controller.dismissWing(.left)
        #expect(controller.hasDismissedWings)
        for wings in [ScreenBarWings.empty,
                      ScreenBarWings(left: ScreenBarWingSlot(text: "Working", provider: "claude")),
                      ScreenBarWings(left: ScreenBarWingSlot(text: "Needs you", provider: "claude", tone: .attention))] {
            controller.wings = wings
            #expect(controller.hasDismissedWings)
        }
        controller.restoreWings()
        #expect(!controller.hasDismissedWings)
    }

    @MainActor
    @Test func dismissedWingsRestoreFromTheVisibleIslandOncePerHorizontalGesture() {
        let point = NSPoint(x: 720, y: 965)
        let interaction = ScreenBarInteraction(
            card: NotchCardPresenter(model: makeTestCardModel()),
            hitRects: { [] }, focus: { nil })
        interaction.extraHitTest = { _ in true }
        var dismissed = true
        interaction.canRestoreIslandWings = { _ in dismissed }
        var restores = 0
        interaction.onWingRestore = { restores += 1; dismissed = false }
        interaction.pointerScrolled(precise: true, phase: .began, deltaX: 0, deltaY: 0,
                                    inverted: false, at: point)
        interaction.pointerScrolled(precise: true, phase: .changed, deltaX: 41, deltaY: 0,
                                    inverted: false, at: point)
        interaction.pointerScrolled(precise: true, phase: .ended, deltaX: 0, deltaY: 0,
                                    inverted: false, at: point)
        interaction.pointerScrolled(precise: true, phase: [], deltaX: 60, deltaY: 0,
                                    inverted: false, at: point)
        interaction.pointerScrolled(precise: true, phase: .began, deltaX: -41, deltaY: 0,
                                    inverted: false, at: point)
        interaction.pointerScrolled(precise: true, phase: .ended, deltaX: 0, deltaY: 0,
                                    inverted: false, at: point)
        #expect(restores == 1)
    }

    @MainActor
    @Test func restingIslandRestorationCommitsAShortNaturalScrollOnRelease() {
        let point = NSPoint(x: 720, y: 965)
        let interaction = ScreenBarInteraction(
            card: NotchCardPresenter(model: makeTestCardModel()),
            hitRects: { [] }, focus: { nil })
        interaction.extraHitTest = { _ in true }
        interaction.canRestoreIslandWings = { _ in true }
        var restores = 0
        interaction.onWingRestore = { restores += 1 }
        interaction.pointerScrolled(precise: true, phase: .began, deltaX: 23, deltaY: 0,
                                    inverted: true, at: point)
        #expect(restores == 0)
        interaction.pointerScrolled(precise: true, phase: .ended, deltaX: 0, deltaY: 0,
                                    inverted: true, at: point)
        #expect(restores == 1)
    }

    @MainActor
    @Test func islandRestorationRejectsVerticalCancelledAndOutsideGestures() {
        let point = NSPoint(x: 720, y: 965)
        let interaction = ScreenBarInteraction(
            card: NotchCardPresenter(model: makeTestCardModel()),
            hitRects: { [] }, focus: { nil })
        interaction.extraHitTest = { $0 == point }
        interaction.canRestoreIslandWings = { _ in true }
        var restores = 0
        var expands = 0
        interaction.islandOwnsNotch = { true }
        interaction.onIslandExpand = { expands += 1 }
        interaction.onWingRestore = { restores += 1 }
        interaction.pointerScrolled(precise: true, phase: .began, deltaX: 0, deltaY: -60,
                                    inverted: false, at: point)
        interaction.pointerScrolled(precise: true, phase: .ended, deltaX: 0, deltaY: 0,
                                    inverted: false, at: point)
        interaction.pointerScrolled(precise: true, phase: .began, deltaX: 5, deltaY: 0,
                                    inverted: false, at: point)
        interaction.pointerScrolled(precise: true, phase: .cancelled, deltaX: 60, deltaY: 0,
                                    inverted: false, at: point)
        interaction.pointerScrolled(precise: true, phase: .began, deltaX: 60, deltaY: 0,
                                    inverted: false, at: .zero)
        interaction.pointerScrolled(precise: true, phase: .ended, deltaX: 0, deltaY: 0,
                                    inverted: false, at: .zero)
        #expect(restores == 0)
        #expect(expands == 0)
    }

    @MainActor
    @Test func hostingRestorationSuppressesHorizontalMediaButKeepsVerticalAndContentSwipes() {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let host = NotchIslandHostingView(rootView: NotchIslandView(toy: store.notch))
        let frame = NSRect(x: 500, y: 600, width: 400, height: 300)
        let header = NSPoint(x: 700, y: 880)
        let content = NSPoint(x: 700, y: 750)
        var dismissed = true
        host.canRestoreIslandWings = { point in
            dismissed && ScreenBarInteraction.isWingRestorationHeader(point, frame: frame)
        }
        var swipes: [NotchIslandSwipe] = []
        host.onSwipe = { swipes.append($0) }
        host.handleScroll(precise: true, phase: .began, deltaX: 0, deltaY: 0, inverted: false, at: header)
        dismissed = false
        host.handleScroll(precise: true, phase: .changed, deltaX: 60, deltaY: 0, inverted: false, at: header)
        host.handleScroll(precise: true, phase: .ended, deltaX: 0, deltaY: 0, inverted: false, at: header)
        host.handleScroll(precise: true, phase: [], deltaX: 60, deltaY: 0, inverted: false, at: header)
        #expect(swipes.isEmpty)
        dismissed = true
        host.handleScroll(precise: true, phase: .began, deltaX: 28, deltaY: 0, inverted: false, at: header)
        dismissed = false
        host.handleScroll(precise: true, phase: .ended, deltaX: 0, deltaY: 0, inverted: false, at: header)
        #expect(swipes.isEmpty)
        dismissed = true
        host.handleScroll(precise: true, phase: .began, deltaX: 0, deltaY: 60, inverted: false, at: header)
        host.handleScroll(precise: true, phase: .ended, deltaX: 0, deltaY: 0, inverted: false, at: header)
        #expect(swipes.count == 1)
        host.handleScroll(precise: true, phase: .began, deltaX: 60, deltaY: 0, inverted: false, at: content)
        host.handleScroll(precise: true, phase: .ended, deltaX: 0, deltaY: 0, inverted: false, at: content)
        #expect(swipes.count == 2)
        dismissed = false
        host.handleScroll(precise: true, phase: .began, deltaX: -60, deltaY: 0, inverted: false, at: header)
        host.handleScroll(precise: true, phase: .ended, deltaX: 0, deltaY: 0, inverted: false, at: header)
        #expect(swipes.count == 3)
        withExtendedLifetime(store) {}
    }

    @MainActor
    @Test func trackpadSwipeOnAPaintedShoulderDismissesOnlyItsWing() {
        let point = NSPoint(x: 650, y: 965)
        let interaction = ScreenBarInteraction(
            card: NotchCardPresenter(model: makeTestCardModel()),
            hitRects: { [] }, focus: { nil })
        interaction.extraHitTest = { _ in true }
        interaction.wingSideAt = { _ in .left }
        var dismissed: [ScreenBarWingSide] = []
        var expanded = false
        interaction.islandOwnsNotch = { true }
        interaction.onIslandExpand = { expanded = true }
        interaction.onWingDismiss = { dismissed.append($0) }
        interaction.pointerScrolled(precise: true, phase: .began, deltaX: 0, deltaY: 0,
                                    inverted: false, at: point)
        interaction.pointerScrolled(precise: true, phase: .changed, deltaX: -41, deltaY: 0,
                                    inverted: false, at: point)
        interaction.pointerScrolled(precise: true, phase: .ended, deltaX: 0, deltaY: 0,
                                    inverted: false, at: point)
        interaction.pointerScrolled(precise: true, phase: [], deltaX: -60, deltaY: 0,
                                    inverted: false, at: point)
        #expect(dismissed == [.left])
        #expect(!expanded)
    }

    @MainActor
    @Test func islandBodyAndCancelledWingGesturesDoNotDismiss() {
        let point = NSPoint(x: 650, y: 965)
        let interaction = ScreenBarInteraction(
            card: NotchCardPresenter(model: makeTestCardModel()),
            hitRects: { [] }, focus: { nil })
        interaction.extraHitTest = { _ in true }
        var side: ScreenBarWingSide?
        interaction.wingSideAt = { _ in side }
        var dismissals = 0
        interaction.onWingDismiss = { _ in dismissals += 1 }
        interaction.pointerScrolled(precise: true, phase: .began, deltaX: 41, deltaY: 0,
                                    inverted: false, at: point)
        interaction.pointerScrolled(precise: true, phase: .ended, deltaX: 0, deltaY: 0,
                                    inverted: false, at: point)
        side = .right
        interaction.pointerScrolled(precise: true, phase: .began, deltaX: 5, deltaY: 0,
                                    inverted: false, at: point)
        interaction.pointerScrolled(precise: true, phase: .cancelled, deltaX: 50, deltaY: 0,
                                    inverted: false, at: point)
        interaction.pointerScrolled(precise: true, phase: .ended, deltaX: 0, deltaY: 0,
                                    inverted: false, at: point)
        #expect(dismissals == 0)
    }

    @MainActor
    @Test func capturedWingPressArmsEvenAfterThePointerHasMovedAway() {
        let rect = NSRect(x: 650, y: 950, width: 13, height: 32)
        let point = NSPoint(x: 655, y: 965)
        let interaction = ScreenBarInteraction(
            card: NotchCardPresenter(model: makeTestCardModel()),
            hitRects: { [rect] }, focus: { nil })
        interaction.pointerLocation = { NSPoint(x: 300, y: 300) }
        interaction.extraHitTest = { rect.contains($0) }
        interaction.wingSideAt = { rect.contains($0) ? .left : nil }
        var dismissed: [ScreenBarWingSide] = []
        interaction.onWingDismiss = { dismissed.append($0) }
        interaction.pointerDown(at: point, time: 1)
        interaction.pointerDragged(to: NSPoint(x: point.x - 20, y: point.y), at: 1.1)
        interaction.pointerReleased(at: 1.2)
        #expect(dismissed == [.left])
    }


    @MainActor
    @Test func accessibilityUsesTheExistingBandAndEarActions() {
        let card = NotchCardPresenter(model: makeTestCardModel())
        let focus = ScreenBarFocus(style: nil, label: "Codex", word: "Working", clickSession: "codex:1")
        let interaction = ScreenBarInteraction(card: card, hitRects: { [] }, focus: { focus })
        var ears: [ScreenBarWingSide] = []
        var peekIntents: [ScreenBarPeekIntent] = []
        var expanded = false
        interaction.islandOwnsNotch = { true }
        interaction.onIslandExpand = { expanded = true }
        interaction.onWingActivate = { ears.append($0); return true }
        interaction.onPeek = { peekIntents.append($0) }
        interaction.rightWingOpensPeek = { true }

        #expect(interaction.accessibilityPress())
        #expect(expanded)
        #expect(interaction.accessibilityActivateWing(.left))
        #expect(ears == [.left])
        #expect(interaction.accessibilityActivateWing(.right))
        #expect(peekIntents == [.toggle])
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
        interaction.setParked(true)

        #expect(!interaction.accessibilityPress())
        #expect(!interaction.accessibilityActivateWing(.left))
        #expect(!interaction.accessibilityActivateWing(.right))
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
