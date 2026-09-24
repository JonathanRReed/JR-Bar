import AppKit
import JRBarCore

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

    /// The least air the frame math leaves between a tile and its
    /// panel, whatever the card asks: the road from the icon to the
    /// cards (`inCorridor`) needs the panel strictly past the tile.
    static let minimumGap: CGFloat = 2

    /// How far a magnified icon swells past its resting tile, off the
    /// Dock: the Dock's `largesize` (128 when it was never set, the
    /// Dock's own default) less the tile's extent across the Dock. A
    /// preview that covers the Dock rides at least this far out, so it
    /// never sits over the swollen icon.
    static func magnifiedReach(tileExtent: CGFloat, largesize: CGFloat?) -> CGFloat {
        max(0, (largesize ?? 128) - tileExtent)
    }

    /// Where a preview panel of `size` opens for a hovered item: off
    /// the dock toward the screen's middle, centred on the tile itself
    /// along the dock's run — the DockDoor read, where the panel sits
    /// over its app — and clamped inside the screen when the tile hugs
    /// a screen edge. The offset off the tile is the card's gap (never
    /// under `minimumGap`), any band kept for the Dock's name bubble,
    /// and a magnified icon's reach.
    static func panelFrame(anchor itemFrame: CGRect, edge: DockEdge, size: CGSize,
                           screen: CGRect, gap: CGFloat,
                           labelClearance: CGFloat = nativeLabelHeight,
                           magnifiedReach: CGFloat = 0) -> CGRect {
        let offset = max(minimumGap, gap) + labelClearance + magnifiedReach
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

    /// The tile's extent across the Dock — its height on a bottom Dock,
    /// its width on a side one: the size a magnified icon grows from.
    static func tileExtent(_ tile: CGRect, edge: DockEdge) -> CGFloat {
        edge == .bottom ? tile.height : tile.width
    }

    /// A window card's thumbnail box — 16:10, two sizes.
    static func cardSize(large: Bool) -> CGSize {
        large ? CGSize(width: 208, height: 130) : CGSize(width: 144, height: 90)
    }

    /// A card that takes its window's shape: the box's height, and a
    /// width that follows the window's aspect, held between 0.6 and 1.9
    /// of the height so a phone-tall window or a ribbon-wide one still
    /// reads as a card. No aspect to go on keeps the 16:10 box.
    static func cardSize(large: Bool, aspect: CGFloat?) -> CGSize {
        let box = cardSize(large: large)
        guard let aspect, aspect.isFinite, aspect > 0 else { return box }
        let h = box.height
        return CGSize(width: min(max(h * aspect, h * 0.6), h * 1.9).rounded(), height: h)
    }

    /// A card's window aspect: its frame's while AX reports one (known
    /// before the still lands, so the strip doesn't reflow when it does),
    /// else the still's own.
    static func aspect(of window: DockPreviewWindow) -> CGFloat? {
        if let frame = window.frame, frame.width > 0, frame.height > 0 { return frame.width / frame.height }
        if let size = window.thumbnail?.size, size.width > 0, size.height > 0 { return size.width / size.height }
        return nil
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
    /// names as its host. `soleAppWindows` is `DockAgentMatch.match`'s,
    /// and only the caller can say it: the cards are what AX and the
    /// display filter left, so one card is not one window.
    static func agentMap(windows: [DockPreviewWindow], bundleID: String?,
                         marks: [DockAgentMark],
                         soleAppWindows: Bool = true) -> (cards: [Int: DockAgentMark], app: [DockAgentMark]) {
        guard let bundleID else { return ([:], []) }
        let hosted = marks.filter { $0.hosts.contains(bundleID) }
        guard !hosted.isEmpty else { return ([:], []) }
        let candidates = windows.map {
            DockAgentMatch.Candidate(key: String($0.id), bundleID: bundleID, title: $0.title)
        }
        var cards: [Int: DockAgentMark] = [:]
        for (key, mark) in DockAgentMatch.match(marks: hosted, candidates: candidates,
                                                soleAppWindows: soleAppWindows) {
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

// MARK: - Placement (pure, tested)

/// How far off the Dock a preview (or a toast) opens, from the card's
/// knobs at show time: the distance from the Dock, whether it covers
/// the Dock's name bubble, and — covering, with the Dock magnifying
/// under the pointer — the swollen icon's reach, so the glass never
/// sits over it. Not covering keeps the band the bubble needs.
struct DockPlacement: Equatable {
    /// The card's distance from the Dock, in points.
    var gap: CGFloat
    var coversLabel: Bool
    /// The Dock magnifies and the pointer is on it — a keyboard-opened
    /// preview magnifies nothing.
    var magnifying = false
    /// The Dock's `largesize`; nil when never set.
    var largesize: CGFloat? = nil

    /// The band kept for the name bubble over a tile titled `title`.
    func labelClearance(title: String, edge: DockEdge) -> CGFloat {
        coversLabel ? 0 : DockEnhanceMath.nativeLabelClearance(title: title, edge: edge)
    }

    /// The magnified icon's reach past `anchor`, when it counts.
    func reach(anchor: CGRect, edge: DockEdge) -> CGFloat {
        guard coversLabel, magnifying else { return 0 }
        return DockEnhanceMath.magnifiedReach(tileExtent: DockEnhanceMath.tileExtent(anchor, edge: edge),
                                              largesize: largesize)
    }

    /// The frame for a panel of `size` over the tile `anchor`, whose
    /// name bubble reads `title`.
    func frame(anchor: CGRect, edge: DockEdge, size: CGSize, screen: CGRect, title: String) -> CGRect {
        DockEnhanceMath.panelFrame(anchor: anchor, edge: edge, size: size, screen: screen, gap: gap,
                                   labelClearance: labelClearance(title: title, edge: edge),
                                   magnifiedReach: reach(anchor: anchor, edge: edge))
    }
}

// MARK: - Spacing (pure, tested)

/// Every inset the preview panel draws, from one spacing scale (the
/// card's Spacing: Tight 0.6, Standard 1.0, Roomy 1.4). Each token is
/// its Standard value times the scale, rounded to a point and held at a
/// floor, so the tightest stop still clears the agent ring (it reaches
/// 3 pt past a still), keeps a verb disc a fair target, and leaves the
/// still's shadow room inside the glass. The header's icon and verb
/// discs are controls, not air, so they stop growing at Standard. The
/// corners are derived, not scaled: the card plate is the still's
/// corner plus its pad, and the glass is the plate's corner plus the
/// panel's inset, so every curve shares one centre.
struct DockPreviewMetrics: Equatable {
    /// Glass edge to content.
    let panelInset: CGFloat
    /// Header, note, asks, rule and cards, one from the next.
    let sectionSpacing: CGFloat
    /// The card plate's reach past its still.
    let cardPad: CGFloat
    /// Plate to plate along the strip.
    let cardSpacing: CGFloat
    /// Still to caption.
    let captionGap: CGFloat
    /// An ask row's padding across and down.
    let rowPadH: CGFloat
    let rowPadV: CGFloat
    /// A compact-list row's padding across.
    let listPadH: CGFloat
    /// The header's app icon. Spacing is air, not size: the icon
    /// shrinks toward Tight but never grows past Standard's 30.
    let headerIcon: CGFloat
    /// The header's verb discs — never under 20, a fair target, and
    /// never past Standard's 22.
    let verbDisc: CGFloat
    /// The hairline between sections. Below 0.8 the air alone
    /// separates them.
    let showsRule: Bool

    /// The card plate's corner: concentric with the still inside it.
    var plateRadius: CGFloat { DockChrome.stillRadius + cardPad }
    /// The glass's corner: concentric with the plates inside it.
    var panelRadius: CGFloat { plateRadius + panelInset }

    static func scaled(_ scale: Double) -> DockPreviewMetrics {
        let s = CGFloat(scale.isFinite ? scale : 1)
        func token(_ base: CGFloat, floor: CGFloat) -> CGFloat { max(floor, (base * s).rounded()) }
        return DockPreviewMetrics(panelInset: token(10, floor: 6),
                                  sectionSpacing: token(10, floor: 6),
                                  cardPad: token(6, floor: 4),
                                  cardSpacing: token(4, floor: 2),
                                  captionGap: token(6, floor: 3),
                                  rowPadH: token(10, floor: 8),
                                  rowPadV: token(8, floor: 6),
                                  listPadH: token(8, floor: 6),
                                  headerIcon: min(30, token(30, floor: 24)),
                                  verbDisc: min(22, token(22, floor: 20)),
                                  showsRule: s >= 0.8)
    }

    /// Standard: the look before the spacing knob, glass corner aside.
    static let standard = scaled(1)
}

/// The ⌥⇥ switcher's air from the same spacing scale as the preview:
/// the pane's inset, the rows' inset, the strip's inset and the gap
/// between cards, each its Standard value times the scale held at a
/// floor, and the zoom pane narrowing with the scale down to 80 %.
/// The glass corner is derived — the card's corner plus the strip's
/// inset, less two, the curve the switcher has always worn.
struct DockSwitcherMetrics: Equatable {
    /// Glass edge to the zoom pane, top and sides.
    let paneInset: CGFloat
    /// The search, hint and armed rows' inset.
    let rowInset: CGFloat
    /// Glass edge to the strip of cards.
    let stripInset: CGFloat
    /// Card to card along the strip.
    let cardGap: CGFloat
    /// The zoom pane's width.
    let zoomWidth: CGFloat

    /// A card's corner in the strip.
    static let cardRadius: CGFloat = 14
    /// The glass's corner, near-concentric with the strip's cards.
    var cornerRadius: CGFloat { Self.cardRadius + stripInset - 2 }

    static func scaled(_ scale: Double) -> DockSwitcherMetrics {
        let s = CGFloat(scale.isFinite ? scale : 1)
        func token(_ base: CGFloat, floor: CGFloat) -> CGFloat { max(floor, (base * s).rounded()) }
        return DockSwitcherMetrics(paneInset: token(18, floor: 10),
                                   rowInset: token(14, floor: 8),
                                   stripInset: token(12, floor: 6),
                                   cardGap: token(4, floor: 2),
                                   zoomWidth: (360 * min(max(s, 0.8), 1)).rounded())
    }

    /// Standard: the switcher before the spacing knob.
    static let standard = scaled(1)
}
