import Foundation

/// What a session is doing, reduced to the six things the panel can show.
/// `lifecycle` wins over `mode`: `failed`, `completed` (a finished run the
/// user has not acknowledged, green check) and `ended` (the process went
/// away without a completion: grey, no check) are the daemon's words;
/// everything else is read from the mode and the ask.
public enum SessionActivity: String, Equatable, Sendable, CaseIterable {
    case working
    case waiting
    case done
    case ended
    case failed
    case idle

    public var word: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Waiting on you"
        case .done: return "Done"
        case .ended: return "Ended"
        case .failed: return "Failed"
        case .idle: return "Idle"
        }
    }

    /// Rows `clear_completed` acknowledges: finished, ended, or stale.
    public var isClearable: Bool { self == .done || self == .ended }

    /// The panel's session order, lowest first: a live ask ranks above
    /// everything (the store orders ask rows among themselves by
    /// `ask.openedAt`, longest-unanswered first), then waiting, failed,
    /// working, done, ended, idle.
    public var sortRank: Int {
        switch self {
        case .waiting: return 1
        case .failed: return 2
        case .working: return 3
        case .done: return 4
        // An ended run is over and nobody is waiting on it: it sits
        // under the finished ones, above the merely idle.
        case .ended: return 5
        case .idle: return 6
        }
    }

    public static func reduce(_ session: CoreSession) -> SessionActivity {
        reduce(lifecycle: session.lifecycle, mode: session.mode, hasAsk: session.ask != nil, nextActor: session.nextActor)
    }

    public static func reduce(lifecycle: String?, mode: String?, hasAsk: Bool, nextActor: String?) -> SessionActivity {
        let lifecycle = lifecycle?.lowercased() ?? "active"
        let mode = mode?.lowercased() ?? ""
        // The terminal words win over an ask: a failed run that also has
        // a question open is still failed, not "waiting on you".
        if lifecycle == "failed" || ["failed", "error", "blocked_error", "blocked"].contains(mode) { return .failed }
        if lifecycle == "completed" || lifecycle == "done" || mode == "completed" { return .done }
        if lifecycle == "ended" || lifecycle == "closed" || lifecycle == "exited" || ["ended", "ended_unconfirmed"].contains(mode) { return .ended }
        if hasAsk || ["waiting", "waiting_for_input", "ask", "needs_input"].contains(mode) || nextActor == "user" { return .waiting }
        if ["working", "tool_running", "long_task_progress", "thinking", "running", "active"].contains(mode) { return .working }
        if ["idle", "idle_ready", "ready"].contains(mode) { return .idle }
        // A row in `state.sessions` is live and its lifecycle agrees; a
        // mode this build does not know must not draw a dead row -- that
        // is how `long_task_progress` once read "Idle" through a
        // twenty-minute build.
        if lifecycle == "active", !mode.isEmpty { return .working }
        return .idle
    }
}

/// The one-word state of everything the monitor knows about, shared by
/// the daemon's `state.aggregate` and the file-feed fallback
/// (`AgentMonitorFeed`). Pure data so it can be tested without AppKit;
/// the menu-bar colour is derived from `tintHex`.
public enum AgentAggregateState: String, Equatable, Sendable, CaseIterable {
    case idle
    case working
    case needsInput
    case completed
    case failed

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .needsInput: return "Needs you"
        case .completed: return "Done"
        case .failed: return "Failed"
        }
    }

    /// The mode colours from `_led_status_legacy.py`; nil keeps the menu
    /// bar's own tint. Failed is a true red, never the ask's orange-red:
    /// a crash is not a question, and drawing them the same made a dead
    /// run read as "waiting on you" everywhere the aggregate landed.
    public var tintHex: String? {
        switch self {
        case .idle: return nil
        case .working: return "#00E5FF"
        case .needsInput: return "#FF3A00"
        case .completed: return "#00FF66"
        case .failed: return "#FF3B30"
        }
    }

    /// `state.aggregate.mode` → the five words. `needs_you` outranks
    /// `failed` deliberately (an unanswered ask is costing time right
    /// now and one keystroke ends it); `failed` outranks working. The
    /// counts back the mode string up so an older daemon's plain
    /// `"active"` still lands somewhere truthful.
    public static func from(aggregate: CoreAggregate) -> AgentAggregateState {
        let mode = aggregate.mode.lowercased()
        if aggregate.needsYou > 0 || mode.contains("need") || mode.contains("ask") || mode.contains("wait") { return .needsInput }
        if aggregate.failed > 0 || mode.contains("fail") || mode.contains("error") || mode.contains("block") { return .failed }
        if mode.contains("work") || mode.contains("active") || mode.contains("run") || aggregate.active > 0 { return .working }
        if mode.contains("done") || mode.contains("complet") || mode.contains("ready") || aggregate.ready > 0 { return .completed }
        return .idle
    }
}

extension CoreAggregate {
    /// "1 needs you · 2 failed · 3 working · 1 ready", in the daemon's
    /// precedence order and the status icon's label order -- the panel
    /// header and the right-click menu's detail line share it so the two
    /// can never disagree about which count comes first.
    public var countParts: [String] {
        var parts: [String] = []
        if needsYou > 0 { parts.append(needsYou == 1 ? "1 needs you" : "\(needsYou) need you") }
        if failed > 0 { parts.append(failed == 1 ? "1 failed" : "\(failed) failed") }
        if active > 0 { parts.append(active == 1 ? "1 working" : "\(active) working") }
        if ready > 0 { parts.append(ready == 1 ? "1 ready" : "\(ready) ready") }
        return parts
    }
}

/// The reduction behind `AgentStateMonitor` (app target): reads
/// `~/.local/state/jrbar/latest.json` (the flat dir
/// `state_paths.default_state_dir` defines) and answers the
/// one-word state plus the detail line.
///
/// The file may carry either the public `agents` summary
/// (`lifecycle_counts` / `next_actor_counts`, as `serve.py` publishes) or
/// the raw version-2 `works` list; both are handled. Completed work only
/// counts as "Done" for a short window, the way the Python attention
/// model treats `COMPLETED_RECENTLY`.
public enum AgentMonitorFeed {
    public static let completedWindow: TimeInterval = 90

    /// A `latest.json` older than this is a fossil, not a snapshot. The
    /// monitor rewrites the file (atomically, debounced to about a second)
    /// on every state change and never heartbeats it, so its age is "how
    /// long since the last change reached disk" — and past a few minutes
    /// the fallback must say so rather than present a frozen file as now.
    public static let staleAfter: TimeInterval = 5 * 60

    public static func reduce(_ data: Data?, now: Date = Date(), fileModifiedAt: Date? = nil) -> (state: AgentAggregateState, detail: String) {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (.idle, "No agent monitor state")
        }
        // When the file was last written: the v2 document's own clock
        // stamp first (robust to the file being copied), then the caller's
        // mtime — an `agents` summary carries no clock of its own.
        let writtenAt = ((json["last_clock"] as? [String: Any])?["wall_epoch"] as? Double)
            ?? (json["updated_at"] as? Double)
            ?? fileModifiedAt?.timeIntervalSince1970
        var lifecycle: [String: Int] = [:]
        var nextActor: [String: Int] = [:]
        var recentlyCompleted = 0
        if let agents = json["agents"] as? [String: Any] {
            lifecycle = (agents["lifecycle_counts"] as? [String: Int]) ?? [:]
            nextActor = (agents["next_actor_counts"] as? [String: Int]) ?? [:]
            recentlyCompleted = lifecycle["completed"] ?? 0
        } else if let works = json["works"] as? [[String: Any]] {
            for work in works {
                guard let life = work["lifecycle"] as? String, let actor = work["next_actor"] as? String else { continue }
                lifecycle[life, default: 0] += 1
                nextActor[actor, default: 0] += 1
                if life == "completed",
                   let watermark = work["watermark"] as? [String: Any],
                   let occurred = watermark["occurred_at_epoch"] as? Double,
                   now.timeIntervalSince1970 - occurred <= completedWindow {
                    recentlyCompleted += 1
                }
            }
        } else {
            return (.idle, "Unrecognised latest.json")
        }
        // A recognised document older than `staleAfter` collapsed to idle:
        // "the file stopped moving" is the only claim left standing.
        if let writtenAt {
            let age = now.timeIntervalSince1970 - writtenAt
            if age > staleAfter {
                return (.idle, "Monitor quiet — last update \(ageText(age)) ago")
            }
        }
        let active = (lifecycle["active"] ?? 0)
        let waiting = (lifecycle["waiting"] ?? 0) + (nextActor["user"] ?? 0)
        let failed = lifecycle["failed"] ?? 0
        let state: AgentAggregateState
        if waiting > 0 { state = .needsInput }
        else if failed > 0 { state = .failed }
        else if active > 0 { state = .working }
        else if recentlyCompleted > 0 { state = .completed }
        else { state = .idle }
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) waiting on you") }
        if failed > 0 { parts.append("\(failed) failed") }
        if active > 0 { parts.append("\(active) working") }
        if recentlyCompleted > 0 { parts.append("\(recentlyCompleted) just finished") }
        let total = lifecycle.values.reduce(0, +)
        let detail = parts.isEmpty ? (total > 0 ? "\(total) sessions, nothing live" : "No sessions") : parts.joined(separator: " · ")
        return (state, detail)
    }

    /// "47s" / "6m" / "2h" — a file age in the same shorthand the panel's
    /// elapsed column uses.
    static func ageText(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}
