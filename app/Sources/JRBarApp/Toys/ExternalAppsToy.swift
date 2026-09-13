import AppKit
import JRBarCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The Toys page's external app rows (docs/TOYS.md): apps the user keeps
/// next to JR-Bar. Identity is the bundle id; the row survives the app
/// being uninstalled so it can say "not installed" and offer Remove.
/// The list lives in `ToysState.externalApps` — `AppState.toys`, not the
/// daemon's document.
@MainActor
@Observable
final class ExternalAppsToy {
    /// The owning store; weak, the store keeps it.
    weak var store: ToysStore?
    /// Bumped on every relevant launch/terminate so `isRunning` re-reads
    /// `NSWorkspace`.
    private(set) var workspaceVersion = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.workspaceVersion += 1 }
            })
        }
    }

    private var apps: [ExternalToyApp] { store?.state.externalApps ?? [] }

    // MARK: Picking

    /// "Add an app…": an open panel on /Applications for .app bundles.
    func pickAndAdd() {
        let panel = NSOpenPanel()
        panel.title = "Add an app"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(url) }
    }

    private func add(_ url: URL) {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else { return }
        guard !apps.contains(where: { $0.id == id }) else { return }
        let info = bundle.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        store?.state.externalApps.append(ExternalToyApp(id: id, name: name))
    }

    func remove(_ app: ExternalToyApp) {
        store?.state.externalApps.removeAll { $0.id == app.id }
    }

    func setLaunchWithJRBar(_ app: ExternalToyApp, _ on: Bool) {
        guard let index = store?.state.externalApps.firstIndex(where: { $0.id == app.id }) else { return }
        store?.state.externalApps[index].launchWithJRBar = on
    }

    // MARK: Facts

    func url(for app: ExternalToyApp) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id)
    }

    func isInstalled(_ app: ExternalToyApp) -> Bool { url(for: app) != nil }

    func isRunning(_ app: ExternalToyApp) -> Bool {
        _ = workspaceVersion
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == app.id }
    }

    /// The app's icon, or a generic placeholder once the app is gone.
    func icon(for app: ExternalToyApp) -> NSImage {
        if let url = url(for: app) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .application)
    }

    // MARK: Actions

    func launch(_ app: ExternalToyApp) {
        guard let url = url(for: app) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    func quit(_ app: ExternalToyApp) {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == app.id }?
            .terminate()
    }

    /// Launch-at-startup: opens every flagged app that is installed and
    /// not already running. Called once from the delegate after launch.
    func launchAtStartup() {
        for app in apps where app.launchWithJRBar && isInstalled(app) && !isRunning(app) {
            launch(app)
        }
    }
}
