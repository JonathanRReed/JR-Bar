import AppKit
import ApplicationServices
import JRBarCore

/// Daemon session → the exact window it runs in → raised. The switcher's
/// window list (CGWindowList z-order merged with each app's AX windows,
/// native ids first) narrowed to the session's host apps, and
/// `DockAgentMatch`'s no-guess rule to pick the one window that hosts
/// it. Anything JR-Bar shows a session on — the panel's Open, the Agent
/// Overview, a Screen Bar notice — can ask this first and fall back to
/// the daemon's `open_session` (which opens or resumes rather than
/// raising a live window) only when it answers `.notFound`.
@MainActor
enum SessionWindowLocator {
    enum Outcome: Equatable {
        /// The session's own window is in front.
        case raised
        /// The window is known but has no reachable element (another
        /// Space, no AX twin): its app was activated instead.
        case activated
        /// No window exclusively hosts the session — the caller's
        /// fallback decides.
        case notFound
    }

    /// The row hosting `sessionID` among `items`, by the exclusive-claim
    /// rule over every mark (a rival session's stronger claim on the
    /// same window still wins). Pure; the live half feeds it.
    static func locate(sessionID: String, marks: [DockAgentMark], items: [SwitcherItem],
                       bundleID: (pid_t) -> String?) -> SwitcherItem? {
        guard marks.contains(where: { $0.sessionID == sessionID }) else { return nil }
        return DockSwitcherList.annotate(items, marks: marks, bundleID: bundleID)
            .first { $0.agent?.sessionID == sessionID }
    }

    /// Find and raise the window hosting `sessionID`.
    @discardableResult
    static func raise(sessionID: String, marks: [DockAgentMark]) -> Outcome {
        guard let target = marks.first(where: { $0.sessionID == sessionID }) else { return .notFound }
        let running = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return target.hosts.contains(id) && !$0.isTerminated
        }
        guard !running.isEmpty else { return .notFound }
        let apps = Dictionary(uniqueKeysWithValues: running.map { ($0.processIdentifier, $0) })
        let pids = Array(apps.keys)
        let items = DockSwitcherList.order(
            rows: DockSwitcherList.onScreenRows(running: pids),
            offRows: DockSwitcherList.offScreenRows(running: pids),
            windowsForApp: { AppleDockReader.windows(pid: $0) },
            appName: { apps[$0]?.localizedName ?? "App" },
            icon: { _ in nil })
        guard let hit = locate(sessionID: sessionID, marks: marks, items: items,
                               bundleID: { apps[$0]?.bundleIdentifier }) else { return .notFound }
        let app = apps[hit.pid]
        if let element = hit.element ?? hit.windowID.flatMap({
            DockRemoteWindows.element(pid: hit.pid, windowID: $0)
        }) {
            let window = DockPreviewWindow(id: 0, title: hit.title, minimized: hit.minimized,
                                           fullScreen: nil, frame: nil, thumbnail: nil,
                                           element: element)
            AppleDockReader.raise(window, app: app)
            return .raised
        }
        app?.activate()
        return .activated
    }
}
