import AppKit
import ApplicationServices
import JRBarCore
import ScreenCaptureKit

/// Esc and click-away for the preview panel — it can't become key, so
/// watchers listen instead: local monitors cover our own windows,
/// global ones every other app. Secure input can starve the global
/// key monitor; the local one still covers clicks and keys aimed at
/// our panels.
@MainActor
final class DockPanelWatchers {
    var onEscape: (@MainActor () -> Void)?
    var onOutside: (@MainActor () -> Void)?
    /// The click-away hit test — the caller reads the panel's live
    /// frame so a mid-animation frame can't misjudge a click.
    var isInside: (@MainActor () -> Bool) = { false }

    private var monitors: [Any] = []

    func start(escape: Bool = true, clickAway: Bool = false) {
        stop()
        if escape {
            if let monitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown,
                handler: { [weak self] event in
                    if event.keyCode == 53 {
                        MainActor.assumeIsolated { self?.onEscape?() }
                    }
                    return event
                }) { monitors.append(monitor) }
            if let monitor = NSEvent.addGlobalMonitorForEvents(
                matching: .keyDown,
                handler: { [weak self] event in
                    if event.keyCode == 53 {
                        MainActor.assumeIsolated { self?.onEscape?() }
                    }
                }) { monitors.append(monitor) }
        }
        if clickAway {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            if let monitor = NSEvent.addLocalMonitorForEvents(
                matching: mask,
                handler: { [weak self] event in
                    MainActor.assumeIsolated {
                        if self?.isInside() == false { self?.onOutside?() }
                    }
                    return event
                }) { monitors.append(monitor) }
            if let monitor = NSEvent.addGlobalMonitorForEvents(
                matching: mask,
                handler: { [weak self] _ in
                    MainActor.assumeIsolated {
                        if self?.isInside() == false { self?.onOutside?() }
                    }
                }) { monitors.append(monitor) }
        }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
    }

    isolated deinit { stop() }
}

/// One-shot `SCScreenshotManager` captures matched to preview cards by
/// frame (title as the fallback). No stream, so no purple indicator;
/// every step fails soft to the icon + title card.
@MainActor
enum DockThumbnailer {
    /// Longest edge in points — a thumbnail never needs more.
    nonisolated static let pointLimit: CGFloat = 480
    /// Windows narrower or shorter than this are helper surfaces
    /// (tooltips, status windows), not something to preview.
    nonisolated static let minimumWindowEdge: CGFloat = 48

    /// The shareable windows worth a card for `pid`: normal-layer,
    /// big enough to be a window, owned by the app.
    nonisolated static func candidates(_ windows: [SCWindow], bundleID: String?,
                                       pid: pid_t) -> [SCWindow] {
        windows.filter { window in
            let mine = (bundleID != nil && window.owningApplication?.bundleIdentifier == bundleID)
                || window.owningApplication?.processID == pid
            return mine && window.windowLayer == 0
                && window.frame.width >= minimumWindowEdge
                && window.frame.height >= minimumWindowEdge
        }
    }

    /// Fill `content.windows`' thumbnails for `pid`'s windows.
    /// `includeOffscreen` also captures windows on other Spaces and
    /// minimized ones — the window server still holds their pixels.
    /// `isStale` lets the caller bail mid-flight when the preview
    /// retargeted or hid while a capture was in flight.
    static func attach(to content: DockPreviewContent,
                       bundleID: String?, pid: pid_t,
                       includeOffscreen: Bool,
                       isStale: @MainActor () -> Bool) async {
        guard let shareable = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: !includeOffscreen) else { return }
        guard !isStale() else { return }
        // Retina sharpness: `SCStreamConfiguration` sizes are PIXELS,
        // not points — multiply the point-space cap by the backing
        // scale or thumbnails stay 1×-soft on a Retina display.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for scWindow in candidates(shareable.windows, bundleID: bundleID, pid: pid) {
            guard !isStale() else { return }
            let rows = content.windows.map { (frame: $0.frame, title: $0.title) }
            guard let index = DockEnhanceMath.matchRow(
                scFrame: scWindow.frame, scTitle: scWindow.title, rows: rows),
                  content.windows[index].thumbnail == nil else { continue }
            let configuration = SCStreamConfiguration()
            let bounds = scWindow.frame
            let factor = min(1, Self.pointLimit / max(bounds.width, bounds.height, 1)) * scale
            configuration.width = max(1, Int(bounds.width * factor))
            configuration.height = max(1, Int(bounds.height * factor))
            configuration.scalesToFit = true
            configuration.showsCursor = false
            guard let cgImage = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
                configuration: configuration) else { continue }
            guard !isStale(), index < content.windows.count else { return }
            content.windows[index].thumbnail = NSImage(
                cgImage: cgImage,
                size: NSSize(width: CGFloat(cgImage.width) / scale,
                             height: CGFloat(cgImage.height) / scale))
        }
    }
}
