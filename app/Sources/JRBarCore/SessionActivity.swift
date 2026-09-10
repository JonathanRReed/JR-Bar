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

    public static func reduce(_ session: CoreSession) -> SessionActivity {
        reduce(lifecycle: session.lifecycle, mode: session.mode, hasAsk: session.ask != nil, nextActor: session.nextActor)
    }

    public static func reduce(lifecycle: String?, mode: String?, hasAsk: Bool, nextActor: String?) -> SessionActivity {
        let lifecycle = lifecycle?.lowercased() ?? "active"
        let mode = mode?.lowercased() ?? ""
        if lifecycle == "failed" || mode == "failed" || mode == "error" { return .failed }
        if lifecycle == "completed" || lifecycle == "done" || mode == "completed" { return .done }
        if lifecycle == "ended" || lifecycle == "closed" || lifecycle == "exited" || mode == "ended" { return .ended }
        if hasAsk || mode == "waiting" || mode == "ask" || nextActor == "user" { return .waiting }
        if ["working", "tool_running", "thinking", "running", "active"].contains(mode) { return .working }
        return .idle
    }
}
