import AppKit
import JRBarCore
import Observation

/// The other apps that do what a JR-Bar utility does, in one table — the
/// menu bar's `MenuBarRivals` made general. "Still allowing them to be
/// an option" cuts both ways: each utility can be switched off, and an
/// installed rival can have the surface. Two apps drawing the same thing
/// is the one outcome nobody wants, so JR-Bar notices a running rival
/// and says so where the person looks.
///
/// What happens then depends on the surface (docs/UTILITIES.md,
/// Coexistence):
/// - a surface (Dock previews, the switcher, the notch island, the HUD)
///   asks: a note with Hand over where the rival can take the pick, and
///   Quit on the person's click, never on its own;
/// - a gesture (the shelf's shake) steps aside automatically, because
///   one shake can't be shared and dropping on the notch still works;
/// - keep-awake is information only: two holds stack harmlessly, and
///   the Mac sleeps once both let go.
///
/// Matching is by bundle id, or by the app's own name for rivals whose
/// id is not pinned. `MenuBarRivals` keeps its own list this wave; the
/// `.menuBar` role reads it, so the two can never disagree.
enum UtilityRivals {
    enum Role: String, CaseIterable, Sendable {
        case menuBar, dockPreviews, switcher, notch, hud, shelfGesture, keepAwake

        /// How JR-Bar behaves while a rival for this role runs.
        var policy: Policy {
            switch self {
            case .menuBar, .dockPreviews, .switcher, .notch, .hud: return .ask
            case .shelfGesture: return .stepAside
            case .keepAwake: return .informOnly
            }
        }
    }

    enum Policy: Sendable {
        /// Say so, offer Hand over and Quit; never act alone.
        case ask
        /// JR-Bar's own gesture stands down while the rival runs.
        case stepAside
        /// Name it; both keep working.
        case informOnly
    }

    /// The pick that hands a role's surface to a rival.
    enum Handoff: Equatable, Sendable {
        case dock(DockProvider)
        case switcher(DockSwitcherProvider)
        case notch(NotchProvider)
        case menuBar(MenuBarProvider)
    }

    struct Rival: Equatable, Sendable, Identifiable {
        let name: String
        /// Bundle ids it has shipped under.
        let bundleIDs: Set<String>
        /// Other names its process may carry ("Dropzone 4").
        var otherNames: [String] = []
        let roles: Set<Role>
        /// Where a role's surface can be handed to it.
        var handoffs: [Role: Handoff] = [:]

        var id: String { name }

        func handoff(for role: Role) -> Handoff? { handoffs[role] }

        /// Whether a running app is this rival: its bundle id, or its
        /// name for the ids nobody pinned.
        func matches(bundleID: String?, name appName: String?) -> Bool {
            if let bundleID, bundleIDs.contains(bundleID) { return true }
            guard let appName else { return false }
            return ([name] + otherNames).contains {
                $0.caseInsensitiveCompare(appName) == .orderedSame
            }
        }
    }

    /// Every rival, each once. Bundle ids were read from the upstream
    /// projects where the source is public, and from the shipped app
    /// otherwise; a name match covers the rest.
    nonisolated static let known: [Rival] = [
        Rival(name: "DockDoor", bundleIDs: ["com.ethanbills.DockDoor", "com.ejbills.DockDoor"],
              roles: [.dockPreviews, .switcher],
              handoffs: [.dockPreviews: .dock(.dockDoor), .switcher: .switcher(.dockDoor)]),
        Rival(name: "ActiveDock", bundleIDs: ["com.apimac.ActiveDock", "com.apimac.ActiveDock2"],
              otherNames: ["ActiveDock 2"], roles: [.dockPreviews],
              handoffs: [.dockPreviews: .dock(.activeDock)]),
        Rival(name: "DockView", bundleIDs: [], roles: [.dockPreviews]),
        Rival(name: "AltTab", bundleIDs: ["com.lwouis.alt-tab-macos"], roles: [.switcher],
              handoffs: [.switcher: .switcher(.altTab)]),
        Rival(name: "Witch", bundleIDs: ["com.manytricks.Witch"], roles: [.switcher],
              handoffs: [.switcher: .switcher(.witch)]),
        Rival(name: "Contexts", bundleIDs: ["com.contextsformac.Contexts"], roles: [.switcher],
              handoffs: [.switcher: .switcher(.contexts)]),
        Rival(name: "Alcove", bundleIDs: [AlcoveGeometry.bundleIdentifier], roles: [.notch, .hud],
              handoffs: [.notch: .notch(.alcove)]),
        Rival(name: "Boring Notch", bundleIDs: ["theboringteam.boringnotch"],
              otherNames: ["boring.notch", "boringNotch"], roles: [.notch, .hud],
              handoffs: [.notch: .notch(.boringNotch)]),
        Rival(name: "Atoll", bundleIDs: ["com.Ebullioscopic.Atoll"], roles: [.notch, .hud]),
        Rival(name: "MewNotch", bundleIDs: ["com.monuk7735.mew.notch"], roles: [.notch, .hud]),
        Rival(name: "DynamicLake", bundleIDs: [], otherNames: ["Dynamic Lake"], roles: [.notch]),
        Rival(name: "Notchy", bundleIDs: [], roles: [.notch]),
        Rival(name: "NotchNook", bundleIDs: [], roles: [.notch]),
        Rival(name: "MediaMate", bundleIDs: [], roles: [.hud]),
        Rival(name: "SlimHUD", bundleIDs: [], roles: [.hud]),
        Rival(name: "Dropover", bundleIDs: ["me.damir.dropover-mac"], roles: [.shelfGesture]),
        Rival(name: "Yoink", bundleIDs: ["at.EternalStorms.Yoink"], roles: [.shelfGesture]),
        Rival(name: "Dropzone", bundleIDs: ["io.aptonic.Dropzone4", "io.aptonic.Dropzone3"],
              otherNames: ["Dropzone 4", "Dropzone 3"], roles: [.shelfGesture]),
        Rival(name: "Amphetamine", bundleIDs: ["com.if.Amphetamine"], roles: [.keepAwake]),
        Rival(name: "KeepingYouAwake", bundleIDs: ["info.marcel-dierkes.KeepingYouAwake"],
              roles: [.keepAwake]),
        Rival(name: "Caffeine", bundleIDs: ["com.intelliscapesolutions.caffeine"], roles: [.keepAwake]),
        Rival(name: "Lungo", bundleIDs: ["com.sindresorhus.Lungo"], roles: [.keepAwake]),
        Rival(name: "Theine", bundleIDs: [], roles: [.keepAwake]),
    ] + MenuBarRivals.known.map { rival in
        Rival(name: rival.name, bundleIDs: rival.bundleIDs, roles: [.menuBar],
              handoffs: rival.handoff.map { [.menuBar: .menuBar($0)] } ?? [:])
    }

    /// The rivals for `role` among `apps` — each once, in table order.
    nonisolated static func running(for role: Role,
                                    in apps: [(bundleID: String?, name: String?)]) -> [Rival] {
        known.filter { rival in
            rival.roles.contains(role) && apps.contains { rival.matches(bundleID: $0.bundleID, name: $0.name) }
        }
    }

    /// The same, from the workspace right now.
    @MainActor
    static func running(for role: Role) -> [Rival] {
        running(for: role, in: runningApps())
    }

    @MainActor
    static func runningApps() -> [(bundleID: String?, name: String?)] {
        NSWorkspace.shared.runningApplications.map { ($0.bundleIdentifier, $0.localizedName) }
    }

    /// Ask a rival to quit — the note's explicit button, never automatic.
    @MainActor
    static func quit(_ rival: Rival) {
        for app in NSWorkspace.shared.runningApplications
        where rival.matches(bundleID: app.bundleIdentifier, name: app.localizedName) {
            app.terminate()
        }
    }

    /// The note's sentence for one running rival.
    nonisolated static func note(for rival: Rival, role: Role) -> String {
        switch role {
        case .menuBar:
            return "\(rival.name) is also managing the menu bar. Two managers fight — its hiding can undo what JR-Bar hides."
        case .dockPreviews:
            return "\(rival.name) is also drawing Dock previews, so hovering an icon can open two."
        case .switcher:
            return "\(rival.name) is also a window switcher and may answer the same keys."
        case .notch:
            return "\(rival.name) is also drawing in the notch, over or beside JR-Bar's island."
        case .hud:
            return "\(rival.name) also draws volume and brightness, so a key press can show two."
        case .shelfGesture:
            return "\(rival.name) is running, so a shake is its shelf — JR-Bar's steps aside until it quits."
        case .keepAwake:
            return "\(rival.name) can hold this Mac awake too. The holds stack harmlessly: the Mac sleeps once both let go."
        }
    }
}

/// App launches and quits, as one observable counter — what makes a
/// rival's note appear the moment it opens without anybody polling.
/// Notification-driven, so it costs nothing between launches.
@MainActor
@Observable
final class UtilityRivalsWatch {
    static let shared = UtilityRivalsWatch()

    private(set) var version = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.version &+= 1 }
            })
        }
    }
}
