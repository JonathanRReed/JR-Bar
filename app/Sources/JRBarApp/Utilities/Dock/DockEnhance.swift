import AppKit
import ApplicationServices
import EventKit
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
    /// Hold an auto-hiding Dock out while a preview is up.
    var holdDockOpen: Bool {
        get { read().holdDockOpen }
        set { write?({ var s = read(); s.holdDockOpen = newValue; return s }()) }
    }
    /// Past this count the panel lists titles instead of thumbnails.
    var compactListLimit: Int {
        get { read().compactListLimit }
        set { write?({ var s = read(); s.compactListLimit = newValue; return s }()) }
    }
    /// ⌥⇥ raises the window switcher.
    var windowSwitcher: Bool {
        get { read().windowSwitcher }
        set { write?({ var s = read(); s.windowSwitcher = newValue; return s }()) }
    }
    /// ⌘⇥ raises the app switcher instead of the system's — off by
    /// default, it eats the OS's own chord.
    var appSwitcher: Bool {
        get { read().appSwitcher }
        set { write?({ var s = read(); s.appSwitcher = newValue; return s }()) }
    }
    /// Bundle ids that never earn a preview.
    var excludedBundleIDs: [String] {
        get { read().excludedBundleIDs }
        set { write?({ var s = read(); s.excludedBundleIDs = newValue; return s }()) }
    }
    /// Resting on a Dock icon opens a preview at all.
    var hoverPreviews: Bool {
        get { read().hoverPreviews }
        set { write?({ var s = read(); s.hoverPreviews = newValue; return s }()) }
    }
    /// ⌥⇥ lists only the pointer's display.
    var switcherThisDisplay: Bool {
        get { read().switcherThisDisplay }
        set { write?({ var s = read(); s.switcherThisDisplay = newValue; return s }()) }
    }
    /// A preview lists only the windows on its Dock's display.
    var previewThisDisplay: Bool {
        get { read().previewThisDisplay }
        set { write?({ var s = read(); s.previewThisDisplay = newValue; return s }()) }
    }
    /// What opens a preview — a rest, a rest with ⌥, or a middle click.
    var previewTrigger: DockPreviewTrigger {
        get { read().previewTrigger }
        set { write?({ var s = read(); s.previewTrigger = newValue; return s }()) }
    }
    /// Scroll up on an icon previews it at once; down hides the app.
    var scrollGestures: Bool {
        get { read().scrollGestures }
        set { write?({ var s = read(); s.scrollGestures = newValue; return s }()) }
    }
    /// ⌥` previews the front app from its Dock tile.
    var frontAppChord: Bool {
        get { read().frontAppChord }
        set { write?({ var s = read(); s.frontAppChord = newValue; return s }()) }
    }
    /// The card under the pointer plays live — the recording dot stays
    /// on while it does.
    var liveCard: Bool {
        get { read().liveCard }
        set { write?({ var s = read(); s.liveCard = newValue; return s }()) }
    }
    /// Clicking the front app's own Dock icon minimizes its windows.
    var clickToMinimize: Bool {
        get { read().clickToMinimize }
        set { write?({ var s = read(); s.clickToMinimize = newValue; return s }()) }
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

    /// A deliberate summon — a middle click or an upward scroll on the
    /// tile — opens the panel now, without waiting out the rest; from
    /// there the usual grace rules close it. The same tile again is a
    /// no-op (the caller decides whether a repeat means "close").
    @discardableResult
    mutating func summon(_ item: String, now: TimeInterval) -> Action {
        hovered = item
        hoveredSince = now
        emptySince = nil
        guard shown != item else { return .none }
        shown = item
        return .show(item)
    }

    /// What the tick hands `note` under a trigger mode: every tile for
    /// Hover; with ⌥ only a tile rested on while ⌥ is held; for Middle
    /// Click nothing rests open a panel. The tile already shown always
    /// passes, so letting go of ⌥ — or never having pressed it — doesn't
    /// close the panel under the pointer.
    static func trackedItem(_ hovered: String?, shown: String?,
                            trigger: DockPreviewTrigger, optionHeld: Bool) -> String? {
        guard let hovered else { return nil }
        if hovered == shown { return hovered }
        switch trigger {
        case .hover: return hovered
        case .optionHover: return optionHeld ? hovered : nil
        case .middleClick: return nil
        }
    }
}

// MARK: - Geometry (pure, tested)

/// The coordinate plumbing: AX reports frames in Quartz screen
/// coordinates (origin top-left of the primary display, y down);
/// `NSEvent.mouseLocation`, `NSScreen.frame` and `NSWindow.frame` are
/// AppKit (origin bottom-left, y up).
/// A snap target on a screen — DockDoor's tile verbs: halves and
/// quarters of the visible frame, written through AX.
enum DockTile: String, CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    /// Two-thirds of the screen, centred — DockDoor's Center.
    case center
    /// The whole visible frame — a fill, not macOS full screen.
    case fill

    var title: String {
        switch self {
        case .center: return "Center"
        case .fill: return "Fill"
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

enum DockEnhanceMath {
    /// The bottom Dock label needs vertical room. A side Dock label needs
    /// its measured width plus the bubble's horizontal padding, capped so
    /// a pathological app name cannot push the preview across the screen.
    static let nativeLabelHeight: CGFloat = 34
    static let nativeSideLabelLimit: CGFloat = 240

    static func nativeLabelClearance(title: String, edge: DockEdge) -> CGFloat {
        guard edge != .bottom else { return nativeLabelHeight }
        let width = ceil((title as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width)
        return min(max(nativeLabelHeight, width + 24), nativeSideLabelLimit)
    }

    static func axPoint(_ appKitPoint: CGPoint, mainScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: appKitPoint.x, y: mainScreenHeight - appKitPoint.y)
    }

    /// The tile's rect inside a Quartz-space visible frame — minY is
    /// the screen's TOP here, so "top" tiles pin at minY and "bottom"
    /// at midY.
    static func tileFrame(_ tile: DockTile, in visible: CGRect) -> CGRect {
        let halfW = visible.width / 2, halfH = visible.height / 2
        switch tile {
        case .leftHalf:
            return CGRect(x: visible.minX, y: visible.minY,
                          width: halfW, height: visible.height)
        case .rightHalf:
            return CGRect(x: visible.midX, y: visible.minY,
                          width: halfW, height: visible.height)
        case .topHalf:
            return CGRect(x: visible.minX, y: visible.minY,
                          width: visible.width, height: halfH)
        case .bottomHalf:
            return CGRect(x: visible.minX, y: visible.midY,
                          width: visible.width, height: halfH)
        case .topLeft:
            return CGRect(x: visible.minX, y: visible.minY,
                          width: halfW, height: halfH)
        case .topRight:
            return CGRect(x: visible.midX, y: visible.minY,
                          width: halfW, height: halfH)
        case .bottomLeft:
            return CGRect(x: visible.minX, y: visible.midY,
                          width: halfW, height: halfH)
        case .bottomRight:
            return CGRect(x: visible.midX, y: visible.midY,
                          width: halfW, height: halfH)
        case .center:
            let w = (visible.width * 2 / 3).rounded(), h = (visible.height * 2 / 3).rounded()
            return CGRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h)
        case .fill:
            return visible
        }
    }

    /// "Move to <display>": the window keeps its size — clamped to fit
    /// the target's visible frame — and lands centred on it. Quartz
    /// space in, Quartz space out.
    static func moveFrame(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let w = min(frame.width, visible.width), h = min(frame.height, visible.height)
        return CGRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h)
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
    /// the dock toward the screen's middle, centred on the tile itself
    /// along the dock's run — the DockDoor read, where the panel sits
    /// over its app — and clamped inside the screen when the tile hugs
    /// a screen edge.
    static func panelFrame(anchor itemFrame: CGRect, edge: DockEdge, size: CGSize,
                           screen: CGRect, gap: CGFloat,
                           labelClearance: CGFloat = nativeLabelHeight) -> CGRect {
        let offset = gap + labelClearance
        switch edge {
        case .bottom:
            let x = min(max(itemFrame.midX - size.width / 2, screen.minX + 8),
                        max(screen.minX + 8, screen.maxX - size.width - 8))
            // An auto-hidden Dock reports its tiles below the screen
            // while it slides; the panel never follows them off it.
            let y = min(max(itemFrame.maxY + offset, screen.minY + 8),
                        max(screen.minY + 8, screen.maxY - size.height - 8))
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        case .left:
            let y = min(max(itemFrame.midY - size.height / 2, screen.minY + 8),
                        max(screen.minY + 8, screen.maxY - size.height - 8))
            return CGRect(x: itemFrame.maxX + offset, y: y,
                          width: size.width, height: size.height)
        case .right:
            let y = min(max(itemFrame.midY - size.height / 2, screen.minY + 8),
                        max(screen.minY + 8, screen.maxY - size.height - 8))
            return CGRect(x: itemFrame.minX - offset - size.width, y: y,
                          width: size.width, height: size.height)
        }
    }

    /// Under magnification the tile's AX frame is the unmagnified
    /// layout while the icon rides the pointer along the dock's run —
    /// the x axis for a bottom Dock, the y axis for a side one. The
    /// off axis keeps the tile's own coordinate: the icon swells out
    /// of the dock but its track never leaves the edge.
    static func magnifiedAnchor(tile: CGRect, edge: DockEdge, pointer: CGPoint) -> CGRect {
        switch edge {
        case .bottom:
            return CGRect(x: pointer.x - tile.width / 2, y: tile.minY,
                          width: tile.width, height: tile.height)
        case .left, .right:
            return CGRect(x: tile.minX, y: pointer.y - tile.height / 2,
                          width: tile.width, height: tile.height)
        }
    }

    /// The safe road between a tile and its panel: the convex hull of
    /// the two rects. The panel sits over its tile, but a wide panel
    /// still reaches past the icon on both sides — and a clamped one
    /// sits shifted off it — so the road is a hull, not a corridor
    /// lined up on the tile. A point inside the hull is still
    /// travelling, not leaving; a point past the hull's far corners
    /// has left the road for good.
    static func inCorridor(item: CGRect, panel: CGRect, edge: DockEdge,
                           point: CGPoint, slop: CGFloat) -> Bool {
        // Work in (a, o): `a` along the dock's run, `o` off it toward
        // the panel — so the tile is always the lower rect, the panel
        // the upper, and one hull construction serves all three edges.
        func axis(_ x: CGFloat, _ y: CGFloat) -> (a: CGFloat, o: CGFloat) {
            switch edge {
            case .bottom: (x, y)
            case .left: (y, x)
            case .right: (y, -x)
            }
        }
        func hullRect(_ r: CGRect) -> (a0: CGFloat, a1: CGFloat, o0: CGFloat, o1: CGFloat) {
            let lo = axis(r.minX, r.minY), hi = axis(r.maxX, r.maxY)
            return (min(lo.a, hi.a), max(lo.a, hi.a), min(lo.o, hi.o), max(lo.o, hi.o))
        }
        let item = hullRect(item), panel = hullRect(panel)
        guard panel.o0 > item.o1 else { return false }
        let p = axis(point.x, point.y)
        // The hull, counter-clockwise from the tile's low corner: the
        // ramp on each side passes through whichever rect reaches
        // further along the axis.
        var v: [(a: CGFloat, o: CGFloat)] = [(item.a0, item.o0), (item.a1, item.o0)]
        if item.a1 < panel.a1 { v += [(panel.a1, panel.o0), (panel.a1, panel.o1)] }
        else { v += [(item.a1, item.o1), (panel.a1, panel.o1)] }
        v.append((panel.a0, panel.o1))
        v.append(item.a0 > panel.a0 ? (panel.a0, panel.o0) : (item.a0, item.o1))
        // Convex containment: the point sits left of every CCW edge —
        // with `slop` of perpendicular forgiveness on each.
        for i in v.indices {
            let e = v[(i + 1) % v.count]
            let da = e.a - v[i].a, do_ = e.o - v[i].o
            let cross = da * (p.o - v[i].o) - do_ * (p.a - v[i].a)
            if cross < -slop * (da * da + do_ * do_).squareRoot() { return false }
        }
        return true
    }

    /// A window card's thumbnail box — 16:10, two sizes.
    static func cardSize(large: Bool) -> CGSize {
        large ? CGSize(width: 208, height: 130) : CGSize(width: 144, height: 90)
    }

    /// Whether `windowCount` crossed the compact-list limit — 0 is
    /// "never compact", and a list at the limit counts as past it.
    static func compactList(windowCount: Int, limit: Int) -> Bool {
        limit > 0 && windowCount >= limit
    }

    /// Apps whose tiles earn the Now Playing row — the players a Dock
    /// preview can plausibly drive with transport controls. When the
    /// now-playing source named a bundle the row only shows on a
    /// match; an anonymous source (the raw info dict carries none)
    /// shows on any player.
    static let playerBundleIDs: Set<String> = [
        "com.apple.Music", "com.apple.podcasts", "com.apple.TV",
        "com.spotify.client", "org.videolan.vlc", "com.colliderli.iina",
    ]

    /// Any app the now-playing source names gets the row — Safari or
    /// Chrome playing a video, a player this list never heard of. The
    /// list only answers for an anonymous source (the raw info dict
    /// names no bundle), where a known player is the best guess.
    static func showsMediaRow(mediaBundleID: String?, appBundleID: String?) -> Bool {
        guard let appBundleID else { return false }
        if let mediaBundleID { return mediaBundleID == appBundleID }
        return playerBundleIDs.contains(appBundleID)
    }

    /// A Folder Pop drill: the trail with `child` appended — only a
    /// direct subfolder of the folder showing, so a chip from a listing
    /// the pop has since left can't jump the trail somewhere else.
    static func drilledTrail(_ trail: [URL], root: URL, into child: URL) -> [URL]? {
        let current = (trail.last ?? root).standardizedFileURL.path
        guard child.deletingLastPathComponent().standardizedFileURL.path == current else { return nil }
        return trail + [child]
    }

    /// The pop's grid: up to five columns, and as many rows as the
    /// entries need up to four before it scrolls — about one screenful
    /// of Apple's Grid stack, not sixty chips in one sideways row.
    static func folderGrid(count: Int, columns maxColumns: Int = 5,
                           visibleRows: Int = 4) -> (columns: Int, rows: Int) {
        guard count > 0 else { return (0, 0) }
        let columns = min(maxColumns, count)
        let rows = (count + columns - 1) / columns
        return (columns, min(rows, visibleRows))
    }

    /// The exclusion list with `bundleID` added once — a second "Never
    /// Preview" on a stale panel doesn't list the app twice.
    static func excluding(_ bundleID: String, from list: [String]) -> [String] {
        list.contains(bundleID) ? list : list + [bundleID]
    }

    /// The front app's Dock tile: its bundle URL first, else its name —
    /// app tiles only.
    static func frontTileIndex(bundleURL: URL?, name: String?,
                               tiles: [(url: URL?, title: String?, isApp: Bool)]) -> Int? {
        func path(_ url: URL?) -> String? {
            guard let url else { return nil }
            let p = url.standardizedFileURL.path
            return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
        }
        if let wanted = path(bundleURL),
           let hit = tiles.indices.first(where: { tiles[$0].isApp && path(tiles[$0].url) == wanted }) {
            return hit
        }
        guard let name, !name.isEmpty else { return nil }
        return tiles.indices.first { tiles[$0].isApp && tiles[$0].title == name }
    }

    /// Where ⌥`'s walk starts: the app's next window — ⌥⇥'s "back to
    /// the other one" — else its only one. Minimized windows wait at
    /// the end of the walk.
    static func frontWalkStart(_ windows: [DockPreviewWindow]) -> Int? {
        let up = windows.filter { !$0.minimized }
        if up.count > 1 { return up[1].id }
        return up.first?.id ?? windows.first?.id
    }

    /// Whether the hovered card plays live: the opt-in is on, the card
    /// carries stills at all (thumbnails on, the grant given, not the
    /// compact list), and a minimized window only when the card
    /// captures those.
    static func streamsLive(liveCard: Bool, thumbnails: Bool, granted: Bool, compact: Bool,
                            minimized: Bool, offscreen: Bool) -> Bool {
        liveCard && thumbnails && granted && !compact && (!minimized || offscreen)
    }

    /// Whether a card click keeps the panel up: ⌥ held, DockDoor's
    /// keep-open-after-activating. ⌘ and ⌃ stay the system's.
    static func keepsPanelOpen(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.option, .command, .control]) == .option
    }

    /// Whether a click on an app's Dock icon should minimize it: the app
    /// was already in front before the click landed. The Dock activates
    /// a background app on the same click, so an activation stamped
    /// after the click is that click's own — never a minimize. An app
    /// whose activation was never seen (front since before launch) is
    /// judged by the front app alone.
    static func clickMinimizes(appPID: pid_t, frontmostPID: pid_t?,
                               lastActivation: (pid: pid_t, at: TimeInterval)?,
                               clickAt: TimeInterval) -> Bool {
        guard frontmostPID == appPID else { return false }
        guard let lastActivation, lastActivation.pid == appPID else { return true }
        return lastActivation.at < clickAt
    }

    /// A Dock-icon scroll in the flick's units: a trackpad's points as
    /// they come, a wheel's line steps scaled so about three notches make
    /// the same deliberate flick a short two-finger swipe does.
    static func scrollAmount(_ delta: CGFloat, precise: Bool) -> CGFloat {
        precise ? delta : delta * 20
    }

    /// "3:07", "1:02:45" — a playhead the way players print it.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Whether a hover should read the Now Playing feed at all: always
    /// for a known player; for any other app only while another surface
    /// already runs the feed — a hover never spawns the media helper
    /// just to find a browser isn't playing.
    static func readsMedia(appBundleID: String?, feedRunning: Bool) -> Bool {
        guard let appBundleID else { return false }
        return playerBundleIDs.contains(appBundleID) || feedRunning
    }

    /// The Calendar tile's bundle id — the only tile that earns the
    /// calendar row on its own (and offers the grant).
    static let calendarBundleID = "com.apple.iCal"

    /// The Calendar tile's glance: the rest of today — what's on now
    /// and what's next, up to `limit`, each with its own Join — else the
    /// next event inside the fetched 24 h, so an evening hover still
    /// names tomorrow's first meeting. `freeUntil` is set when nothing
    /// is on right now and something is still coming today.
    static func calendarGlance(_ events: [ShelfCalendarModel.Event], now: Date,
                               calendar: Calendar = .current,
                               limit: Int = 3) -> (events: [ShelfCalendarModel.Event], freeUntil: Date?) {
        let upcoming = events.filter { $0.end > now }.sorted { $0.start < $1.start }
        let startOfDay = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfDay)
            ?? startOfDay.addingTimeInterval(24 * 3600)
        let today = upcoming.filter { $0.start < endOfToday }
        guard let first = today.first else { return (Array(upcoming.prefix(1)), nil) }
        let busy = today.contains { $0.start <= now }
        return (Array(today.prefix(limit)), busy ? nil : first.start)
    }

    /// The apps a meeting link opens in, by the link's host — a Zoom,
    /// Teams, Webex or FaceTime tile offers Join on the event whose
    /// link is theirs, where you'd look just before the call.
    static let meetingHosts: [(suffix: String, bundleIDs: Set<String>)] = [
        ("zoom.us", ["us.zoom.xos"]),
        ("teams.microsoft.com", ["com.microsoft.teams2", "com.microsoft.teams"]),
        ("teams.live.com", ["com.microsoft.teams2", "com.microsoft.teams"]),
        ("webex.com", ["Cisco-Systems.Spark", "com.cisco.webexmeetingsapp"]),
        ("facetime.apple.com", ["com.apple.FaceTime"]),
    ]

    /// Whether `bundleID` is a meeting app some link could belong to.
    static func isMeetingApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return meetingHosts.contains { $0.bundleIDs.contains(bundleID) }
    }

    /// The meeting apps a link opens in: its host is the suffix or a
    /// subdomain of it (`us02web.zoom.us`), never a lookalike
    /// (`notzoom.us`).
    static func meetingBundleIDs(for url: URL?) -> Set<String> {
        guard let host = url?.host?.lowercased() else { return [] }
        return meetingHosts.reduce(into: Set<String>()) { out, entry in
            if host == entry.suffix || host.hasSuffix("." + entry.suffix) { out.formUnion(entry.bundleIDs) }
        }
    }

    /// A meeting app's row: the first of today's glance (or the next
    /// event) whose link opens in that app — one event, never a list.
    static func meetingEvent(for bundleID: String, in events: [ShelfCalendarModel.Event],
                             now: Date, calendar: Calendar = .current) -> ShelfCalendarModel.Event? {
        let glance = calendarGlance(events, now: now, calendar: calendar, limit: .max).events
        let pool = glance.isEmpty ? events.filter { $0.end > now }.sorted { $0.start < $1.start } : glance
        return pool.first { meetingBundleIDs(for: $0.url).contains(bundleID) }
    }

    /// DockDoor's Aero shake: a fast left-right-left wiggle of the
    /// pointer over a card. Counted as x-direction reversals past a
    /// step inside a sliding window — 3+ reversals in `window` is a
    /// shake. Fires once per rest (the caller resets on hover exit) so
    /// a held wiggle can't machine-gun minimise.
    struct ShakeDetector {
        private var lastX: CGFloat?
        private var direction = 0
        private var reversals = 0
        private var windowStart: TimeInterval = 0
        private var fired = false

        static let window: TimeInterval = 0.9
        static let step: CGFloat = 6
        static let needed = 3

        mutating func note(x: CGFloat, now: TimeInterval) -> Bool {
            guard !fired else { return false }
            if now - windowStart > Self.window {
                reversals = 0
                direction = 0
                windowStart = now
            }
            guard let last = lastX else {
                lastX = x
                return false
            }
            let dx = x - last
            guard abs(dx) >= Self.step else { return false }
            lastX = x
            let dir = dx > 0 ? 1 : -1
            if direction != 0, dir != direction { reversals += 1 }
            direction = dir
            if reversals >= Self.needed {
                fired = true
                return true
            }
            return false
        }

        mutating func reset() {
            lastX = nil
            direction = 0
            reversals = 0
            fired = false
        }
    }

    /// A trackpad flick on a card: vertical scroll deltas accumulate
    /// (normalised so "swipe down" means finger-down under either
    /// scroll direction); past `threshold` the flick lands as
    /// `.down` (minimise) or `.up` (restore). A pause or a reversal
    /// restarts the count so an accidental brush can't stack into one.
    struct SwipeAccumulator {
        enum Flick: Equatable { case down, up }
        private var total: CGFloat = 0
        private var lastAt: TimeInterval = 0

        static let threshold: CGFloat = 50
        static let idle: TimeInterval = 0.3

        mutating func note(deltaY: CGFloat, inverted: Bool,
                           now: TimeInterval) -> Flick? {
            // Finger-down is +deltaY under natural scrolling, -deltaY
            // under traditional; normalise to finger motion.
            let physical = inverted ? deltaY : -deltaY
            if now - lastAt > Self.idle || (total != 0 && (physical > 0) != (total > 0)) {
                total = 0
            }
            lastAt = now
            total += physical
            if total >= Self.threshold { total = 0; return .down }
            if total <= -Self.threshold { total = 0; return .up }
            return nil
        }
    }

    enum WindowMatch: Equatable {
        case matched(Int), ambiguous, none
    }

    /// Native IDs win. Without one, accept only an unambiguous frame or
    /// title match; two identical windows must not borrow each other's image.
    static func matchResult(scFrame: CGRect, scTitle: String?,
                            rows: [(frame: CGRect?, title: String)],
                            scWindowID: CGWindowID? = nil,
                            rowWindowIDs: [CGWindowID?] = [],
                            tolerance: CGFloat = 2) -> WindowMatch {
        guard rowWindowIDs.isEmpty || rowWindowIDs.count == rows.count else { return .none }
        if let scWindowID, !rowWindowIDs.isEmpty {
            let exact = rows.indices.filter { rowWindowIDs[$0] == scWindowID }
            if exact.count == 1 { return .matched(exact[0]) }
            if exact.count > 1 { return .ambiguous }
        }
        let eligible = rows.indices.filter {
            scWindowID == nil || rowWindowIDs.isEmpty || rowWindowIDs[$0] == nil
        }
        let frames = eligible.filter { index in
            guard let frame = rows[index].frame else { return false }
            return abs(frame.minX - scFrame.minX) <= tolerance
                && abs(frame.minY - scFrame.minY) <= tolerance
                && abs(frame.width - scFrame.width) <= tolerance
                && abs(frame.height - scFrame.height) <= tolerance
        }
        if frames.count == 1 { return .matched(frames[0]) }
        let pool = frames.isEmpty ? eligible : frames
        if let scTitle, !scTitle.isEmpty {
            let titles = pool.filter { rows[$0].title == scTitle }
            if titles.count == 1 { return .matched(titles[0]) }
            if titles.count > 1 { return .ambiguous }
        }
        return frames.count > 1 ? .ambiguous : .none
    }

    /// A preview's agents: card id → the session that window exclusively
    /// hosts, and every live session the app hosts at all (most urgent
    /// first). Nothing for a folder, a bare tile, or an app no session
    /// names as its host.
    static func agentMap(windows: [DockPreviewWindow], bundleID: String?,
                         marks: [DockAgentMark]) -> (cards: [Int: DockAgentMark], app: [DockAgentMark]) {
        guard let bundleID else { return ([:], []) }
        let hosted = marks.filter { $0.hosts.contains(bundleID) }
        guard !hosted.isEmpty else { return ([:], []) }
        let candidates = windows.map {
            DockAgentMatch.Candidate(key: String($0.id), bundleID: bundleID, title: $0.title)
        }
        var cards: [Int: DockAgentMark] = [:]
        for (key, mark) in DockAgentMatch.match(marks: hosted, candidates: candidates) {
            if let id = Int(key) { cards[id] = mark }
        }
        let app = hosted.filter(\.isLive).enumerated()
            .sorted { $0.element.urgency != $1.element.urgency
                ? $0.element.urgency < $1.element.urgency : $0.offset < $1.offset }
            .map(\.element)
        return (cards, app)
    }

    /// A live refresh's card list: the app's windows as they are now, in
    /// AX order, with each surviving window keeping its card id (so an
    /// in-flight action or thumbnail still lands on it) and its still.
    /// Survival is the native window id, else the same AX element —
    /// never a title, which is exactly what just changed.
    static func mergeWindows(old: [DockPreviewWindow], new: [DockPreviewWindow]) -> [DockPreviewWindow] {
        new.map { fresh in
            guard let prior = old.first(where: { sameWindow($0, fresh) }) else { return fresh }
            return DockPreviewWindow(id: prior.id, title: fresh.title, minimized: fresh.minimized,
                                     fullScreen: fresh.fullScreen, frame: fresh.frame,
                                     documentURL: fresh.documentURL, thumbnail: prior.thumbnail,
                                     element: fresh.element, windowID: fresh.windowID)
        }
    }

    static func sameWindow(_ a: DockPreviewWindow, _ b: DockPreviewWindow) -> Bool {
        if let x = a.windowID, let y = b.windowID { return x == y }
        if let x = a.element, let y = b.element { return x == y }
        return false
    }

    /// Whether a refresh changed anything the cards draw — a no-op burst
    /// (focus moving, a retitle to the same title) must not re-lay out.
    static func cardsDiffer(_ a: [DockPreviewWindow], _ b: [DockPreviewWindow]) -> Bool {
        guard a.count == b.count else { return true }
        return zip(a, b).contains { lhs, rhs in
            lhs.id != rhs.id || lhs.title != rhs.title || lhs.minimized != rhs.minimized
                || lhs.fullScreen != rhs.fullScreen
        }
    }

    /// Whether a live refresh earns a capture pass: a still-less card
    /// that just appeared, or one just back from the Dock. A card that
    /// was already there without a still had its pass — a terminal
    /// retitling every beat must not ask the window server each time.
    static func wantsStills(old: [DockPreviewWindow], new: [DockPreviewWindow]) -> Bool {
        new.contains { card in
            guard card.thumbnail == nil else { return false }
            guard let prior = old.first(where: { $0.id == card.id }) else { return true }
            return prior.minimized && !card.minimized
        }
    }

    /// "Only windows on this display": cards whose window's centre sits
    /// on `display` (Quartz space). Minimized and frameless windows stay
    /// — they belong to no display, and the filter never hides what it
    /// can't place.
    static func onDisplay(_ windows: [DockPreviewWindow], display: CGRect) -> [DockPreviewWindow] {
        windows.filter { window in
            guard !window.minimized, let frame = window.frame else { return true }
            return display.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    /// Aero shake's plan: minimise the shaken card's siblings, or — when
    /// every sibling is already down — bring them all back. nil with no
    /// sibling to move. `minimize` is the value each target is set to.
    static func shakePlan(_ windows: [DockPreviewWindow], shaken id: Int) -> (targets: [DockPreviewWindow], minimize: Bool)? {
        let others = windows.filter { $0.id != id }
        guard !others.isEmpty else { return nil }
        let restore = others.allSatisfy(\.minimized)
        return (others.filter { $0.minimized == restore }, !restore)
    }

    /// Close-all's split: windows hosting a working or waiting agent are
    /// kept — tidying terminals from the Dock must not end a run.
    static func closable(_ windows: [DockPreviewWindow],
                         agents: [Int: DockAgentMark]) -> (close: [DockPreviewWindow], keep: [DockPreviewWindow]) {
        var close: [DockPreviewWindow] = []
        var keep: [DockPreviewWindow] = []
        for window in windows {
            if agents[window.id]?.isLive == true { keep.append(window) } else { close.append(window) }
        }
        return (close, keep)
    }

    static func matchRow(scFrame: CGRect, scTitle: String?,
                         rows: [(frame: CGRect?, title: String)],
                         scWindowID: CGWindowID? = nil,
                         rowWindowIDs: [CGWindowID?] = [],
                         tolerance: CGFloat = 2) -> Int? {
        if case .matched(let index) = matchResult(
            scFrame: scFrame, scTitle: scTitle, rows: rows,
            scWindowID: scWindowID, rowWindowIDs: rowWindowIDs, tolerance: tolerance) {
            return index
        }
        return nil
    }

}

// MARK: - The Dock's AX tree

/// One application item in Apple's Dock list — frame in AX coordinates.
struct DockAXItem {
    /// The Dock's own tile class: `.app` tiles preview windows,
    /// `.folder` tiles (Downloads, Stacks) pop their directory's
    /// contents, `.minimizedWindow` tiles preview the window parked
    /// in them.
    enum Kind { case app, folder, minimizedWindow }

    /// The tile classes worth previewing — spacers, the separator and
    /// the Trash stay skipped.
    static func kind(forSubrole subrole: String?) -> Kind? {
        switch subrole {
        case "AXApplicationDockItem": return .app
        case "AXFolderDockItem": return .folder
        case "AXMinimizedWindowDockItem": return .minimizedWindow
        default: return nil
        }
    }
    let element: AXUIElement
    let frame: CGRect
    let title: String?
    /// `AXURL` — the file URL the tile points at, when the Dock shares it.
    let url: URL?
    /// `AXStatusLabel` — the tile's badge string ("3", "•"), nil when
    /// the app shows none. ActiveDock's unread dot, verbatim.
    let badge: String?
    let kind: Kind

    init(element: AXUIElement, frame: CGRect, title: String?, url: URL?,
         badge: String? = nil, kind: Kind = .app) {
        self.element = element
        self.frame = frame
        self.title = title
        self.url = url
        self.badge = badge
        self.kind = kind
    }
    /// Stable hover identity: the URL, else the title, else the slot —
    /// two tiles with one title (two copies of an app) still retarget.
    /// Minimized-window tiles carry no URL and can share a title (two
    /// "Untitled" windows), so theirs keeps the slot too.
    var hoverID: String {
        if kind == .minimizedWindow {
            return "window:\(title ?? "")@\(Int(frame.minX)),\(Int(frame.minY))"
        }
        return url?.path ?? title ?? "dock-item@\(Int(frame.minX))"
    }
}

/// The Dock's pid, kept rather than asked for: the preview tick re-reads
/// the Dock's list up to twenty times a second, and each read looked the
/// Dock up among every running app first. The workspace's launch and
/// terminate notices keep the answer; a read that found nothing at it
/// (`forget`) asks the workspace again, so a Dock relaunch no notice
/// reported still heals on the next read.
@MainActor
final class DockPIDCache {
    private var cached: pid_t?
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    /// The workspace query — the tests count it.
    private let lookUp: () -> pid_t?

    /// nil watches the shared workspace's notices.
    init(center: NotificationCenter? = nil,
         lookUp: @escaping () -> pid_t? = {
             NSRunningApplication.runningApplications(withBundleIdentifier: AppleDockReader.dockBundleID)
                 .first?.processIdentifier
         }) {
        let center = center ?? NSWorkspace.shared.notificationCenter
        self.center = center
        self.lookUp = lookUp
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            let launched = name == NSWorkspace.didLaunchApplicationNotification
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                let pid = app?.processIdentifier ?? 0
                MainActor.assumeIsolated {
                    self?.noteWorkspace(launched: launched, bundleID: bundleID, pid: pid)
                }
            })
        }
    }

    isolated deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    var pid: pid_t? {
        if let cached { return cached }
        cached = lookUp()
        return cached
    }

    func forget() { cached = nil }

    /// A workspace notice: the Dock's launch brings its new pid, its
    /// exit takes the old one away; any other app's is no news.
    func noteWorkspace(launched: Bool, bundleID: String?, pid: pid_t) {
        guard bundleID == AppleDockReader.dockBundleID else { return }
        cached = launched ? pid : nil
    }
}

/// Read-only queries against the Dock process's accessibility tree,
/// plus the window verbs a preview card offers. Every read fails soft
/// (nil / []) without Accessibility permission — the caller's
/// `AXIsProcessTrusted` gate decides whether that means "no dock" or
/// "no rights".
enum AppleDockReader {
    static let dockBundleID = "com.apple.dock"

    /// The Dock's pid, from `dockProcess` rather than a running-apps
    /// query each time the tick re-reads the list.
    @MainActor
    static func dockPID() -> pid_t? { dockProcess.pid }

    /// A read against the pid failed: ask the workspace again next time.
    @MainActor
    static func forgetDockPID() { dockProcess.forget() }

    @MainActor static let dockProcess = DockPIDCache()

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

    /// Every previewable tile in the list, in Dock order — app tiles
    /// preview windows, folder tiles (Downloads, Stacks) pop their
    /// directory's contents, minimized-window tiles preview the window
    /// they hold; spacers, the separator and the Trash are skipped.
    /// One walk; the caller keeps the result for a beat and hit-tests
    /// in memory, so the tick never re-walks the whole tree.
    static func items(list: AXUIElement) -> [DockAXItem] {
        axChildren(list).compactMap { child -> DockAXItem? in
            let subrole = axString(child, kAXSubroleAttribute)
            guard let kind = DockAXItem.kind(forSubrole: subrole) else { return nil }
            guard let frame = axFrame(child) else { return nil }
            let badge = axString(child, "AXStatusLabel")
            return DockAXItem(element: child, frame: frame,
                              title: axString(child, kAXTitleAttribute),
                              url: axURL(child),
                              badge: badge?.isEmpty == false ? badge : nil, kind: kind)
        }
    }

    /// The application tile under `point` (AX coordinates), or nil.
    static func item(list: AXUIElement, at point: CGPoint) -> DockAXItem? {
        items(list: list).first { $0.frame.contains(point) }
    }

    static func frame(of element: AXUIElement) -> CGRect? { axFrame(element) }

    /// Repeated AX references are one window; matching titles and frames
    /// are not. Stacked untitled windows must each keep their own card.
    static func uniqueWindowsByIdentity(_ windows: [DockPreviewWindow]) -> [DockPreviewWindow] {
        var seen = Set<AXUIElement>()
        var seenWindowIDs = Set<CGWindowID>()
        return windows.filter { window in
            if let id = window.windowID, !seenWindowIDs.insert(id).inserted { return false }
            guard let element = window.element else { return true }
            return seen.insert(element).inserted
        }
    }

    /// One app's windows as preview rows — AX gives the title, the
    /// frame (the thumbnail match key), the minimized flag, and the
    /// element a later click can raise, close or minimize.
    /// Per-list stamp folded into each row's `id`: plain indices repeat
    /// across fills, and a thumbnail write in flight during a retarget
    /// could then land on the next preview's same-indexed row. Stamped
    /// ids never repeat, so a stale writer finds no row to land on.
    @MainActor private static var rowStamp = 0

    @MainActor
    static func windows(pid: pid_t) -> [DockPreviewWindow] {
        windowsReading(pid: pid).windows
    }

    /// `windows(pid:)` plus whether the app failed to answer inside the
    /// half-second timeout — a hung app, which the switcher then stops
    /// asking for a while instead of paying the wait on every open.
    @MainActor
    static func windowsReading(pid: pid_t) -> (windows: [DockPreviewWindow], unresponsive: Bool) {
        windowsReading(pid: pid, stamp: nextStamp())
    }

    /// A fresh stamp for one app's rows — taken on main for a read that
    /// runs elsewhere (the switcher's side-by-side reads).
    @MainActor
    static func nextStamp() -> Int {
        rowStamp &+= 1
        return rowStamp << 20
    }

    /// The read itself, callable off the main thread (`DockAXWorker`):
    /// `stamp` is folded into each row's id — a caller that never shows
    /// the rows as cards (a ⌘⇥ commit's restore check) passes 0.
    static func windowsReading(pid: pid_t, stamp: Int) -> (windows: [DockPreviewWindow], unresponsive: Bool) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let elements = value as? [AXUIElement] else {
            return ([], status == .cannotComplete)
        }
        let windows: [DockPreviewWindow] = elements.enumerated().compactMap { index, element in
            // Sheets, drawers, floating palettes: not windows a person
            // switches to.
            let subrole = axString(element, kAXSubroleAttribute)
            if let subrole, subrole != "AXStandardWindow", subrole != "AXDialog" { return nil }
            let frame = axFrame(element)
            // A row without a real frame can never match a ScreenCaptureKit
            // window — it only renders as an empty card (same floor the
            // thumbnailer applies).
            guard let frame,
                  frame.width >= DockThumbnailer.minimumWindowEdge,
                  frame.height >= DockThumbnailer.minimumWindowEdge else { return nil }
            let title = axString(element, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Untitled window"
            return DockPreviewWindow(
                id: stamp | index,
                title: title,
                minimized: axBool(element, kAXMinimizedAttribute),
                fullScreen: fullScreenState(of: element),
                frame: frame,
                documentURL: documentURL(of: element),
                element: element, windowID: DockWindowIdentity.windowID(of: element))
        }
        return (uniqueWindowsByIdentity(windows), false)
    }

    /// Click a preview card: un-minimize if needed, raise the window,
    /// make it main, and bring the app forward. A card backed by a
    /// minimized-window Dock *tile* (its window never matched an AX
    /// row) answers only `AXPress` — the system's own restore — so the
    /// press goes out too; on a real window the action is unsupported.
    static func raise(_ window: DockPreviewWindow, app: NSRunningApplication?) {
        raiseWindow(window)
        // Plain activate: `.activateAllWindows` brought every window of
        // the app forward and buried the one that was picked.
        app?.activate()
    }

    /// `raise`'s AX half — the writes alone, so a commit can run them on
    /// `DockAXWorker` and activate from main after.
    static func raiseWindow(_ window: DockPreviewWindow) {
        guard let element = window.element else { return }
        if window.minimized {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                         false as CFTypeRef)
            AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
        AXUIElementPerformAction(element, "AXRaise" as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, true as CFTypeRef)
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

    /// The card's fullscreen verb: the window's own `AXFullScreen`
    /// write — the same attribute the green button toggles. Apps that
    /// never expose it (Finder) report the verb unsupported and the
    /// card hides it.
    @discardableResult
    static func setFullScreen(_ window: DockPreviewWindow, _ on: Bool) -> Bool {
        guard let element = window.element else { return false }
        return AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString,
                                            on as CFTypeRef) == .success
    }

    /// The tile verbs: `AXSize` then `AXPosition` in Quartz space —
    /// size first, since the position write clamps against the
    /// window's current extent and moving first can pin the old size's
    /// origin instead of the tile's.
    @discardableResult
    static func setFrame(_ window: DockPreviewWindow, _ frame: CGRect) -> Bool {
        guard let element = window.element else { return false }
        var origin = frame.origin
        var size = frame.size
        guard let originValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        let sized = AXUIElementSetAttributeValue(
            element, kAXSizeAttribute as CFString, sizeValue) == .success
        let moved = AXUIElementSetAttributeValue(
            element, kAXPositionAttribute as CFString, originValue) == .success
        return sized || moved
    }

    /// The window's `AXDocument` — the file it shows, when the app
    /// declares one. Cards carrying a document become drag sources:
    /// dropping the card on another app's Dock tile is macOS's own
    /// "open this in that app" (DockDoor's preview handoff).
    static func documentURL(of element: AXUIElement) -> URL? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXDocumentAttribute as CFString, &value) == .success
        else { return nil }
        if let url = value as? URL { return url.isFileURL ? url : nil }
        if let string = value as? String, !string.isEmpty {
            // Most apps report the document as a POSIX path.
            if string.hasPrefix("/") { return URL(fileURLWithPath: string) }
            return URL(string: string).flatMap { $0.isFileURL ? $0 : nil }
        }
        return nil
    }

    /// Whether `AXFullScreen` is there to write — and its value — read
    /// at list time so the card knows whether to offer the verb.
    /// Returns nil where the attribute is absent or not settable.
    static func fullScreenState(of element: AXUIElement) -> Bool? {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, "AXFullScreen" as CFString, &settable) == .success,
              settable.boolValue else { return nil }
        return axBool(element, "AXFullScreen")
    }

    /// One menu item as the New-window pick reads it.
    struct MenuItemFacts: Equatable {
        var title: String
        var cmdChar: String?
        /// `AXMenuItemCmdModifiers`: 0 is ⌘ alone; bits add ⇧ (1),
        /// ⌥ (2), ⌃ (4), and 8 means no ⌘ at all.
        var cmdModifiers: Int?
        var enabled: Bool
        var hasSubmenu = false
    }

    /// The item "New window" should press: an enabled leaf titled "New
    /// Window", else the enabled leaf the app itself binds to plain ⌘N
    /// (whatever it calls it). nil means the menu offers neither.
    static func newWindowItemIndex(_ items: [MenuItemFacts]) -> Int? {
        let leaves = items.indices.filter { items[$0].enabled && !items[$0].hasSubmenu }
        func normalized(_ title: String) -> String {
            title.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "….")))
                .lowercased()
        }
        if let titled = leaves.first(where: { normalized(items[$0].title) == "new window" }) {
            return titled
        }
        return leaves.first {
            items[$0].cmdChar?.uppercased() == "N" && (items[$0].cmdModifiers ?? 0) == 0
        }
    }

    /// Walk the app's menu bar (past the Apple menu, one submenu deep)
    /// for the New-window item. AX reads only — the press is the caller's.
    static func newWindowMenuItem(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) == .success,
              let bar = value, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var facts: [MenuItemFacts] = []
        var elements: [AXUIElement] = []
        func collect(_ menu: AXUIElement, depth: Int) {
            for item in axChildren(menu) {
                let submenu = axChildren(item).first
                let modifiers: Int? = {
                    var raw: AnyObject?
                    guard AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString,
                                                        &raw) == .success else { return nil }
                    return (raw as? NSNumber)?.intValue
                }()
                facts.append(MenuItemFacts(
                    title: axString(item, kAXTitleAttribute) ?? "",
                    cmdChar: axString(item, kAXMenuItemCmdCharAttribute),
                    cmdModifiers: modifiers,
                    enabled: axBool(item, kAXEnabledAttribute),
                    hasSubmenu: submenu != nil))
                elements.append(item)
                if let submenu, depth < 1 { collect(submenu, depth: depth + 1) }
            }
        }
        for top in axChildren(bar as! AXUIElement).dropFirst().prefix(6) {
            for menu in axChildren(top) { collect(menu, depth: 0) }
        }
        return newWindowItemIndex(facts).map { elements[$0] }
    }

    /// The header's "New": the app's own New Window menu item, pressed
    /// through AX — it works where ⌘N means New Document or isn't bound,
    /// and never types into whatever window has focus. Only when the
    /// menu offers neither does the old path run: post ⌘N to the app.
    /// The menu walk is dozens of AX reads against an app that may be
    /// busy — up to half a second each — so it runs on `DockAXWorker`;
    /// the activation it follows stays here.
    static func newWindow(app: NSRunningApplication?) {
        guard let app else { return }
        app.activate()
        let pid = app.processIdentifier
        DockAXWorker.run { pressNewWindow(pid: pid) }
    }

    /// `newWindow`'s AX half: press the menu's New-window item, else
    /// post ⌘N to the app.
    static func pressNewWindow(pid: pid_t) {
        if let item = newWindowMenuItem(pid: pid),
           AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
            return
        }
        // Virtual key 45 is 'n'. Posting to the pid lands the chord in
        // the app's own queue — a real event, and a pid-targeted post
        // asks for no scripting right.
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 45, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 45, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
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
    /// `AXFullScreen` state; nil where the window doesn't offer the
    /// write (Finder et al.) — the card hides the verb.
    var fullScreen: Bool?
    /// The window's frame in Quartz coordinates, when AX reports one.
    var frame: CGRect?
    /// The file the window shows (`AXDocument`), when it declares one —
    /// a card carrying a document drags it onto another app's Dock tile.
    var documentURL: URL? = nil
    var thumbnail: NSImage?
    /// The AX window element — the raise/close/minimize target. A card
    /// lives on the main actor; the switcher's commits carry the bare
    /// handle to `DockAXWorker` (`DockAXElement`) instead of the card.
    let element: AXUIElement?
    /// Native capture identity, when the OS exposes it.
    var windowID: CGWindowID? = nil
}

/// One entry in a folder pop (DockDoor's Folder Pop): the name, the
/// type icon and the URL a click opens. Ids are indices — a folder
/// fill is synchronous, there is no in-flight write to mis-land.
struct DockFolderEntry: Identifiable {
    let id: Int
    let name: String
    let url: URL
    let icon: NSImage
    let isDirectory: Bool
}

/// How a Dock folder tile is arranged — the stack's own Sort By, stored
/// as `arrangement` in the tile's `com.apple.dock` `persistent-others`
/// entry (1 Name, 2 Date Added, 3 Date Modified, 4 Date Created,
/// 5 Kind). The pop follows it, so Downloads leads with today's file.
enum DockFolderSort: Int, Equatable, Sendable {
    case name = 1, dateAdded = 2, dateModified = 3, dateCreated = 4, kind = 5

    /// The resource key a sort reads per entry — nil for Name, which
    /// needs nothing past `readdir`.
    var resourceKey: URLResourceKey? {
        switch self {
        case .name: return nil
        case .dateAdded: return .addedToDirectoryDateKey
        case .dateModified: return .contentModificationDateKey
        case .dateCreated: return .creationDateKey
        case .kind: return .localizedTypeDescriptionKey
        }
    }

    /// The tile's arrangement, read out of the Dock's `persistent-others`
    /// (read-only — nothing here writes `com.apple.dock`). A folder the
    /// list doesn't hold, or an arrangement it doesn't know, is Name.
    static func of(folder: URL, persistentOthers: [Any]?) -> DockFolderSort {
        let wanted = standardizedPath(folder)
        for case let tile as [String: Any] in persistentOthers ?? [] {
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String else { continue }
            let url = URL(string: string) ?? URL(fileURLWithPath: string)
            guard standardizedPath(url) == wanted else { continue }
            let raw = (data["arrangement"] as? NSNumber)?.intValue ?? 1
            return DockFolderSort(rawValue: raw) ?? .name
        }
        return .name
    }

    private static func standardizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// One folder row as the sort sees it.
    struct Row {
        let name: String
        let url: URL
        let isDir: Bool
    }

    /// Order rows the way the stack does: Name keeps directories first
    /// then Finder's name order; the date sorts run newest first; Kind
    /// groups by the type's description, then name. An entry the read
    /// couldn't date sinks to the end rather than guessing a place.
    func arrange(_ rows: [Row], date: (URL) -> Date?, kind: (URL) -> String?) -> [Row] {
        func byName(_ a: Row, _ b: Row) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        switch self {
        case .name:
            return rows.sorted {
                if $0.isDir != $1.isDir { return $0.isDir }
                return byName($0, $1)
            }
        case .kind:
            let kinds = Dictionary(rows.map { ($0.url, kind($0.url) ?? "") }, uniquingKeysWith: { a, _ in a })
            return rows.sorted {
                let a = kinds[$0.url] ?? "", b = kinds[$1.url] ?? ""
                if a != b { return a.localizedStandardCompare(b) == .orderedAscending }
                return byName($0, $1)
            }
        case .dateAdded, .dateModified, .dateCreated:
            let dates = Dictionary(rows.map { ($0.url, date($0.url)) }, uniquingKeysWith: { a, _ in a })
            return rows.sorted {
                switch (dates[$0.url] ?? nil, dates[$1.url] ?? nil) {
                case let (a?, b?): return a != b ? a > b : byName($0, $1)
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return byName($0, $1)
                }
            }
        }
    }
}

/// Where a folder pop's listing stands. `denied` is the TCC case —
/// the app lacks Files-and-Folders consent for Downloads/Desktop/
/// Documents, so the panel can offer the Settings shortcut rather
/// than pretending the folder is empty.
enum DockFolderState {
    case loading, ready, denied, failed
}

/// The off-main result of reading one folder: the capped entries,
/// the folder's own icon (resolved where a stall can't reach the UI)
/// and whether the read was refused outright.
struct DockFolderListing {
    var entries: [DockFolderEntry] = []
    var folderIcon: NSImage?
    var denied = false
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
    /// The tile's `AXStatusLabel` — the Dock's own unread badge, drawn
    /// on the header icon the way the tile draws it.
    var badge: String?
    /// Non-nil when the hovered tile is a folder: the panel pops the
    /// directory's entries instead of window cards.
    var folderURL: URL?
    /// The folders drilled into below `folderURL`, outermost first — the
    /// pop browses in place like Apple's Grid stack. Empty at the tile's
    /// own folder.
    var folderTrail: [URL] = []
    /// The folder the pop shows now: the deepest drilled one, else the
    /// tile's.
    var folderShown: URL? { folderTrail.last ?? folderURL }
    var folderEntries: [DockFolderEntry] = []
    /// The entries load off the main actor — a directory can stall
    /// (file provider, dead mount, a pending TCC consent) and the pop
    /// shows "Loading…" until they land or fail. Only read when
    /// `folderURL` is non-nil.
    var folderState: DockFolderState = .loading
    /// DockDoor's player row: while a media app's preview is up the
    /// panel subscribes to `MediaFeed` and shows what the system says
    /// that app is playing. nil until a track lands.
    var media: AlcoveMedia?
    /// The Calendar tile's glance (the rest of today, up to three), or a
    /// meeting app's one event whose link is its own — read only when
    /// JR-Bar already holds Full Calendar Access; a hover never prompts.
    var calendarEvents: [ShelfCalendarModel.Event] = []
    /// "Free until 3:30" — nothing on now, something later today.
    var calendarFreeUntil: Date?
    /// Calendar access was never asked: the row offers an explicit
    /// "Show events" button rather than reading unprompted.
    var calendarNeedsAuth = false
    var largeCards = false
    /// True when the window count passed `compactListLimit` — the
    /// panel lists titles instead of thumbnails and skips captures.
    var compact = false
    /// The keyboard-walked card — arrows move it, Return raises it.
    var selectedWindowID: Int?
    /// card id → the agent session that window exclusively hosts
    /// (`DockAgentMatch`) — the card's mark, ring and status line.
    var agents: [Int: DockAgentMark] = [:]
    /// Every live session this app hosts, matched to a card or not — the
    /// header's count, the ask rows and Quit's guard read it.
    var appAgents: [DockAgentMark] = []
    /// Cards a shake or flick just moved — they dip for a beat.
    var pulsedWindowIDs: Set<Int> = []
    /// A guarded close's first press: the card that rings and its line.
    var armedWindowID: Int?
    var armedNote: String?
    /// The header's one-line note: a guarded Quit's first press, or the
    /// windows Close all kept because an agent runs in them.
    var headerNote: String?
    /// Quit was asked and the app is still here a beat later — the
    /// header's power disc becomes Force Quit.
    var stillRunning = false

    /// The waiting sessions the ask rows offer, most urgent first,
    /// capped so a busy terminal can't grow the panel into a list.
    var askRows: [DockAgentMark] {
        Array(appAgents.filter { $0.isWaiting && $0.ask != nil }.prefix(3))
    }
}

// MARK: - Parking (pure, tested)

/// When nobody can point at the Dock — the displays asleep, the screen
/// locked, the session switched to another user — the preview tick has
/// nothing to watch, and it parked nothing: it woke main eight times a
/// second all night. Each notice flips its own fact; the tick parks when
/// the first one holds and resumes when the last one lets go.
struct DockTickPark: Equatable {
    enum Event: Equatable, Sendable {
        case displaysSlept, displaysWoke, locked, unlocked, sessionLeft, sessionReturned
    }

    enum Change: Equatable { case park, resume }

    static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    private(set) var displaysAsleep = false
    private(set) var locked = false
    private(set) var sessionInactive = false

    var parked: Bool { displaysAsleep || locked || sessionInactive }

    /// Apply a notice; the change it makes to the tick, if any.
    mutating func note(_ event: Event) -> Change? {
        let before = parked
        switch event {
        case .displaysSlept: displaysAsleep = true
        case .displaysWoke: displaysAsleep = false
        case .locked: locked = true
        case .unlocked: locked = false
        case .sessionLeft: sessionInactive = true
        case .sessionReturned: sessionInactive = false
        }
        guard parked != before else { return nil }
        return parked ? .park : .resume
    }
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
/// The TCC probes are cached: `AXIsProcessTrusted` for
/// `permissionTTL`, the Screen Recording preflight — a tccd round
/// trip on every call — through `FoldCapturePermission`'s shared
/// 30 s cache (see `refreshPermissions`). With the displays asleep, the
/// screen locked or the session switched away the timer parks
/// (`DockTickPark`).
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
    /// The minimum gap between Accessibility and magnification
    /// re-reads. Screen Recording keeps its own 30 s cache — see
    /// `refreshPermissions`.
    nonisolated static let permissionTTL: TimeInterval = 3

    static let pollInterval: TimeInterval = 0.05
    /// The cadence while the pointer is far from every screen edge a
    /// Dock could live on — 8 Hz keeps the idle read near-free (the
    /// AX walk stays TTL-bound, not poll-bound) while halving the
    /// worst-case wait before a dock-ward pointer is noticed.
    nonisolated static let farPollInterval: TimeInterval = 0.125
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
    nonisolated static let listSlop: CGSize = CGSize(width: 20, height: 96)
    /// The list frame inflated by `listSlop` — the "over the dock"
    /// reach the tick's hit-test, the frame cache's freshness rule,
    /// the quick-quit hit-test and the poll cadence all share.
    nonisolated static func listReach(of frame: CGRect) -> CGRect {
        frame.insetBy(dx: -listSlop.width, dy: -listSlop.height)
    }

    @ObservationIgnored private var timer: Timer?
    /// Displays asleep, locked, switched away: the tick stops until the
    /// matching wake (`DockTickPark`).
    @ObservationIgnored private(set) var presence = DockTickPark()
    @ObservationIgnored private var presenceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var lockObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var panelWarmupTimer: Timer?
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
    /// Apple's Dock magnification, re-read with the permission probe.
    /// Under magnification the tiles' Accessibility frames are the
    /// unmagnified layout while the icons slide under the pointer: a
    /// panel centred on the frame sat 200 pt off the icon (measured:
    /// tile 288–325, pointer 542). The pointer is where the icon is.
    @ObservationIgnored private var magnificationOn = false
    /// The list's app tiles, read once per `itemsTTL` for the list
    /// frame they were read under.
    @ObservationIgnored private var cachedItems: (listFrame: CGRect, items: [DockAXItem], at: TimeInterval)?
    /// The tile the visible panel is anchored to and the edge it opens
    /// from — re-anchored every tick while the pointer stays on the
    /// tile, so a Dock still sliding in carries the panel with it and
    /// a size measured before the content settled is corrected a beat
    /// later.
    @ObservationIgnored private var anchor: (item: DockAXItem, edge: DockEdge, screen: CGRect)?

    /// The hold that keeps an auto-hiding Dock out while the panel is
    /// up — injectable; the default resolves the CoreDock verbs.
    @ObservationIgnored let autohideHold: DockAutohideHold
    /// ⌥⇥ — the utility's window switcher, DockDoor's other half. The
    /// Dock utility owns its lifecycle (it runs with the previews parked
    /// too); the watcher only borrows its key tap for the preview's keys.
    @ObservationIgnored let switcher: DockSwitcherController
    /// The quick-quit watch: ⌘+right-click on a Dock tile. A global
    /// monitor (observe-only — the Dock's own menu still opens).
    @ObservationIgnored private var quickQuitMonitor: Any?
    /// The Middle Click trigger's watch — only while that trigger is picked.
    @ObservationIgnored private var middleClickMonitor: Any?
    /// Scroll on a Dock icon — only while scroll gestures are on.
    @ObservationIgnored private var scrollMonitor: Any?
    /// Click the front app's icon — only while click-to-minimize is on.
    @ObservationIgnored private var clickMonitor: Any?
    /// The last app activation seen, stamped in system uptime — the
    /// click-to-minimize rule's "was it already in front".
    @ObservationIgnored private var lastActivation: (pid: pid_t, at: TimeInterval)?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// The scroll gesture's running total, per tile.
    @ObservationIgnored private var scrollFlick = DockEnhanceMath.SwipeAccumulator()
    @ObservationIgnored private var scrollTile: String?
    /// The `MediaFeed` reader a player tile's preview holds — started
    /// on show, released on hide, so the perl helper only lives while
    /// a media card is actually up.
    @ObservationIgnored private var mediaToken: UUID?
    /// The daemon's live sessions as marks — wired by `DockUtility`.
    @ObservationIgnored var agentMarks: @MainActor () -> [DockAgentMark] = { [] }
    /// The notch Shelf's tray — wired by the app delegate. A folder
    /// chip or a document card's "Send to Shelf" stages the file there.
    @ObservationIgnored var sendToShelf: (@MainActor ([URL]) -> Void)? {
        didSet { wireShelf() }
    }

    private func wireShelf() {
        guard let panel else { return }
        guard let send = sendToShelf else {
            panel.actions.onSendToShelf = nil
            return
        }
        panel.actions.onSendToShelf = { url in send([url]) }
    }

    /// The notch Shelf's synced lyrics for the playing track — wired by
    /// the app delegate; the player row shows its current line.
    @ObservationIgnored var lyrics: @MainActor () -> SyncedLyrics? = { nil } {
        didSet { panel?.actions.lyrics = lyrics }
    }
    /// × / Quit on a window or app hosting a live agent needs a second press.
    @ObservationIgnored private var agentGuard = DockAgentGuard()
    /// The open panel's live list — the previewed app's window events.
    @ObservationIgnored private let windowObserver = DockWindowObserver()
    /// The quick-quit tiles last mirrored into the switcher's tap, and
    /// the tile read they came from.
    @ObservationIgnored private var mirroredQuitTargets: [CGRect] = []
    @ObservationIgnored private var quitTargetsStamp: (at: TimeInterval, listFrame: CGRect)?
    /// Tile URL → bundle id, so the mirror never re-opens a bundle it
    /// already read. A tile no bundle answers for stays nil.
    @ObservationIgnored private var tileBundleIDs: [URL: String?] = [:]
    /// The preview action keys last mirrored into the tap.
    @ObservationIgnored private var mirroredChars: Set<String> = []
    /// Windows whose hovered still is being re-taken — one capture each.
    @ObservationIgnored private var freshening = Set<CGWindowID>()
    /// The opt-in live card's stream — at most one window at a time.
    @ObservationIgnored private let liveStill = DockLiveStill()
    /// A preview ⌥` opened from the keyboard: the pointer never rested
    /// on its tile, so the rest-and-grace rules don't close it — Esc,
    /// Return, a click away or resting on another tile do.
    @ObservationIgnored private var keyboardPinned = false

    /// Default-argument expressions are evaluated in the caller's
    /// (nonisolated) context under Swift 6, so the main-actor
    /// `DockEnhancePreferences()` can't be a default value — callers
    /// pass nil and the main-actor body builds it.
    init(preferences: DockEnhancePreferences? = nil,
         autohideHold: DockAutohideHold? = nil,
         switcher: DockSwitcherController? = nil) {
        self.preferences = preferences ?? DockEnhancePreferences()
        self.autohideHold = autohideHold ?? DockAutohideHold()
        self.switcher = switcher ?? DockSwitcherController()
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
        watchers.onKey = { [weak self] keyCode in
            self?.panelKey(keyCode) ?? false
        }
        // The switcher's event tap eats the preview's keys while the
        // panel floats — the watchers only fire with the pointer on
        // the panel, the tap fires with it parked on the Dock too.
        self.switcher.onPreviewKey = { [weak self] code in
            self?.previewTapKey(code)
        }
        self.switcher.onQuickQuit = { [weak self] point, force in
            self?.quickQuit(axPoint: point, force: force)
        }
        self.switcher.onPreviewAction = { [weak self] action in
            self?.previewAction(action)
        }
        self.switcher.onFrontPreview = { [weak self] in self?.previewFrontApp() }
        self.switcher.cachedBadges = { [weak self] in self?.freshBadges() }
        windowObserver.onChange = { [weak self] in self?.refreshLiveWindows() }
        liveStill.onFrame = { [weak self] windowID, image in
            guard let self, let row = self.preview.windows.firstIndex(where: { $0.windowID == windowID })
            else { return }
            self.preview.windows[row].thumbnail = image
        }
    }

    isolated deinit {
        timer?.invalidate()
        panelWarmupTimer?.invalidate()
        unwatchPresence()
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        refreshPermissions(force: true)
        if !accessibilityTrusted {
            // Register + prompt once: nothing else ever calls the
            // prompting API, so a stale or missing TCC entry (a
            // re-signed reinstall loses the grant silently) used to
            // leave the preview dead with no path back but manual
            // pane surgery. With an entry already decided this is a
            // cheap no-op — the system prompts only on an undecided one.
            _ = AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if !screenCaptureGranted && preferences.showThumbnails {
            // The same registration gap: CGPreflightScreenCaptureAccess
            // never creates the pane entry, so a missing grant left the
            // thumbnails on "No preview" with nothing for the user to
            // toggle. Requesting once registers JR-Bar and prompts only
            // while the answer is still undecided.
            screenCaptureGranted = FoldCapturePermission.request()
        }
        Self.log.notice("enhance start: accessibility \(self.accessibilityTrusted, privacy: .public), screen recording \(self.screenCaptureGranted, privacy: .public), dock list \(AppleDockReader.dockPID().flatMap { AppleDockReader.dockList(pid: $0) } != nil, privacy: .public)")
        quickQuitMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard event.modifierFlags.contains(.command) else { return }
            let force = event.modifierFlags.contains(.option)
            let point = NSEvent.mouseLocation
            Task { @MainActor [weak self] in self?.quickQuit(at: point, force: force) }
        }
        installGestureMonitors()
        watchPresence()
        scheduleTick(after: Self.pollInterval)
        schedulePanelWarmup(layoutOnly: panel != nil)
    }

    /// The sleep, lock and session notices the tick parks on — for as
    /// long as the watcher runs.
    private func watchPresence() {
        guard presenceObservers.isEmpty, lockObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let notices: [(Notification.Name, DockTickPark.Event)] = [
            (NSWorkspace.screensDidSleepNotification, .displaysSlept),
            (NSWorkspace.screensDidWakeNotification, .displaysWoke),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionLeft),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionReturned),
        ]
        for (name, event) in notices {
            presenceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.notePresence(event) }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        let lockNotices: [(Notification.Name, DockTickPark.Event)] = [
            (DockTickPark.lockedNotification, .locked),
            (DockTickPark.unlockedNotification, .unlocked),
        ]
        for (name, event) in lockNotices {
            lockObservers.append(distributed.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.notePresence(event) }
            })
        }
    }

    private func unwatchPresence() {
        for observer in presenceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in lockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        presenceObservers = []
        lockObservers = []
        presence = DockTickPark()
    }

    /// A sleep, lock or session notice: the tick parks when the first
    /// reason holds — an open preview closes with it and lets the Dock
    /// go — and comes back at its near rate when the last one lifts.
    func notePresence(_ event: DockTickPark.Event) {
        switch presence.note(event) {
        case .park?:
            timer?.invalidate()
            timer = nil
            if tracker.shown != nil {
                tracker.reset()
                hidePreview()
            }
            Self.log.notice("preview tick parked: \(String(describing: event), privacy: .public)")
        case .resume?:
            guard running else { return }
            Self.log.notice("preview tick resumed: \(String(describing: event), privacy: .public)")
            scheduleTick(after: Self.pollInterval)
        case nil:
            break
        }
    }

    /// Whether the pointer poll is armed — the tests read it.
    var isTicking: Bool { timer != nil }

    /// The Dock-icon gestures the card asks for: a middle-click monitor
    /// under the Middle Click trigger, a scroll monitor with scroll
    /// gestures on. Observe-only global monitors — Apple's Dock ignores
    /// both, nothing is eaten or synthesized — re-seated on every
    /// settings apply so a card edit lands without a restart.
    func installGestureMonitors() {
        let wantsClick = running && preferences.previewTrigger == .middleClick
        if wantsClick, middleClickMonitor == nil {
            middleClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                guard event.buttonNumber == 2 else { return }
                let point = NSEvent.mouseLocation
                Task { @MainActor [weak self] in self?.middleClick(at: point) }
            }
        } else if !wantsClick, let monitor = middleClickMonitor {
            NSEvent.removeMonitor(monitor)
            middleClickMonitor = nil
        }
        let wantsScroll = running && preferences.scrollGestures
        if wantsScroll, scrollMonitor == nil {
            scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard event.momentumPhase == [] else { return }
                let deltaY = DockEnhanceMath.scrollAmount(event.scrollingDeltaY,
                                                          precise: event.hasPreciseScrollingDeltas)
                let inverted = event.isDirectionInvertedFromDevice
                let now = event.timestamp
                let point = NSEvent.mouseLocation
                Task { @MainActor [weak self] in
                    self?.scroll(at: point, deltaY: deltaY, inverted: inverted, now: now)
                }
            }
        } else if !wantsScroll, let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        let wantsMinimize = running && preferences.clickToMinimize
        if wantsMinimize, clickMonitor == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .processIdentifier
                let at = ProcessInfo.processInfo.systemUptime
                MainActor.assumeIsolated {
                    if let pid { self?.lastActivation = (pid, at) }
                }
            }
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return }
                let point = NSEvent.mouseLocation
                let at = event.timestamp
                Task { @MainActor [weak self] in self?.clickToMinimize(at: point, clickAt: at) }
            }
        } else if !wantsMinimize, let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
            if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
            activationObserver = nil
            lastActivation = nil
        }
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        unwatchPresence()
        panelWarmupTimer?.invalidate()
        panelWarmupTimer = nil
        tracker.reset()
        cachedList = nil
        mirroredQuitTargets = []
        quitTargetsStamp = nil
        switcher.setQuickQuitTargets([])
        if let quickQuitMonitor { NSEvent.removeMonitor(quickQuitMonitor) }
        quickQuitMonitor = nil
        installGestureMonitors()
        hidePreview()
    }

    /// The card's appear hook and the tick's gate: re-read TCC only
    /// when the cache is stale (or `force`). Accessibility and the
    /// magnification flag ride the tick's TTL — neither costs an IPC
    /// after the first call. The Screen Recording preflight costs one
    /// every call (2026-09-22: a TCCAccessRequest line on the main
    /// thread every 3.02 s for as long as the app ran), and nothing on
    /// the tick needs it — only thumbnails and the card's row do. So
    /// the tick takes the shared 30 s cache — dropped on re-activate,
    /// when a new grant lands — and only `force` (start, the card
    /// appearing) asks TCC outright.
    func refreshPermissions(force: Bool = false) {
        guard force || Date().timeIntervalSince(permissionsCheckedAt) > Self.permissionTTL else { return }
        permissionsCheckedAt = Date()
        let wasTrusted = accessibilityTrusted
        accessibilityTrusted = AXIsProcessTrusted()
        screenCaptureGranted = force ? FoldCapturePermission.recheck() : FoldCapturePermission.granted
        magnificationOn = UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "magnification") ?? false
        if running, !wasTrusted, accessibilityTrusted {
            schedulePanelWarmup(layoutOnly: panel != nil)
        }
    }

    /// Prepare the retained, empty panel before the first hover. Default
    /// run-loop mode avoids doing this while a menu or drag is tracking.
    /// Separate turns keep construction and first layout from forming one
    /// long synchronous operation. Nothing is shown or captured here.
    private func schedulePanelWarmup(layoutOnly: Bool) {
        panelWarmupTimer?.invalidate()
        let timer = Timer(timeInterval: layoutOnly ? 0.1 : 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panelWarmupTimer = nil
                guard self.running, self.accessibilityTrusted else { return }
                let start = ProcessInfo.processInfo.systemUptime
                if layoutOnly {
                    guard let panel = self.panel, !panel.isVisible else { return }
                    _ = panel.fittingSize()
                } else {
                    guard self.panel == nil else { return }
                    _ = self.ensurePanel()
                    self.schedulePanelWarmup(layoutOnly: true)
                }
                let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
                Self.log.notice("preview warmup \(layoutOnly ? "layout" : "construction", privacy: .public): \(milliseconds, privacy: .public) ms")
            }
        }
        panelWarmupTimer = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    /// The frame a panel anchors on: the tile's, or under magnification
    /// the tile's size at the pointer along the dock's run — x for a
    /// bottom Dock, y for a side one.
    private func anchorFrame(for item: DockAXItem, edge: DockEdge, pointer: NSPoint) -> CGRect {
        let tile = DockEnhanceMath.appKitRect(item.frame, mainScreenHeight: Self.mainScreenHeight())
        // A keyboard-opened preview: the pointer isn't on the Dock, so
        // nothing is magnified and the tile's own frame is the icon.
        guard magnificationOn, !keyboardPinned else { return tile }
        return DockEnhanceMath.magnifiedAnchor(tile: tile, edge: edge, pointer: pointer)
    }

    // MARK: The tick

    /// One-shot, re-armed at the cadence the pointer's position earns:
    /// 20 Hz near a screen edge, inside the dock's own reach, or while
    /// a panel is up — the band a first hover can land in — 8 Hz
    /// elsewhere. In-reach polling pays the same per-tick cost the
    /// pointer already costs while resting on the Dock; the far band
    /// stays cheap. Parked (`presence`), nothing is re-armed.
    private func scheduleTick(after interval: TimeInterval) {
        self.timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running, !self.presence.parked else { return }
                self.tick()
                let axPoint = DockEnhanceMath.axPoint(NSEvent.mouseLocation, mainScreenHeight: Self.mainScreenHeight())
                let overDock = self.cachedList.map { Self.listReach(of: $0.frame).contains(axPoint) } ?? false
                let near = Self.nearScreenEdge(axPoint) || overDock
                    || self.tracker.shown != nil || self.pointerInPanel()
                self.scheduleTick(after: near ? Self.pollInterval : Self.farPollInterval)
            }
        }
        // A tenth of the period (5 ms near, 12.5 ms far) lets these
        // wakes coalesce with the system's own; a hover never feels it.
        timer.tolerance = interval / 10
        self.timer = timer
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
            if Self.listReach(of: list.frame).contains(axPoint) {
                hovered = tiles(of: list).first { $0.frame.contains(axPoint) }
            }
        }
        // The tap decides synchronously whether a ⌘-right-click is a
        // quick quit — it reads this mirror, not the main-actor cache.
        mirrorQuickQuitTargets()
        mirrorPreviewChars(pointerInPanel: inPanel)
        let tracked = DockHoverTracker.trackedItem(
            hovered?.hoverID, shown: tracker.shown, trigger: preferences.previewTrigger,
            optionHeld: NSEvent.modifierFlags.contains(.option))
        // A keyboard-opened preview holds like one with the pointer on it.
        let action = tracker.note(hovered: tracked, pointerInPanel: inPanel || keyboardPinned,
                                  now: CACurrentMediaTime(), delay: preferences.previewDelay)
        switch action {
        case .show:
            if let hovered {
                keyboardPinned = false
                showPreview(for: hovered)
            }
        case .hide:
            hidePreview()
        case .none:
            if let hovered, hovered.hoverID == tracker.shown { anchorPanel(to: hovered) }
        }
    }

    /// Mirror the tiles quick quit can act on into the tap, re-derived
    /// only when the tile read or the list's frame changed: the tick
    /// re-reads the tiles whenever the pointer is in the Dock's reach,
    /// so a ⌘-right-click on a tile always meets a fresh mirror. A list
    /// that moved or hid since its tiles were read mirrors nothing.
    private func mirrorQuickQuitTargets() {
        var targets: [CGRect] = []
        if let list = cachedList, let cached = cachedItems, cached.listFrame == list.frame {
            if let stamp = quitTargetsStamp, stamp.at == cached.at, stamp.listFrame == list.frame {
                return
            }
            quitTargetsStamp = (cached.at, list.frame)
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            targets = Self.quickQuitTargets(
                cached.items.map { ($0.frame, $0.kind, $0.url.flatMap(bundleID(forTile:))) },
                running: running)
        } else {
            quitTargetsStamp = nil
        }
        guard targets != mirroredQuitTargets else { return }
        mirroredQuitTargets = targets
        switcher.setQuickQuitTargets(targets)
    }

    /// The frames a ⌘-right-click is eaten over: the tiles quick quit
    /// acts on — a running app that isn't JR-Bar. Folders, the Trash, a
    /// pinned app that isn't running and the air above the tiles all
    /// keep their click, and so does the window under them.
    static func quickQuitTargets(_ tiles: [(frame: CGRect, kind: DockAXItem.Kind, bundleID: String?)],
                                 running: Set<String>) -> [CGRect] {
        tiles.compactMap { tile in
            guard tile.kind == .app, let id = tile.bundleID, running.contains(id),
                  !MenuBarUtility.isOwnFamily(id) else { return nil }
            return tile.frame
        }
    }

    private func bundleID(forTile url: URL) -> String? {
        if let known = tileBundleIDs[url] { return known }
        let id = Bundle(url: url)?.bundleIdentifier
        tileBundleIDs[url] = .some(id)
        return id
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

    /// The Dock's unread badges from the tile read the tick keeps, while
    /// it is inside `itemsTTL` — the ⌥⇥ strip's cards take them without
    /// a walk of their own. nil once the read has aged.
    func freshBadges(now: TimeInterval = CACurrentMediaTime()) -> [String: String]? {
        guard let cached = cachedItems, now - cached.at < Self.itemsTTL else { return nil }
        return DockSwitcherList.badges(of: cached.items)
    }

    static let log = Logger(subsystem: "devin.jrbar", category: "dock")

    /// The dock list, re-read from AX when the cache is stale or the
    /// pointer is inside the last known frame (a magnified or moved
    /// Dock reflows its list, and only a live read follows it).
    private func dockList(near point: CGPoint) -> (element: AXUIElement, frame: CGRect)? {
        let now = CACurrentMediaTime()
        if let cached = cachedList {
            let inside = Self.listReach(of: cached.frame).contains(point)
            let ttl = Self.nearScreenEdge(point) ? Self.edgeListFrameTTL : Self.listFrameTTL
            if !inside, now - cached.at < ttl {
                return (cached.element, cached.frame)
            }
        }
        guard let pid = AppleDockReader.dockPID(),
              let list = AppleDockReader.dockList(pid: pid),
              let frame = AppleDockReader.frame(of: list) else {
            // A Dock that relaunched unannounced answers nothing at the
            // pid kept for it — the next read asks the workspace again.
            AppleDockReader.forgetDockPID()
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
        let pointer = NSEvent.mouseLocation
        if panel.frame.insetBy(dx: -4, dy: -4).contains(pointer) { return true }
        // The panel owns the screen's centre now — the road from the
        // tile to it crosses open desk, and a pointer on that road is
        // travelling, not leaving.
        guard let anchor else { return false }
        let itemFrame = anchorFrame(for: anchor.item, edge: anchor.edge, pointer: pointer)
        return DockEnhanceMath.inCorridor(item: itemFrame, panel: panel.frame,
                                          edge: anchor.edge, point: pointer, slop: 6)
    }

    private static func mainScreenHeight() -> CGFloat {
        // The primary screen is the one holding the global origin.
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?
            .frame.height ?? 0
    }

    // MARK: Show / hide

    private func showPreview(for item: DockAXItem) {
        generation += 1
        liveStill.stop()
        let generationAtShow = generation
        if let mediaToken { MediaFeed.shared.unsubscribe(mediaToken) }
        mediaToken = nil
        preview.largeCards = preferences.largePreviews
        fill(preview, for: item)

        // Nothing to preview — no windows to raise — is no panel. A
        // running app with no windows earned a header-only chip on
        // every pass before; an app not running has the Dock's own
        // click to open it. A folder tile pops even when empty — the
        // pop is the point of the hover — and a player or the Calendar
        // tile earns its row even without a window. The tracker keeps
        // the tile as shown, so this does not retry on every tick.
        let earnsRow = preview.bundleID.map {
            DockEnhanceMath.playerBundleIDs.contains($0)
                || $0 == DockEnhanceMath.calendarBundleID
        } ?? false
        guard !preview.windows.isEmpty || preview.folderURL != nil || earnsRow else {
            hidePreview()
            return
        }
        preview.compact = DockEnhanceMath.compactList(
            windowCount: preview.windows.count, limit: preferences.compactListLimit)

        // Hold an auto-hiding Dock out for the life of the panel —
        // without it the Dock slides away the moment the pointer steps
        // from an icon onto the cards.
        if preferences.holdDockOpen { autohideHold.hold() }

        let mainHeight = Self.mainScreenHeight()
        // The screen under the pointer: a sliding Dock's tiles report
        // below the screen, where no screen contains them.
        let pointer = NSEvent.mouseLocation
        let tile = DockEnhanceMath.appKitRect(item.frame, mainScreenHeight: mainHeight)
        // A keyboard-opened preview belongs to the tile's screen, not the
        // pointer's — an auto-hidden Dock's tile sits below it, so its
        // run along the screen's width decides.
        let tileScreen = keyboardPinned
            ? NSScreen.screens.first { $0.frame.contains(CGPoint(x: tile.midX, y: tile.midY)) }
                ?? NSScreen.screens.first { $0.frame.minX <= tile.midX && tile.midX < $0.frame.maxX }
            : nil
        let screen = tileScreen
            ?? NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.screens.first { $0.frame.contains(tile.origin) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? .zero
        let listFrame = cachedList.map {
            DockEnhanceMath.appKitRect($0.frame, mainScreenHeight: mainHeight)
        } ?? tile
        let edge = DockEnhanceMath.dockEdge(listFrame: listFrame, screen: screenFrame)
        let itemFrame = anchorFrame(for: item, edge: edge, pointer: pointer)
        anchor = (item, edge, screenFrame)

        let panel = ensurePanel()
        let size = panel.fittingSize()
        let target = DockEnhanceMath.panelFrame(
            anchor: itemFrame, edge: edge, size: size,
            screen: screenFrame, gap: Self.panelGap,
            labelClearance: DockEnhanceMath.nativeLabelClearance(
                title: preview.appName, edge: edge))
        panel.present(frame: target, dockedAt: edge)
        watchers.start(escape: true, clickAway: true)
        switcher.setPreviewOpen(true)
        // An app tile's cards follow the app while the panel is up — a
        // window opened or closed elsewhere lands without a re-hover. A
        // minimized-window tile previews its one window, never the list.
        if item.kind == .app, let pid = preview.processIdentifier {
            windowObserver.observe(pid: pid, windows: preview.windows.compactMap(\.element))
        } else {
            windowObserver.stop()
        }

        // A folder's entries list on a background queue — one stall
        // inside the directory must never reach the main thread. The
        // generation check is the same stale-guard the thumbnails use.
        // The sleep races the read: a TCC consent that cannot prompt
        // (~5s auth pend) or a stuck vnode resolves to `failed` rather
        // than an eternal spinner; the abandoned read's write-back is
        // generation-guarded away.
        if let folderURL = preview.folderURL {
            // The tile's own Sort By — a read of the Dock's preferences,
            // never a write — so the pop leads where the stack does, and
            // so does every folder drilled into from it.
            folderSort = DockFolderSort.of(
                folder: folderURL,
                persistentOthers: UserDefaults(suiteName: AppleDockReader.dockBundleID)?
                    .array(forKey: "persistent-others"))
            loadFolder(folderURL, generation: generationAtShow)
        }

        // A player tile subscribes to the shared Now Playing feed for
        // the life of its panel — any app tile too while another surface
        // already runs the feed; the reader applies the bundle match —
        // a track from a different app never lands on this one.
        if let bundleID = preview.bundleID,
           DockEnhanceMath.readsMedia(appBundleID: bundleID, feedRunning: MediaFeed.shared.isRunning) {
            mediaToken = MediaFeed.shared.subscribe { [weak self] media in
                guard let self, self.generation == generationAtShow else { return }
                self.preview.media = media.flatMap {
                    DockEnhanceMath.showsMediaRow(
                        mediaBundleID: $0.bundleIdentifier,
                        appBundleID: bundleID) ? $0 : nil
                }
                self.reframe()
            }
        }

        // The Calendar tile: read the rest of today only when the grant
        // already exists — a hover never prompts, it offers. A meeting
        // app's tile reads too, but only under an existing grant: it
        // never offers one.
        if let bundleID = preview.bundleID, DockEnhanceMath.isMeetingApp(bundleID),
           EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            loadCalendarRow(generation: generationAtShow, meetingApp: bundleID)
        }
        if preview.bundleID == DockEnhanceMath.calendarBundleID {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess:
                loadCalendarRow(generation: generationAtShow)
            case .notDetermined, .writeOnly:
                preview.calendarNeedsAuth = true
            case .denied, .restricted:
                break
            @unknown default:
                break
            }
        }

        if preferences.showThumbnails, !preview.compact, screenCaptureGranted,
           let pid = preview.processIdentifier {
            let bundleID = preview.bundleID
            // A minimized-window tile is one window the pointer chose —
            // its single still is taken even with "Capture every
            // window" off, so the card shows what's inside, not an icon.
            let offscreen = preferences.includeOffscreenWindows || item.kind == .minimizedWindow
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
        keyboardPinned = false
        liveStill.stop()
        anchor = nil
        windowObserver.stop()
        if let mediaToken { MediaFeed.shared.unsubscribe(mediaToken) }
        mediaToken = nil
        watchers.stop()
        switcher.setPreviewOpen(false)
        panel?.dismiss()
        autohideHold.release()
    }

    /// The open pop's sort — the tile's, read at show.
    @ObservationIgnored private var folderSort: DockFolderSort = .name

    /// List one folder into the pop. The generation check is the stale
    /// guard the thumbnails use, and the folder check drops a listing
    /// the pop has since drilled or backed away from. The sleep races
    /// the read: a TCC consent that cannot prompt (~5s auth pend) or a
    /// stuck vnode resolves to `failed` rather than an eternal spinner.
    private func loadFolder(_ url: URL, generation generationAtLoad: Int) {
        preview.folderState = .loading
        preview.folderEntries = []
        let sort = folderSort
        Task { @MainActor [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                Self.folderListing(of: url, sort: sort)
            }
            let listing = await withTaskGroup(
                of: DockFolderListing?.self,
                returning: DockFolderListing?.self
            ) { group in
                group.addTask { await work.value }
                group.addTask {
                    try? await Task.sleep(for: .seconds(6))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let self, self.generation == generationAtLoad,
                  self.preview.folderShown == url else { return }
            if let listing {
                self.preview.folderEntries = listing.entries
                if let icon = listing.folderIcon { self.preview.icon = icon }
                self.preview.folderState = listing.denied ? .denied : .ready
            } else {
                self.preview.folderState = .failed
            }
            // The pointer is on the grid, not the tile, so the tick's
            // re-anchor won't refit it — the new size lands here.
            self.reframe()
        }
    }

    /// A folder chip's click: browse into it in place — Apple's Grid
    /// stack, one level at a time, with the header's chevron back out.
    private func drillFolder(_ url: URL) {
        guard let root = preview.folderURL,
              let trail = DockEnhanceMath.drilledTrail(preview.folderTrail, root: root, into: url) else { return }
        preview.folderTrail = trail
        loadFolder(url, generation: generation)
        reframe()
    }

    /// The header's chevron: one folder back up the trail.
    private func folderBack() {
        guard !preview.folderTrail.isEmpty else { return }
        preview.folderTrail.removeLast()
        guard let shown = preview.folderShown else { return }
        loadFolder(shown, generation: generation)
        reframe()
    }

    /// The previewed app's windows changed under the open panel — a new
    /// one, a closed one, a retitle, a minimize. Re-list, keep every
    /// surviving card's id and still, and watch the newcomers. The panel
    /// moves only when its size changed, and stills are fetched only for
    /// newcomers and windows just back from the Dock: a retitle is a
    /// re-list and nothing more.
    private func refreshLiveWindows(force: Bool = false) {
        guard let panel, panel.isVisible, let pid = preview.processIdentifier,
              force || windowObserver.pid == pid, preview.folderURL == nil else { return }
        let old = preview.windows
        let merged = DockEnhanceMath.mergeWindows(old: old, new: listWindows(pid: pid))
        guard DockEnhanceMath.cardsDiffer(old, merged) else { return }
        preview.windows = merged
        windowObserver.watch(merged.compactMap(\.element))
        if let selected = preview.selectedWindowID, !merged.contains(where: { $0.id == selected }) {
            preview.selectedWindowID = nil
        }
        applyAgents(to: preview)
        let earnsRow = preview.bundleID.map {
            DockEnhanceMath.playerBundleIDs.contains($0) || $0 == DockEnhanceMath.calendarBundleID
        } ?? false
        if merged.isEmpty, !earnsRow {
            // The app's last window closed elsewhere — nothing left to raise.
            tracker.reset()
            hidePreview()
            return
        }
        preview.compact = DockEnhanceMath.compactList(
            windowCount: merged.count, limit: preferences.compactListLimit)
        reframe(onlyIfResized: true)
        guard preferences.showThumbnails, !preview.compact, screenCaptureGranted,
              DockEnhanceMath.wantsStills(old: old, new: merged) else { return }
        let generationAtRefresh = generation
        let bundleID = preview.bundleID
        let offscreen = preferences.includeOffscreenWindows
        Task { @MainActor [weak self] in
            guard let self else { return }
            await DockThumbnailer.attach(
                to: self.preview, bundleID: bundleID, pid: pid,
                includeOffscreen: offscreen,
                isStale: { [weak self] in self?.generation != generationAtRefresh })
        }
    }

    /// The pointer landed on a card: with the live card on, that window
    /// streams while the pointer stays; otherwise its still is freshened
    /// if it has aged past a glance.
    private func hoverCard(_ window: DockPreviewWindow) {
        guard DockEnhanceMath.streamsLive(liveCard: preferences.liveCard,
                                          thumbnails: preferences.showThumbnails,
                                          granted: screenCaptureGranted, compact: preview.compact,
                                          minimized: window.minimized,
                                          offscreen: preferences.includeOffscreenWindows),
              let pid = preview.processIdentifier, let windowID = window.windowID else {
            freshenStill(window)
            return
        }
        liveStill.start(windowID: windowID, pid: pid)
    }

    /// The pointer left a card: its stream stops, the last frame stays.
    private func leaveCard(_ window: DockPreviewWindow) {
        guard let windowID = window.windowID, liveStill.windowID == windowID else { return }
        liveStill.stop()
    }

    /// A hovered card whose still has aged past a glance, or predates
    /// its agent's current state, re-takes that one window; the other
    /// cards keep the cache. Minimized and other-Space windows only when
    /// the card captures those at all.
    private func freshenStill(_ window: DockPreviewWindow) {
        guard preferences.showThumbnails, screenCaptureGranted, !preview.compact,
              let pid = preview.processIdentifier, let windowID = window.windowID,
              !window.minimized || preferences.includeOffscreenWindows,
              !freshening.contains(windowID) else { return }
        let tag = preview.agents[window.id]?.stillTag
        let cached = DockThumbnailer.cached(pid: pid, windowID: windowID)
        guard DockThumbnailer.wantsHoverRefresh(hasStill: window.thumbnail != nil, age: cached?.age,
                                                cachedTag: cached?.tag, tag: tag) else { return }
        freshening.insert(windowID)
        let generationAtHover = generation
        let cardID = window.id
        Task { @MainActor [weak self] in
            let image = await DockThumbnailer.fresh(windowID: windowID, pid: pid, tag: tag)
            guard let self else { return }
            self.freshening.remove(windowID)
            guard let image, self.generation == generationAtHover, self.preview.processIdentifier == pid,
                  let row = self.preview.windows.firstIndex(where: { $0.id == cardID }) else { return }
            self.preview.windows[row].thumbnail = image
        }
    }

    /// Keep the visible panel on its tile: the tile's frame moves while
    /// an auto-hidden Dock slides in, and the content's fitting size
    /// settles a beat after it was first measured. Only a real change
    /// moves the frame, without animation — it is a correction, not a
    /// retarget.
    private func anchorPanel(to item: DockAXItem) {
        guard let panel, panel.isVisible, let anchor else { return }
        let itemFrame = anchorFrame(for: item, edge: anchor.edge, pointer: NSEvent.mouseLocation)
        let size = panel.fittingSize()
        let target = DockEnhanceMath.panelFrame(anchor: itemFrame, edge: anchor.edge, size: size,
                                                screen: anchor.screen, gap: Self.panelGap,
                                                labelClearance: DockEnhanceMath.nativeLabelClearance(
                                                    title: preview.appName, edge: anchor.edge))
        self.anchor = (item, anchor.edge, anchor.screen)
        if abs(target.minX - panel.frame.minX) > 1 || abs(target.minY - panel.frame.minY) > 1
            || abs(target.width - panel.frame.width) > 1 || abs(target.height - panel.frame.height) > 1 {
            panel.setFrame(target, display: true)
        }
    }

    /// The retained panel, built once with its actions wired — internal
    /// (not private) so a test can read the wiring without a hover.
    func ensurePanel() -> DockPreviewPanel {
        if let panel { return panel }
        let panel = DockPreviewPanel(content: preview)
        panel.actions.onPick = { [weak self] window in self?.pick(window) }
        panel.actions.onPickKeepOpen = { [weak self] window in self?.pick(window, keepOpen: true) }
        panel.actions.onClose = { [weak self] window in self?.close(window) }
        panel.actions.onMinimize = { [weak self] window in self?.toggleMinimized(window) }
        panel.actions.onFullScreen = { [weak self] window in self?.toggleFullScreen(window) }
        panel.actions.onTile = { [weak self] window, tile in self?.tile(window, tile) }
        panel.actions.onNewWindow = { [weak self] in self?.newWindow() }
        panel.actions.onQuitApp = { [weak self] in self?.quitApp() }
        panel.actions.onHideApp = { [weak self] in self?.hideApp() }
        panel.actions.onMinimizeAll = { [weak self] in self?.minimizeAll() }
        panel.actions.onCloseAll = { [weak self] in self?.closeAll() }
        panel.actions.onOpen = { [weak self] url in self?.openItem(url) }
        panel.actions.onMediaCommand = { MediaFeed.shared.send($0) }
        panel.actions.onMediaSeek = { MediaFeed.shared.seek(to: $0) }
        panel.actions.lyrics = lyrics
        panel.actions.onReveal = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
        panel.actions.onDrillFolder = { [weak self] url in self?.drillFolder(url) }
        panel.actions.onFolderBack = { [weak self] in self?.folderBack() }
        panel.actions.onShake = { [weak self] window in self?.shakeOthers(window) }
        panel.actions.onSwipeMinimize = { [weak self] window, minimize in
            self?.swipeMinimize(window, minimize)
        }
        panel.actions.onCalendarAuth = { [weak self] in self?.authorizeCalendar() }
        panel.actions.onCalendarJoin = { url in
            guard let url else { return }
            NSWorkspace.shared.open(url)
        }
        panel.actions.onDocumentDrop = { [weak self] url in self?.openDocumentInPreview(url) ?? false }
        panel.actions.onAnswered = { [weak self] in self?.reframe(onlyIfResized: true) }
        panel.actions.onMoveToDisplay = { [weak self] window, display in
            self?.move(window, toDisplay: display)
        }
        panel.actions.onHoverCard = { [weak self] window in self?.hoverCard(window) }
        panel.actions.onHoverCardEnd = { [weak self] window in self?.leaveCard(window) }
        panel.actions.onExcludeApp = { [weak self] in self?.excludePreviewedApp() }
        self.panel = panel
        wireShelf()
        return panel
    }

    /// A document card dropped on this preview: the previewed app
    /// opens the file — the same verb as dropping the document on the
    /// app's Dock tile, one panel nearer.
    private func openDocumentInPreview(_ url: URL) -> Bool {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path),
              let bundleID = preview.bundleID,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return false }
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
        Self.log.notice("document handoff: \(url.lastPathComponent, privacy: .public) → \(bundleID, privacy: .public)")
        return true
    }

    /// What a hovered tile resolves to: a running app via the tile's
    /// `AXURL`/bundle id or a title match, else a bare "open me" card.
    /// A folder tile skips all of it and pops the directory's entries.
    private func fill(_ content: DockPreviewContent, for item: DockAXItem) {
        defer { applyAgents(to: content) }
        let appURL = item.url
        content.folderURL = nil
        content.folderTrail = []
        content.folderEntries = []
        content.media = nil
        content.calendarEvents = []
        content.calendarFreeUntil = nil
        content.calendarNeedsAuth = false
        content.badge = item.badge
        content.armedWindowID = nil
        content.armedNote = nil
        content.pulsedWindowIDs = []
        content.headerNote = nil
        content.stillRunning = false
        agentGuard.reset()
        if item.kind == .folder {
            content.folderURL = appURL
            content.appName = appURL?.lastPathComponent ?? item.title ?? "Folder"
            // The generic folder glyph comes from LaunchServices — no
            // file access. `icon(forFile:)` would open the folder and,
            // on a TCC-gated path like Downloads, stall the main
            // thread seconds while the consent check pends. The real
            // icon upgrades with the entries off-actor.
            content.icon = NSWorkspace.shared.icon(for: .folder)
            content.folderEntries = []
            content.folderState = .loading
            content.bundleID = nil
            content.appURL = appURL
            content.processIdentifier = nil
            content.isRunning = false
            content.windows = []
            return
        }
        if item.kind == .minimizedWindow {
            fillMinimizedWindow(content, for: item)
            return
        }
        let bundleID = appURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        // An excluded app rests and earns nothing — DockDoor's app
        // filter. The tile reads as shown so the tick never retries.
        if let bundleID, preferences.excludedBundleIDs.contains(bundleID) {
            content.appName = item.title
                ?? appURL?.deletingPathExtension().lastPathComponent ?? "Dock item"
            content.icon = nil
            content.bundleID = nil
            content.appURL = nil
            content.processIdentifier = nil
            content.isRunning = false
            content.windows = []
            return
        }
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
        content.windows = running.map { listWindows(pid: $0.processIdentifier) } ?? []
        content.selectedWindowID = nil
    }

    /// One app's cards: its AX windows, narrowed to the Dock's display
    /// when the card asks — DockDoor's per-monitor filter; the Dock is
    /// on the pointer's screen, and so are the windows worth previewing
    /// from it.
    private func listWindows(pid: pid_t) -> [DockPreviewWindow] {
        let windows = AppleDockReader.windows(pid: pid)
        guard preferences.previewThisDisplay, let display = Self.pointerDisplayQuartz() else { return windows }
        return DockEnhanceMath.onDisplay(windows, display: display)
    }

    /// The pointer's screen in Quartz space — where AX frames live.
    private static func pointerDisplayQuartz() -> CGRect? {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) else { return nil }
        let f = screen.frame
        return CGRect(x: f.minX, y: mainScreenHeight() - f.maxY, width: f.width, height: f.height)
    }

    /// Mark the cards whose windows host an agent session, and collect
    /// every live session the previewed app hosts for the header count,
    /// the ask rows and Quit's guard. Re-run whenever the card list
    /// changes under the panel.
    private func applyAgents(to content: DockPreviewContent) {
        let mapped = DockEnhanceMath.agentMap(windows: content.windows,
                                              bundleID: content.bundleID,
                                              marks: agentMarks())
        content.agents = mapped.cards
        content.appAgents = mapped.app
    }

    /// A minimized-window tile: the Dock gives the tile the window's
    /// title and frame but no `AXURL`, so the owning app resolves
    /// through the off-screen window list — the same read the ⌥⇥
    /// switcher does for its minimized rows. The preview shows just
    /// that window: the AX row when it matches (the card's verbs then
    /// act on the real window), else the tile itself — its `AXPress`
    /// IS the system's restore.
    private func fillMinimizedWindow(_ content: DockPreviewContent, for item: DockAXItem) {
        let title = item.title ?? "Window"
        content.appName = title
        content.bundleID = nil
        content.appURL = nil
        content.processIdentifier = nil
        content.isRunning = false
        content.icon = nil
        content.selectedWindowID = nil
        var card = DockPreviewWindow(id: 0, title: title, minimized: true,
                                     fullScreen: nil, frame: nil, element: item.element)
        // A tile with no usable title can't be matched to an owner —
        // the tile-backed card still previews and restores.
        guard let itemTitle = item.title, !itemTitle.isEmpty else {
            content.windows = [card]
            return
        }
        let offRows = DockSwitcherList.offScreenRows()
        guard let pid = DockSwitcherList.minimizedOwnerPID(
            title: itemTitle, rows: offRows, axWindows: { AppleDockReader.windows(pid: $0) }),
              let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular else {
            content.windows = [card]
            return
        }
        if let bundleID = app.bundleIdentifier,
           preferences.excludedBundleIDs.contains(bundleID) {
            // An excluded app rests and earns nothing — same rule the
            // app tiles follow.
            content.windows = []
            return
        }
        content.appName = app.localizedName ?? title
        content.bundleID = app.bundleIdentifier
        content.appURL = app.bundleURL
        content.processIdentifier = pid
        content.isRunning = true
        content.icon = app.icon
        let rows = offRows.filter { $0.pid == pid && $0.title == itemTitle }
        let axWindows = AppleDockReader.windows(pid: pid)
        // A same-titled window parked on another Space shares the
        // off-screen list; only a minimized one can be this tile.
        let matched = rows.compactMap { DockSwitcherList.match(row: $0, in: axWindows) }
        let minimizedHits = matched.filter(\.minimized)
        let hits = minimizedHits.isEmpty ? matched : minimizedHits
        if hits.count == 1 {
            content.windows = [hits[0]]
        } else {
            // Zero or several AX claimants — the tile-backed card keeps
            // the CG id and bounds so its thumbnail can still land.
            card.frame = rows.first?.bounds
            card.windowID = rows.first?.windowID
            content.windows = [card]
        }
    }

    // MARK: Verbs

    /// A window card's click — raise it and bring the app forward. With
    /// `keepOpen` (⌥-click) the panel stays and the raised card becomes
    /// the walked one, so the next ⌥-click, arrow or W carries on from it.
    private func pick(_ window: DockPreviewWindow, keepOpen: Bool = false) {
        let app = preview.processIdentifier.flatMap { NSRunningApplication(processIdentifier: $0) }
        AppleDockReader.raise(window, app: app)
        guard keepOpen else {
            tracker.reset()
            hidePreview()
            return
        }
        preview.selectedWindowID = window.id
        mirrorPreviewChars()
        if let index = preview.windows.firstIndex(where: { $0.id == window.id }) {
            preview.windows[index].minimized = false
        }
    }

    /// ⌥`: the front app's windows on its own Dock tile, the next window
    /// already walked — a visual ⌘` that needs no pointer. Return raises
    /// the walked card, the arrows walk, W/M/F act; ⌥` again closes it.
    func previewFrontApp() {
        guard running, accessibilityTrusted,
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let dock = AppleDockReader.dockPID(), let list = AppleDockReader.dockList(pid: dock),
              let frame = AppleDockReader.frame(of: list) else { return }
        let now = CACurrentMediaTime()
        cachedList = (list, frame, now)
        let items = AppleDockReader.items(list: list)
        guard let index = DockEnhanceMath.frontTileIndex(
            bundleURL: front.bundleURL, name: front.localizedName,
            tiles: items.map { ($0.url, $0.title, $0.kind == .app) }) else { return }
        let item = items[index]
        if keyboardPinned, tracker.shown == item.hoverID {
            tracker.reset()
            hidePreview()
            return
        }
        tracker.reset()
        tracker.summon(item.hoverID, now: now)
        keyboardPinned = true
        showPreview(for: item)
        guard keyboardPinned else { return }  // nothing to preview
        preview.selectedWindowID = DockEnhanceMath.frontWalkStart(preview.windows)
        mirrorPreviewChars()
    }

    /// A key the switcher's tap ate for the floating preview — Esc
    /// closes it, the rest feed the same card walk the watchers'
    /// `onKey` runs. Unlike that path this needs no pointer on the
    /// panel: a preview resting open over the Dock still answers.
    private func previewTapKey(_ code: Int64) {
        if code == 53 {
            tracker.reset()
            hidePreview()
        } else {
            _ = panelKey(UInt16(code))
        }
    }

    /// An action key the tap ate for the preview: W closes the walked
    /// card (agent-guarded like ×), M minimizes or restores it, F flips
    /// full screen, ⌥←/⌥→ tile it into a half, Space plays or pauses
    /// the player row.
    private func previewAction(_ action: String) {
        if action == " " {
            MediaFeed.shared.send(.togglePlayPause)
            return
        }
        guard let id = preview.selectedWindowID,
              let window = preview.windows.first(where: { $0.id == id }) else { return }
        switch action {
        case "w": close(window)
        case "m": toggleMinimized(window)
        case "f": toggleFullScreen(window)
        case "tile-left": tile(window, .leftHalf)
        case "tile-right": tile(window, .rightHalf)
        default: break
        }
    }

    /// The action keys to ask the tap for: the window verbs, tiling and
    /// Return only once a card is walked (the bare arrows are already
    /// the preview's), Space only while the pointer rests on a panel
    /// showing a player. Anything else keeps typing into the front app.
    static func previewChars(walked: Bool, media: Bool, pointerInPanel: Bool) -> Set<String> {
        var chars: Set<String> = walked ? ["w", "m", "f", SwitcherKeyTap.walkedMarker] : []
        if media && pointerInPanel { chars.insert(" ") }
        return chars
    }

    /// Hand the tap the keys the preview wants now — on every tick, and
    /// at once when a walk starts, so a Return pressed straight after
    /// the arrow is already the preview's.
    private func mirrorPreviewChars(pointerInPanel inPanel: Bool? = nil) {
        let chars = tracker.shown == nil ? [] : Self.previewChars(
            walked: preview.selectedWindowID != nil, media: preview.media != nil,
            pointerInPanel: inPanel ?? pointerInPanel())
        guard chars != mirroredChars else { return }
        mirroredChars = chars
        switcher.setPreviewChars(chars)
    }

    /// Arrows walk the window cards while the pointer rests on the
    /// panel — ←/→ between cards, ↓/↑ in the compact list — and Return
    /// raises the walked one. DockDoor's keyboard path over the same
    /// non-activating surface.
    private func panelKey(_ keyCode: UInt16) -> Bool {
        let windows = preview.windows
        guard !windows.isEmpty else { return false }
        switch keyCode {
        case 123, 124, 125, 126: // ← → ↓ ↑
            let current = windows.firstIndex { $0.id == preview.selectedWindowID }
            let delta = (keyCode == 123 || keyCode == 126) ? -1 : 1
            let next = current.map {
                ($0 + delta + windows.count) % windows.count
            } ?? (delta > 0 ? 0 : windows.count - 1)
            preview.selectedWindowID = windows[next].id
            mirrorPreviewChars()
            return true
        case 36, 76: // Return / keypad Enter
            guard let id = preview.selectedWindowID,
                  let window = windows.first(where: { $0.id == id }) else { return false }
            pick(window)
            return true
        default:
            return false
        }
    }

    /// The card's ×: close the window and drop its card; the panel
    /// stays so a person can close several in a row. A window hosting a
    /// working or waiting agent needs the press twice — a mis-click on a
    /// thumbnail must not end a mid-task session.
    private func close(_ window: DockPreviewWindow) {
        let live = preview.agents[window.id].flatMap { $0.isLive ? $0 : nil }
        let key = "close:\(window.id)"
        guard agentGuard.confirm(key, guarded: live != nil, now: CACurrentMediaTime()) else {
            if let live {
                preview.armedWindowID = window.id
                preview.armedNote = DockAgentGuard.note(for: live, again: "× again to close")
                disarmLater(key)
            }
            return
        }
        preview.armedWindowID = nil
        preview.armedNote = nil
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

    /// The card's fullscreen verb — toggles the window's own
    /// `AXFullScreen` and keeps the panel up so several windows can
    /// be flipped in a row.
    private func toggleFullScreen(_ window: DockPreviewWindow) {
        guard let element = window.element,
              let current = AppleDockReader.fullScreenState(of: element) else { return }
        guard AppleDockReader.setFullScreen(window, !current) else { return }
        if let index = preview.windows.firstIndex(where: { $0.id == window.id }) {
            preview.windows[index].fullScreen = !current
        }
    }

    /// The context menu's tile: snap the window into a half or quarter
    /// of the screen the preview is over — DockDoor's grid, minus the
    /// drag. A minimized window stands back up first, and the panel
    /// stays so the rest of the set can still be worked.
    private func tile(_ window: DockPreviewWindow, _ tile: DockTile) {
        let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                      ?? NSScreen.main ?? NSScreen.screens[0])
        let visible = screen.visibleFrame
        // visibleFrame is AppKit — flip it into the Quartz space the
        // AX writes expect before carving it.
        let quartz = CGRect(x: visible.minX,
                            y: Self.mainScreenHeight() - visible.maxY,
                            width: visible.width, height: visible.height)
        if window.minimized { _ = AppleDockReader.setMinimized(window, false) }
        _ = AppleDockReader.setFrame(window, DockEnhanceMath.tileFrame(tile, in: quartz))
    }

    /// The context menu's Move To: the window keeps its size (clamped
    /// to fit) and lands centred on the other display's visible frame.
    private func move(_ window: DockPreviewWindow, toDisplay id: CGDirectDisplayID) {
        guard let display = DockDisplays.all().first(where: { $0.id == id }) else { return }
        let visible = DockEnhanceMath.appKitRect(display.screen.visibleFrame,
                                                 mainScreenHeight: Self.mainScreenHeight())
        let current = window.frame ?? window.element.flatMap { AppleDockReader.frame(of: $0) }
            ?? CGRect(origin: .zero, size: visible.size)
        if window.minimized { _ = AppleDockReader.setMinimized(window, false) }
        _ = AppleDockReader.setFrame(window, DockEnhanceMath.moveFrame(current, to: visible))
    }

    /// The header's "New" — the app's New Window. The live list usually lands
    /// the new card by itself; a beat later the same refresh runs once
    /// more for apps that post no window-created notification.
    private func newWindow() {
        let app = preview.processIdentifier
            .flatMap { NSRunningApplication(processIdentifier: $0) }
        AppleDockReader.newWindow(app: app)
        let generationAtNew = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, self.generation == generationAtNew else { return }
            self.refreshLiveWindows(force: true)
        }
    }

    /// The header's "Quit" — a plain terminate. An app still running a
    /// beat later turns the disc into Force Quit, and the next press
    /// force-terminates. An app hosting a working or waiting agent asks
    /// first: quitting Ghostty ends every session in it.
    private func quitApp() {
        let key = "quit:\(preview.processIdentifier ?? 0)"
        let live = preview.appAgents.first(where: \.isLive)
        guard agentGuard.confirm(key, guarded: live != nil, now: CACurrentMediaTime()) else {
            if let live {
                preview.headerNote = DockAgentGuard.note(
                    for: live, again: "Quit again to quit \(preview.appName)")
                disarmLater(key)
                reframe()
            }
            return
        }
        guard let app = preview.processIdentifier
            .flatMap({ NSRunningApplication(processIdentifier: $0) }) else { return }
        if preview.stillRunning {
            // The second Quit on an app that ignored the first is the
            // force the header now offers.
            app.forceTerminate()
            tracker.reset()
            hidePreview()
            return
        }
        app.terminate()
        // Quit is a request. The panel stays a beat: an app that goes
        // takes its cards with it (the live list hides the panel); one
        // that blocks the quit, or keeps running in the background —
        // macOS 27's gray dot — gets an honest "still running" and a
        // Force Quit instead of a panel that closed as if it worked.
        preview.headerNote = "Quitting…"
        reframe()
        let generationAtQuit = generation
        let name = preview.appName
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitFollowThrough) { [weak self] in
            guard let self, self.generation == generationAtQuit else { return }
            if app.isTerminated {
                self.tracker.reset()
                self.hidePreview()
            } else {
                self.preview.stillRunning = true
                self.preview.headerNote = "\(name) is still running — Quit again to force it"
                self.reframe()
            }
        }
    }

    /// A guarded verb's first press lapses with the guard's window —
    /// the ring and the note go with it unless the press was repeated.
    private func disarmLater(_ key: String) {
        let generationAtArm = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DockAgentGuard.window))
            guard let self, self.generation == generationAtArm,
                  !self.agentGuard.isArmed(key, now: CACurrentMediaTime()) else { return }
            if key.hasPrefix("close:") {
                self.preview.armedWindowID = nil
                self.preview.armedNote = nil
            } else {
                self.preview.headerNote = nil
                self.reframe()
            }
        }
    }

    /// DockDoor's minimise-all: every open window of the previewed app
    /// goes to the Dock in one verb. Minimized rows are left alone.
    private func minimizeAll() {
        var changed = false
        for index in preview.windows.indices where !preview.windows[index].minimized {
            if AppleDockReader.setMinimized(preview.windows[index], true) {
                preview.windows[index].minimized = true
                changed = true
            }
        }
        if changed { reframe() }
    }

    /// Close-all: every window of the previewed app closes in one verb
    /// — quit's gentler sibling, the app stays running windowless.
    /// Closed cards drop; the panel stays while windows remain so a
    /// person can keep working the set. Windows hosting a working or
    /// waiting agent are skipped, and the header says so.
    private func closeAll() {
        let split = DockEnhanceMath.closable(preview.windows, agents: preview.agents)
        var keptIDs = Set(split.keep.map(\.id))
        for window in split.close where !AppleDockReader.close(window) {
            keptIDs.insert(window.id)
        }
        preview.windows = preview.windows.filter { keptIDs.contains($0.id) }
        if !split.keep.isEmpty {
            preview.headerNote = split.keep.count == 1
                ? "Kept the window an agent is running in"
                : "Kept \(split.keep.count) windows agents are running in"
        }
        if preview.windows.isEmpty {
            tracker.reset()
            hidePreview()
        } else {
            reframe()
        }
    }

    /// Aero shake — minimise the rest of the app's windows, or bring
    /// them all back when the shaken card is the only one left up.
    private func shakeOthers(_ window: DockPreviewWindow) {
        guard let plan = DockEnhanceMath.shakePlan(preview.windows, shaken: window.id) else { return }
        var changed = Set<Int>()
        for other in plan.targets {
            guard AppleDockReader.setMinimized(other, plan.minimize),
                  let index = preview.windows.firstIndex(where: { $0.id == other.id })
            else { continue }
            preview.windows[index].minimized = plan.minimize
            changed.insert(other.id)
        }
        acknowledge(changed)
        if !changed.isEmpty { reframe() }
    }

    /// A vertical flick on a card — down minimises, up restores.
    private func swipeMinimize(_ window: DockPreviewWindow, _ minimize: Bool) {
        guard window.minimized != minimize,
              AppleDockReader.setMinimized(window, minimize),
              let index = preview.windows.firstIndex(where: { $0.id == window.id })
        else { return }
        preview.windows[index].minimized = minimize
        acknowledge([window.id])
    }

    /// A shake or flick landed: a level-change tick under the trackpad
    /// and a brief dip on the cards it moved — a hidden gesture says it
    /// worked, and on which windows, without a word on screen.
    private func acknowledge(_ ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        pulseToken &+= 1
        let token = pulseToken
        preview.pulsedWindowIDs = ids
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pulseLength) { [weak self] in
            guard let self, self.pulseToken == token else { return }
            self.preview.pulsedWindowIDs = []
        }
    }

    static let pulseLength: TimeInterval = 0.3
    @ObservationIgnored private var pulseToken = 0

    /// A folder pop click — the entry (or the folder itself) opens.
    private func openItem(_ url: URL) {
        NSWorkspace.shared.open(url)
        tracker.reset()
        hidePreview()
    }

    /// The calendar row — the shelf's own read (24 h, not all-day,
    /// earliest first) done off-main; an EventKit query is a synchronous
    /// IPC to `calendard` and a hover never waits on it. The Calendar
    /// tile gets today's glance; a meeting app gets the one event whose
    /// link it opens, or no row.
    private func loadCalendarRow(generation: Int, meetingApp: String? = nil) {
        Task { @MainActor [weak self] in
            let events = await Task.detached(priority: .userInitiated) {
                Self.upcomingCalendarEvents()
            }.value
            guard let self, self.generation == generation else { return }
            let now = Date()
            if let meetingApp {
                self.preview.calendarEvents = DockEnhanceMath.meetingEvent(
                    for: meetingApp, in: events, now: now).map { [$0] } ?? []
                self.preview.calendarFreeUntil = nil
            } else {
                let glance = DockEnhanceMath.calendarGlance(events, now: now)
                self.preview.calendarEvents = glance.events
                self.preview.calendarFreeUntil = glance.freeUntil
            }
            self.reframe()
        }
    }

    /// One EventKit store for every hover — building one per hover paid
    /// its database open each time. Created on the first read, which
    /// only ever runs under an existing Full Calendar grant.
    nonisolated(unsafe) private static var calendarStore: EKEventStore?
    nonisolated private static let calendarStoreLock = NSLock()

    /// The EventKit half of the calendar row — pure enough to run on a
    /// worker: the grant is already checked, and `project`/`joinableURL`
    /// are nonisolated. Empty reads as "nothing upcoming".
    nonisolated static func upcomingCalendarEvents() -> [ShelfCalendarModel.Event] {
        let store: EKEventStore = calendarStoreLock.withLock {
            if let calendarStore { return calendarStore }
            let made = EKEventStore()
            calendarStore = made
            return made
        }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(24 * 3600), calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .map { ShelfCalendarModel.project($0) }
    }

    /// The calendar row's explicit ask — "Show events" requests the
    /// Full Calendar grant, then fills the row when it's given.
    private func authorizeCalendar() {
        let store = EKEventStore()
        let generationAtAuth = generation
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generationAtAuth else { return }
                self.preview.calendarNeedsAuth = false
                if granted { self.loadCalendarRow(generation: generationAtAuth) }
            }
        }
    }

    /// A folder pop's contents: top-level entries in the tile's own
    /// arrangement (`DockFolderSort` — Name is directories first, then
    /// Finder's name order). Hidden files are skipped, like Finder's
    /// default view. A date or kind sort reads one attribute per entry
    /// (`getattrlist`, no file is opened) before the cap, so the newest
    /// file is never the one cut.
    ///
    /// Runs OFF the main actor (the pop shows Loading… until it
    /// lands). The listing uses `atPath:` — a bare readdir — because
    /// the URL variant's resource prefetch opens every file, and one
    /// Reads names via POSIX `opendir`/`readdir` rather than
    /// `contentsOfDirectory`: the Foundation enumerator's `DirEnumRead`
    /// holds a syscall open in a way an EndpointSecurity client (e.g.
    /// Defender) or a pending TCC consent can stall for seconds.
    /// `readdir` needs one `opendir` and `d_type` carries the
    /// directory flag for free — still one `open` per call, so this
    /// must stay off the caller's thread.
    ///
    /// Capped at 60: the pop is a quick-open surface, not Finder.
    nonisolated static func folderListing(of url: URL, sort: DockFolderSort = .name) -> DockFolderListing {
        guard let dir = opendir(url.path) else {
            // Downloads/Desktop/Documents gate behind Files-and-Folders
            // consent — the denial surfaces as EACCES/EPERM, or EINTR
            // when the auth upcall can't present its prompt.
            let e = errno
            return DockFolderListing(denied: e == EACCES || e == EPERM || e == EINTR)
        }
        defer { closedir(dir) }
        var rows: [DockFolderSort.Row] = []
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != "..", !name.hasPrefix(".") else { continue }
            rows.append(.init(name: name, url: url.appendingPathComponent(name),
                              isDir: ent.pointee.d_type == DT_DIR))
        }
        let key = sort.resourceKey
        func value(_ entry: URL) -> URLResourceValues? {
            guard let key else { return nil }
            return try? entry.resourceValues(forKeys: [key])
        }
        let capped = sort.arrange(
            rows,
            date: { entry in
                let values = value(entry)
                switch sort {
                case .dateAdded: return values?.addedToDirectoryDate
                case .dateModified: return values?.contentModificationDate
                case .dateCreated: return values?.creationDate
                default: return nil
                }
            },
            kind: { value($0)?.localizedTypeDescription }).prefix(60)
        return DockFolderListing(
            entries: capped.enumerated().map { index, row in
                DockFolderEntry(id: index, name: row.name, url: row.url,
                                icon: NSWorkspace.shared.icon(forFile: row.url.path),
                                isDirectory: row.isDir)
            },
            folderIcon: NSWorkspace.shared.icon(forFile: url.path))
    }

    /// The test seam — the entries half of `folderListing`.
    nonisolated static func folderEntries(of url: URL) -> [DockFolderEntry] {
        folderListing(of: url).entries
    }

    /// DockDoor's quick-quit: ⌘+right-click a Dock icon terminates the
    /// app, ⌘⌥+right-click force-quits it. The switcher's tap eats the
    /// click on a running app's tile so Apple's menu never pops over
    /// the quit; this global monitor path (AppKit point) is the
    /// fallback while the tap's mirrored tiles are stale.
    private func quickQuit(at point: NSPoint, force: Bool) {
        quickQuit(axPoint: DockEnhanceMath.axPoint(point, mainScreenHeight: Self.mainScreenHeight()),
                  force: force)
    }

    private func quickQuit(axPoint: CGPoint, force: Bool) {
        // The tap and the fallback monitor can both see one click; the
        // second report of the same press is the same press — never the
        // confirming second click an agent guard waits for.
        let now = CACurrentMediaTime()
        if let last = lastQuickQuit, now - last.at < 0.3,
           hypot(last.point.x - axPoint.x, last.point.y - axPoint.y) < 3 { return }
        lastQuickQuit = (axPoint, now)
        guard let list = dockList(near: axPoint),
              Self.listReach(of: list.frame).contains(axPoint),
              let item = tiles(of: list).first(where: { $0.frame.contains(axPoint) }),
              let appURL = item.url,
              let bundleID = Bundle(url: appURL)?.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        // Never let the verb reach our own family — a ⌘-click on our
        // own tile would self-terminate.
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !MenuBarUtility.isOwnFamily(bundleID) else { return }
        let name = app.localizedName ?? "the app"
        // A reflexive quit must not end a mid-task agent run: a terminal
        // or IDE hosting a working or waiting session asks for the same
        // click twice.
        let live = agentMarks().first { $0.hosts.contains(bundleID) && $0.isLive }
        let key = "quickquit:\(app.processIdentifier)"
        guard agentGuard.confirm(key, guarded: live != nil, now: CACurrentMediaTime()) else {
            if let live {
                showToast(DockAgentGuard.note(for: live, again: "⌘-right-click again to quit"),
                          over: item, duration: DockAgentGuard.window)
            }
            return
        }
        Self.log.notice("quick quit: \(bundleID, privacy: .public) force=\(force, privacy: .public)")
        if force { app.forceTerminate() } else { app.terminate() }
        tracker.reset()
        hidePreview()
        showToast(force ? "Force quit \(name)" : "Quit \(name)", over: item)
        // Quit is a request: an app that blocks it, or keeps running in
        // the background (macOS 27's gray dot), says so rather than the
        // toast claiming a quit that never happened.
        guard !force else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitFollowThrough) { [weak self] in
            guard let self, !app.isTerminated else { return }
            self.showToast("\(name) is still running — ⌘⌥-right-click to force quit", over: item,
                           duration: 2.4)
        }
    }

    /// The tile under an AppKit point, when it's over the Dock. The
    /// gesture monitors call this for every click or scroll anywhere, so
    /// a point outside the cached reach answers at once — the tick keeps
    /// that frame fresh wherever the pointer nears a Dock edge — and
    /// only a point over the Dock pays the AX read.
    private func tile(at point: NSPoint) -> DockAXItem? {
        let axPoint = DockEnhanceMath.axPoint(point, mainScreenHeight: Self.mainScreenHeight())
        guard accessibilityTrusted else { return nil }
        if let cached = cachedList, !Self.listReach(of: cached.frame).contains(axPoint) { return nil }
        guard let list = dockList(near: axPoint),
              Self.listReach(of: list.frame).contains(axPoint) else { return nil }
        return tiles(of: list).first { $0.frame.contains(axPoint) }
    }

    /// The Middle Click trigger: a middle click on a tile opens its
    /// preview at once; the same click on the tile already shown closes it.
    private func middleClick(at point: NSPoint) {
        guard running, preferences.previewTrigger == .middleClick, let item = tile(at: point) else { return }
        if tracker.shown == item.hoverID {
            tracker.reset()
            hidePreview()
            return
        }
        if case .show = tracker.summon(item.hoverID, now: CACurrentMediaTime()) {
            showPreview(for: item)
        }
    }

    /// Scroll on a Dock icon — HyperDock's classic: a deliberate scroll
    /// up opens that app's preview without the rest, a scroll down hides
    /// the app. The flick threshold is the cards' own, so a brush of the
    /// wheel on the way past does nothing.
    private func scroll(at point: NSPoint, deltaY: CGFloat, inverted: Bool, now: TimeInterval) {
        guard running, preferences.scrollGestures, let item = tile(at: point), item.kind == .app else {
            scrollTile = nil
            return
        }
        if scrollTile != item.hoverID {
            scrollTile = item.hoverID
            scrollFlick = DockEnhanceMath.SwipeAccumulator()
        }
        switch scrollFlick.note(deltaY: deltaY, inverted: inverted, now: now) {
        case .up:
            if case .show = tracker.summon(item.hoverID, now: CACurrentMediaTime()) {
                showPreview(for: item)
            }
        case .down:
            guard let url = item.url, let bundleID = Bundle(url: url)?.bundleIdentifier,
                  !MenuBarUtility.isOwnFamily(bundleID),
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            if tracker.shown == item.hoverID {
                tracker.reset()
                hidePreview()
            }
            app.hide()
        case nil:
            break
        }
    }

    /// Click the front app's own Dock icon: its visible windows minimize
    /// through AX — the Windows-taskbar habit, on the Dock you already
    /// use. A click on a background app is the Dock's own activation; an
    /// app with nothing visible left is the Dock's own restore; neither
    /// is touched. Only plain clicks — a modified click is the Dock's.
    private func clickToMinimize(at point: NSPoint, clickAt: TimeInterval) {
        guard running, preferences.clickToMinimize, let item = tile(at: point), item.kind == .app,
              let url = item.url, let bundleID = Bundle(url: url)?.bundleIdentifier,
              !MenuBarUtility.isOwnFamily(bundleID),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              DockEnhanceMath.clickMinimizes(
                appPID: app.processIdentifier,
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                lastActivation: lastActivation, clickAt: clickAt) else { return }
        let visible = AppleDockReader.windows(pid: app.processIdentifier).filter { !$0.minimized }
        guard !visible.isEmpty else { return }
        for window in visible { AppleDockReader.setMinimized(window, true) }
        if tracker.shown == item.hoverID {
            tracker.reset()
            hidePreview()
        }
    }

    /// How long a plain quit gets before "still running" is the truth.
    static let quitFollowThrough: TimeInterval = 1.2
    @ObservationIgnored private var lastQuickQuit: (point: CGPoint, at: TimeInterval)?

    /// The glass line above a tile — what a gesture did, or why it waited.
    @ObservationIgnored private var toast: DockToastPanel?

    private func showToast(_ text: String, over item: DockAXItem, duration: TimeInterval = 1.4) {
        let mainHeight = Self.mainScreenHeight()
        let tile = DockEnhanceMath.appKitRect(item.frame, mainScreenHeight: mainHeight)
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
                ?? NSScreen.screens.first(where: { $0.frame.contains(tile.origin) }) ?? NSScreen.main
        else { return }
        let listFrame = cachedList.map { DockEnhanceMath.appKitRect($0.frame, mainScreenHeight: mainHeight) } ?? tile
        let edge = DockEnhanceMath.dockEdge(listFrame: listFrame, screen: screen.frame)
        let anchor = magnificationOn
            ? DockEnhanceMath.magnifiedAnchor(tile: tile, edge: edge, pointer: pointer) : tile
        let panel = toast ?? DockToastPanel()
        toast = panel
        panel.show(text, over: anchor, edge: edge, screen: screen.frame, duration: duration)
    }

    /// The header's "Never Preview <App>": the app joins the exclusion
    /// list and the panel goes. The tracker keeps the tile as shown, so
    /// the resting pointer doesn't reopen what was just excluded.
    private func excludePreviewedApp() {
        guard let bundleID = preview.bundleID else { return }
        preferences.excludedBundleIDs = DockEnhanceMath.excluding(bundleID, from: preferences.excludedBundleIDs)
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
    /// `onlyIfResized` leaves a panel whose content still fits its frame
    /// where it is — a live retitle usually changes nothing it sizes by.
    private func reframe(onlyIfResized: Bool = false) {
        guard let panel, panel.isVisible else { return }
        let size = panel.fittingSize()
        if onlyIfResized, size == panel.frame.size { return }
        guard let anchor else {
            var frame = panel.frame
            frame.origin.x += (frame.width - size.width) / 2
            frame.size = size
            panel.setFrame(frame, display: true)
            return
        }
        // The same anchor the show/hover path uses — under magnification
        // the AX frame is the unmagnified layout and the tile sits at
        // the pointer, so refitting on it jumped the panel off the icon.
        let itemFrame = anchorFrame(for: anchor.item, edge: anchor.edge,
                                    pointer: NSEvent.mouseLocation)
        panel.setFrame(DockEnhanceMath.panelFrame(
            anchor: itemFrame, edge: anchor.edge, size: size,
            screen: anchor.screen, gap: Self.panelGap,
            labelClearance: DockEnhanceMath.nativeLabelClearance(
                title: preview.appName, edge: anchor.edge)), display: true)
    }
}
