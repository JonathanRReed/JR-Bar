import AppKit
import JRBarCore

/// One menu bar item another app owns: a window on the status layer of
/// the menu bar row, read off `CGWindowListCopyWindowInfo`. The bounds
/// stay in Quartz screen coordinates (top-left origin) — the same space
/// the window list reports and `CGEvent` posts in, so a click reposted
/// at the frame needs no conversion.
struct MenuBarItem: Equatable, Sendable {
    /// The identity `MenuBarSettings.sections` is keyed by: the owner's
    /// name — plus an `AXIdentifier` or title when it carries one —
    /// with a per-owner ordinal only when an owner fields more than one
    /// item. Moving positions do not rename an item; an owner relaunch
    /// does not either.
    let id: String
    let ownerPID: pid_t
    let ownerName: String
    /// The item's frame in Quartz screen coordinates (top-left origin).
    /// Items macOS has parked in its own overflow report a position
    /// below the row — they still list, and `AXPress` still reaches them.
    let bounds: CGRect
    let title: String?
    let windowID: CGWindowID
    /// The item's `AXIdentifier` when it exposes one — the stablest key
    /// an item offers (e.g. `com.apple.menuextra.wifi`).
    var identifier: String? = nil
    /// The item's index inside its owner's extras-menu-bar children —
    /// the last resort for re-resolving the `AXUIElement` a tile click
    /// presses.
    var extrasIndex: Int = 0
    /// macOS 26's own overflow control — the "Show Hidden Menu Bar
    /// Items" button MenuBarAgent draws at the left end of the visible
    /// run whenever something is parked. Listed so the plan can tell
    /// an item stacked under it from one on the row; never covered,
    /// never pressed.
    var isNativeOverflowControl: Bool = false
    /// The owning app's bundle identifier — the concealer's key. nil
    /// for a bare helper process, which the agent can never conceal.
    /// Resolved once, when the listing is taken, from the workspace's
    /// own snapshot: read through `owner` it was a fresh LaunchServices
    /// lookup per access (26 µs), about 150 of them a reconcile pass.
    var bundleID: String? = nil

    /// The owning app, for the tile's icon and the always-hidden tile's
    /// raise — a LaunchServices lookup per read, so never on a pass.
    var owner: NSRunningApplication? {
        NSRunningApplication(processIdentifier: ownerPID)
    }
}

/// Enumerates the menu bar's items off the window list. The filter is a
/// pure function of the raw dicts so the rules — the status layer, the
/// row's band, our own process, the protected owners — are testable
/// without a screen.
enum MenuBarItemLister {
    /// `kCGWindowLayer` for the windows menu bar items are: the status
    /// window layer, just above the menu bar's own.
    nonisolated static let statusWindowLayer = 25
    /// A window slimmer than this on the row is a stray, not an item.
    nonisolated static let minItemWidth: CGFloat = 4
    /// Owners the utility never lists, counts or hides: the system
    /// items MenuBarAgent owns — the clock, Control Center, Wi-Fi,
    /// battery — are pinned by the system and are never ours to cover
    /// or move. (The app menu is the frontmost app's own drawing; it
    /// is never an extras item.)
    nonisolated static let protectedOwnerNames: Set<String> = [
        "Control Center", "ControlCenter", "MenuBarAgent", "TextInputMenuAgent",
        "TextInputSwitcher", "Spotlight",
        // Our own extras items — the chevron, the always-hidden
        // control, the meters — are never ours to cover or move, and
        // their frames split cover runs.
        "JR-Bar", "JRBarApp",
    ]

    nonisolated static func isProtected(ownerName: String) -> Bool {
        protectedOwnerNames.contains(ownerName)
    }

    /// Whether the owner is a pinned system item — the clock, Control
    /// Center, Wi-Fi. Protected items are still *listed* (the reveal's
    /// empty-space hit test and the section plan both need their
    /// frames); protection only means the utility never covers or
    /// moves them.
    nonisolated static func isProtected(_ item: MenuBarItem) -> Bool {
        isProtected(ownerName: item.ownerName)
    }

    /// One raw window-info dict → an item, or nil when it is not one of
    /// the menu bar's. `rows` are the displays' bar strips in Quartz
    /// coordinates; an item only needs to overlap a row's band —
    /// items pushed off the screen edge horizontally still report in,
    /// which is how a hidden run keeps its identity.
    nonisolated static func item(from info: [String: Any], ownPID: pid_t, rows: [CGRect]) -> MenuBarItem? {
        guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == statusWindowLayer else { return nil }
        guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              pid != ownPID else { return nil }
        let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
        guard !isProtected(ownerName: ownerName) else { return nil }
        guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              !bounds.isEmpty, bounds.width >= minItemWidth else { return nil }
        guard rows.contains(where: { bounds.minY < $0.maxY && bounds.maxY > $0.minY })
        else { return nil }
        let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
        return MenuBarItem(id: "", ownerPID: pid, ownerName: ownerName,
                           bounds: bounds, title: title, windowID: windowID)
    }

    /// Window-info dicts → the items, sorted left to right, identities
    /// assigned: `ownerName`, `ownerName·title` when the window has one,
    /// and a `#n` ordinal only when the same base fields more than one.
    /// `bundleIDs` is the workspace snapshot the owners' identifiers
    /// come from, keyed by pid.
    nonisolated static func items(from infos: [[String: Any]], ownPID: pid_t, rows: [CGRect],
                                  bundleIDs: [pid_t: String] = [:]) -> [MenuBarItem] {
        var items = infos.compactMap { item(from: $0, ownPID: ownPID, rows: rows) }
        items.sort {
            $0.bounds.minX == $1.bounds.minX ? $0.windowID < $1.windowID
                                             : $0.bounds.minX < $1.bounds.minX
        }
        var totals: [String: Int] = [:]
        for item in items { totals[base(of: item), default: 0] += 1 }
        var seen: [String: Int] = [:]
        return items.map { item in
            let base = base(of: item)
            var id = base
            if totals[base, default: 0] > 1 {
                let n = seen[base, default: 0]
                seen[base] = n + 1
                id = "\(base)#\(n)"
            }
            return MenuBarItem(id: id, ownerPID: item.ownerPID, ownerName: item.ownerName,
                               bounds: item.bounds, title: item.title, windowID: item.windowID,
                               identifier: item.identifier, extrasIndex: item.extrasIndex,
                               isNativeOverflowControl: item.isNativeOverflowControl,
                               bundleID: bundleIDs[item.ownerPID])
        }
    }

    /// The identity's stem before the ordinal: `owner`, or
    /// `owner·identifier`/`owner·title` when the item carries one.
    /// An `AXIdentifier` outranks a title — it is the key that survives
    /// localization and relabeling.
    nonisolated static func base(of item: MenuBarItem) -> String {
        if let key = item.identifier ?? item.title { return "\(item.ownerName)·\(key)" }
        return item.ownerName
    }

    /// The window layer pop-up menus draw on — a status item's open
    /// menu is one of these, owned by the item's app.
    nonisolated static var menuWindowLayer: Int {
        Int(CGWindowLevelForKey(.popUpMenuWindow))
    }

    /// Whether any of `pids` owns a menu-layer window — a status item's
    /// menu currently open. A reveal must not fold the run out from
    /// under a menu the person is reading.
    nonisolated static func menuOpen(ownerPIDs: Set<pid_t>,
                                     infos: [[String: Any]]) -> Bool {
        infos.contains { info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == menuWindowLayer,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            else { return false }
            return ownerPIDs.contains(pid)
        }
    }

    /// The menu bar row in Quartz coordinates: the top of the main
    /// display, `NSStatusBar.system.thickness` deep — or the notch's
    /// depth where one reaches below it.
    @MainActor
    static func menuBarRow() -> CGRect {
        let main = CGDisplayBounds(CGMainDisplayID())
        let depth = max(NSStatusBar.system.thickness,
                        NSScreen.main.map { ScreenBarGeometry.notchDepth(of: $0) } ?? 0)
        return CGRect(x: main.minX, y: main.minY, width: main.width, height: max(depth, 1))
    }

    /// Every display's menu bar row — each screen carries its own strip
    /// in Quartz space, and an extras item reports the frame on the bar
    /// it actually stands on. A single main-display row misclassifies a
    /// secondary-bar item as parked, which is how it would read to a
    /// conceal sweep. Not a union rect: the dead space between two
    /// displays' bars must not count as on-row.
    @MainActor
    static func menuBarRows() -> [CGRect] {
        var rows: [CGRect] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber else { continue }
            let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            let depth = max(NSStatusBar.system.thickness,
                            ScreenBarGeometry.notchDepth(of: screen))
            rows.append(CGRect(x: bounds.minX, y: bounds.minY,
                               width: bounds.width, height: max(depth, 1)))
        }
        return rows.isEmpty ? [menuBarRow()] : rows
    }

    /// Does `bounds` stand on any display's menu bar row.
    @MainActor
    static func onAnyMenuBarRow(_ bounds: CGRect) -> Bool {
        menuBarRows().contains { $0.intersects(bounds) }
    }

    /// One window-list snapshot shared by `list` and the open-menu
    /// check. The call is a WindowServer round trip with TCC accounting
    /// on the other end, so a burst of consumers inside `infosCacheTTL`
    /// — a reconcile plus a rehide's menu check, say — pays it once.
    @MainActor
    private static var infosCache: (at: Date, infos: [[String: Any]])?
    /// How long a snapshot stays fresh. Shorter than the reconcile
    /// cadence, so every timer pass still reads a live list.
    nonisolated static let infosCacheTTL: TimeInterval = 0.75

    /// The raw window-info dicts, cached for `infosCacheTTL`.
    @MainActor
    static func windowInfos() -> [[String: Any]] {
        if let cache = infosCache, Date().timeIntervalSince(cache.at) < infosCacheTTL {
            return cache.infos
        }
        let infos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        infosCache = (Date(), infos)
        return infos
    }

    /// The latest Accessibility snapshot. macOS 26 draws the extras
    /// region in full-width layer-0 windows, so the window list no
    /// longer exposes per-item frames — `AXExtrasMenuBar` is the only
    /// source of real item geometry. The cache is what `list` reads;
    /// `refreshAXItems` refills it off-actor.
    @MainActor
    private(set) static var axItems: [MenuBarItem] = []
    /// Bumped on every completed AX scan — a reader that wrote a
    /// length can tell whether the listing it sees is from before or
    /// after the write.
    @MainActor
    private(set) static var axGeneration = 0

    /// A scan is in flight — a second caller waits rather than piling
    /// another AX round trip onto tccd.
    @MainActor
    private static var axScanInFlight = false

    /// The right edge of the menus on the bar — the menu-bar owner's
    /// (`menuBarOwnerApp`) — refilled by each AX scan and, when the
    /// menu bar changes hands, by `refreshMenuEdge`. Items left of it
    /// draw under menu text and are unreachable; the icon's mirror and
    /// the concealer's reveal zone start right of it. nil when the
    /// owner did not answer its AXMenuBar.
    @MainActor
    private(set) static var appMenuEdge: CGFloat?
    /// Bumped by every read of the menu edge — a scan's or
    /// `refreshMenuEdge`'s — so a slow read that lands after a newer
    /// one, which saw a newer owner, is dropped.
    @MainActor
    private static var menuEdgeGeneration = 0

    /// The app whose menus are on the bar. Not always the frontmost
    /// app: an accessory app that activates — JR-Bar's own Settings or
    /// Usage window, Raycast — becomes frontmost while the previous
    /// regular app keeps the menu bar, and an accessory app's own
    /// AXMenuBar items report 0×0 (JR-Bar's and Raycast's, probed
    /// 2026-09-22), so reading it left the edge nil with the owner's
    /// menus still on screen. The band's `AppMenuExtent` asks the same
    /// question; one answer keeps the two from disagreeing about whose
    /// menus they avoid.
    @MainActor
    static func menuBarOwnerApp() -> NSRunningApplication? {
        let workspace = NSWorkspace.shared
        return workspace.menuBarOwningApplication ?? workspace.frontmostApplication
    }

    /// Re-read only the menu edge — the listing's AX scan runs every
    /// 2 s, and after an app switch the edge it left is the previous
    /// owner's until the next one. Called when the menu bar changes
    /// hands; a full item scan per activation is the energy pattern
    /// this utility avoids, and one already in flight would drop the
    /// request anyway. The AX read runs off the main actor. Returns
    /// whether the edge moved.
    @MainActor
    @discardableResult
    static func refreshMenuEdge() async -> Bool {
        guard axTrusted() else { return false }
        menuEdgeGeneration += 1
        let token = menuEdgeGeneration
        let ownerPID = menuBarOwnerApp()?.processIdentifier
        let edge = await Task.detached(priority: .utility) {
            ownerPID.flatMap { MenuBarAX.frontMenuRightEdge(pid: $0) }
        }.value
        guard token == menuEdgeGeneration, edge != appMenuEdge else { return false }
        appMenuEdge = edge
        return true
    }

    /// The Accessibility answer, cached for `trustCacheTTL`. Not for
    /// TCC's sake: measured 2026-09-22, `AXIsProcessTrusted` sends one
    /// `TCCAccessRequest` IPC on its first call only and answers
    /// locally after that — the TCC line that recurred every 3 s (212
    /// requests in ten minutes) was DockEnhance's
    /// `CGPreflightScreenCaptureAccess`, not this. The cache stays
    /// because it costs nothing: a grant that changes is rare, and a
    /// revoked one already shows as an empty scan, so the listing
    /// follows within 10 s. `MenuBarUtility.probeAccessibility` holds
    /// the card's copy.
    @MainActor
    private static var trustCache: (at: Date, trusted: Bool)?
    nonisolated static let trustCacheTTL: TimeInterval = 10

    /// The cached Accessibility answer.
    @MainActor
    static func axTrusted() -> Bool {
        if let cache = trustCache, Date().timeIntervalSince(cache.at) < trustCacheTTL {
            return cache.trusted
        }
        let trusted = AXIsProcessTrusted()
        trustCache = (Date(), trusted)
        return trusted
    }

    /// The owners the last full scan found items for. A quick scan asks
    /// only these — an Accessibility round trip to every running app
    /// twice a second was the app's whole idle CPU.
    @MainActor
    private(set) static var axOwnerPIDs: Set<pid_t> = []
    @MainActor
    private static var lastFullScanAt = Date.distantPast
    /// The full walks app launches asked for that are still to come.
    @MainActor
    private(set) static var launchWalksDue: [Date] = []
    /// How long a quick scan may stand in for a full one. A walk asks
    /// every running app — 140-odd Accessibility servers woken for a
    /// handful of items — and launches and quits force one on their
    /// own, so this only catches an app that adds its extra later (a
    /// toggled preference, a call starting) with no launch to say so.
    nonisolated static let fullScanInterval: TimeInterval = 120
    /// After a launch, full walks this long after it too: an app draws
    /// its extra anywhere from a beat to half a minute after the launch
    /// notification, past the walk the launch itself forces.
    nonisolated static let launchWalkDelays: [TimeInterval] = [2, 10, 30]

    /// Forces the next scan to walk every app.
    @MainActor
    static func invalidateOwners() { lastFullScanAt = .distantPast }

    /// An app launched: the next scan walks every app, and so does the
    /// first scan after each of `launchWalkDelays`. The listing loop's
    /// own cadence runs them — no timer of their own.
    @MainActor
    static func noteLaunch(at now: Date = Date()) {
        invalidateOwners()
        launchWalksDue += launchWalkDelays.map { now.addingTimeInterval($0) }
    }

    /// Whether a scan at `now` walks every app: no owners known yet, the
    /// last full walk `fullScanInterval` old, or a launch's walk due.
    nonisolated static func walksAll(now: Date, lastFull: Date, ownersKnown: Bool,
                                     launchWalksDue due: [Date]) -> Bool {
        !ownersKnown || now.timeIntervalSince(lastFull) >= fullScanInterval || due.contains { $0 <= now }
    }

    /// Re-run the AX scan off the main actor and refill `axItems`.
    /// Callers pick the cadence; the in-flight flag makes overlap a
    /// no-op. Returns the fresh list.
    @MainActor
    @discardableResult
    static func refreshAXItems(full: Bool = false) async -> [MenuBarItem] {
        if axScanInFlight { return axItems }
        axScanInFlight = true
        defer { axScanInFlight = false }
        let rows = menuBarRows()
        let now = Date()
        let walkAll = full || walksAll(now: now, lastFull: lastFullScanAt,
                                       ownersKnown: !axOwnerPIDs.isEmpty, launchWalksDue: launchWalksDue)
        // Our own app stays in the scan — its extras items list as
        // protected, so the chevron and the always-hidden control split
        // cover runs instead of disappearing under a merged one.
        let targets = NSWorkspace.shared.runningApplications.compactMap { app -> MenuBarAX.Target? in
            guard !app.isTerminated,
                  let name = app.localizedName, !name.isEmpty else { return nil }
            if !walkAll, !axOwnerPIDs.contains(app.processIdentifier) { return nil }
            return MenuBarAX.Target(pid: app.processIdentifier, name: name,
                                    bundleID: app.bundleIdentifier)
        }
        menuEdgeGeneration += 1
        let edgeToken = menuEdgeGeneration
        let ownerPID = menuBarOwnerApp()?.processIdentifier
        let scanned = await Task.detached {
            (MenuBarAX.items(targets: targets, rows: rows),
             ownerPID.flatMap { MenuBarAX.frontMenuRightEdge(pid: $0) })
        }.value
        axItems = scanned.0
        // An edge re-read that started after this scan (the menu bar
        // changed hands mid-scan) saw the newer owner and stands.
        if edgeToken == menuEdgeGeneration { appMenuEdge = scanned.1 }
        axGeneration += 1
        if walkAll {
            axOwnerPIDs = Set(scanned.0.map(\.ownerPID))
            lastFullScanAt = now
            launchWalksDue.removeAll { $0 <= now }
        }
        return scanned.0
    }

    /// A listing begun after this call — never the snapshot a scan
    /// already under way hands back, which can predate the caller's
    /// moment. Waits that scan out (up to `timeout`), then takes one of
    /// its own; nil when none could be had.
    @MainActor
    static func freshAXItems(timeout: TimeInterval = 3) async -> [MenuBarItem]? {
        let deadline = Date().addingTimeInterval(timeout)
        while axScanInFlight {
            guard Date() < deadline else { return nil }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let generation = axGeneration
        let listed = await refreshAXItems()
        return axGeneration != generation ? listed : nil
    }

    /// The live list: the AX snapshot when Accessibility is granted,
    /// else the window-list fallback (still useful on systems whose
    /// items draw in per-item status-layer windows).
    @MainActor
    static func list() -> [MenuBarItem] {
        if axTrusted() { return axItems }
        var bundleIDs: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { bundleIDs[app.processIdentifier] = id }
        }
        return items(from: windowInfos(), ownPID: ProcessInfo.processInfo.processIdentifier,
                     rows: menuBarRows(), bundleIDs: bundleIDs)
    }

}
