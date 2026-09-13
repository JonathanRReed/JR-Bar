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
        // Borderless panels draw no title; setting one names the window in
        // the accessibility tree instead of leaving it "window".
        title = "JR-Bar Screen Bar"
        // Set last: `isFloatingPanel` and friends rewrite the level. One above
        // NSStatusWindowLevel so the band rides over the Python Screen Bar
        // while both are alive during the migration.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `screen_bar_show_in_full_screen` (default on, matching how the
    /// panel is created): `.fullScreenAuxiliary` keeps the band over
    /// full-screen spaces and videos; off, it stays on ordinary ones.
    var showsInFullScreen = true {
        didSet {
            if showsInFullScreen {
                collectionBehavior.insert(.fullScreenAuxiliary)
            } else {
                collectionBehavior.remove(.fullScreenAuxiliary)
            }
        }
    }

    /// AppKit keeps ordinary windows below the menu bar; this one lives in it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
