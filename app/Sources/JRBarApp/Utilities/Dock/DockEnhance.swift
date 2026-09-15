import AppKit
import ApplicationServices
import JRBarCore
import Observation
import QuartzCore
import ScreenCaptureKit

// MARK: - Preferences

/// Enhance mode's knobs — a facade over `DockSettings.enhance`, which
/// lives in `app-state.json` like every other Dock knob. `DockUtility`
/// wires `read`/`write` to its settings closure and `update` path, so
/// a card edit persists through the store's debounce and re-applies.
///
/// Builds that predate the schema wrote two `UserDefaults` keys
/// instead; `DockUtility` folds them into the settings once (see
/// `migrateLegacyEnhanceDefaults`) and removes them.
@MainActor
final class DockEnhancePreferences {
    /// The live settings read — wired to `DockUtility.settings`.
    var read: @MainActor () -> DockEnhanceSettings = { DockEnhanceSettings() }
    /// The card's write path — wired to `DockUtility.update`.
    var write: (@MainActor (DockEnhanceSettings) -> Void)?

    /// Seconds the pointer must rest on a Dock icon before the preview
    /// opens — Apple's own ~250 ms hover feel.
    var previewDelay: Double {
        get { read().previewDelay }
        set { write?({ var s = read(); s.previewDelay = newValue; return s }()) }
    }
    /// Live window thumbnails via one-shot `SCScreenshotManager`
    /// captures; off falls back to icon + title rows and needs no
    /// Screen Recording permission.
    var showThumbnails: Bool {
        get { read().showThumbnails }
        set { write?({ var s = read(); s.showThumbnails = newValue; return s }()) }
    }

    static let delayRange: ClosedRange<Double> = DockEnhanceSettings.delayRange
    static let defaultDelay: Double = DockEnhanceSettings.defaultDelay
    /// The pre-schema `UserDefaults` keys, kept for the one-shot
    /// migration `DockUtility.migrateLegacyEnhanceDefaults` runs.
    static let legacyDelayKey = "JRBarDock.enhance.previewDelay"
    static let legacyThumbnailsKey = "JRBarDock.enhance.thumbnails"
}

// MARK: - Hover debounce (pure, tested)

/// The state machine behind hover previews: a dock item must hold the
/// pointer for `delay` before its panel opens; once open, the panel
/// survives quick trips across other icons and the gap onto the panel
/// itself, and only closes after the pointer has been off both the
/// dock and the panel for `grace`.
struct DockHoverTracker {
    enum Action: Equatable {
        case none
        /// The named item earned a panel (first show or a retarget).
        case show(String)
        /// Pointer is gone — close the panel.
        case hide
    }

    private(set) var hovered: String?
    private(set) var shown: String?
    private var hoveredSince: TimeInterval?
    private var emptySince: TimeInterval?

    /// The grace a stray reading gets before the panel closes — covers
    /// the gap between dock and panel and jitter across item edges.
    static let grace: TimeInterval = 0.22

    @discardableResult
    mutating func note(hovered item: String?, pointerInPanel: Bool,
                       now: TimeInterval, delay: TimeInterval) -> Action {
        if item != hovered {
            hovered = item
            hoveredSince = item == nil ? nil : now
        }
        if item == nil {
            if emptySince == nil { emptySince = now }
        } else {
            emptySince = nil
        }
        // A rested item opens — or retargets — the panel.
        if let item, shown != item, let since = hoveredSince, now - since >= delay {
            shown = item
            return .show(item)
        }
        // Off the dock, off the panel, past the grace — close.
        if shown != nil, item == nil, !pointerInPanel,
           let left = emptySince, now - left >= Self.grace {
            shown = nil
            return .hide
        }
        return .none
    }

    mutating func reset() {
        hovered = nil
        shown = nil
        hoveredSince = nil
        emptySince = nil
    }
}

// MARK: - Geometry (pure, tested)

/// The coordinate plumbing: AX reports frames in Quartz screen
/// coordinates (origin top-left of the primary display, y down);
/// `NSEvent.mouseLocation`, `NSScreen.frame` and `NSWindow.frame` are
/// AppKit (origin bottom-left, y up).
enum DockEnhanceMath {
    static func axPoint(_ appKitPoint: CGPoint, mainScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: appKitPoint.x, y: mainScreenHeight - appKitPoint.y)
    }

    static func appKitRect(_ axRect: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: axRect.minX, y: mainScreenHeight - axRect.maxY,
               width: axRect.width, height: axRect.height)
    }

    /// Which edge Apple's Dock hugs: the screen edge nearest the dock
    /// list's frame (AppKit coordinates).
    static func dockEdge(listFrame: CGRect, screen: CGRect) -> DockEdge {
        let candidates: [(DockEdge, CGFloat)] = [
            (.bottom, listFrame.minY - screen.minY),
            (.left, listFrame.minX - screen.minX),
            (.right, screen.maxX - listFrame.maxX),
        ]
        return candidates.min(by: { $0.1 < $1.1 })?.0 ?? .bottom
    }

    /// Where a preview panel of `size` opens for a hovered item: off
    /// the dock toward the screen's middle, centred on the item, and
    /// clamped inside the screen.
    static func panelFrame(anchor itemFrame: CGRect, edge: DockEdge, size: CGSize,
                           screen: CGRect, gap: CGFloat) -> CGRect {
        switch edge {
        case .bottom:
            let x = min(max(itemFrame.midX - size.width / 2, screen.minX + 8),
                        max(screen.minX + 8, screen.maxX - size.width - 8))
            return CGRect(x: x, y: itemFrame.maxY + gap,
                          width: size.width, height: size.height)
        case .left:
            let y = min(max(itemFrame.midY - size.height / 2, screen.minY + 8),
                        max(screen.minY + 8, screen.maxY - size.height - 8))
            return CGRect(x: itemFrame.maxX + gap, y: y,
                          width: size.width, height: size.height)
        case .right:
            let y = min(max(itemFrame.midY - size.height / 2, screen.minY + 8),
                        max(screen.minY + 8, screen.maxY - size.height - 8))
            return CGRect(x: itemFrame.minX - gap - size.width, y: y,
                          width: size.width, height: size.height)
        }
    }
}

// MARK: - The Dock's AX tree

/// One application item in Apple's Dock list — frame in AX coordinates.
struct DockAXItem {
    let element: AXUIElement
    let frame: CGRect
    let title: String?
    /// `AXURL` — the file URL the tile points at, when the Dock shares it.
    let url: URL?
    /// Stable hover identity: the title, else the URL, else a constant.
    var hoverID: String { title ?? url?.lastPathComponent ?? "dock-item" }
}

/// Read-only queries against the Dock process's accessibility tree.
/// Every call fails soft (nil / []) without Accessibility permission
/// — the caller's `AXIsProcessTrusted` gate decides whether that means
/// "no dock" or "no rights".
enum AppleDockReader {
    static let dockBundleID = "com.apple.dock"

    static func dockPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleID)
            .first?.processIdentifier
    }

    /// The dock's `AXList` element (subrole `AXDockList`).
    static func dockList(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        return axChildren(app).first { axString($0, kAXSubroleAttribute) == "AXDockList" }
    }

    /// The application tile under `point` (AX coordinates), or nil —
    /// spacers, folders, the Trash and minimized-window tiles are
    /// skipped: previews are an app feature.
    static func item(list: AXUIElement, at point: CGPoint) -> DockAXItem? {
        for child in axChildren(list) {
            guard axString(child, kAXSubroleAttribute) == "AXApplicationDockItem",
                  let frame = axFrame(child), frame.contains(point) else { continue }
            return DockAXItem(element: child, frame: frame,
                              title: axString(child, kAXTitleAttribute),
                              url: axURL(child))
        }
        return nil
    }

    static func frame(of element: AXUIElement) -> CGRect? { axFrame(element) }

    /// One app's windows as preview rows — AX gives both the title and
    /// the element a later click can `AXRaise`.
    static func windows(pid: pid_t) -> [DockPreviewWindow] {
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements.enumerated().map { index, element in
            DockPreviewWindow(
                id: index,
                title: axString(element, kAXTitleAttribute) ?? "Untitled window",
                minimized: axBool(element, kAXMinimizedAttribute),
                element: element)
        }
    }

    /// Click a preview row: un-minimize if needed, raise the window,
    /// make it main, and bring the app forward.
    static func raise(_ window: DockPreviewWindow, app: NSRunningApplication?) {
        if let element = window.element {
            if window.minimized {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                             false as CFTypeRef)
            }
            AXUIElementPerformAction(element, "AXRaise" as CFString)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, true as CFTypeRef)
        }
        app?.activate(options: [.activateAllWindows])
    }

    // MARK: Primitives

    static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    static func axBool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return false }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }

    static func axURL(_ element: AXUIElement) -> URL? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success
        else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    static func axFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        // AXValue wraps CGPoint/CGSize; the casts are the documented pattern.
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}

// MARK: - Preview content

/// One row in the preview panel: a title, an AX handle a click can
/// raise, and an optional thumbnail filled in asynchronously.
struct DockPreviewWindow: Identifiable {
    let id: Int
    var title: String
    var minimized: Bool
    var thumbnail: NSImage?
    /// The AX window element — the raise target. AX handles only ever
    /// touch the main actor here.
    let element: AXUIElement?
}

/// Everything the panel renders for one hovered dock icon — an
/// observable box so late-arriving thumbnails re-render the view.
@MainActor
@Observable
final class DockPreviewContent {
    var appName = ""
    var icon: NSImage?
    var bundleID: String?
    var appURL: URL?
    var processIdentifier: pid_t?
    var isRunning = false
    var windows: [DockPreviewWindow] = []
}

// MARK: - Controller

/// Enhance mode: Apple's Dock stays; we watch the pointer over it
/// through Accessibility and float a window-preview panel above a
/// rested icon (docs/TOY-PARITY.md: "Hover a Dock icon → live window
/// previews … AX to hit-test the Dock, SCScreenshotManager one-shots
/// per window, no stream so no purple indicator").
///
/// The watch is a 20 Hz timer, not an event tap: a poll reads the
/// pointer, hit-tests the Dock list (one AX call while the pointer is
/// off the dock; per-item frames only while it's inside), and feeds
/// `DockHoverTracker`. No Accessibility, no Dock, no hover — all fold
/// into "nothing shown".
@MainActor
@Observable
final class DockEnhanceController {
    let preferences: DockEnhancePreferences
    /// What the panel shows right now — the view binds to it.
    let preview = DockPreviewContent()

    private(set) var running = false
    /// Re-polled every tick and by the card's appear, so the chip and
    /// the permission row can never sit stale.
    private(set) var accessibilityTrusted = AXIsProcessTrusted()
    private(set) var screenCaptureGranted = CGPreflightScreenCaptureAccess()

    static let pollInterval: TimeInterval = 0.05
    /// Air between the dock and the preview panel.
    static let panelGap: CGFloat = 10
    /// The dock list's frame, inflated toward the screen so a
    /// magnified icon's overflow still counts as "over the dock".
    static let listSlop: CGSize = CGSize(width: 20, height: 96)

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tracker = DockHoverTracker()
    @ObservationIgnored private var panel: DockPreviewPanel?
    /// Esc closes the preview even though it can't take key status.
    @ObservationIgnored private let watchers = DockPanelWatchers()
    /// Bumped per show so a slow thumbnail batch can't land on a
    /// preview that has since retargeted.
    @ObservationIgnored private var generation = 0

    /// Default-argument expressions are evaluated in the caller's
    /// (nonisolated) context under Swift 6, so the main-actor
    /// `DockEnhancePreferences()` can't be a default value — callers
    /// pass nil and the main-actor body builds it.
    init(preferences: DockEnhancePreferences? = nil) {
        self.preferences = preferences ?? DockEnhancePreferences()
        watchers.onEscape = { [weak self] in
            self?.tracker.reset()
            self?.hidePreview()
        }
    }

    isolated deinit {
        timer?.invalidate()
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        tracker.reset()
        hidePreview()
    }

    /// The card's appear hook — permissions are live reads, this just
    /// refreshes the cached values the chip and rows display.
    func refreshPermissions() {
        accessibilityTrusted = AXIsProcessTrusted()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
    }

    // MARK: The tick

    private func tick() {
        refreshPermissions()
        let inPanel = pointerInPanel()
        guard accessibilityTrusted else {
            if tracker.shown != nil { tracker.reset(); hidePreview() }
            return
        }
        var hovered: DockAXItem?
        if let pid = AppleDockReader.dockPID(),
           let list = AppleDockReader.dockList(pid: pid),
           let listFrame = AppleDockReader.frame(of: list) {
            let axPoint = DockEnhanceMath.axPoint(
                NSEvent.mouseLocation, mainScreenHeight: Self.mainScreenHeight())
            let reach = listFrame.insetBy(dx: -Self.listSlop.width, dy: -Self.listSlop.height)
            if reach.contains(axPoint) {
                hovered = AppleDockReader.item(list: list, at: axPoint)
                // The inflated read can hit an icon a magnification
                // grew past its frame — only the item's own frame wins.
                if let item = hovered, !item.frame.contains(axPoint) { hovered = nil }
            }
        }
        let action = tracker.note(hovered: hovered?.hoverID, pointerInPanel: inPanel,
                                  now: CACurrentMediaTime(), delay: preferences.previewDelay)
        switch action {
        case .show:
            if let hovered { showPreview(for: hovered) }
        case .hide:
            hidePreview()
        case .none:
            break
        }
    }

    private func pointerInPanel() -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
    }

    private static func mainScreenHeight() -> CGFloat {
        // The primary screen is the one holding the global origin.
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?
            .frame.height ?? 0
    }

    // MARK: Show / hide

    private func showPreview(for item: DockAXItem) {
        generation += 1
        let generationAtShow = generation
        fill(preview, for: item)

        let mainHeight = Self.mainScreenHeight()
        let itemFrame = DockEnhanceMath.appKitRect(item.frame, mainScreenHeight: mainHeight)
        let screen = NSScreen.screens.first { $0.frame.contains(itemFrame.origin) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? .zero
        let listFrame = dockListAppKitFrame(mainHeight: mainHeight) ?? itemFrame
        let edge = DockEnhanceMath.dockEdge(listFrame: listFrame, screen: screenFrame)

        let panel = ensurePanel()
        let size = panel.fittingSize()
        panel.present(frame: DockEnhanceMath.panelFrame(
            anchor: itemFrame, edge: edge, size: size,
            screen: screenFrame, gap: Self.panelGap), dockedAt: edge)
        watchers.start(escape: true)

        if preferences.showThumbnails, screenCaptureGranted, let pid = preview.processIdentifier {
            let bundleID = preview.bundleID
            Task { @MainActor [weak self] in
                await self?.attachThumbnails(
                    bundleID: bundleID, pid: pid, generation: generationAtShow)
            }
        }
    }

    /// Reads the dock list's frame again for edge detection — one AX
    /// call, only on a show.
    private func dockListAppKitFrame(mainHeight: CGFloat) -> CGRect? {
        guard let pid = AppleDockReader.dockPID(),
              let list = AppleDockReader.dockList(pid: pid),
              let axFrame = AppleDockReader.frame(of: list) else { return nil }
        return DockEnhanceMath.appKitRect(axFrame, mainScreenHeight: mainHeight)
    }

    private func hidePreview() {
        generation += 1
        watchers.stop()
        panel?.dismiss()
    }

    private func ensurePanel() -> DockPreviewPanel {
        if let panel { return panel }
        let panel = DockPreviewPanel(content: preview)
        panel.actions.onPick = { [weak self] window in self?.pick(window) }
        panel.actions.onOpenApp = { [weak self] in self?.openApp() }
        self.panel = panel
        return panel
    }

    /// What a hovered tile resolves to: a running app via the tile's
    /// `AXURL`/bundle id or a title match, else a bare "open me" card.
    private func fill(_ content: DockPreviewContent, for item: DockAXItem) {
        let appURL = item.url
        let bundleID = appURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        let running = bundleID.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        } ?? NSWorkspace.shared.runningApplications.first {
            $0.localizedName == item.title && $0.activationPolicy == .regular
        }
        content.appName = running?.localizedName ?? item.title
            ?? appURL?.deletingPathExtension().lastPathComponent ?? "Dock item"
        content.bundleID = running?.bundleIdentifier ?? bundleID
        content.appURL = running?.bundleURL ?? appURL
        content.processIdentifier = running?.processIdentifier
        content.isRunning = running != nil && !(running?.isTerminated ?? true)
        content.icon = running?.icon
            ?? appURL.map { DockIconResolver.icon(appURL: $0, pointSize: 64, scale: 2) }
        content.windows = running.map { AppleDockReader.windows(pid: $0.processIdentifier) } ?? []
    }

    /// One-shot `SCScreenshotManager` captures matched to AX rows by
    /// title — `DockThumbnailer` does the Retina-scaled capturing;
    /// `generation` keeps a retarget or hide from landing stale rows.
    private func attachThumbnails(bundleID: String?, pid: pid_t, generation: Int) async {
        await DockThumbnailer.attach(
            to: preview, bundleID: bundleID, pid: pid,
            isStale: { [weak self] in self?.generation != generation })
    }

    /// A window row's click — raise it and bring the app forward.
    private func pick(_ window: DockPreviewWindow) {
        let app = preview.processIdentifier.flatMap { NSRunningApplication(processIdentifier: $0) }
        AppleDockReader.raise(window, app: app)
        tracker.reset()
        hidePreview()
    }

    /// The header's "Open" for a pinned app that isn't running.
    private func openApp() {
        if let url = preview.appURL {
            NSWorkspace.shared.openApplication(
                at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
        tracker.reset()
        hidePreview()
    }
}
