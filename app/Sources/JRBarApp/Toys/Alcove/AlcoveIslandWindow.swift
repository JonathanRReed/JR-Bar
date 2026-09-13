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
/// The island's hosting view with a click gate: while Fold's overlay is
/// up the island is invisible under it, so clicks must fall through to
/// the (itself click-through) fold rather than die on unseen glass.
private final class AlcoveIslandHostingView: NSHostingView<AlcoveIslandView> {
    var acceptsClicks: () -> Bool = { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsClicks() ? super.hitTest(point) : nil
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
