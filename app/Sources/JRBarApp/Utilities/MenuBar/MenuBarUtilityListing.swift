import AppKit
import ApplicationServices
import CoreGraphics
import JRBarCore
import Observation
import SwiftUI

/// The Menu Bar utility's listing: the card's item rows and the Item
/// Bar's tiles.
extension MenuBarUtility {
    // MARK: Listing (the card's item rows)

    /// The card's enumeration with the utility parked: refresh the AX
    /// snapshot (off-actor — a slow app must not stall the card) and
    /// run the listing-only plan — a parked utility draws no covers,
    /// so everything on the row reports as it sits.
    func refreshListing() {
        probeAccessibility()
        guard !running else { return }
        guard accessibilityGranted else {
            lastPlan = MenuBarItemHider.unzonedPlan(
                items: MenuBarItemLister.list(), rows: MenuBarItemLister.menuBarRows())
            return
        }
        Task { [weak self] in
            _ = await MenuBarItemLister.refreshAXItems()
            guard let self, !self.running else { return }
            self.lastPlan = MenuBarItemHider.unzonedPlan(
                items: MenuBarItemLister.axItems, rows: MenuBarItemLister.menuBarRows())
        }
    }

    /// Every item the card lists, in bar order.
    var listedItems: [MenuBarItem] {
        lastPlan.shown + lastPlan.hidden + lastPlan.alwaysHidden
    }

    /// The Item Bar's tiles: both hidden runs.
    func barItems() -> [MenuBarItem] {
        lastPlan.hidden + lastPlan.alwaysHidden
    }

    /// The `.bar` reveal surface for a gesture — a hover, a click on the
    /// blank stretch, a scroll. A gesture only ever opens: a scroll
    /// stream re-fires every half second and a hover re-entry lands
    /// while the bar is up, and a toggle here flapped the bar shut under
    /// the hand (161 scroll notices in two minutes, 2026-09-22). A click
    /// on the blank stretch still folds an open bar — the bar's own
    /// outside-click monitor closes it — so a gesture landing in the same
    /// beat as that close does not reopen it. The deliberate toggle is
    /// `toggleHiddenSection` (the ‹, the menu, the hotkey). When the item
    /// list is empty — the grant is gone or macOS stopped reporting — an
    /// empty bar would answer the gesture with nothing, so a deployed
    /// hidden section falls back to the inline reveal: the covers drop
    /// and the run is reachable without any listing at all.
    func revealBarStyle() {
        guard !bar.isOpen,
              !Self.gestureRefolds(closedAt: barClosedAtUptime,
                                   now: ProcessInfo.processInfo.systemUptime) else { return }
        if !barItems().isEmpty {
            bar.open()
            return
        }
        let glyph = host?.boundaryGlyphLength ?? MenuBarControlFrames.glyphLength
        if (hider.assignedLengths[.hidden] ?? glyph) > glyph + 1 {
            hider.reveal([.hidden, .alwaysHidden])
        }
    }

    /// How close behind a fold a gesture counts as the click that
    /// folded it: the bar's monitor and the reveal's arrive as two
    /// unordered main-actor hops of the same event.
    nonisolated static let gestureRefoldWindow: TimeInterval = 0.3

    /// Whether a gesture at `now` belongs to the fold at `closedAt`.
    /// Pure so a test pins the window.
    nonisolated static func gestureRefolds(closedAt: TimeInterval, now: TimeInterval) -> Bool {
        now - closedAt < gestureRefoldWindow
    }

    /// Whether an owner of a covered item currently has a menu-layer
    /// window up — the reveal must not fold the run out from under a
    /// menu the person is reading.
    func listedItemMenuOpen() -> Bool {
        let pids = Set((lastPlan.hidden + lastPlan.alwaysHidden).map(\.ownerPID))
        guard !pids.isEmpty else { return false }
        return MenuBarItemLister.menuOpen(ownerPIDs: pids,
                                          infos: MenuBarItemLister.windowInfos())
    }

    /// `concealedApps` entries whose bundle identifier no longer
    /// resolves — uninstalled apps the map still carries. A quit app's
    /// id still resolves on disk, so only genuinely gone entries are
    /// dropped; the user's choices survive an app merely not running.
    /// Runs after every plan, so the cheap answers go first — the
    /// running check is the `RunningApps` index's — and the disk lookup
    /// last, through `installedApps`, which keeps a found app's answer
    /// for a while instead of asking LaunchServices every pass.
    func pruneUninstalledConcealedApps() {
        let apps = settings().concealedApps
        guard !apps.isEmpty else { return }
        let running = RunningApps.shared
        let stale = apps.keys.filter { id in
            // The clock's and Control Center's keys are items, not apps:
            // nothing installs them, and nothing uninstalls them.
            MenuBarConcealPlan.concealableSystemItems[id] == nil
                && !running.isRunning(bundleID: id)
                // A helper bundled inside another app resolves neither
                // lookup but is installed and will be back — an id that
                // owned an item this session is not "uninstalled".
                && knownItems[id] == nil
                && !installedApps.isInstalled(id)
        }
        guard !stale.isEmpty else { return }
        update { draft in
            for id in stale { draft.concealedApps.removeValue(forKey: id) }
        }
    }

    /// Anyone's item but ours — the system's extras included: a gesture
    /// must respect the clock and Wi-Fi, never our own spacer.
    nonisolated static func isForeignOwner(_ owner: String) -> Bool {
        !["JR-Bar", "JRBarApp"].contains(owner)
    }

    /// Our own family's bundle identifiers — the app's
    /// (`com.jonathanreed.jrbar`) and every helper it ships, the daemon
    /// `com.jonathanreed.jrbar.core` included. Their items are never
    /// conceal candidates: the agent would take them, and hiding our
    /// own meter behind our own utility is exactly the self-inflicted
    /// wound the running-set sweep once caused.
    nonisolated static func isOwnFamily(_ id: String?) -> Bool {
        guard let id, let own = Bundle.main.bundleIdentifier else { return false }
        return id == own || id.hasPrefix(own + ".")
    }

    /// The on-row items a click should count as "on an item" — the
    /// shown zone only. Covered items are the reveal zone itself.
    /// Frames arrive in Quartz and flip to AppKit for the hit test.
    func shownItemFrames() -> [NSRect] {
        let height = CGDisplayBounds(CGMainDisplayID()).height
        // The « is covered while the run is hidden — a click on it is
        // the reveal, not a click on an item. Our own items are the
        // boundary and the controls: the host's frame spans the whole
        // blank stretch, which is exactly the zone a gesture lands on.
        var frames = lastPlan.shown.filter {
            !$0.isNativeOverflowControl && Self.isForeignOwner($0.ownerName)
        }.map {
            NSRect(x: $0.bounds.minX, y: height - $0.bounds.maxY,
                   width: $0.bounds.width, height: $0.bounds.height)
        }
        // The extra items (spacers, agent, combined): their own actions
        // answer the click — it must not ALSO land as a blank-stretch
        // reveal, or a hide click double-fires.
        for item in spacerItems.values + [agentItem, combinedItem.item].compactMap({ $0 }) {
            if let quartz = Self.quartzFrame(of: item) {
                let height = CGDisplayBounds(CGMainDisplayID()).height
                frames.append(NSRect(x: quartz.minX, y: height - quartz.maxY,
                                     width: quartz.width, height: quartz.height))
            }
        }
        return frames
    }
}

/// Whether an app is installed, by bundle identifier, for the prune. A
/// found app stays found for `ttl` — uninstalling one is rare, and the
/// prune asks after every plan — while a missing one is asked again each
/// time, so an app installed since is seen at once.
@MainActor
final class InstalledBundleCache {
    nonisolated static let defaultTTL: TimeInterval = 600

    private let ttl: TimeInterval
    private let lookUp: @MainActor (String) -> Bool
    private let monotonic: () -> TimeInterval
    private var foundAt: [String: TimeInterval] = [:]

    init(ttl: TimeInterval = InstalledBundleCache.defaultTTL,
         lookUp: @escaping @MainActor (String) -> Bool = {
             NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
         },
         monotonic: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.ttl = ttl
        self.lookUp = lookUp
        self.monotonic = monotonic
    }

    func isInstalled(_ bundleID: String) -> Bool {
        let now = monotonic()
        if let at = foundAt[bundleID], now >= at, now - at < ttl { return true }
        guard lookUp(bundleID) else {
            foundAt[bundleID] = nil
            return false
        }
        foundAt[bundleID] = now
        return true
    }
}
