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
    /// Presentation never falls back to a process slug or bundle id.
    var displayName: String { MenuBarAppNames.displayName(ownerName) }
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
    /// The owning app's bundle identifier. nil
    /// for a bare helper process.
    /// Resolved once, when the listing is taken, from the workspace's
    /// own snapshot: read through `owner` it was a fresh LaunchServices
    /// lookup per access (26 µs), about 150 of them a reconcile pass.
    var bundleID: String? = nil
    var searchName: String? = nil

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

    /// The owners of the system's own items — the clock, Control Center,
    /// Wi-Fi, battery: the protected owners minus our own family. Every
    /// scan asks them, owners or not, and the icon's probe reads them on
    /// their own: a seat that stood on one is the worst way to be wrong.
    nonisolated static func isSystemOwner(ownerName: String) -> Bool {
        isProtected(ownerName: ownerName) && !["JR-Bar", "JRBarApp"].contains(ownerName)
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

    /// Whether any of `pids` owns an onscreen menu-layer window.
    /// The all-window snapshot also contains retained, closed menus.
    /// Those must not keep the reveal open.
    nonisolated static func menuOpen(ownerPIDs: Set<pid_t>,
                                     infos: [[String: Any]]) -> Bool {
        infos.contains { info in
            guard (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == menuWindowLayer,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            else { return false }
            return ownerPIDs.contains(pid)
        }
    }

    /// The screen whose row the divider measures. `NSScreen.main` follows
    /// the key window and may belong to another display.
    @MainActor
    static var managedScreen: NSScreen? {
        let display = CGMainDisplayID()
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        } ?? NSScreen.screens.first
    }

    /// The menu bar row in Quartz coordinates, including the notch depth.
    @MainActor
    static func menuBarRow() -> CGRect {
        let main = CGDisplayBounds(CGMainDisplayID())
        let depth = max(NSStatusBar.system.thickness,
                        managedScreen.map { ScreenBarGeometry.notchDepth(of: $0) } ?? 0)
        return CGRect(x: main.minX, y: main.minY, width: main.width, height: max(depth, 1))
    }

    /// Every display's menu bar row — each screen carries its own strip
    /// in Quartz space, and an extras item reports the frame on the bar
    /// it actually stands on. A single main-display row misclassifies a
    /// secondary-bar item as parked. Not a union rect: the dead space between two
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
    /// The latest attempt answered every known or patiently probed owner.
    /// Retained items remain useful for identity, but are not fresh geometry.
    @MainActor
    private(set) static var axInventoryComplete = false

    /// A scan is in flight — a second caller waits rather than piling
    /// another AX round trip onto tccd.
    @MainActor
    private static var axScanInFlight = false
    /// Invalidates asynchronous geometry reads across sleep, wake and
    /// display reconfiguration. A scan begun against an old arrangement
    /// may finish, but it cannot publish its frames into the new one.
    @MainActor private static var environmentGeneration: UInt64 = 0

    @MainActor
    static func invalidateGeometry() {
        environmentGeneration &+= 1
        axItems = []
        axInventoryComplete = false
        infosCache = nil
        trustCache = nil
        lastFullScanAt = .distantPast
        invalidateMenuEdge()
    }

    @MainActor
    static func invalidateMenuEdge() {
        menuEdgeGeneration += 1
        appMenuEdge = nil
        noteBarActivity()
    }

    /// Bumped whenever something that can move the bar's items happened —
    /// an app launched or quit, the screens changed, a reveal or a hide,
    /// another app took the menu bar. The listing loops watch it: a
    /// number that moved ends a long wait between scans and restarts the
    /// quick pace.
    @MainActor private(set) static var barActivity: UInt64 = 0

    @MainActor
    static let activityChanged = Notification.Name("JRBarMenuBarActivityChanged")

    @MainActor
    static func noteBarActivity() {
        barActivity &+= 1
        NotificationCenter.default.post(name: activityChanged, object: nil)
    }

    /// Whether anybody can see the bar: false while the displays sleep,
    /// the screen is locked or the session is switched away. The listing
    /// loops do not scan while it is false — their answers would go to a
    /// bar nobody is looking at, and each scan is a round of Accessibility
    /// calls into other apps.
    @MainActor private(set) static var presence = DockTickPark()

    /// Apply a display, lock or session notice; true when it ended the
    /// parked stretch (the caller restarts whatever it paused).
    @MainActor
    @discardableResult
    static func notePresence(_ event: DockTickPark.Event) -> Bool {
        let change = presence.note(event)
        if change == .resume { noteBarActivity() }
        return change == .resume
    }

    /// A fresh start: nothing is asleep as far as this run knows.
    @MainActor
    static func resetPresence() {
        presence = DockTickPark()
    }

    /// Whether the bar can be seen at all right now.
    @MainActor
    static var barIsVisible: Bool { !presence.parked }

    /// Two scans of the same bar: the same items, owned by the same apps,
    /// each within `tolerance` points of where it stood. The clock's
    /// width, and with it everything left of it, moves a point or two
    /// when its digits change, and its title is the time: neither is news.
    nonisolated static func sameListing(_ a: [MenuBarItem], _ b: [MenuBarItem],
                                        tolerance: CGFloat = 4) -> Bool {
        guard a.count == b.count else { return false }
        for (left, right) in zip(a, b) {
            guard left.id == right.id, left.ownerPID == right.ownerPID,
                  left.isNativeOverflowControl == right.isNativeOverflowControl,
                  abs(left.bounds.minX - right.bounds.minX) <= tolerance,
                  abs(left.bounds.maxX - right.bounds.maxX) <= tolerance,
                  abs(left.bounds.minY - right.bounds.minY) <= tolerance else { return false }
        }
        return true
    }

    /// The right edge of the menus on the bar — the menu-bar owner's
    /// (`menuBarOwnerApp`) — refilled by each AX scan and, when the
    /// menu bar changes hands, by `refreshMenuEdge`. Items left of it
    /// draw under menu text and are unreachable; the obscured frames
    /// start right of it. nil when the
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
        let environment = environmentGeneration
        let ownerPID = menuBarOwnerApp()?.processIdentifier
        let edge = await Task.detached(priority: .utility) {
            ownerPID.flatMap { MenuBarAX.frontMenuRightEdge(pid: $0) }
        }.value
        guard !Task.isCancelled, environment == environmentGeneration,
              token == menuEdgeGeneration, edge != appMenuEdge else { return false }
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

    /// The owners the last full scan found items for, plus any a later
    /// scan found. A quick scan asks only these — an Accessibility round
    /// trip to every running app twice a second was the app's whole idle
    /// CPU.
    @MainActor
    private(set) static var axOwnerPIDs: Set<pid_t> = []
    @MainActor
    private static var lastFullScanAt = Date.distantPast
    /// The launched apps still to be asked, and when.
    @MainActor
    private(set) static var launchProbes = MenuBarLaunchProbes()
    /// Apps that ran out of `MenuBarAX.quickTimeout` on the last scan:
    /// the next one asks them again with the owners' longer wait.
    @MainActor
    private static var slowPIDs: Set<pid_t> = []
    /// How long a quick scan may stand in for a full one. A walk asks
    /// every running app — 140-odd Accessibility servers woken for a
    /// handful of items — so this only catches an app that adds its
    /// extra later (a toggled preference, a call starting) with no
    /// launch to say so.
    nonisolated static let fullScanInterval: TimeInterval = 120
    /// After a launch, the launched app is asked again this long after
    /// it: an app draws its extra anywhere from a beat to half a minute
    /// after it starts.
    nonisolated static let launchWalkDelays: [TimeInterval] = [2, 10, 30]

    /// Apps launched: the next scan asks each of them, and so does the
    /// first scan after each of `launchWalkDelays` — the launched apps
    /// alone, not every running app, since only they can have brought a
    /// new extra. The listing loop's own cadence runs them — no timer of
    /// their own.
    @MainActor
    static func noteLaunch(pids: [pid_t], at now: Date = Date()) {
        for pid in pids { launchProbes.noteLaunch(pid, at: now) }
        if !pids.isEmpty {
            axInventoryComplete = false
            environmentGeneration += 1
            noteBarActivity()
        }
    }

    /// Apps quit: they are nobody's owner any more, and nothing is left
    /// to ask them. Their items leave with the next scan.
    @MainActor
    static func noteQuit(pids: [pid_t]) {
        for pid in pids {
            axOwnerPIDs.remove(pid)
            slowPIDs.remove(pid)
            launchProbes.noteQuit(pid)
        }
        if !pids.isEmpty {
            axInventoryComplete = false
            environmentGeneration += 1
            noteBarActivity()
        }
    }

    /// Whether a scan at `now` walks every app: no owners known yet, or
    /// the last full walk `fullScanInterval` old.
    nonisolated static func walksAll(now: Date, lastFull: Date, ownersKnown: Bool) -> Bool {
        !ownersKnown || now.timeIntervalSince(lastFull) >= fullScanInterval
    }

    /// What one scan asks, from the running apps: every app on a full
    /// walk, else the known owners, the launched apps due a look and the
    /// apps that ran out of time last scan. The owners and the retried
    /// apps get `MenuBarAX.messagingTimeout`; everyone else the quick
    /// one, except a launched app that can draw UI. Filtering comes
    /// first and reads only the index — no app is asked anything here.
    nonisolated static func scanTargets(apps: [RunningApp], walkAll: Bool, owners: Set<pid_t>,
                                        launched: Set<pid_t>, slow: Set<pid_t>) -> [MenuBarAX.Target] {
        apps.compactMap { app in
            let pid = app.pid
            // The system's own owners are asked on every scan with the
            // owners' long wait, whether or not a full walk found them
            // last time: the walk replaces the owner set with whoever
            // answered inside its short wait, and a MenuBarAgent that
            // missed it once would drop out of every quick scan for two
            // minutes — its battery and Wi-Fi unlisted, and the icon's
            // seat free to stand on them.
            let system = app.name.map { isSystemOwner(ownerName: $0) } ?? false
            let owner = owners.contains(pid) || slow.contains(pid) || system
            let fresh = launched.contains(pid)
            guard walkAll || owner || fresh else { return nil }
            guard let name = app.name, !name.isEmpty else { return nil }
            let patient = owner || (fresh && app.policy != .prohibited)
            return MenuBarAX.Target(pid: pid, name: name, bundleID: app.bundleID,
                                    timeout: patient ? MenuBarAX.messagingTimeout : MenuBarAX.quickTimeout)
        }
    }

    struct AXPublication: Sendable {
        var items: [MenuBarItem]
        var owners: Set<pid_t>
        var complete: Bool
    }

    @MainActor
    static func publishAXInventory(_ publication: AXPublication) {
        axItems = publication.items
        axOwnerPIDs = publication.owners
        axInventoryComplete = publication.complete
    }

    /// Incomplete owners keep their previous inventory, never a mixture
    /// of old and partially read geometry. Complete empty answers remove it.
    nonisolated static func mergeAXInventory(previous: [MenuBarItem], owners: Set<pid_t>,
        scanned: [MenuBarItem], targeted: Set<pid_t>, incomplete: Set<pid_t>,
        critical: Set<pid_t>, running: Set<pid_t>) -> AXPublication {
        let retained = previous.filter {
            running.contains($0.ownerPID) && (!targeted.contains($0.ownerPID) || incomplete.contains($0.ownerPID))
        }
        let answered = scanned.filter { running.contains($0.ownerPID) && !incomplete.contains($0.ownerPID) }
        let found = Set(scanned.map(\.ownerPID)).intersection(running)
        let keptOwners = owners.intersection(running).filter {
            !targeted.contains($0) || incomplete.contains($0)
        }
        let nextOwners = Set(keptOwners).union(found)
        let relevant = critical.union(owners).union(found)
        let items = retained.isEmpty ? answered : (retained + answered).sorted { $0.bounds.minX < $1.bounds.minX }
        return AXPublication(items: items,
            owners: nextOwners,
            complete: retained.isEmpty && incomplete.intersection(running).isDisjoint(with: relevant))
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
        let environment = environmentGeneration
        let rows = menuBarRows()
        let now = Date()
        let walkAll = full || walksAll(now: now, lastFull: lastFullScanAt, ownersKnown: !axOwnerPIDs.isEmpty)
        // Our own app stays in the scan: its icon lists as protected, so
        // it splits cover runs instead of disappearing under a merged one.
        let launched = launchProbes.pids(dueAt: now)
        let targets = scanTargets(apps: RunningApps.shared.apps, walkAll: walkAll, owners: axOwnerPIDs,
                                  launched: launched, slow: slowPIDs)
        menuEdgeGeneration += 1
        let edgeToken = menuEdgeGeneration
        let ownerPID = menuBarOwnerApp()?.processIdentifier
        let scanned = await Task.detached {
            (MenuBarAX.scan(targets: targets, rows: rows),
             ownerPID.flatMap { MenuBarAX.frontMenuRightEdge(pid: $0) })
        }.value
        guard !Task.isCancelled, environment == environmentGeneration,
              rows == menuBarRows() else { return axItems }
        let running = Set(RunningApps.shared.apps.map(\.pid))
        let targeted = Set(targets.map(\.pid))
        // Unknown apps that exhausted a discovery probe remain retryable,
        // but cannot freeze the bar without evidence that they own an item.
        let critical = Set(targets.filter {
            axOwnerPIDs.contains($0.pid) || launched.contains($0.pid) || isSystemOwner(ownerName: $0.name)
        }.map(\.pid))
        let publication = mergeAXInventory(previous: axItems, owners: axOwnerPIDs,
            scanned: scanned.0.items, targeted: targeted, incomplete: scanned.0.incomplete,
            critical: critical, running: running)
        publishAXInventory(publication)
        // An edge re-read that started after this scan (the menu bar
        // changed hands mid-scan) saw the newer owner and stands.
        if edgeToken == menuEdgeGeneration { appMenuEdge = scanned.1 }
        axGeneration += 1
        // Owners that quit mid-scan leave both the inventory and retry set.
        let found = Set(scanned.0.items.map(\.ownerPID))
        if walkAll {
            lastFullScanAt = now
        }
        // Incomplete discovery probes get the longer wait next time;
        // known owners remain targets even when their longer read fails.
        let quick = Set(targets.lazy.filter { $0.timeout < MenuBarAX.messagingTimeout }.map(\.pid))
        slowPIDs = scanned.0.incomplete.intersection(quick).subtracting(found).intersection(running)
        launchProbes.spend(dueAt: now)
        return axItems
    }

    /// A listing begun after this call — never the snapshot a scan
    /// already under way hands back, which can predate the caller's
    /// moment. Waits that scan out (up to `timeout`), then takes one of
    /// its own; nil when none could be had.
    @MainActor
    static func freshAXItems(timeout: TimeInterval = 3) async -> [MenuBarItem]? {
        guard timeout.isFinite, timeout > 0, !Task.isCancelled else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let environment = environmentGeneration
        while axScanInFlight {
            guard !Task.isCancelled, environment == environmentGeneration,
                  ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return nil }
        }
        let generation = axGeneration
        let read = Task { await refreshAXItems() }
        defer { read.cancel() }
        while axGeneration == generation {
            guard !Task.isCancelled, environment == environmentGeneration,
                  ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return nil }
        }
        guard environment == environmentGeneration, axInventoryComplete else { return nil }
        return axItems
    }

    /// The live list: the AX snapshot when Accessibility is granted,
    /// else the window-list fallback (still useful on systems whose
    /// items draw in per-item status-layer windows).
    @MainActor
    static func list() -> [MenuBarItem] {
        if axTrusted() { return axItems }
        var bundleIDs: [pid_t: String] = [:]
        for app in RunningApps.shared.apps {
            if let id = app.bundleID { bundleIDs[app.pid] = id }
        }
        return items(from: windowInfos(), ownPID: ProcessInfo.processInfo.processIdentifier,
                     rows: menuBarRows(), bundleIDs: bundleIDs)
    }

}

/// The launched apps the listing still has to ask, and when: at once,
/// then after each of `MenuBarItemLister.launchWalkDelays`. Pure so a
/// test drives it with a fixed clock.
struct MenuBarLaunchProbes: Equatable {
    private(set) var due: [pid_t: [Date]] = [:]

    mutating func noteLaunch(_ pid: pid_t, at now: Date) {
        due[pid] = [now] + MenuBarItemLister.launchWalkDelays.map { now.addingTimeInterval($0) }
    }

    mutating func noteQuit(_ pid: pid_t) {
        due[pid] = nil
    }

    /// The apps with a look due at `now`.
    func pids(dueAt now: Date) -> Set<pid_t> {
        Set(due.compactMap { pid, times in times.contains { $0 <= now } ? pid : nil })
    }

    /// The looks due at `now` are taken; an app with none left is done.
    mutating func spend(dueAt now: Date) {
        for (pid, times) in due {
            let left = times.filter { $0 > now }
            due[pid] = left.isEmpty ? nil : left
        }
    }
}
