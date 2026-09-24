import AppKit
import JRBarCore
import Observation
import SwiftUI

/// The island's gestures: tap, pull, swipe, pinch and the ⌘-drag timer.
extension NotchToy {
    // MARK: Tap

    /// A tap on the island itself — the view's tap gesture. The card
    /// toggles: grown folds, resting grows (the same deliberate pin a
    /// band click earns — a tap is a click, so outside-click and Esc
    /// still let it go). A capsule about a session opens that session —
    /// news you tap takes you to the thing, and a tap on "failed" no
    /// longer throws away the only pointer to the broken run — and steps
    /// down; one about nothing in particular (power, a device) just puts
    /// itself away. Key feedback is only ever put away. None of them
    /// re-opens the card.
    func islandTapped() {
        guard isDrawingIsland, !foldEngaged else { return }
        if islandExpanded {
            collapseIsland()
        } else if activeOverlay != nil {
            endOverlay(settle: true)
        } else if let capsule = activeCapsule {
            if let session = capsule.session, !CoreSession.isRemoteID(session) {
                openCapsuleSession()
            } else {
                dismissCapsule()
            }
        } else if NSEvent.modifierFlags.contains(.option), settings.mirror {
            summonMirror()
        } else {
            expandFromBand()
        }
    }

    /// ⌃⌥D and `jrbar://shelf`: the card opens straight onto the shelf,
    /// or folds when it is already up — the Yoink key, which is about
    /// the shelf, not the sessions. The island's card while the island
    /// is drawn, else the band's glass card, which has the same two
    /// pages. nil once it acted, else the sentence a link says instead
    /// of doing nothing: with the utility off there is no card at all.
    @discardableResult
    func toggleShelf() -> String? {
        if islandExpanded {
            collapseFromBand()
            return nil
        }
        switch notchSurface {
        case .island:
            // Fold's overlay owns the screen; the band press waits it out too.
            guard !foldEngaged else { return nil }
            cardModel.show(.shelf)
            expandFromBand()
            return nil
        case .glass:
            return toggleGlassShelf()
        case .none:
            return "The Notch utility is off — turn it on in Utilities."
        }
    }

    /// ⌥-click on the resting island: the card opens straight onto the
    /// Mirror. The camera only ever runs when asked for like this (or
    /// from the card header's camera button), and closes with the card.
    func summonMirror() {
        guard settings.mirror, isDrawingIsland, !foldEngaged else { return }
        cardModel.summonMirror()
        if !islandExpanded { expandFromBand() }
    }

    /// A click on the resting island's amber count — straight to the
    /// session that has waited longest, rather than the card: one click
    /// from "someone needs me" to the terminal that does.
    func openOldestAsk() {
        guard isDrawingIsland, !foldEngaged,
              let session = islandSummary.oldestWaiting else {
            islandTapped()
            return
        }
        openInFlight = Task { [weak self] in _ = await self?.open(session: session) }
    }

    // MARK: Pull

    /// The press-and-pull engaged — the window's finger-following
    /// stretch is live. While it runs, `pullActive` keeps the hover
    /// debounce from folding the card the finger is holding; the
    /// pending hover-expand cancels too — the pull IS the intent.
    func islandPullBegan() {
        pullActive = true
        collapseWork?.cancel()
        collapseWork = nil
        expandWork?.cancel()
        expandWork = nil
    }

    /// The pull let go — `verdict` is the pure machine's call. A commit
    /// is the surface's act: the resting island's pull-down is the
    /// swipe-down's own truth (open on idle, dismiss on a capsule,
    /// fold on the card — `islandSwipe(.down)` already says it). A
    /// retreat springs the frame back to wherever the island's face
    /// wants it; a pull that never engaged stays the click it was.
    func islandPullEnded(_ verdict: NotchPullGesture.Verdict) {
        pullActive = false
        switch verdict {
        case .commit:
            islandSwipe(.down)
        case .retreat:
            // A pull that ended off the island is a leave the debounce
            // never saw — re-check the real pointer against the frame
            // the face actually wants before it stays grown.
            if islandExpanded, !expandHeld,
               let resting = desiredFrame ?? islandFrame(face: currentFace),
               !resting.contains(NSEvent.mouseLocation) {
                hoverHeld = false
                peekWork?.cancel()
                peekWork = nil
                islandHoverPeek = false
                scheduleCollapseCheck()
            }
        case .click:
            break
        }
        // Either way the window lands on its face's frame — the
        // verdict's own path reframed when it acted; a refused commit
        // (gestures switched off mid-pull) still settles.
        if let frame = desiredFrame {
            island?.applyFrame(frame,
                               animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    // MARK: Swipe

    /// A two-finger swipe on the island, read off the hosting view's
    /// scroll events — or the pull's commit verdict, which means the
    /// same thing. Horizontal rides the media transport — only while
    /// the island is actually showing a track, so a stray swipe never
    /// pokes a player we aren't displaying. Down folds the open card
    /// back under the notch, dismisses the capsule, and — on the plain
    /// resting island — is the pull-open: the same deliberate grow a
    /// band click earns.
    func islandSwipe(_ swipe: NotchIslandSwipe) {
        guard settings.pullGestures else { return }
        switch swipe {
        case .left:
            // Across the grown card a sideways swipe turns its page; on
            // the resting island it is the transport.
            if islandExpanded {
                cardModel.flipPage(toShelf: true)
            } else if islandMedia != nil {
                mediaNextTrack()
            }
        case .right:
            if islandExpanded {
                cardModel.flipPage(toShelf: false)
            } else if islandMedia != nil {
                mediaPreviousTrack()
            }
        case .down:
            if islandExpanded {
                foldExpandedCard()
            } else if activeCapsule != nil || activeOverlay != nil || capsuleQueue.current != nil {
                dismissCapsule()
            } else {
                // The pull-open: a down swipe on the resting island
                // grows the card, deliberately — it holds like a band
                // click, not like a hover.
                expand(held: true)
            }
        case .up:
            if islandExpanded {
                // Fingers up tuck the card back into the notch —
                // Alcove's dismiss flick, the same fold a down-swipe
                // earns.
                foldExpandedCard()
            } else if activeCapsule != nil || activeOverlay != nil || capsuleQueue.current != nil {
                dismissCapsule()
            }
            // On a resting island an up-flick means nothing — the
            // notch cannot be pushed into the screen.
        }
    }

    /// A pinch on the island: spreading two fingers grows the resting
    /// island into the card (deliberately, like a band click);
    /// squeezing folds the card back into the notch, or puts a capsule
    /// away. Behind the same gestures switch as pull and swipe.
    func islandPinch(_ verdict: NotchPinch.Verdict) {
        guard settings.pullGestures, isDrawingIsland, !foldEngaged else { return }
        switch verdict {
        case .grow:
            guard !islandExpanded else { return }
            expandFromBand()
        case .fold:
            if islandExpanded {
                foldExpandedCard()
            } else if activeCapsule != nil || activeOverlay != nil || capsuleQueue.current != nil {
                dismissCapsule()
            }
        }
    }

    // MARK: ⌘-drag timer

    /// Whether a ⌘-press on the island starts a timer drag: the resting
    /// island (or news on it), never the card or an ask's buttons, and
    /// behind the same gestures switch as pull and pinch.
    var timerDragAllowed: Bool {
        guard settings.pullGestures, isDrawingIsland, !foldEngaged, !islandExpanded else { return false }
        return !(activeCapsule?.kind.hasVerbs ?? false)
    }

    /// The readout while the drag runs, and its word when it lands: the
    /// level face's continuous fill toward three hours, the minutes in
    /// place of a percent. Never a scrub target — its key names no level.
    static func timerDragNotice(minutes: Int?, set: Bool) -> AlcoveNotice {
        let words = minutes.map(NotchTimerDrag.label)
        return AlcoveNotice(id: "timer-drag", kind: .level, title: "Timer",
                            subtitle: words.map { set ? "\($0) set" : $0 } ?? "Drag right",
                            key: "timer-drag", glyph: set ? "timer.circle.fill" : "timer",
                            fraction: NotchTimerDrag.fraction(minutes))
    }

    func timerDragChanged(travel: CGFloat) {
        guard timerDragAllowed else { return }
        presentFeedback(Self.timerDragNotice(minutes: NotchTimerDrag.minutes(forTravel: travel), set: false))
    }

    /// Let go: a drag that reached a minute starts that timer (the card's
    /// own timer model — the chip, the capsule and the strips follow); one
    /// that didn't puts the readout away.
    func timerDragEnded(travel: CGFloat) {
        guard let minutes = NotchTimerDrag.minutes(forTravel: travel) else {
            endOverlay(settle: true)
            return
        }
        cardModel.timers.add(label: "\(NotchTimerDrag.label(minutes)) timer",
                             duration: TimeInterval(minutes) * 60)
        presentFeedback(Self.timerDragNotice(minutes: minutes, set: true))
    }

    /// The swipe's fold of the grown card — and it is a dismissal, so
    /// a capsule shelved beneath it goes with it: collapsing alone
    /// would only replay the shelf as a fresh notice where the card
    /// just was.
    private func foldExpandedCard() {
        if capsuleQueue.current != nil || shelvedCapsule != nil {
            capsuleWork?.cancel()
            capsuleWork = nil
            capsuleQueue.cancel(at: capsuleClock())
            shelvedCapsule = nil
        }
        collapseIsland()
    }
}
