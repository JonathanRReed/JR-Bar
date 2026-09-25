import AppKit
import ApplicationServices
import CoreGraphics

/// The other apps' windows on screen right now, front to back — read from
/// the window list's bounds and layer, which need no permission (only
/// titles do). One read for every toy that cares where windows are: the
/// buddy strolls along their top edges, the confetti skips a screen a
/// fullscreen app owns and lands its pieces on window tops. JR-Bar's own
/// panels are left out, and so is anything invisible or off the normal
/// window level (menus, the Dock, overlays).
enum OnScreenWindows {
    /// The frames in the window list's own space: top-left origin at the
    /// primary display's top edge, y growing down.
    @MainActor
    static func quartzFrames() -> [CGRect] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        return frames(in: info, ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// The same frames in AppKit's space (bottom-left origin), where
    /// `NSScreen.frame` lives.
    @MainActor
    static func frames() -> [CGRect] {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return quartzFrames().map { appKit($0, primaryHeight: primaryHeight) }
    }

    /// The filter, pure: normal-level windows of other processes that
    /// can be seen, in list order (front to back).
    static func frames(in info: [[String: Any]], ownPID: Int32) -> [CGRect] {
        info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return rect
        }
    }

    /// A window-list rect in AppKit's space. The flip is its own
    /// inverse, so the same call takes a screen frame the other way.
    static func appKit(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Where the Dock's row of tiles is, in the window list's space, read
    /// from its accessibility list: the window list only knows the Dock
    /// as one screen-sized window. nil without Accessibility permission,
    /// or when the Dock doesn't answer within a quarter of a second.
    @MainActor
    static func dockBar() -> CGRect? {
        guard AXIsProcessTrusted(), let pid = AppleDockReader.dockPID(),
              let list = AppleDockReader.dockList(pid: pid) else { return nil }
        AXUIElementSetMessagingTimeout(list, 0.25)
        return AppleDockReader.frame(of: list)
    }

    /// `rect` (window-list space) measured from the top-left corner of
    /// `screen` (AppKit space) — the space a full-screen overlay on that
    /// screen draws in.
    static func local(_ rect: CGRect, on screen: CGRect, primaryHeight: CGFloat) -> CGRect {
        let top = primaryHeight - screen.maxY
        return CGRect(x: rect.minX - screen.minX, y: rect.minY - top,
                      width: rect.width, height: rect.height)
    }
}
