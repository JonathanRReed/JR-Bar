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
    /// Non-Esc keys while the pointer is over the panel — arrows walk
    /// the window cards, Return raises. Return true when consumed.
    var onKey: (@MainActor (UInt16) -> Bool)?
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
                    MainActor.assumeIsolated {
                        if event.keyCode == 53 { self?.onEscape?() }
                        else if self?.isInside() == true { _ = self?.onKey?(event.keyCode) }
                    }
                    return event
                }) { monitors.append(monitor) }
            if let monitor = NSEvent.addGlobalMonitorForEvents(
                matching: .keyDown,
                handler: { [weak self] event in
                    MainActor.assumeIsolated {
                        if event.keyCode == 53 { self?.onEscape?() }
                        else if self?.isInside() == true { _ = self?.onKey?(event.keyCode) }
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

/// Keeps an open preview's card list live: an `AXObserver` on the
/// previewed app for new windows, and on each listed window for its
/// close, retitle, minimize and restore. Bursts coalesce into one
/// `onChange` a beat later (a new window posts created, titled and
/// focused in a row). DockDoor 1.40's live list — the cards follow the
/// app instead of only our own verbs.
@MainActor
final class DockWindowObserver {
    var onChange: (@MainActor () -> Void)?
    /// A burst's settle time before one refresh runs.
    static let debounce: TimeInterval = 0.15

    private var observer: AXObserver?
    private(set) var pid: pid_t?
    private var watched = Set<AXUIElement>()
    private var pending: DispatchWorkItem?

    static let appNotifications = [kAXWindowCreatedNotification]
    static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ]

    /// Watch `pid`'s window list and each of `windows`. Replaces any
    /// earlier watch; fails soft (no watch) without Accessibility.
    func observe(pid: pid_t, windows: [AXUIElement]) {
        stop()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<DockWindowObserver>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.fire() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        observer = created
        self.pid = pid
        let app = AXUIElementCreateApplication(pid)
        for name in Self.appNotifications {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        watch(windows)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    /// Start watching windows that arrived since `observe` — a window
    /// that just opened must report its own close too.
    func watch(_ windows: [AXUIElement]) {
        guard let observer else { return }
        for window in windows where watched.insert(window).inserted {
            for name in Self.windowNotifications {
                AXObserverAddNotification(observer, window, name as CFString, refcon)
            }
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        pid = nil
        watched = []
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private func fire() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
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
    /// Captures kept per window for `captureLifetime`: every capture
    /// makes macOS flash its recording indicator beside the clock (and
    /// shift the menu bar under it), so a window hovered twice in half
    /// a minute shows the same still. DockDoor's answer to the same
    /// complaint, at the same lifetime.
    /// Keyed by owner pid + window id: a bare CGWindowID can be
    /// recycled by the window server after a window dies, and a stale
    /// entry under a recycled id once served another app's pixels.
    @MainActor private static var captureCache: [String: (image: NSImage, at: Date)] = [:]
    nonisolated static let captureLifetime: TimeInterval = 30

    /// Downsamples the capture to 8×8 and sums the alpha channel —
    /// a purged backing store yields a `CGImage` of nothing.
    nonisolated static func fullyTransparent(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let drawn = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let context = CGContext(data: ptr.baseAddress, width: 8, height: 8,
                                          bitsPerComponent: 8, bytesPerRow: 32,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            return true
        }
        guard drawn else { return false }
        return stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + Int(pixels[$1]) } < 8
    }

    /// Crops the transparent margins a capture can carry — a purged
    /// sub-region or the window's shadow inset leaves the real content
    /// drifting off-centre inside the frame. The probe is the same
    /// 32×32 downsample as `fullyTransparent`: columns and rows that
    /// hold no alpha are not content. A degenerate crop keeps the
    /// original; one cell of margin keeps soft edges unclipped.
    nonisolated static func trimmed(_ image: CGImage) -> CGImage {
        let probe = 32
        var pixels = [UInt8](repeating: 0, count: probe * probe * 4)
        let drawn = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let context = CGContext(data: ptr.baseAddress, width: probe, height: probe,
                                          bitsPerComponent: 8, bytesPerRow: probe * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: probe, height: probe))
            return true
        }
        guard drawn else { return image }
        func opaque(_ x: Int, _ y: Int) -> Bool {
            // A shadow or a half-purged margin still carries some alpha —
            // at 16 it kept the dead band at the top of the card, and the
            // averaged probe reads a real edge well past 64 while a soft
            // shadow cell stays under it.
            pixels[(y * probe + x) * 4 + 3] > 64
        }
        var minX = probe, maxX = -1, minY = probe, maxY = -1
        for y in 0..<probe { for x in 0..<probe where opaque(x, y) {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX, maxY >= minY else { return image }
        minX = max(0, minX - 1); maxX = min(probe - 1, maxX + 1)
        minY = max(0, minY - 1); maxY = min(probe - 1, maxY + 1)
        let unitW = CGFloat(image.width) / CGFloat(probe)
        let unitH = CGFloat(image.height) / CGFloat(probe)
        let rect = CGRect(x: CGFloat(minX) * unitW, y: CGFloat(minY) * unitH,
                          width: CGFloat(maxX - minX + 1) * unitW,
                          height: CGFloat(maxY - minY + 1) * unitH)
        guard rect.width >= unitW * 4, rect.height >= unitH * 4 else { return image }
        return image.cropping(to: rect) ?? image
    }

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
        let cands = candidates(shareable.windows, bundleID: bundleID, pid: pid)
        for scWindow in cands {
            guard !isStale() else { return }
            let rows = content.windows.map { (frame: $0.frame, title: $0.title) }
            guard let index = DockEnhanceMath.matchRow(
                scFrame: scWindow.frame, scTitle: scWindow.title, rows: rows,
                scWindowID: scWindow.windowID, rowWindowIDs: content.windows.map(\.windowID)),
                  content.windows[index].thumbnail == nil else { continue }
            // The row's identity, not its index: a card closed while
            // this capture was in flight would shift the rows under it.
            let rowID = content.windows[index].id
            guard let image = await capture(scWindow: scWindow, pid: pid, scale: scale) else { continue }
            // Re-check the preview still belongs to this app — a
            // same-generation refill (New window) rewrites the rows
            // without tripping `isStale`.
            guard !isStale(), content.processIdentifier == pid,
                  let row = content.windows.firstIndex(where: { $0.id == rowID }) else { continue }
            content.windows[row].thumbnail = image
        }
    }

    /// One window's still, sized to `pointLimit` at the screen's
    /// backing scale — the capture the previews and the ⌥⇥ switcher
    /// share, cached per window for `captureLifetime`. Purged backing
    /// stores come back as a fully transparent "success" and are
    /// refused: a dark window keeps alpha 255, so the probe reads the
    /// channel, not colour.
    static func capture(scWindow: SCWindow, pid: pid_t, scale: CGFloat) async -> NSImage? {
        let cacheKey = "\(pid):\(scWindow.windowID)"
        let now = Date()
        if let cached = captureCache[cacheKey],
           now.timeIntervalSince(cached.at) < captureLifetime { return cached.image }
        captureCache = captureCache.filter { now.timeIntervalSince($0.value.at) < captureLifetime }
        let configuration = SCStreamConfiguration()
        let bounds = scWindow.frame
        let factor = min(1, Self.pointLimit / max(bounds.width, bounds.height, 1)) * scale
        configuration.width = max(1, Int(bounds.width * factor))
        configuration.height = max(1, Int(bounds.height * factor))
        configuration.scalesToFit = true
        configuration.showsCursor = false
        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
            configuration: configuration) else { return nil }
        guard !Self.fullyTransparent(cgImage) else { return nil }
        let trimmed = Self.trimmed(cgImage)
        let image = NSImage(
            cgImage: trimmed,
            size: NSSize(width: CGFloat(trimmed.width) / scale,
                         height: CGFloat(trimmed.height) / scale))
        captureCache[cacheKey] = (image, Date())
        return image
    }
}
