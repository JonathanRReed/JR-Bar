import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Alcove (docs/TOYS.md): Henrik's notch app — JR-Bar already follows
/// its capsule (`AlcoveFollower`, `screen_bar_follow_alcove`). The card
/// makes that visible: installed? running? the capsule width the
/// follower sees, the follow toggle, and Open/Get buttons. The toggle
/// is a real daemon setting written through `SettingsStore`, so the
/// card's switch and the toggle inside say the same thing.
@MainActor
@Observable
final class AlcoveToy: Toy {
    let core: CoreModel
    /// The owning store; weak, the store keeps the toy.
    weak var store: ToysStore?
    /// Bumped on every Alcove launch/terminate so `isRunning` re-reads
    /// `NSWorkspace` — the workspace ping lands even when the follower's
    /// capsule did not change.
    private(set) var workspaceVersion = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(core: CoreModel, store: ToysStore) {
        self.core = core
        self.store = store
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == AlcoveGeometry.bundleIdentifier else { return }
                MainActor.assumeIsolated { self?.workspaceVersion += 1 }
            })
        }
    }

    let id = "alcove"
    let name = "Alcove"
    let blurb = "JR-Bar already follows Alcove's capsule. This is where you can see it doing that."
    let symbol = "capsule.fill"

    /// The card's switch is the follow setting itself.
    var isOn: Bool {
        get { store?.settings.document.bool(SettingsPath("screen_bar_follow_alcove")) ?? true }
        set { store?.settings.set("screen_bar_follow_alcove", .bool(newValue)) }
    }

    var isInstalled: Bool { appURL != nil }

    var isRunning: Bool {
        _ = workspaceVersion
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == AlcoveGeometry.bundleIdentifier }
    }

    private var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: AlcoveGeometry.bundleIdentifier)
    }

    var status: ToyStatus {
        _ = workspaceVersion
        if !isInstalled { return .unavailable("Alcove isn't installed") }
        if !isOn { return .off }
        if !isRunning { return .external("Alcove isn't running") }
        if let capsule = store?.alcoveCapsule { return .external("Following: \(Int(capsule.width.rounded())) pt wide") }
        return .external("Alcove is running")
    }

    var controls: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 4) {
                if let settings = store?.settings {
                    SettingToggle(settings, "Follow Alcove's capsule",
                                  subtitle: "The Screen Bar matches the capsule's width while Alcove is up.",
                                  path: "screen_bar_follow_alcove", default: true)
                }
                LabeledContent {
                    Text(capsuleFact)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } label: {
                    SettingLabel(title: "Capsule", subtitle: "What the follower sees right now.")
                }
                HStack(spacing: 8) {
                    if isInstalled {
                        Button("Open Alcove") { self.open() }
                    } else {
                        Button("Get Alcove") { NSWorkspace.shared.open(URL(string: "https://alcove.app")!) }
                    }
                }
            }
        )
    }

    private var capsuleFact: String {
        _ = workspaceVersion
        guard isInstalled else { return "not installed" }
        guard isRunning else { return "Alcove isn't running" }
        if let capsule = store?.alcoveCapsule { return "following: \(Int(capsule.width.rounded())) pt wide" }
        return "running, no capsule seen"
    }

    private func open() {
        guard let url = appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}
