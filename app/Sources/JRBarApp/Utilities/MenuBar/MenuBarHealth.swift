import AppKit
import JRBarCore

/// Which engine hides the bar right now, and whether it is healthy — the
/// card's "Right now" line. A framework that did not resolve, an
/// assertion macOS keeps refusing, or an unnotarized build used to live
/// only in the log; this says it where the person already looks. Pure
/// over its inputs so a test pins every line.
enum MenuBarEngineHealth: Equatable, Sendable {
    /// The utility is off or handed to another manager.
    case parked
    /// macOS's concealer runs; `hidden` apps are concealed right now.
    case concealer(hidden: Int)
    /// The concealer is up and waiting out the start grace.
    case concealerStarting
    /// The concealer has a target but macOS refuses every assertion —
    /// nothing is hidden and the real icon is handed back.
    case concealerFailing
    /// The spacer engine stands in, and why.
    case spacer(SpacerReason)

    enum SpacerReason: Equatable, Sendable {
        /// macOS 26, or a 27 point release that renamed the framework.
        case frameworkMissing
        /// This copy is not notarized and the person did not opt in.
        case notNotarized
        /// The Advanced toggle forces it — a diagnostic.
        case forced
        /// Still deciding: the notarization check has not answered.
        case pending
    }

    /// The inputs, gathered by the utility.
    struct Inputs: Equatable, Sendable {
        var running: Bool
        var frameworkAvailable: Bool
        var forced: Bool
        var notarized: Bool?
        var concealUnnotarized: Bool
        var engineUp: Bool
        var assertionLive: Bool
        var activationFailing: Bool
        var inStartGrace: Bool
        var concealedCount: Int
    }

    nonisolated static func assess(_ i: Inputs) -> MenuBarEngineHealth {
        guard i.running else { return .parked }
        if i.engineUp {
            if i.activationFailing, !i.assertionLive { return .concealerFailing }
            if !i.assertionLive, i.inStartGrace, i.concealedCount > 0 { return .concealerStarting }
            return .concealer(hidden: i.assertionLive ? i.concealedCount : 0)
        }
        if !i.frameworkAvailable { return .spacer(.frameworkMissing) }
        if i.forced { return .spacer(.forced) }
        guard let notarized = i.notarized else { return .spacer(.pending) }
        if !notarized, !i.concealUnnotarized { return .spacer(.notNotarized) }
        return .spacer(.pending)
    }

    /// Whether this is worth an alert tone: hiding stopped working.
    var isAlert: Bool { self == .concealerFailing }

    /// The card's line. `fitEdge` joins the spacer engine's line: the x
    /// it packs against on this screen.
    func line(fitEdge: CGFloat? = nil) -> String {
        switch self {
        case .parked:
            return "Parked"
        case .concealer(let hidden):
            return hidden == 0 ? "macOS concealer · nothing hidden"
                : "macOS concealer · \(hidden) app\(hidden == 1 ? "" : "s") hidden"
        case .concealerStarting:
            return "macOS concealer · starting"
        case .concealerFailing:
            return "The concealer is failing — macOS refused the last assertion, so nothing is hidden and the real icon is back."
        case .spacer(let reason):
            let why: String
            switch reason {
            case .frameworkMissing: why = "macOS's concealer isn't available on this system"
            case .notNotarized: why = "this copy isn't notarized"
            case .forced: why = "forced in Advanced"
            case .pending: why = "checking the concealer"
            }
            let edge = fitEdge.map { " · edge at \(Int($0.rounded())) pt" } ?? ""
            return "Spacer engine · \(why)\(edge)"
        }
    }
}

/// The other menu-bar managers that fight ours when both run: live
/// assertions combine as a union of allowlists, so another manager's
/// assertion quietly un-hides what JR-Bar conceals, and two spacer
/// engines push each other's items around. Nothing detected this before.
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

    /// The same, from the workspace.
    @MainActor
    static func runningNow() -> [Rival] {
        running(in: NSWorkspace.shared.runningApplications.map {
            ($0.bundleIdentifier, $0.localizedName)
        })
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
