import AppKit
import ApplicationServices
import JRBarCore
import Observation
import OSLog
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
    /// captures; off falls back to icon + title cards and needs no
    /// Screen Recording permission.
    var showThumbnails: Bool {
        get { read().showThumbnails }
        set { write?({ var s = read(); s.showThumbnails = newValue; return s }()) }
    }
    /// Bigger cards.
    var largePreviews: Bool {
        get { read().largePreviews }
        set { write?({ var s = read(); s.largePreviews = newValue; return s }()) }
    }
    /// Windows on other Spaces and minimized windows list too.
    var includeOffscreenWindows: Bool {
        get { read().includeOffscreenWindows }
        set { write?({ var s = read(); s.includeOffscreenWindows = newValue; return s }()) }
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
    /// How long a reading of "no tile" is forgiven before the rest
    /// clock restarts: the pointer crossing the seam between two
    /// tiles reads as nothing for a tick, and a sweep along the Dock
    /// never opened anything when each seam started the clock over.
    static let seamGrace: TimeInterval = 0.12

    @discardableResult
    mutating func note(hovered item: String?, pointerInPanel: Bool,
                       now: TimeInterval, delay: TimeInterval) -> Action {
        if let item {
            if item != hovered {
                hovered = item
                hoveredSince = now
            }
            emptySince = nil
        } else {
            if emptySince == nil { emptySince = now }
            if let left = emptySince, now - left >= Self.seamGrace {
                hovered = nil
                hoveredSince = nil
            }
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
            // An auto-hidden Dock reports its tiles below the screen
            // while it slides; the panel never follows them off it.
            let y = min(max(itemFrame.maxY + gap, screen.minY + 8),
                        max(screen.minY + 8, screen.maxY - size.height - 8))
            return CGRect(x: x, y: y, width: size.width, height: size.height)
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

    /// A window card's thumbnail box — 16:10, two sizes.
    static func cardSize(large: Bool) -> CGSize {
        large ? CGSize(width: 208, height: 130) : CGSize(width: 144, height: 90)
    }

    /// Match a captured window to an AX row. Frames are the honest key
    /// — titles repeat, go empty, or change mid-session — with a title
    /// match as the fallback for a window whose frame the app reports
    /// oddly. Returns the index of the row, or nil.
    static func matchRow(scFrame: CGRect, scTitle: String?,
                         rows: [(frame: CGRect?, title: String)],
                         tolerance: CGFloat = 2) -> Int? {
        if let index = rows.firstIndex(where: { row in
            guard let frame = row.frame else { return false }
            return abs(frame.minX - scFrame.minX) <= tolerance
                && abs(frame.minY - scFrame.minY) <= tolerance
                && abs(frame.width - scFrame.width) <= tolerance
                && abs(frame.height - scFrame.height) <= tolerance
        }) { return index }
        guard let scTitle, !scTitle.isEmpty else { return nil }
        return rows.firstIndex(where: { $0.title == scTitle })
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
    /// Stable hover identity: the URL, else the title, else the slot —
    /// two tiles with one title (two copies of an app) still retarget.
    var hoverID: String {
        url?.path ?? title ?? "dock-item@\(Int(frame.minX))"
    }
}

/// Read-only queries against the Dock process's accessibility tree,
/// plus the window verbs a preview card offers. Every read fails soft
/// (nil / []) without Accessibility permission — the caller's
/// `AXIsProcessTrusted` gate decides whether that means "no dock" or
/// "no rights".
enum AppleDockReader {
    static let dockBundleID = "com.apple.dock"

    static func dockPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleID)
            .first?.processIdentifier
    }

    /// The dock's `AXList` element. Older releases gave it the
    /// `AXDockList` subrole; macOS 26 reports no subrole at all
    /// (verified live), so the role is the key and the subrole only a
    /// tie-break.
    static func dockList(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let children = axChildren(app)
        return children.first { axString($0, kAXSubroleAttribute) == "AXDockList" }
            ?? children.first { axString($0, kAXRoleAttribute) == kAXListRole }
    }

    /// Every application tile in the list, in Dock order — spacers,
    /// folders, the Trash and minimized-window tiles are skipped:
    /// previews are an app feature. One walk; the caller keeps the
    /// result for a beat and hit-tests in memory, so the tick never
    /// re-walks the whole tree.
    static func items(list: AXUIElement) -> [DockAXItem] {
        axChildren(list).compactMap { child in
            guard axString(child, kAXSubroleAttribute) == "AXApplicationDockItem",
                  let frame = axFrame(child) else { return nil }
            return DockAXItem(element: child, frame: frame,
                              title: axString(child, kAXTitleAttribute),
                              url: axURL(child))
        }
    }

    /// The application tile under `point` (AX coordinates), or nil.
    static func item(list: AXUIElement, at point: CGPoint) -> DockAXItem? {
        items(list: list).first { $0.frame.contains(point) }
    }

    static func frame(of element: AXUIElement) -> CGRect? { axFrame(element) }

    /// One app's windows as preview rows — AX gives the title, the
    /// frame (the thumbnail match key), the minimized flag, and the
    /// element a later click can raise, close or minimize.
    static func windows(pid: pid_t) -> [DockPreviewWindow] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements.enumerated().compactMap { index, element in
            // Sheets, drawers, floating palettes: not windows a person
            // switches to.
            let subrole = axString(element, kAXSubroleAttribute)
            if let subrole, subrole != "AXStandardWindow", subrole != "AXDialog" { return nil }
            return DockPreviewWindow(
                id: index,
                title: axString(element, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Untitled window",
                minimized: axBool(element, kAXMinimizedAttribute),
                frame: axFrame(element),
                element: element)
        }
    }

    /// Click a preview card: un-minimize if needed, raise the window,
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
        // Plain activate: `.activateAllWindows` brought every window of
        // the app forward and buried the one that was picked.
        app?.activate()
    }

    /// The card's ×: press the window's close button. Returns false
    /// when the window offers none.
    @discardableResult
    static func close(_ window: DockPreviewWindow) -> Bool {
        guard let element = window.element else { return false }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &value) == .success,
              let button = value, CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// The card's –: minimize, or bring back a minimized window.
    @discardableResult
    static func setMinimized(_ window: DockPreviewWindow, _ minimized: Bool) -> Bool {
        guard let element = window.element else { return false }
        return AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                            minimized as CFTypeRef) == .success
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
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        // AXValue wraps CGPoint/CGSize; the casts are the documented pattern.
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}

// MARK: - Preview content

/// One card in the preview panel: a title, the window's frame (the
/// thumbnail match key), an AX handle the verbs act on, and an
/// optional thumbnail filled in asynchronously.
struct DockPreviewWindow: Identifiable {
    let id: Int
    var title: String
    var minimized: Bool
    /// The window's frame in Quartz coordinates, when AX reports one.
    var frame: CGRect?
    var thumbnail: NSImage?
    /// The AX window element — the raise/close/minimize target. AX
    /// handles only ever touch the main actor here.
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
    var largeCards = false
}

// MARK: - Controller

/// Enhance mode: Apple's Dock stays; we watch the pointer over it
/// through Accessibility and float a window-preview panel above a
/// rested icon (docs/TOY-PARITY.md: "Hover a Dock icon → live window
/// previews … AX to hit-test the Dock, SCScreenshotManager one-shots
/// per window, no stream so no purple indicator").
///
/// The watch is a 20 Hz timer, not an event tap. Per tick it reads the
/// pointer and compares it against a *cached* dock-list frame — the AX
/// walk to the Dock process runs at most once a second while the
/// pointer is away, and per-item hit-testing only while it is inside.
/// The TCC probes (`AXIsProcessTrusted`, the Screen Recording
/// preflight) are IPC round trips and are cached for
/// `permissionTTL`, the same rule the Menu Bar utility follows.
@MainActor
@Observable
final class DockEnhanceController {
    let preferences: DockEnhancePreferences
    /// What the panel shows right now — the view binds to it.
    let preview = DockPreviewContent()

    private(set) var running = false
    /// Cached TCC answers; `refreshPermissions()` re-reads when stale.
    private(set) var accessibilityTrusted = false
    private(set) var screenCaptureGranted = false
    @ObservationIgnored private var permissionsCheckedAt = Date.distantPast
    /// The minimum gap between TCC polls.
    nonisolated static let permissionTTL: TimeInterval = 3

    static let pollInterval: TimeInterval = 0.05
    /// The cadence while the pointer is far from every screen edge a
    /// Dock could live on.
    nonisolated static let farPollInterval: TimeInterval = 0.25
    /// How long a dock-list frame stays trusted while the pointer is
    /// away from it — and a much shorter trust while the pointer is
    /// near a screen edge, where an auto-hidden Dock slides in and its
    /// frame moves on screen.
    nonisolated static let listFrameTTL: TimeInterval = 1.0
    nonisolated static let edgeListFrameTTL: TimeInterval = 0.2
    /// How long the tiles read from the list stay trusted while the
    /// pointer is over it — the tick hit-tests these in memory instead
    /// of walking the Dock's tree twenty times a second.
    nonisolated static let itemsTTL: TimeInterval = 0.25
    /// How close to a screen edge counts as "near" for the fast refresh.
    nonisolated static let edgeReach: CGFloat = 120
    /// Air between the dock and the preview panel.
    static let panelGap: CGFloat = 10
    /// The dock list's frame, inflated toward the screen so a
    /// magnified icon's overflow still counts as "over the dock".
    static let listSlop: CGSize = CGSize(width: 20, height: 96)

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tracker = DockHoverTracker()
    @ObservationIgnored private var panel: DockPreviewPanel?
    /// Esc and a click anywhere else close the preview even though it
    /// can't take key status.
    @ObservationIgnored private let watchers = DockPanelWatchers()
    /// Bumped per show so a slow thumbnail batch can't land on a
    /// preview that has since retargeted.
    @ObservationIgnored private var generation = 0
    /// The dock list element and its AX frame, with the time read.
    @ObservationIgnored private var cachedList: (element: AXUIElement, frame: CGRect, at: TimeInterval)?
    /// The list's app tiles, read once per `itemsTTL` for the list
    /// frame they were read under.
    @ObservationIgnored private var cachedItems: (listFrame: CGRect, items: [DockAXItem], at: TimeInterval)?
    /// The tile the visible panel is anchored to and the edge it opens
    /// from — re-anchored every tick while the pointer stays on the
    /// tile, so a Dock still sliding in carries the panel with it and
    /// a size measured before the content settled is corrected a beat
    /// later.
    @ObservationIgnored private var anchor: (item: DockAXItem, edge: DockEdge, screen: CGRect)?

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
        watchers.onOutside = { [weak self] in
            self?.tracker.reset()
            self?.hidePreview()
        }
        watchers.isInside = { [weak self] in
            guard let self, let panel, panel.isVisible else { return true }
            return panel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        }
    }

    isolated deinit {
        timer?.invalidate()
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        refreshPermissions(force: true)
        Self.log.notice("enhance start: accessibility \(self.accessibilityTrusted, privacy: .public), screen recording \(self.screenCaptureGranted, privacy: .public), dock list \(AppleDockReader.dockPID().flatMap { AppleDockReader.dockList(pid: $0) } != nil, privacy: .public)")
        scheduleTick(after: Self.pollInterval)
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        tracker.reset()
        cachedList = nil
        hidePreview()
    }

    /// The card's appear hook and the tick's gate: re-read TCC only
    /// when the cache is stale (or `force`).
    func refreshPermissions(force: Bool = false) {
        guard force || Date().timeIntervalSince(permissionsCheckedAt) > Self.permissionTTL else { return }
        permissionsCheckedAt = Date()
        accessibilityTrusted = AXIsProcessTrusted()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
    }

    // MARK: The tick

    /// One-shot, re-armed at the cadence the pointer's position earns:
    /// 20 Hz near a screen edge or while a panel is up, 4 Hz elsewhere.
    private func scheduleTick(after interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.tick()
                let axPoint = DockEnhanceMath.axPoint(NSEvent.mouseLocation, mainScreenHeight: Self.mainScreenHeight())
                let near = Self.nearScreenEdge(axPoint) || self.tracker.shown != nil || self.pointerInPanel()
                self.scheduleTick(after: near ? Self.pollInterval : Self.farPollInterval)
            }
        }
    }

    private func tick() {
        refreshPermissions()
        let inPanel = pointerInPanel()
        guard accessibilityTrusted else {
            if tracker.shown != nil { tracker.reset(); hidePreview() }
            return
        }
        let axPoint = DockEnhanceMath.axPoint(
            NSEvent.mouseLocation, mainScreenHeight: Self.mainScreenHeight())
        var hovered: DockAXItem?
        if let list = dockList(near: axPoint) {
            let reach = list.frame.insetBy(dx: -Self.listSlop.width, dy: -Self.listSlop.height)
            if reach.contains(axPoint) {
                hovered = tiles(of: list).first { $0.frame.contains(axPoint) }
            }
        }
        let action = tracker.note(hovered: hovered?.hoverID, pointerInPanel: inPanel,
                                  now: CACurrentMediaTime(), delay: preferences.previewDelay)
        switch action {
        case .show:
            if let hovered {
                Self.log.notice("preview: \(hovered.hoverID, privacy: .public)")
                showPreview(for: hovered)
            }
        case .hide:
            hidePreview()
        case .none:
            if let hovered, hovered.hoverID == tracker.shown { anchorPanel(to: hovered) }
        }
    }

    /// The list's app tiles — the cached read while it is fresh and the
    /// list has not moved, else one walk.
    private func tiles(of list: (element: AXUIElement, frame: CGRect)) -> [DockAXItem] {
        let now = CACurrentMediaTime()
        // Fresh frames while a panel is up: under magnification the
        // tiles move with the pointer, and a panel anchored on a
        // quarter-second-old frame sat visibly off its icon.
        let live = tracker.shown != nil
        if !live, let cached = cachedItems, cached.listFrame == list.frame, now - cached.at < Self.itemsTTL {
            return cached.items
        }
        let items = AppleDockReader.items(list: list.element)
        cachedItems = (list.frame, items, now)
        return items
    }

    static let log = Logger(subsystem: "devin.jrbar", category: "dock")

    /// The dock list, re-read from AX when the cache is stale or the
    /// pointer is inside the last known frame (a magnified or moved
    /// Dock reflows its list, and only a live read follows it).
    private func dockList(near point: CGPoint) -> (element: AXUIElement, frame: CGRect)? {
        let now = CACurrentMediaTime()
        if let cached = cachedList {
            let inside = cached.frame.insetBy(dx: -Self.listSlop.width, dy: -Self.listSlop.height)
                .contains(point)
            let ttl = Self.nearScreenEdge(point) ? Self.edgeListFrameTTL : Self.listFrameTTL
            if !inside, now - cached.at < ttl {
                return (cached.element, cached.frame)
            }
        }
        guard let pid = AppleDockReader.dockPID(),
              let list = AppleDockReader.dockList(pid: pid),
              let frame = AppleDockReader.frame(of: list) else {
            cachedList = nil
            return nil
        }
        cachedList = (list, frame, now)
        return (list, frame)
    }

    /// Whether an AX-space point is within `edgeReach` of the bottom,
    /// left or right edge of the screen that holds it — where an
    /// auto-hidden Dock lives.
    private static func nearScreenEdge(_ axPoint: CGPoint) -> Bool {
        let height = mainScreenHeight()
        let appKit = CGPoint(x: axPoint.x, y: height - axPoint.y)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKit) }) else { return false }
        let f = screen.frame
        return appKit.y - f.minY < Self.edgeReach || appKit.x - f.minX < Self.edgeReach
            || f.maxX - appKit.x < Self.edgeReach
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
        preview.largeCards = preferences.largePreviews
        fill(preview, for: item)
        // Nothing to preview — no windows to raise — is no panel. A
        // running app with no windows earned a header-only chip on
        // every pass before; an app not running has the Dock's own
        // click to open it. The tracker keeps the tile as shown, so
        // this does not retry on every tick.
        guard !preview.windows.isEmpty else {
            hidePreview()
            return
        }

        let mainHeight = Self.mainScreenHeight()
        let itemFrame = DockEnhanceMath.appKitRect(item.frame, mainScreenHeight: mainHeight)
        // The screen under the pointer: a sliding Dock's tiles report
        // below the screen, where no screen contains them.
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.screens.first { $0.frame.contains(itemFrame.origin) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? .zero
        let listFrame = cachedList.map {
            DockEnhanceMath.appKitRect($0.frame, mainScreenHeight: mainHeight)
        } ?? itemFrame
        let edge = DockEnhanceMath.dockEdge(listFrame: listFrame, screen: screenFrame)
        anchor = (item, edge, screenFrame)

        let panel = ensurePanel()
        let size = panel.fittingSize()
        let target = DockEnhanceMath.panelFrame(
            anchor: itemFrame, edge: edge, size: size,
            screen: screenFrame, gap: Self.panelGap)
        Self.log.notice("preview geometry: tile \(String(format: "%.0f–%.0f", itemFrame.minX, itemFrame.maxX), privacy: .public) (mid \(String(format: "%.0f", itemFrame.midX), privacy: .public)), list \(String(format: "%.0f–%.0f", listFrame.minX, listFrame.maxX), privacy: .public), pointer \(String(format: "%.0f", pointer.x), privacy: .public), size \(String(format: "%.0fx%.0f", size.width, size.height), privacy: .public), panel \(String(format: "%.0f–%.0f", target.minX, target.maxX), privacy: .public) (mid \(String(format: "%.0f", target.midX), privacy: .public)), \(self.preview.windows.count, privacy: .public) windows")
        panel.present(frame: target, dockedAt: edge)
        watchers.start(escape: true, clickAway: true)

        if preferences.showThumbnails, screenCaptureGranted, let pid = preview.processIdentifier {
            let bundleID = preview.bundleID
            let offscreen = preferences.includeOffscreenWindows
            Task { @MainActor [weak self] in
                guard let self else { return }
                await DockThumbnailer.attach(
                    to: preview, bundleID: bundleID, pid: pid,
                    includeOffscreen: offscreen,
                    isStale: { [weak self] in self?.generation != generationAtShow })
            }
        }
    }

    private func hidePreview() {
        generation += 1
        anchor = nil
        watchers.stop()
        panel?.dismiss()
    }

    /// Keep the visible panel on its tile: the tile's frame moves while
    /// an auto-hidden Dock slides in, and the content's fitting size
    /// settles a beat after it was first measured. Only a real change
    /// moves the frame, without animation — it is a correction, not a
    /// retarget.
    private func anchorPanel(to item: DockAXItem) {
        guard let panel, panel.isVisible, let anchor else { return }
        let itemFrame = DockEnhanceMath.appKitRect(item.frame, mainScreenHeight: Self.mainScreenHeight())
        let size = panel.fittingSize()
        let target = DockEnhanceMath.panelFrame(anchor: itemFrame, edge: anchor.edge, size: size,
                                                screen: anchor.screen, gap: Self.panelGap)
        self.anchor = (item, anchor.edge, anchor.screen)
        if abs(target.minX - panel.frame.minX) > 1 || abs(target.minY - panel.frame.minY) > 1
            || abs(target.width - panel.frame.width) > 1 || abs(target.height - panel.frame.height) > 1 {
            panel.setFrame(target, display: true)
        }
    }

    private func ensurePanel() -> DockPreviewPanel {
        if let panel { return panel }
        let panel = DockPreviewPanel(content: preview)
        panel.actions.onPick = { [weak self] window in self?.pick(window) }
        panel.actions.onClose = { [weak self] window in self?.close(window) }
        panel.actions.onMinimize = { [weak self] window in self?.toggleMinimized(window) }
        panel.actions.onOpenApp = { [weak self] in self?.openApp() }
        panel.actions.onQuitApp = { [weak self] in self?.quitApp() }
        panel.actions.onHideApp = { [weak self] in self?.hideApp() }
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

    // MARK: Verbs

    /// A window card's click — raise it and bring the app forward.
    private func pick(_ window: DockPreviewWindow) {
        let app = preview.processIdentifier.flatMap { NSRunningApplication(processIdentifier: $0) }
        AppleDockReader.raise(window, app: app)
        tracker.reset()
        hidePreview()
    }

    /// The card's ×: close the window and drop its card; the panel
    /// stays so a person can close several in a row.
    private func close(_ window: DockPreviewWindow) {
        guard AppleDockReader.close(window) else { return }
        preview.windows.removeAll { $0.id == window.id }
        if preview.windows.isEmpty {
            tracker.reset()
            hidePreview()
        } else {
            reframe()
        }
    }

    /// The card's –: minimize, or bring a minimized window back.
    private func toggleMinimized(_ window: DockPreviewWindow) {
        let target = !window.minimized
        guard AppleDockReader.setMinimized(window, target),
              let index = preview.windows.firstIndex(where: { $0.id == window.id }) else { return }
        preview.windows[index].minimized = target
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

    /// The header's "Quit" — a plain terminate, never forced.
    private func quitApp() {
        preview.processIdentifier
            .flatMap { NSRunningApplication(processIdentifier: $0) }?
            .terminate()
        tracker.reset()
        hidePreview()
    }

    /// The header's "Hide" — the app's own ⌘H.
    private func hideApp() {
        preview.processIdentifier
            .flatMap { NSRunningApplication(processIdentifier: $0) }?
            .hide()
        tracker.reset()
        hidePreview()
    }

    /// The panel's content changed size (a card left): re-fit on the
    /// same tile, from the same edge, clamped to the same screen.
    private func reframe() {
        guard let panel, panel.isVisible else { return }
        guard let anchor else {
            let size = panel.fittingSize()
            var frame = panel.frame
            frame.origin.x += (frame.width - size.width) / 2
            frame.size = size
            panel.setFrame(frame, display: true)
            return
        }
        let itemFrame = DockEnhanceMath.appKitRect(anchor.item.frame, mainScreenHeight: Self.mainScreenHeight())
        panel.setFrame(DockEnhanceMath.panelFrame(
            anchor: itemFrame, edge: anchor.edge, size: panel.fittingSize(),
            screen: anchor.screen, gap: Self.panelGap), display: true)
    }
}
