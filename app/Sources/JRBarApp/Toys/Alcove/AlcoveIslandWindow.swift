import AppKit
import QuartzCore
import SwiftUI

/// The island's panel: a borderless, non-activating panel pinned to the
/// screen's top edge over the notch, one level above the menu bar —
/// `NotchHUD`'s level, high enough to own the notch, short of pop-ups
/// and the Fold overlay's screen-saver tier. `sharingType = .none`
/// keeps it out of Fold's desktop capture so a warped screen never
/// shows the island twice.
///
/// Unlike `FoldOverlayWindow` it takes mouse events — hover is what
/// grows the capsule — so its frame is always exactly the drawn shape:
/// the island never parks invisible glass over the menu bar. Grow and
/// shrink only ever move the bottom edge; the top stays pinned.
/// A two-finger swipe on the island, in finger-travel direction —
/// `.left` is a swipe toward the left. Read off trackpad scroll events.
enum AlcoveIslandSwipe { case left, right, down }

/// The island's hosting view with a click gate and a swipe reader:
/// while Fold's overlay is up the island is invisible under it, so
/// clicks must fall through to the (itself click-through) fold rather
/// than die on unseen glass. `scrollWheel` turns precise trackpad
/// deltas into one swipe per gesture — Alcove's signature move: a
/// horizontal flick for the transport, a downward flick for dismiss.
/// A mouse wheel has no phase and no precise deltas, so it never reads
/// as a swipe; and a swipe only ever fires once per gesture, so it can
/// never fight the hover that is also live.
private final class AlcoveIslandHostingView: NSHostingView<AlcoveIslandView> {
    var acceptsClicks: () -> Bool = { true }
    var onSwipe: (AlcoveIslandSwipe) -> Void = { _ in }

    /// Travel this many points before the gesture commits — small
    /// scrolls and scroll-jitter stay scrolls.
    private static let horizontalThreshold: CGFloat = 48
    private static let verticalThreshold: CGFloat = 40

    private var gestureX: CGFloat = 0
    private var gestureY: CGFloat = 0
    private var gestureLive = false
    private var gestureFired = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsClicks() ? super.hitTest(point) : nil
    }

    override func scrollWheel(with event: NSEvent) {
        // Only a trackpad gesture carries phases; momentum events arrive
        // with `phase` empty and are ignored with everything else.
        guard event.hasPreciseScrollingDeltas, event.phase != [] else { return }
        if event.phase.contains(.began) {
            gestureLive = true
            gestureFired = false
            gestureX = 0
            gestureY = 0
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            gestureLive = false
            gestureX = 0
            gestureY = 0
            return
        }
        guard gestureLive, !gestureFired else { return }
        // Normalise to finger direction: with "natural" scrolling the
        // delta already follows the fingers (`isDirectionInvertedFrom-
        // Device`), with legacy scrolling it is the wheel's opposite.
        let inverted = event.isDirectionInvertedFromDevice
        gestureX += inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
        gestureY += inverted ? event.scrollingDeltaY : -event.scrollingDeltaY
        if abs(gestureX) >= Self.horizontalThreshold, abs(gestureX) > abs(gestureY) {
            gestureFired = true
            // Fingers left = next track, fingers right = previous.
            onSwipe(gestureX < 0 ? .left : .right)
        } else if gestureY <= -Self.verticalThreshold, abs(gestureY) > abs(gestureX) {
            gestureFired = true
            onSwipe(.down)
        }
    }
}

@MainActor
final class AlcoveIslandWindow: NSPanel {
    private let hosting: AlcoveIslandHostingView

    init(toy: AlcoveToy) {
        hosting = AlcoveIslandHostingView(rootView: AlcoveIslandView(toy: toy))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 140, height: 30),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = hosting
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        sharingType = .none
        hosting.acceptsClicks = { [weak toy] in !(toy?.foldEngaged ?? false) }
        hosting.onSwipe = { [weak toy] swipe in toy?.islandSwipe(swipe) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// A resize that keeps the top edge pinned: the caller hands a frame
    /// that already hangs from the screen's top, so the ease is only the
    /// bottom edge travelling. Snaps under Reduce Motion.
    func applyFrame(_ frame: NSRect, animated: Bool) {
        if animated, isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
                animator().setFrame(frame, display: true)
            }
        } else {
            setFrame(frame, display: true)
        }
    }
}
