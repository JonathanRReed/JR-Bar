import AppKit
import Observation

/// One running app as the index keeps it: read once, when it launched
/// or when the index started, and never asked again.
struct RunningApp: Equatable, Sendable {
    let pid: pid_t
    let bundleID: String?
    let name: String?
    let policy: NSApplication.ActivationPolicy
}

/// Where the index hears about launches and quits. The app's feed is the
/// workspace (`WorkspaceRunningAppsFeed`); a test hands in synthetic apps.
@MainActor
protocol RunningAppsFeed: AnyObject {
    /// Starts listening and returns every app running now. `onChange`
    /// receives the apps that launched since, each read once, and the
    /// pids that quit.
    func start(onChange: @escaping @MainActor (_ launched: [RunningApp], _ quit: [pid_t]) -> Void) -> [RunningApp]
}

/// A launch or a quit, as the index's listeners hear it. A quit carries
/// the app as it was known, so a listener can still read its bundle id.
struct RunningAppsChange: Sendable {
    let launched: [RunningApp]
    let quit: [RunningApp]
}

/// Every running app, kept as a small index the launches and quits
/// update. Asking `NSWorkspace` for its apps is cheap; asking each app
/// for its name, bundle id or whether it quit is a LaunchServices round
/// trip, and the answers are thrown away every run-loop turn. With 158
/// apps running, the first read of the list in a turn cost 12.5–15.7 ms
/// on the main thread, and four readers each paid it on their own turn:
/// the notch's rivals check, the menu bar's Accessibility targets, its
/// running-bundle snapshot and its uninstalled-app prune. The index reads
/// each app once, when it appears, and every reader asks it instead.
///
/// It is `@Observable`: a view body that reads `version`, `apps` or
/// `bundleIDs` updates when an app launches or quits.
@MainActor
@Observable
final class RunningApps {
    /// The app's index, made on first use.
    static let shared = RunningApps(feed: WorkspaceRunningAppsFeed())

    /// Bumped on every launch or quit.
    private(set) var version = 0

    @ObservationIgnored private var byPID: [pid_t: RunningApp] = [:]
    @ObservationIgnored private var cachedApps: [RunningApp]?
    @ObservationIgnored private var cachedBundleIDs: Set<String>?
    @ObservationIgnored private var cachedNames: Set<String>?
    @ObservationIgnored private var listeners: [Int: @MainActor (RunningAppsChange) -> Void] = [:]
    @ObservationIgnored private var nextListener = 0
    @ObservationIgnored private let feed: RunningAppsFeed

    init(feed: RunningAppsFeed) {
        self.feed = feed
        let initial = feed.start { [weak self] launched, quit in
            self?.apply(launched: launched, quit: quit)
        }
        for app in initial where app.pid > 0 { byPID[app.pid] = app }
    }

    /// Every running app, in pid order.
    var apps: [RunningApp] {
        _ = version
        if let cachedApps { return cachedApps }
        let apps = byPID.values.sorted { $0.pid < $1.pid }
        cachedApps = apps
        return apps
    }

    /// The bundle identifiers of every running app.
    var bundleIDs: Set<String> {
        _ = version
        if let cachedBundleIDs { return cachedBundleIDs }
        let ids = Set(byPID.values.compactMap(\.bundleID))
        cachedBundleIDs = ids
        return ids
    }

    /// The running app with this pid, if one runs.
    func app(pid: pid_t) -> RunningApp? {
        _ = version
        return byPID[pid]
    }

    func isRunning(bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    /// Whether an app runs whose name matches `name` ignoring case — the
    /// rule `UtilityRivals.Rival.matches` applies to names.
    func isRunning(named name: String) -> Bool {
        _ = version
        if cachedNames == nil {
            cachedNames = Set(byPID.values.compactMap { $0.name.map(Self.nameKey) })
        }
        return cachedNames?.contains(Self.nameKey(name)) ?? false
    }

    /// The key names compare by: case folded, as `caseInsensitiveCompare`
    /// compares them.
    nonisolated static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive], locale: nil)
    }

    /// Hear every launch and quit from now on. Returns the token
    /// `removeListener` takes.
    @discardableResult
    func addListener(_ listener: @escaping @MainActor (RunningAppsChange) -> Void) -> Int {
        nextListener += 1
        listeners[nextListener] = listener
        return nextListener
    }

    func removeListener(_ token: Int) {
        listeners[token] = nil
    }

    /// A launch or a quit from the feed. Internal so a test can drive the
    /// index without a feed of its own.
    func apply(launched: [RunningApp], quit: [pid_t]) {
        var gone: [RunningApp] = []
        for pid in quit {
            if let app = byPID.removeValue(forKey: pid) { gone.append(app) }
        }
        var arrived: [RunningApp] = []
        for app in launched where app.pid > 0 && byPID[app.pid] != app {
            byPID[app.pid] = app
            arrived.append(app)
        }
        guard !arrived.isEmpty || !gone.isEmpty else { return }
        cachedApps = nil
        cachedBundleIDs = nil
        cachedNames = nil
        version &+= 1
        let change = RunningAppsChange(launched: arrived, quit: gone)
        for listener in listeners.values { listener(change) }
    }
}

/// The feed's bookkeeping, pure so a test can drive it: which app
/// object is which pid. The workspace hands out a fresh
/// `NSRunningApplication` for every app on each run-loop turn, and a quit
/// app's object reads pid -1, so a quit is known by the object the
/// launch or the start handed over — and when an object turns up that
/// nobody was handed, the caller resyncs by pid.
struct RunningAppsLedger<Key: Hashable> {
    private(set) var pids: [Key: pid_t] = [:]

    /// A launched app's object and its pid. False for a pid that
    /// already reads as gone.
    @discardableResult
    mutating func insert(_ key: Key, pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        pids[key] = pid
        return true
    }

    /// The pids of the apps whose objects quit; nil when one of them is
    /// an object the ledger never met — the caller then resyncs by pid.
    mutating func remove(_ keys: [Key]) -> [pid_t]? {
        guard keys.allSatisfy({ pids[$0] != nil }) else { return nil }
        return keys.compactMap { pids.removeValue(forKey: $0) }
    }

    /// The whole list again, as (object, pid): the objects whose pid is
    /// new, and the pids that are gone. The ledger holds the new objects
    /// afterwards.
    mutating func resync(_ current: [(key: Key, pid: pid_t)]) -> (added: [Key], quit: [pid_t]) {
        let known = Set(pids.values)
        let live = current.filter { $0.pid > 0 }
        let now = Set(live.map(\.pid))
        let added = live.filter { !known.contains($0.pid) }.map(\.key)
        let quit = known.subtracting(now).sorted()
        pids = Dictionary(live.map { ($0.key, $0.pid) }, uniquingKeysWith: { first, _ in first })
        return (added, quit)
    }
}

/// The workspace as the index's feed: key-value observation of
/// `runningApplications`, which hears every app, helpers and background
/// agents included — the launch notification skips many of them. An
/// insertion carries the launched app's object, read once; a removal
/// carries the quit app's, matched to the one the insertion or the start
/// handed over. Anything else — a whole new list, or a quit object nobody
/// was handed — resyncs by pid, reading only the apps that are new.
@MainActor
final class WorkspaceRunningAppsFeed: RunningAppsFeed {
    private var ledger = RunningAppsLedger<ObjectIdentifier>()
    /// The objects the ledger's keys name, held so a key stays unique.
    private var objects: [ObjectIdentifier: NSRunningApplication] = [:]
    private var onChange: (@MainActor ([RunningApp], [pid_t]) -> Void)?
    private var observation: NSKeyValueObservation?

    func start(onChange: @escaping @MainActor ([RunningApp], [pid_t]) -> Void) -> [RunningApp] {
        self.onChange = onChange
        var apps: [RunningApp] = []
        for app in NSWorkspace.shared.runningApplications {
            let entry = Self.read(app)
            guard remember(app, pid: entry.pid) else { continue }
            apps.append(entry)
        }
        observation = NSWorkspace.shared.observe(\.runningApplications, options: [.new, .old]) { [weak self] _, change in
            // The workspace posts these on the main thread; one that
            // came from elsewhere is read afresh there instead.
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.resync() }
                }
                return
            }
            let kind = change.kind
            let inserted = change.newValue ?? []
            let removed = change.oldValue ?? []
            MainActor.assumeIsolated { self?.apply(kind: kind, inserted: inserted, removed: removed) }
        }
        return apps
    }

    private func apply(kind: NSKeyValueChange, inserted: [NSRunningApplication],
                       removed: [NSRunningApplication]) {
        guard kind == .insertion || kind == .removal || kind == .replacement else {
            resync()
            return
        }
        guard let quit = ledger.remove(removed.map(ObjectIdentifier.init)) else {
            resync()
            return
        }
        for app in removed { objects[ObjectIdentifier(app)] = nil }
        var launched: [RunningApp] = []
        for app in inserted {
            let entry = Self.read(app)
            if remember(app, pid: entry.pid) { launched.append(entry) }
        }
        guard !launched.isEmpty || !quit.isEmpty else { return }
        onChange?(launched, quit)
    }

    /// The whole list, by pid: a pid read per app (a LaunchServices round
    /// trip each, so only when the objects can't say), and the rest of
    /// an app read only when its pid is new.
    private func resync() {
        let current = NSWorkspace.shared.runningApplications
        let keyed = current.map { (key: ObjectIdentifier($0), pid: $0.processIdentifier) }
        let (added, quit) = ledger.resync(keyed)
        objects = Dictionary(current.map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { first, _ in first })
        let addedKeys = Set(added)
        let launched = current.filter { addedKeys.contains(ObjectIdentifier($0)) }.map(Self.read)
        guard !launched.isEmpty || !quit.isEmpty else { return }
        onChange?(launched, quit)
    }

    private func remember(_ app: NSRunningApplication, pid: pid_t) -> Bool {
        let key = ObjectIdentifier(app)
        guard ledger.insert(key, pid: pid) else { return false }
        objects[key] = app
        return true
    }

    private static func read(_ app: NSRunningApplication) -> RunningApp {
        RunningApp(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                   name: app.localizedName, policy: app.activationPolicy)
    }
}
