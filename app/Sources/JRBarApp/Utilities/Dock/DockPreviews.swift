import AppKit
import ApplicationServices
import JRBarCore
import ScreenCaptureKit

/// Esc and click-away for the dock's transient panels (the folder
/// grid, the window previews) — none of them can become key, so
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

/// One-shot `SCScreenshotManager` captures matched to preview rows by
/// title — shared by the enhance watcher and the bar's own swipe-up
/// previews. No stream, so no purple indicator; every step fails soft
/// to the icon + title rows (P5).
@MainActor
enum DockThumbnailer {
    /// Longest edge in points — a thumbnail never needs more.
    static let pointLimit: CGFloat = 480

    /// Fill `content.windows`' thumbnails for `pid`'s on-screen
    /// windows. `isStale` lets the caller bail mid-flight when the
    /// preview retargeted or hid while a capture was in flight.
    static func attach(to content: DockPreviewContent,
                       bundleID: String?, pid: pid_t,
                       isStale: @MainActor () -> Bool) async {
        guard let shareable = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return }
        guard !isStale() else { return }
        // Retina sharpness: `SCStreamConfiguration` sizes are PIXELS,
        // not points — multiply the point-space cap by the backing
        // scale or thumbnails stay 1×-soft on a Retina display.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let scWindows = shareable.windows.filter {
            ($0.owningApplication?.bundleIdentifier == bundleID && bundleID != nil)
                || $0.owningApplication?.processID == pid
        }
        for scWindow in scWindows {
            guard !isStale(),
                  let title = scWindow.title, !title.isEmpty,
                  let index = content.windows.firstIndex(where: { $0.title == title }),
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
            guard !isStale() else { return }
            content.windows[index].thumbnail = NSImage(cgImage: cgImage, size: .zero)
        }
    }
}

/// The bar's own window previews (P4/P5): the swipe-up-over-a-tile
/// gesture floats the same `DockPreviewPanel` the enhance watcher
/// uses, anchored to our tile instead of Apple's. A multi-window
/// app's windows group into the panel's one row; Esc or a click
/// anywhere outside closes it.
@MainActor
final class DockItemPreviewer {
    /// What the panel renders — public so tests can inspect the fill.
    let content = DockPreviewContent()
    private var panel: DockPreviewPanel?
    private var generation = 0
    private let watchers = DockPanelWatchers()

    /// `DockSettings.enhance.showThumbnails` — the one knob gates
    /// both preview surfaces. Wired by the panel from the settings.
    var thumbnailsEnabled: @MainActor () -> Bool = { true }
    /// Screen Recording preflight — injectable for tests.
    var screenCaptureGranted: @MainActor () -> Bool = {
        CGPreflightScreenCaptureAccess()
    }
    /// The AX window listing — injectable; empty without
    /// Accessibility, and the panel still shows the app card.
    var windows: @MainActor (pid_t) -> [DockPreviewWindow] =
        { AppleDockReader.windows(pid: $0) }
    /// A window row's raise — `AppleDockReader.raise` live.
    var raise: @MainActor (DockPreviewWindow, NSRunningApplication?) -> Void =
        { AppleDockReader.raise($0, app: $1) }
    /// The header's "Open" for an app that isn't running.
    var openApp: @MainActor (URL) -> Void = { url in
        NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    init() {
        watchers.onEscape = { [weak self] in self?.hide() }
        watchers.onOutside = { [weak self] in self?.hide() }
        watchers.isInside = { [weak self] in
            guard let self, let panel, panel.isVisible else { return true }
            return panel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        }
    }

    /// Whether the pointer rests on the preview panel — the bar's
    /// auto-hide poll treats it as part of the bar, so the panel
    /// doesn't vanish out from under its own popover.
    func pointerInside(_ location: NSPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -4, dy: -4).contains(location)
    }

    /// Fill the content from a dock item — the app's name/icon, and
    /// its AX windows grouped as the panel's rows. Internal, not
    /// private, so the tests can pin the grouping.
    func fill(item: DockItem) {
        let app = item.processIdentifier
            .flatMap { NSRunningApplication(processIdentifier: $0) }
        content.appName = item.name
        content.bundleID = item.bundleID
        content.appURL = item.bundleURL
        content.processIdentifier = item.processIdentifier
        content.isRunning = app.map { !$0.isTerminated } ?? item.isRunning
        content.icon = app?.icon ?? item.bundleURL.map {
            DockIconResolver.icon(appURL: $0, pointSize: 64, scale: 2)
        }
        content.windows = item.processIdentifier.map { windows($0) } ?? []
    }

    /// Show the previews for `item`, anchored to its tile's screen
    /// frame on `edge` of `screen`.
    func show(item: DockItem, anchor: CGRect, edge: DockEdge,
              screen: NSScreen, gap: CGFloat) {
        generation += 1
        let generationAtShow = generation
        fill(item: item)
        let panel = ensurePanel()
        panel.present(frame: DockEnhanceMath.panelFrame(
            anchor: anchor, edge: edge, size: panel.fittingSize(),
            screen: screen.frame, gap: gap), dockedAt: edge)
        watchers.start(escape: true, clickAway: true)
        guard thumbnailsEnabled(), screenCaptureGranted(),
              let pid = content.processIdentifier else { return }
        let bundleID = content.bundleID
        Task { @MainActor [weak self] in
            guard let self else { return }
            await DockThumbnailer.attach(
                to: content, bundleID: bundleID, pid: pid,
                isStale: { [weak self] in
                    (self?.generation ?? .min) != generationAtShow
                })
        }
    }

    /// Instant — a leave means leave.
    func hide() {
        generation += 1
        watchers.stop()
        panel?.dismiss()
    }

    private func ensurePanel() -> DockPreviewPanel {
        if let panel { return panel }
        let panel = DockPreviewPanel(content: content)
        panel.actions.onPick = { [weak self] window in
            guard let self else { return }
            let app = content.processIdentifier
                .flatMap { NSRunningApplication(processIdentifier: $0) }
            raise(window, app)
            hide()
        }
        panel.actions.onOpenApp = { [weak self] in
            guard let self else { return }
            if let url = content.appURL { openApp(url) }
            hide()
        }
        self.panel = panel
        return panel
    }
}
