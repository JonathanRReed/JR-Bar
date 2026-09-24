import AppKit
import JRBarCore
import Observation
import SwiftUI

/// The feedback overlay: the Mac's own announcements and the level
/// scrub, said by the island while it is ours and up.
extension NotchToy {
    // MARK: Feedback overlay

    /// The Mac's own announcements (`NotchHUD`): the level keys, Caps
    /// Lock, Focus, devices, displays and the app's toasts. True when
    /// the island will say it — ours, shown, not grown, not under Fold,
    /// and the line open to it — so the HUD's glass pill stays down and
    /// nothing is said twice. Key feedback overlays at once; news joins
    /// the capsule line. False sends it to the pill: "SidePulse
    /// disconnected" must never vanish between the two.
    @discardableResult
    func presentSystemNotice(_ notice: AlcoveNotice) -> Bool {
        let s = settings
        guard s.enabled, s.provider == .jrbar, s.islandEnabled, islandVisible,
              !islandExpanded, !foldEngaged else { return false }
        if notice.kind.isFeedback { return presentFeedback(notice) }
        // A latched ask holds the line for as long as it is open: news
        // offered behind it would wait there and go stale unsaid. The
        // pill speaks now instead, the same as for key feedback.
        guard capsuleQueue.acceptsOverlay else { return false }
        return offer(Self.focusPolicyNotice(notice,
                                            holding: s.holdNewsWhileQuiet && s.capsuleNotifications))
    }

    /// Draw key feedback over the island for its beat. A latched ask
    /// refuses it (`acceptsOverlay`) — its buttons are why the island
    /// is open — and the caller falls back to the pill.
    @discardableResult
    func presentFeedback(_ notice: AlcoveNotice) -> Bool {
        guard islandVisible, !islandExpanded, capsuleQueue.present(notice) else { return false }
        let wasUp = activeOverlay != nil
        activeOverlay = notice
        overlayWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endOverlay(settle: true) }
        }
        overlayWork = work
        // A level holds for the person's HUD duration; Caps Lock keeps
        // the system's own beat.
        let life = notice.kind == .level
            ? settings.hudDuration
            : (notice.kind.life ?? AlcoveCapsuleQueue.feedbackLife)
        DispatchQueue.main.asyncAfter(deadline: .now() + life, execute: work)
        // A held key updates the fill in place — the face is already
        // the notice, so only a first press morphs.
        if !wasUp {
            reframe(currentFace, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        return true
    }

    /// A scroll over the level capsule: while a volume or brightness
    /// level is up it is a slider — the fill follows the fingers, the
    /// Mac's level follows the fill, and the capsule holds for another
    /// beat. False when no settable level is up, so the scroll stays a
    /// swipe.
    func scrubLevel(fingerDelta: CGFloat, precise: Bool) -> Bool {
        guard let shown = activeOverlay, shown.kind == .level,
              let target = NotchLevelScrub.target(ofKey: shown.key),
              NotchLevelScrub.settable(target) else { return false }
        let before = shown.fraction ?? 0
        let next = NotchLevelScrub.step(before, fingerDelta: fingerDelta, precise: precise)
        guard next != before else {
            _ = presentFeedback(shown)   // pressed at the stop: hold the beat
            return true
        }
        guard levelWriter(target, Float(next)) else { return true }
        var moved = shown
        moved.fraction = next
        if target == .volume {
            moved.muted = shown.muted && next <= 0
            // The device the sound goes to, read again as the key does;
            // a headless toy (the tests) draws the plain speaker.
            let route = runtimeEnabled ? SystemLevelReader.outputRoute() : nil
            moved.glyph = NotchLevelGlyph.volume(level: Float(next), muted: moved.muted,
                                                 transport: route?.transport, name: route?.name)
        } else {
            moved.glyph = NotchLevelGlyph.brightness(level: Float(next))
        }
        _ = presentFeedback(moved)
        return true
    }

    /// The feedback's beat ended: the face under it shows again — the
    /// capsule it covered, or whatever the cursor wants.
    func endOverlay(settle: Bool) {
        overlayWork?.cancel()
        overlayWork = nil
        guard activeOverlay != nil else { return }
        activeOverlay = nil
        capsuleQueue.endOverlay()
        guard settle else { return }
        if activeCapsule == nil {
            settleToRest()
        } else {
            reframeCurrent(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    /// The gap between two capsules: nothing drawn yet, `current` already
    /// picked — this is the timer that draws it.
    func scheduleCapsuleShow(after delay: TimeInterval) {
        capsuleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showCurrentCapsule() }
        }
        capsuleWork = work
        capsuleTimer(delay, work)
    }

    /// The shown capsule's life ended: the queue promotes whatever was
    /// waiting (after the minimum gap), or the island settles back to
    /// whatever the cursor currently wants — idle, or the card a
    /// mid-capsule hover earned.
    /// Internal so tests can end a capsule's run without sleeping out
    /// its whole life.
    func finishCapsule() {
        // The firing work item cancels itself cleanly; a direct call
        // (tests, dismiss paths) must not leave the life timer armed.
        capsuleWork?.cancel()
        capsuleWork = nil
        switch capsuleQueue.finish(at: capsuleClock()) {
        case .idle:
            activeCapsule = nil
            settleToRest()
        case .now:
            activeCapsule = nil
            showCurrentCapsule()
        case .after(let delay, _):
            activeCapsule = nil
            settleToRest()
            // The settle may have grown the card — `expand` shelved the
            // promoted capsule (it stays `current`; the shelf IS the
            // queue's slot) — so the gap timer only arms when the
            // island settled to rest with a capsule still waiting to
            // be drawn. Firing it under the card would just land in
            // `showCurrentCapsule`'s early return.
            if !islandExpanded, capsuleQueue.current != nil {
                scheduleCapsuleShow(after: delay)
            }
        }
    }

    /// A swipe down on the island. "Stop" rather than "next": the shown
    /// capsule AND anything waiting behind it are dropped. The swipe is
    /// a dismissal — the held cursor must not pop the card right back
    /// open where the capsule was.
    func dismissCapsule() {
        if activeOverlay != nil, activeCapsule == nil, capsuleQueue.current == nil {
            endOverlay(settle: true)
            return
        }
        guard activeCapsule != nil || capsuleQueue.current != nil else { return }
        endOverlay(settle: false)
        capsuleWork?.cancel()
        capsuleWork = nil
        capsuleQueue.cancel(at: capsuleClock())
        activeCapsule = nil
        shelvedCapsule = nil
        hoverHeld = false
        peekWork?.cancel()
        peekWork = nil
        islandHoverPeek = false
        // A dismissal eats a remembered band click too — the swipe is
        // "go away", so the card must not pop open off the back of it.
        bandExpandPending = false
        settleToRest()
    }

    /// Back to the face the cursor wants: a remembered band click grows
    /// the card, a remembered hover grows it too, or nothing — the
    /// capsule just stepped down. The grow runs INSTEAD of the idle
    /// reframe, not after it: easing to idle and then straight back out
    /// reads as the island dipping under the capsule's feet.
    private func settleToRest() {
        if bandExpandPending {
            bandExpandPending = false
            expand(held: true)
            return
        }
        // The face that just stepped down is wider than idle — the
        // notice carries a line of copy. A cursor over its shoulder is
        // already outside the resting capsule, and the tracking-area
        // exit lands a tick after this pass. Re-check the real pointer
        // against the resting frame before trusting the remembered
        // hover: the card must never grow out from under a cursor that
        // already left.
        if hoverHeld, let resting = islandFrame(face: .idle),
           !resting.contains(NSEvent.mouseLocation) {
            hoverHeld = false
        }
        islandHoverPeek = hoverHeld
        if hoverHeld { applyHover() }
        reframeCurrent(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}
