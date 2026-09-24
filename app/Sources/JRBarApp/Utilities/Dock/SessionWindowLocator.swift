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

    /// A running host app as the search needs it — read on main, carried
    /// to `DockAXWorker`.
    struct Host: Sendable {
        let pid: pid_t
        let name: String
        let bundleID: String?
    }

    /// The row hosting `sessionID` among `items`, by the exclusive-claim
    /// rule over every mark (a rival session's stronger claim on the
    /// same window still wins). Only a window that is the session's own:
    /// an app-hosted app's sole window, which shows whatever conversation
    /// the app last had open, is left to `open_session`. Pure; the live
    /// half feeds it.
    nonisolated static func locate(sessionID: String, marks: [DockAgentMark], items: [SwitcherItem],
                                   bundleID: (pid_t) -> String?) -> SwitcherItem? {
        guard marks.contains(where: { $0.sessionID == sessionID }) else { return nil }
        return DockSwitcherList.annotate(items, marks: marks, bundleID: bundleID, soleAppWindows: false)
            .first { $0.agent?.sessionID == sessionID }
    }

    /// The running apps that can host `sessionID`'s window; empty when
    /// the session has no mark or none of its hosts is running.
    static func hosts(sessionID: String, marks: [DockAgentMark]) -> [Host] {
        guard let target = marks.first(where: { $0.sessionID == sessionID }) else { return [] }
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, target.hosts.contains(id), !app.isTerminated else { return nil }
            return Host(pid: app.processIdentifier, name: app.localizedName ?? "App", bundleID: id)
        }
    }

    /// The AX half: list the hosts' windows, find the session's, and
    /// raise it — or say it has no reachable element, or none hosts it.
    /// The pid is the app activation should bring forward after. Safe
    /// off the main thread, and meant for it: each host's window list
    /// can cost a hung app half a second, a window on another Space the
    /// remote-token walk's 0.2 s.
    nonisolated static func land(sessionID: String, marks: [DockAgentMark],
                                 hosts: [Host]) -> (outcome: Outcome, pid: pid_t?) {
        guard !hosts.isEmpty else { return (.notFound, nil) }
        let byPID = Dictionary(hosts.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let pids = Array(byPID.keys)
        let items = DockSwitcherList.order(
            rows: DockSwitcherList.onScreenRows(running: pids),
            offRows: DockSwitcherList.offScreenRows(running: pids),
            windowsForApp: { AppleDockReader.windowsReading(pid: $0, stamp: 0).windows },
            appName: { byPID[$0]?.name ?? "App" },
            icon: { _ in nil })
        guard let hit = locate(sessionID: sessionID, marks: marks, items: items,
                               bundleID: { byPID[$0]?.bundleID }) else { return (.notFound, nil) }
        guard let element = hit.element ?? hit.windowID.flatMap({
            DockRemoteWindows.element(pid: hit.pid, windowID: $0)
        }) else { return (.activated, hit.pid) }
        AppleDockReader.raiseWindow(DockPreviewWindow(id: 0, title: hit.title, minimized: hit.minimized,
                                                      fullScreen: nil, frame: nil, thumbnail: nil,
                                                      element: element))
        return (.raised, hit.pid)
    }

    /// Find and raise the window hosting `sessionID`, here and now — a
    /// synchronous caller's answer. An async caller should use the
    /// overload below, which keeps the AX work off the main thread.
    @discardableResult
    static func raise(sessionID: String, marks: [DockAgentMark]) -> Outcome {
        let landed = land(sessionID: sessionID, marks: marks,
                          hosts: hosts(sessionID: sessionID, marks: marks))
        activate(landed.pid)
        return landed.outcome
    }

    /// Find and raise the window hosting `sessionID`, with the window
    /// lists and the walk on `DockAXWorker`; activation and the answer
    /// come back to the main actor.
    @discardableResult
    static func raise(sessionID: String, marks: [DockAgentMark]) async -> Outcome {
        let hosts = hosts(sessionID: sessionID, marks: marks)
        guard !hosts.isEmpty else { return .notFound }
        return await withCheckedContinuation { continuation in
            DockAXWorker.run({
                land(sessionID: sessionID, marks: marks, hosts: hosts)
            }, then: { landed in
                activate(landed.pid)
                continuation.resume(returning: landed.outcome)
            })
        }
    }

    /// Plain activate, after the raise — `.activateAllWindows` would
    /// bury the window just picked under the app's others.
    private static func activate(_ pid: pid_t?) {
        guard let pid else { return }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}
