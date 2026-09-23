import Foundation
import JRBarCore

/// Deep work: JR-Bar's quiet held at asks-only for a focused stretch —
/// 25 minutes unless told otherwise — and, when it ends, one line on
/// what the agents did while you were heads-down. One Switch pairs its
/// Do Not Disturb with a Pomodoro; this one knows your agents.
///
/// Pure: a snapshot of every session's state when the stretch starts,
/// and the sentence the live sessions make of it at the end.
enum DeepWork {
    /// A Pomodoro.
    nonisolated static let defaultSeconds = 25 * 60

    /// Each session's state as the stretch begins.
    nonisolated static func snapshot(_ sessions: [CoreSession]) -> [String: SessionActivity] {
        Dictionary(sessions.map { ($0.id, SessionActivity.reduce($0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// "Deep work over (25 min): 3 sessions finished, 1 needs you." A
    /// session counts as finished or failed only when it reached that
    /// state during the stretch (a row already done at the start is not
    /// news); needing you is the asks open now, whenever they arrived.
    nonisolated static func summary(before: [String: SessionActivity], after sessions: [CoreSession],
                                    elapsedSeconds: Int, early: Bool) -> String {
        var finished = 0
        var failed = 0
        var waiting = 0
        for session in sessions {
            let now = SessionActivity.reduce(session)
            let then = before[session.id]
            switch now {
            case .done where then != .done: finished += 1
            case .failed where then != .failed: failed += 1
            case .waiting: waiting += 1
            default: break
            }
        }
        let minutes = max(1, Int((Double(elapsedSeconds) / 60).rounded()))
        let head = early ? "Deep work ended after \(minutes) min" : "Deep work over (\(minutes) min)"
        var parts: [String] = []
        if finished > 0 { parts.append("\(finished) session\(finished == 1 ? "" : "s") finished") }
        if failed > 0 { parts.append("\(failed) failed") }
        if waiting > 0 { parts.append("\(waiting) need\(waiting == 1 ? "s" : "") you") }
        if parts.isEmpty { return "\(head): the agents had nothing new." }
        let listed = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return "\(head): \(listed)."
    }
}
