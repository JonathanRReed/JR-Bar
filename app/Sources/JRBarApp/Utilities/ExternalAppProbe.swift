import AppKit

/// One external counterpart's install-and-run probe — the notch's
/// `boringNotchProbe` generalized for the utility pickers. Bundle ids
/// answer through Launch Services first; the Applications-folder name
/// scan catches builds that never registered one (boring.notch ships
/// none, a Bartender side-load may not either). Nothing is cached —
/// `running` and `installed` read the workspace live, and the caller's
/// `workspaceVersion` is what makes a launch show up in SwiftUI.
struct ExternalAppProbe {
    /// Bundle ids the counterpart has shipped under — newest first,
    /// older registrations kept for side-grades.
    let bundleIDs: [String]
    /// Filenames under /Applications, for builds with no registered id.
    let appNames: [String]

    /// The app's location, or nil when it is not installed.
    var url: URL? {
        for id in bundleIDs {
            if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return found
            }
        }
        let apps = ApplicationsFolderIndex.shared.entries()
        for name in appNames {
            if let found = apps.first(where: { $0.lastPathComponent == name }) {
                return found
            }
        }
        return nil
    }

    var installed: Bool { url != nil }

    /// Running means a live process — a registered bundle id answers
    /// through the running-apps index, an unregistered app falls back to
    /// matching on its bundle path (the rare path: boring.notch ships no
    /// id). Both answer from the running-apps index, which read each app
    /// once; walking `NSWorkspace.runningApplications` here cost a Launch
    /// Services trip per running app on every card body. Main-actor: the
    /// index is main-actor, and every caller reads this from a card body.
    @MainActor var running: Bool {
        if bundleIDs.contains(where: { RunningApps.shared.isRunning(bundleID: $0) }) { return true }
        guard let url else { return false }
        return RunningApps.shared.isRunning(bundleURL: url)
    }

    /// Launch it — the card's "Open" for a picked-but-not-running
    /// counterpart.
    @MainActor func open() {
        guard let url else { return }
        DesktopServices.automatic.open(url)
    }
}

/// What is in /Applications, listed once and kept for a short while. Every
/// `ExternalAppProbe.url` that Launch Services cannot place asks for it, from
/// a view body; the listing is the same each time.
final class ApplicationsFolderIndex: @unchecked Sendable {
    static let shared = ApplicationsFolderIndex()

    /// How long a listing stands. An app installed a moment ago shows up
    /// within this; a person installing a counterpart and flipping back to
    /// the card reads a fresh listing at most this late.
    static let lifetime: TimeInterval = 30

    private let lock = NSLock()
    private var cached: (at: TimeInterval, urls: [URL])?
    /// How the folder is listed and what time it is — the tests' seams.
    private let list: @Sendable () -> [URL]
    private let now: @Sendable () -> TimeInterval

    init(list: @escaping @Sendable () -> [URL] = {
            (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil)) ?? []
        },
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.list = list
        self.now = now
    }

    func entries() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        if let cached, current - cached.at >= 0, current - cached.at < Self.lifetime { return cached.urls }
        let urls = list()
        cached = (current, urls)
        return urls
    }

    /// Forget the listing: the next ask reads the folder.
    func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}

/// The counterparts each utility's provider picker offers. Display
/// names live on the pickers; these are only where to find the apps.
/// The menu bar's take their bundle ids from `MenuBarRivals.known`,
/// the table the rival check reads, so Hand over finds every release
/// the rival check knows.
enum ExternalProviders {
    /// Paid: Bartender, every release from 4 to 7.
    static let bartender = ExternalAppProbe(
        bundleIDs: MenuBarRivals.bundleIDs(of: "Bartender"),
        appNames: ["Bartender 7.app", "Bartender 6.app", "Bartender 5.app", "Bartender 4.app",
                   "Bartender.app"])
    /// Free: Jordan Baird's Ice.
    static let ice = ExternalAppProbe(
        bundleIDs: MenuBarRivals.bundleIDs(of: "Ice"),
        appNames: ["Ice.app"])
    /// Free: Dwarves' Hidden Bar — hide-only, still a counterpart.
    static let hiddenBar = ExternalAppProbe(
        bundleIDs: MenuBarRivals.bundleIDs(of: "Hidden Bar"),
        appNames: ["Hidden Bar.app"])
    /// Free: DockDoor.
    static let dockDoor = ExternalAppProbe(
        bundleIDs: ["com.ethanbills.DockDoor", "com.ejbills.DockDoor"],
        appNames: ["DockDoor.app"])
    /// Paid: ActiveDock (Apimac).
    static let activeDock = ExternalAppProbe(
        bundleIDs: ["com.apimac.ActiveDock", "com.apimac.ActiveDock2"],
        appNames: ["ActiveDock.app", "ActiveDock 2.app"])
}
