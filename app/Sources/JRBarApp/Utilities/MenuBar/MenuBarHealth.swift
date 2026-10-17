import AppKit
import JRBarCore

/// Whether the divider is hiding the bar — the card's "Right now" line.
/// Pure over its input so a test pins every line.
enum MenuBarEngineHealth: Equatable, Sendable {
    /// The utility is off or handed to another manager.
    case parked
    /// The icon is the divider: items left of it are hidden, and
    /// position is the setting.
    case divider

    nonisolated static func assess(running: Bool) -> MenuBarEngineHealth {
        running ? .divider : .parked
    }

    /// The card's line. `fitEdge` joins it: the x the spacer packs
    /// against on this screen.
    func line(fitEdge: CGFloat? = nil) -> String {
        switch self {
        case .parked:
            return "Parked"
        case .divider:
            let edge = fitEdge.map { " · edge at \(Int($0.rounded())) pt" } ?? ""
            return "Divider · the icon is the divider, position is the setting\(edge)"
        }
    }
}

/// The other menu-bar managers that fight ours when both run: two spacer
/// engines push each other's items around, and another manager's hiding
/// can undo what JR-Bar hides.
enum MenuBarRivals {
    struct Rival: Equatable, Sendable {
        var name: String
        /// Bundle ids it has shipped under.
        var bundleIDs: Set<String>
        /// The Render-with pick that hands it the surface, when there is one.
        var handoff: MenuBarProvider?
    }

    nonisolated static let known: [Rival] = [
        Rival(name: "Bartender",
              bundleIDs: ["com.surteesstudios.Bartender", "com.surteesstudios.Bartender-4",
                          "com.surteesstudios.Bartender-5", "com.surteesstudios.Bartender-6",
                          "com.surteesstudios.Bartender-7"],
              handoff: .bartender),
        Rival(name: "Ice", bundleIDs: ["com.jordanbaird.Ice"], handoff: .ice),
        Rival(name: "Hidden Bar", bundleIDs: ["com.dwarvesf.hidden"], handoff: .hiddenBar),
        Rival(name: "Vanilla", bundleIDs: ["net.matthewpalmer.Vanilla"], handoff: nil),
        Rival(name: "Dozer", bundleIDs: ["com.mortennn.Dozer"], handoff: nil),
        Rival(name: "Barbee", bundleIDs: ["com.HyperartFlow.Barbee"], handoff: nil),
        Rival(name: "Tuck", bundleIDs: [], handoff: nil),
        Rival(name: "SaneBar", bundleIDs: [], handoff: nil),
    ]

    /// The named rival's bundle ids, newest release first: numbered ids
    /// descending, a bare id (which several releases shared) last.
    /// Hand over's install probe reads its list from here, so the two
    /// never drift. Empty for a name the table does not know.
    nonisolated static func bundleIDs(of name: String) -> [String] {
        guard let rival = known.first(where: { $0.name == name }) else { return [] }
        func release(_ id: String) -> Int {
            id.split(separator: "-").last.flatMap { Int($0) } ?? 0
        }
        return rival.bundleIDs.sorted { a, b in
            release(a) != release(b) ? release(a) > release(b) : a < b
        }
    }

    /// The known managers among running apps — matched by bundle id, or
    /// by name for the ones whose id is not pinned. Each rival once.
    nonisolated static func running(in apps: [(bundleID: String?, name: String?)]) -> [Rival] {
        known.filter { rival in
            apps.contains { app in
                if let id = app.bundleID, rival.bundleIDs.contains(id) { return true }
                return app.name.map { $0.caseInsensitiveCompare(rival.name) == .orderedSame } ?? false
            }
        }
    }

    /// The same, from the running apps — the `RunningApps` index, so
    /// the card's body can ask on every render.
    @MainActor
    static func runningNow() -> [Rival] {
        running(in: RunningApps.shared.apps.map { ($0.bundleID, $0.name) })
    }

    /// Ask a rival to quit — the card's explicit button, never automatic.
    @MainActor
    static func quit(_ rival: Rival) {
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier.map(rival.bundleIDs.contains) == true
            || app.localizedName?.caseInsensitiveCompare(rival.name) == .orderedSame {
            app.terminate()
        }
    }
}
