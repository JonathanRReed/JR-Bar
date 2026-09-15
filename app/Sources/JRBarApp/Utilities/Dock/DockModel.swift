import AppKit
import ApplicationServices
import JRBarCore
import Observation

/// One tile in the bar. Value type so ordering, seeding and pin edits
/// are testable without `NSRunningApplication`; the app-side icon is
/// resolved by the view (`NSWorkspace.icon(forFile:)`) rather than
/// carried here.
struct DockItem: Identifiable, Equatable, Sendable {
    /// The bundle id — identity, pin key and dedupe key in one.
    var id: String { bundleID }
    let bundleID: String
    var name: String
    var bundleURL: URL?
    var isRunning: Bool
    var isPinned: Bool
    /// Set for running apps; the actions re-resolve the
    /// `NSRunningApplication` from it.
    var processIdentifier: pid_t?
    /// Hidden-but-running dims the tile (public on NSRunningApplication).
    var isHidden: Bool = false
    /// A badge string when one is readable. Honest gap: no public API
    /// exposes a running app's Dock badge — `NSRunningApplication`
    /// carries no count and our own `NSDockTile` only covers ourselves.
    /// Filled from `DockModel.badgeSource` so a later AX read of Apple's
    /// (hidden) Dock lands without a model change.
    var badge: String?
    /// The Trash tile is a sentinel appended after the app run, not a
    /// bundle — it never pins, launches, or shows a running mark.
    var isTrash: Bool = false
    /// Whether `~/.Trash` held no items at the last refresh — picks
    /// the empty-can icon and greys "Empty Trash".
    var trashIsEmpty: Bool = true
    /// A folder-stack tile (P2): the click opens the contents popover
    /// rather than an app; `bundleURL` carries the folder's file URL.
    var isFolder: Bool = false
    /// A file parked in the tray (P3): click opens, menu reveals or
    /// removes; `bundleURL` is the file's URL.
    var isTrayItem: Bool = false
    /// A dock-widget tile (P4) — nil for every real item. Widgets
    /// render their own content instead of an icon.
    var widget: DockWidgetKind?
}

/// The bar's contents: the pinned run first, then running apps, in the
/// order `NSWorkspace` reports them. Refreshes off
/// `NSWorkspace.notificationCenter` launch/terminate posts and the
/// caller's nudges.
///
/// Seams are closures so the tests run without a real workspace:
/// `runningApplications`, `resolveApplicationURL`, `pinSource` (the
/// `com.apple.dock` read) and `badgeSource` all swap for fakes.
@MainActor
@Observable
final class DockModel {
    /// The tiles in dock order: pins first, then running apps that
    /// aren't pinned, deduped by bundle id.
    private(set) var items: [DockItem] = []
    /// Pin order. Mirrors `settings().pinned` except across the seed
    /// and pin edits — both report through the callbacks so the caller
    /// can persist.
    private(set) var pinnedIDs: [String] = []
    /// Finder's bundle id — the `showFinder` toggle's only subject.
    static let finderBundleID = "com.apple.finder"
    /// The Trash tile's sentinel id — deliberately not a bundle id, so
    /// it can never collide with a real app or land in `pinned`.
    static let trashBundleID = "jrbar.dock-trash"
    /// The folder the Trash tile opens and empties.
    static let trashURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".Trash")

    /// The widgets' live data — one model shared by every panel's
    /// view (the clock face needs nothing; the battery tile reads
    /// `power`, polled while the battery widget is on).
    let widgetModel = DockWidgetModel()
    /// Folder-stack paths in dock order — mirrors `settings().folders`
    /// except across dock-side edits, which report through
    /// `onFoldersChanged` for persistence (same shape as `pinnedIDs`).
    private(set) var folderPaths: [String] = []
    /// The tray's parked file paths — `settings().tray`'s live twin.
    private(set) var trayPaths: [String] = []

    /// The live settings read, wired by `DockUtility`.
    var settings: @MainActor () -> DockSettings = { DockSettings() }
    /// Pins changed by the user (toggle, reorder) — persist this list.
    var onPinsChanged: (@MainActor ([String]) -> Void)?
    /// The Apple-Dock seed ran — persist this list AND set
    /// `DockSettings.seededFromAppleDock` so it never runs twice.
    var onSeeded: (@MainActor ([String]) -> Void)?
    /// `items` changed — panels re-anchor. `DockUtility` fans this out.
    var onItemsChanged: (@MainActor () -> Void)?
    /// The folder list changed on the bar (drop, unpin) — persist it
    /// into `DockSettings.folders`.
    var onFoldersChanged: (@MainActor ([String]) -> Void)?
    /// The tray's contents changed — persist into `DockSettings.tray`.
    var onTrayChanged: (@MainActor ([String]) -> Void)?

    // MARK: Injected seams

    var runningApplications: @MainActor () -> [NSRunningApplication] =
        { NSWorkspace.shared.runningApplications }
    var resolveApplicationURL: @MainActor (String) -> URL? =
        { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    /// The `com.apple.dock persistent-apps` read; nil = suite unreadable.
    var pinSource: @MainActor () -> [String]? = { AppleDockPins.persistentAppBundleIDs() }
    /// Badge strings by bundle id; empty by default (see `DockItem.badge`).
    var badgeSource: @MainActor () -> [String: String] = { [:] }
    /// What `~/.Trash` holds; nil = unreadable (treated as empty).
    var trashContents: @MainActor () -> [String]? = {
        try? FileManager.default.contentsOfDirectory(atPath: DockModel.trashURL.path)
    }
    /// Opens a URL — the Trash folder in Finder. Injectable.
    var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The "Empty Trash" confirm; the default runs a real alert so a
    /// menu misclick can't delete anything. Injectable for tests.
    var confirmEmptyTrash: @MainActor () -> Bool = {
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "The items in the Trash will be deleted permanently."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Deletes one Trash entry by path. Injectable for tests.
    var trashRemover: @MainActor (String) -> Void = {
        try? FileManager.default.removeItem(atPath: $0)
    }
    /// Ourselves — never our own tile.
    var ownBundleID: String = Bundle.main.bundleIdentifier ?? "com.jonathanreed.jrbar"
    /// Whether a path exists right now — folder/tray tiles skip missing
    /// paths without dropping the pin (an ejected disk comes back).
    var pathExists: @MainActor (String) -> Bool = {
        FileManager.default.fileExists(atPath: $0)
    }
    /// Directory check for drop classification — directories become
    /// folder stacks, everything else parks in the tray.
    var directoryCheck: @MainActor (URL) -> Bool = {
        (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
    /// "Reveal in Finder" for folder/tray tiles. Injectable.
    var revealURL: @MainActor (URL) -> Void = {
        NSWorkspace.shared.activateFileViewerSelecting([$0])
    }
    /// Moves a file into a folder — the folder tile's drop target.
    /// Injectable; the default is a best-effort `FileManager` move.
    var fileMover: @MainActor (URL, URL) -> Bool = { source, folder in
        (try? FileManager.default.moveItem(
            at: source,
            to: folder.appendingPathComponent(source.lastPathComponent))) != nil
    }
    /// An app's windows for scroll-cycling — the AX read. Injectable;
    /// empty without Accessibility, which falls back to activate.
    var windowProvider: @MainActor (pid_t) -> [DockPreviewWindow] =
        { AppleDockReader.windows(pid: $0) }
    /// Raises one window for a cycle step — un-minimize, `AXRaise`,
    /// `AXMain`, then a plain `activate`. Deliberately not
    /// `activateAllWindows`: that would undo the point of cycling.
    var windowCycler: @MainActor (DockPreviewWindow, NSRunningApplication?) -> Void = { window, app in
        if let element = window.element {
            if window.minimized {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                             false as CFTypeRef)
            }
            AXUIElementPerformAction(element, "AXRaise" as CFString)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString,
                                         true as CFTypeRef)
        }
        app?.activate()
    }
    /// The activate fallback for a cycle over an app with no
    /// AX-readable windows — separate from `windowCycler` so tests can
    /// watch it. Injectable.
    var activateApp: @MainActor (NSRunningApplication) -> Void = { $0.activate() }

    private(set) var running = false
    /// Live apps by bundle id, for the actions — refreshed with `items`.
    @ObservationIgnored private var apps: [String: NSRunningApplication] = [:]
    /// The window-cycle cursor per bundle id — which window the next
    /// scroll step lands on.
    @ObservationIgnored private var cycleCursors: [String: Int] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {}

    // MARK: Lifecycle

    /// Seeds pins on first run, then subscribes to the workspace. Safe
    /// to call twice.
    func start() {
        guard !running else { return }
        running = true
        pinnedIDs = DockSettings.deduped(settings().pinned)
        folderPaths = DockSettings.deduped(settings().folders)
        trayPaths = DockSettings.deduped(settings().tray)
        seedPinsIfNeeded()
        let center = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append(observer)
        }
        refresh()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers = []
        apps = [:]
        cycleCursors = [:]
        widgetModel.stop()
        running = false
    }

    /// Re-mirror the persisted collections — the card's folder/tray
    /// edits arrive here via `DockUtility.applySettings`; dock-side
    /// edits originate in the model and report out instead.
    func syncCollections() {
        folderPaths = DockSettings.deduped(settings().folders)
        trayPaths = DockSettings.deduped(settings().tray)
        refresh()
    }

    /// Runs once: merge `persistent-apps` under any pins the user
    /// already has, then hand the list up so `seededFromAppleDock` is
    /// persisted with it. An unreadable suite still seals the flag —
    /// the alternative is re-reading `com.apple.dock` on every launch
    /// for a migration that already failed once.
    private func seedPinsIfNeeded() {
        guard !settings().seededFromAppleDock else { return }
        let seeded = pinSource() ?? []
        let merged = DockSettings.deduped(pinnedIDs + seeded)
        pinnedIDs = merged
        onSeeded?(merged)
    }

    // MARK: Ordering

    /// Pins first in pin order, then running apps that aren't pinned,
    /// deduped by bundle id. A pinned app's running entry folds into
    /// its pin tile (`isRunning`, pid, hidden flag travel across) so a
    /// running pin never draws twice.
    static func ordered(pinned: [DockItem], running: [DockItem]) -> [DockItem] {
        var seen = Set<String>()
        var out: [DockItem] = []
        for var pin in pinned where seen.insert(pin.bundleID).inserted {
            if let live = running.first(where: { $0.bundleID == pin.bundleID }) {
                pin.isRunning = true
                pin.processIdentifier = live.processIdentifier
                pin.isHidden = live.isHidden
                if pin.bundleURL == nil { pin.bundleURL = live.bundleURL }
            }
            pin.isPinned = true
            out.append(pin)
        }
        for var run in running where seen.insert(run.bundleID).inserted {
            run.isPinned = false
            out.append(run)
        }
        return out
    }

    /// Rebuilds `items` from the workspace and the pin list.
    func refresh() {
        let current = settings()
        let live = runningApplications().filter {
            $0.activationPolicy == .regular
                && $0.bundleIdentifier != nil
                && $0.bundleIdentifier != ownBundleID
        }
        var byID: [String: NSRunningApplication] = [:]
        var runningItems: [DockItem] = []
        for app in live {
            guard let id = app.bundleIdentifier, byID[id] == nil else { continue }
            byID[id] = app
            runningItems.append(DockItem(
                bundleID: id,
                name: app.localizedName ?? id,
                bundleURL: app.bundleURL,
                isRunning: true, isPinned: false,
                processIdentifier: app.processIdentifier,
                isHidden: app.isHidden,
                badge: nil))
        }
        let pinnedItems = pinnedIDs.map { resolvedPin($0) }
        var next = Self.ordered(pinned: pinnedItems, running: runningItems)
        if !current.showFinder {
            next.removeAll { $0.bundleID == Self.finderBundleID }
        }
        let badges = badgeSource()
        if !badges.isEmpty {
            for i in next.indices { next[i].badge = badges[next[i].bundleID] }
        }
        // The file group — widgets first, then folder stacks, then
        // parked tray items — sits between the app run and the Trash.
        // Missing paths keep their persisted slot but draw no tile.
        if current.widgets.clock { next.append(.widget(.clock)) }
        if current.widgets.battery { next.append(.widget(.battery)) }
        for path in folderPaths where pathExists(path) {
            next.append(.folder(path: path))
        }
        for path in trayPaths where pathExists(path) {
            next.append(.trayItem(path: path))
        }
        // The battery tile's poll only runs while its tile can draw —
        // a timer that feeds no pixels is the FoldToy rule's enemy.
        if current.widgets.battery {
            widgetModel.start()
        } else {
            widgetModel.stop()
        }
        // The Trash rides at the end, like Apple's — always present so
        // the bar is never empty and its anchor never wanders.
        next.append(DockItem(
            bundleID: Self.trashBundleID, name: "Trash", bundleURL: Self.trashURL,
            isRunning: false, isPinned: false, processIdentifier: nil,
            isTrash: true, trashIsEmpty: (trashContents() ?? []).isEmpty))
        apps = byID
        items = next
        onItemsChanged?()
    }

    /// A pin's tile: resolved through the workspace so a not-running
    /// pin still shows its real icon and name; unresolved pins keep a
    /// placeholder name (the bundle id) rather than dropping — the pin
    /// may point at an app that is merely not discoverable right now.
    private func resolvedPin(_ bundleID: String) -> DockItem {
        let url = apps[bundleID]?.bundleURL ?? resolveApplicationURL(bundleID)
        let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
        return DockItem(bundleID: bundleID, name: name, bundleURL: url,
                        isRunning: false, isPinned: true, processIdentifier: nil)
    }

    // MARK: Pin edits

    /// "Keep in Dock" / "Remove from Dock".
    func togglePin(_ item: DockItem) {
        guard !item.isTrash else { return }
        if let index = pinnedIDs.firstIndex(of: item.bundleID) {
            pinnedIDs.remove(at: index)
        } else {
            pinnedIDs.append(item.bundleID)
        }
        onPinsChanged?(pinnedIDs)
        refresh()
    }

    /// Drag-reorder inside the pinned run: `dragged` lands where
    /// `target` sits. Moving onto a running tile is a no-op — the
    /// pinned run is the only reorderable range.
    func movePin(_ dragged: String, before target: String) {
        guard dragged != target,
              let from = pinnedIDs.firstIndex(of: dragged),
              pinnedIDs.contains(target) else { return }
        let item = pinnedIDs.remove(at: from)
        let destination = pinnedIDs.firstIndex(of: target) ?? pinnedIDs.count
        pinnedIDs.insert(item, at: destination)
        onPinsChanged?(pinnedIDs)
        refresh()
    }

    // MARK: Actions

    // MARK: Folders & tray

    /// "Add Folder…" (the card) or a dropped directory — pin a stack
    /// tile. Dedupe keeps a re-drop of an already-pinned folder a
    /// no-op.
    func addFolder(path: String) {
        guard !path.isEmpty, !folderPaths.contains(path) else { return }
        folderPaths.append(path)
        onFoldersChanged?(folderPaths)
        refresh()
    }

    /// The folder tile's "Remove from Dock".
    func removeFolder(path: String) {
        guard let index = folderPaths.firstIndex(of: path) else { return }
        folderPaths.remove(at: index)
        onFoldersChanged?(folderPaths)
        refresh()
    }

    /// Park a file in the tray — the shelf's "drop to park".
    func addTrayItem(path: String) {
        guard !path.isEmpty, !trayPaths.contains(path) else { return }
        trayPaths.append(path)
        onTrayChanged?(trayPaths)
        refresh()
    }

    /// The tray tile's "Remove from Tray" — forgets the park, never
    /// touches the file.
    func removeTrayItem(path: String) {
        guard let index = trayPaths.firstIndex(of: path) else { return }
        trayPaths.remove(at: index)
        onTrayChanged?(trayPaths)
        refresh()
    }

    /// The row-level drop: directories pin as folder stacks, files
    /// park in the tray. One report per collection even when a mixed
    /// drag lands both.
    func acceptDrop(urls: [URL]) {
        let plan = DockDropPlan.classify(urls: urls, isDirectory: directoryCheck)
        guard !plan.folders.isEmpty || !plan.tray.isEmpty else { return }
        folderPaths = DockSettings.deduped(folderPaths + plan.folders)
        trayPaths = DockSettings.deduped(trayPaths + plan.tray)
        onFoldersChanged?(folderPaths)
        onTrayChanged?(trayPaths)
        refresh()
    }

    /// A drop onto a folder tile moves the dragged files inside — the
    /// same thing Apple's Dock does when you park a file on a stack.
    func moveIntoFolder(_ urls: [URL], folderPath: String) {
        guard !folderPath.isEmpty else { return }
        let folder = URL(fileURLWithPath: folderPath)
        for url in urls where url.isFileURL {
            _ = fileMover(url, folder)
        }
    }

    /// "Reveal in Finder" for folder and tray tiles.
    func reveal(_ item: DockItem) {
        guard let url = item.bundleURL else { return }
        revealURL(url)
    }

    // MARK: Actions

    /// Click: running apps activate (all windows forward, the dock's
    /// own behaviour); pinned-but-not-running apps launch; folder and
    /// tray tiles open their file URL (the folder tile's popover is
    /// the view's call — this is its menu's "Open"); the Trash opens
    /// its Finder window; widgets ignore clicks.
    func activate(_ item: DockItem) {
        if item.isTrash { openTrash(); return }
        if item.isFolder || item.isTrayItem {
            if let url = item.bundleURL { openURL(url) }
            return
        }
        if item.widget != nil { return }
        if let app = app(for: item) {
            app.activate(options: [.activateAllWindows])
            return
        }
        guard let url = item.bundleURL ?? resolveApplicationURL(item.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    /// The Trash tile's click — its Finder window.
    func openTrash() { openURL(Self.trashURL) }

    /// "Empty Trash…": confirm, then delete `~/.Trash`'s contents.
    /// Per-entry failures (locked files, other volumes' trash lives
    /// elsewhere anyway) are skipped, matching Finder's best effort.
    func emptyTrash() {
        guard confirmEmptyTrash() else { return }
        for child in trashContents() ?? [] {
            trashRemover(Self.trashURL.appendingPathComponent(child).path)
        }
        refresh()
    }

    func hide(_ item: DockItem) { app(for: item)?.hide() }
    func unhide(_ item: DockItem) { app(for: item)?.unhide() }

    /// Graceful quit. Finder gets "Relaunch" instead — `quit` is a
    /// no-op for it; callers route to `forceQuit` (launchd restarts
    /// Finder automatically).
    func quit(_ item: DockItem) {
        guard item.bundleID != Self.finderBundleID else { return }
        app(for: item)?.terminate()
    }

    /// `forceTerminate` — the ⌘⌥ path, and Finder's "Relaunch".
    func forceQuit(_ item: DockItem) { app(for: item)?.forceTerminate() }

    /// Scroll-to-switch (P4): step the app's windows to the front —
    /// the next one forward, the previous one back, wrapping like
    /// DockDoor's scroll-over-icon. Without Accessibility the AX read
    /// is empty and the honest answer is a plain activate.
    func cycleWindows(_ item: DockItem, forward: Bool) {
        guard item.section == .apps, let app = app(for: item) else { return }
        let windows = windowProvider(app.processIdentifier)
        guard !windows.isEmpty else {
            cycleCursors[item.bundleID] = nil
            activateApp(app)
            return
        }
        guard let index = Self.nextCycleIndex(
            current: cycleCursors[item.bundleID], count: windows.count,
            forward: forward) else { return }
        cycleCursors[item.bundleID] = index
        windowCycler(windows[index], app)
    }

    /// The ring step, pure for the tests: no usable cursor yet → the
    /// first window going forward, the last going back; then wrap.
    /// An out-of-range cursor (a window closed mid-cycle) restarts
    /// rather than crashing or sticking.
    static func nextCycleIndex(current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current >= 0, current < count else {
            return forward ? 0 : count - 1
        }
        return (current + (forward ? 1 : -1) + count) % count
    }

    private func app(for item: DockItem) -> NSRunningApplication? {
        if let app = apps[item.bundleID], !app.isTerminated { return app }
        if let pid = item.processIdentifier,
           let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            return app
        }
        return nil
    }
}
