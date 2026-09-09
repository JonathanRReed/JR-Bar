import AppKit

/// The borderless, click-through panel that carries the Screen Bar.
@MainActor
final class ScreenBarPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        // Set last: `isFloatingPanel` and friends rewrite the level. One above
        // NSStatusWindowLevel so the band rides over the Python Screen Bar
        // while both are alive during the migration.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit keeps ordinary windows below the menu bar; this one lives in it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
