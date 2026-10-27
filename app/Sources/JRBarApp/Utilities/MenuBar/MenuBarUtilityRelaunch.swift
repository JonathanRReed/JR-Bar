import AppKit
import JRBarCore

/// The relaunch that lets a spacing change take.
extension MenuBarUtility {
    /// The apps a spacing relaunch would quit and reopen: every app with
    /// an item on the bar that is someone else's — never Apple's own
    /// agents, never JR-Bar's family — by name. Pure so a test pins it.
    nonisolated static func relaunchCandidates(_ items: [MenuBarItem]) -> [(bundleID: String, name: String)] {
        var seen = Set<String>()
        var out: [(bundleID: String, name: String)] = []
        for item in items where !item.isNativeOverflowControl && !MenuBarItemLister.isProtected(item) {
            guard let id = item.bundleID, !id.hasPrefix("com.apple."), !isOwnFamily(id),
                  seen.insert(id).inserted else { continue }
            out.append((id, item.displayName))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The apps the confirm sheet lists — running ones, today.
    var spacingRelaunchApps: [(bundleID: String, name: String)] {
        Self.relaunchCandidates(listedItems).filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
        }
    }

    /// Quit and reopen `apps` one at a time so each picks up the item
    /// spacing — only ever from the confirm sheet's button. Each app is
    /// asked to quit (never forced), given a few seconds, and reopened in
    /// the background from where it was.
    func relaunchForSpacing(_ apps: [String], desktop: DesktopServices = .automatic) {
        guard !WindowPresenter.suppressesDesktop else { return }
        guard relaunchingApps.isEmpty, !apps.isEmpty else { return }
        relaunchingApps = apps
        Task { @MainActor [weak self] in
            for id in apps {
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
                      let url = app.bundleURL else { continue }
                MenuBarUtility.log.notice("spacing: relaunching \(id, privacy: .public)")
                app.terminate()
                var waited = 0
                while !app.isTerminated, waited < 50 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
                guard app.isTerminated else {
                    MenuBarUtility.log.notice("spacing: \(id, privacy: .public) did not quit — left running")
                    continue
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try? await desktop.openApplication(at: url, configuration: configuration)
                self?.relaunchingApps.removeAll { $0 == id }
            }
            self?.relaunchingApps = []
        }
    }
}
