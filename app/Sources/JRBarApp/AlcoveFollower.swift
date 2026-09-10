import AppKit
import ApplicationServices
import JRBarCore

/// Keeps the Screen Bar on Alcove's capsule (`screen_bar_follow_alcove`).
///
/// Nothing is captured: the window list's bounds for Alcove's top-hugging
/// window are the capsule (`AlcoveGeometry.select`). Alcove 1.7.9 draws the
/// capsule inside one fixed 624×320 window instead, so when the top window
/// is such a container and this process already has accessibility access
/// (never asked for here), the capsule is estimated from the controls Alcove
/// lays out inside it (`AlcoveGeometry.capsule(fromContentFrames:)`). The
/// list is read at 2 Hz, and only while Alcove is running; with Alcove gone,
/// or the setting off, the poll stops and the band goes back to the notch.
@MainActor
final class AlcoveFollower {
    static let pollInterval: TimeInterval = 0.5

    /// Called on the main actor whenever the capsule changes (nil: stop following).
    var onChange: (@MainActor (AlcoveCapsule?) -> Void)?
    private(set) var capsule: AlcoveCapsule?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// The setting, and whether the bar is shown at all.
    var enabled = false {
        didSet { if enabled != oldValue { reconcile() } }
    }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == AlcoveGeometry.bundleIdentifier else { return }
                MainActor.assumeIsolated { self?.reconcile() }
            })
        }
    }

    var isAlcoveRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == AlcoveGeometry.bundleIdentifier }
    }

    var isPolling: Bool { timer != nil }

    /// "following the capsule (212 pt)", "Alcove not running", "off", for the status menu.
    var statusDescription: String {
        guard enabled else { return "off" }
        guard isAlcoveRunning else { return "Alcove not running" }
        if let capsule { return "following the capsule (\(Int(capsule.width.rounded())) pt, \(source))" }
        return "Alcove running, \(source)"
    }

    private func reconcile() {
        if enabled, isAlcoveRunning {
            if timer == nil {
                let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.poll() }
                }
                timer.tolerance = 0.1
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
            poll()
        } else {
            timer?.invalidate()
            timer = nil
            update(nil)
        }
    }

    /// How the last capsule was found, for the status menu.
    private(set) var source = "none"

    func poll() {
        guard let screen = ScreenBarGeometry.preferredScreen() else { update(nil); return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.maxY
        let rows = Self.windowRows()
        if let capsule = AlcoveGeometry.select(rows: rows, screenFrame: screen.frame, primaryHeight: primaryHeight) {
            source = "window bounds"
            update(capsule)
            return
        }
        if let container = AlcoveGeometry.containerWindow(rows: rows, screenFrame: screen.frame, primaryHeight: primaryHeight) {
            if AXIsProcessTrusted() {
                let frames = Self.accessibilityContentFrames(pid: pid_t(container.ownerPID), window: container.bounds)
                source = "accessibility"
                update(AlcoveGeometry.capsule(fromContentFrames: frames, container: container.bounds, screenFrame: screen.frame, primaryHeight: primaryHeight))
                return
            }
            source = "container window, no accessibility access"
        } else {
            source = "no capsule window"
        }
        update(nil)
    }

    /// The frames of everything Alcove lays out in `window` (a few levels
    /// deep, a bounded number of elements), in window-list coordinates.
    static func accessibilityContentFrames(pid: pid_t, window: CGRect) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return [] }
        func frame(of element: AXUIElement) -> CGRect? {
            var positionValue: AnyObject?
            var sizeValue: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
                  let position = positionValue, let size = sizeValue,
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            // swiftlint:disable force_cast
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
            // swiftlint:enable force_cast
            return CGRect(origin: point, size: dimensions)
        }
        var frames: [CGRect] = []
        var budget = 96
        func walk(_ element: AXUIElement, depth: Int) {
            guard budget > 0, depth < 6 else { return }
            budget -= 1
            if let rect = frame(of: element) { frames.append(rect) }
            var childrenValue: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else { return }
            for child in children { walk(child, depth: depth + 1) }
        }
        for candidate in windows {
            guard let rect = frame(of: candidate), abs(rect.minX - window.minX) < 2, abs(rect.minY - window.minY) < 2,
                  abs(rect.width - window.width) < 2 else { continue }
            walk(candidate, depth: 0)
        }
        return frames
    }

    private func update(_ new: AlcoveCapsule?) {
        guard new != capsule else { return }
        capsule = new
        onChange?(new)
    }

    /// Alcove's on-screen windows as plain rows. Bounds only: no capture,
    /// no Screen Recording permission involved.
    static func windowRows() -> [AlcoveWindowRow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var rows: [AlcoveWindowRow] = []
        for entry in info {
            guard let owner = entry[kCGWindowOwnerName as String] as? String, owner == AlcoveGeometry.ownerName,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            rows.append(AlcoveWindowRow(
                ownerName: owner,
                ownerPID: entry[kCGWindowOwnerPID as String] as? Int ?? 0,
                number: entry[kCGWindowNumber as String] as? Int ?? 0,
                layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
                bounds: bounds
            ))
        }
        return rows
    }
}
