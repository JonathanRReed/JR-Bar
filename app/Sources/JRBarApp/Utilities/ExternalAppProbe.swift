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
        let apps = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Applications"),
            includingPropertiesForKeys: nil)) ?? []
        for name in appNames {
            if let found = apps.first(where: { $0.lastPathComponent == name }) {
                return found
            }
        }
        return nil
    }

    var installed: Bool { url != nil }

    /// Running means a live process — a registered bundle id answers
    /// directly, an unregistered app matches on its bundle path.
    var running: Bool {
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, bundleIDs.contains(id) { return true }
        }
        guard let url else { return false }
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL == url.standardizedFileURL
        }
    }

    /// Launch it — the card's "Open" for a picked-but-not-running
    /// counterpart.
    func open() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The counterparts each utility's provider picker offers. Display
/// names live on the pickers; these are only where to find the apps.
enum ExternalProviders {
    /// Paid: Bartender 4/5 (com.surteesstudios.Bartender across both).
    static let bartender = ExternalAppProbe(
        bundleIDs: ["com.surteesstudios.Bartender",
                    "com.surteesstudios.Bartender-5",
                    "com.surteesstudios.Bartender-4"],
        appNames: ["Bartender 5.app", "Bartender 4.app", "Bartender.app"])
    /// Free: Jordan Baird's Ice.
    static let ice = ExternalAppProbe(
        bundleIDs: ["com.jordanbaird.Ice"],
        appNames: ["Ice.app"])
    /// Free: Dwarves' Hidden Bar — hide-only, still a counterpart.
    static let hiddenBar = ExternalAppProbe(
        bundleIDs: ["com.dwarvesf.hidden"],
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
