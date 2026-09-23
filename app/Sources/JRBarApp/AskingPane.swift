import Darwin
import Foundation
import JRBarCore

/// "The user is already looking at this ask" — the read
/// `answer_local.py` makes before it will type into a session, reused
/// here for a milder question: not "may a keystroke land" but "is the
/// escalation ladder's noise redundant". The daemon proves the
/// frontmost application's process is an ancestor of the session's own
/// process (bundle identity alone cannot tell a same-terminal sibling
/// window apart); the same proof suppresses the pulse and the chime.
/// Its tab-level tty check stays answer-side — suppression never
/// injects anything, so it does not earn an AppleScript round trip.
enum AskingPane {
    /// The daemon's walk depth (`answer_local.MAX_ANCESTRY_DEPTH`).
    static let ancestryDepth = 12

    /// The session's pane is in front when the frontmost app is one of
    /// the session's hosts (its terminal's bundle or the origin app's)
    /// AND — when the session names a process — the frontmost process
    /// sits on that process's ancestry. A walk that cannot run or runs
    /// dry is "unproven": the daemon refuses a keystroke on it, and the
    /// ladder keeps its noise — a stray chime is cheaper than a missed
    /// ask. With no `sessionPID` at all, the bundle match is the best
    /// signal there is.
    static func isFrontmost(expectedBundleIDs: Set<String>, sessionPID: Int?,
                            frontmostBundleID: String?, frontmostPID: Int32?,
                            parentPID: (Int32) -> Int32? = AskingPane.parentPID) -> Bool {
        guard let frontmostBundleID, expectedBundleIDs.contains(frontmostBundleID) else { return false }
        guard let sessionPID else { return true }
        guard let frontmostPID, sessionPID > 0 else { return false }
        let pid = Int32(sessionPID)
        if pid == frontmostPID { return true }
        return ancestry(of: pid, parentPID: parentPID).contains(frontmostPID)
    }

    /// The session process's ancestors, child→parent order, the same
    /// walk the daemon's process table gives it — here straight from
    /// `proc_pidinfo`, one lookup per hop. A cycle or a dead link ends
    /// the walk; what it found still counts.
    static func ancestry(of pid: Int32, parentPID: (Int32) -> Int32? = AskingPane.parentPID) -> [Int32] {
        var out: [Int32] = []
        var current = pid
        for _ in 0..<ancestryDepth {
            guard let parent = parentPID(current), parent > 1, parent != current else { break }
            out.append(parent)
            current = parent
        }
        return out
    }

    /// One process's parent pid via `proc_pidinfo`'s bsd info — the
    /// read the daemon's `ps` table makes, without the table. nil when
    /// the pid is gone or the kernel declines to say.
    static func parentPID(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(bitPattern: info.pbi_ppid)
    }

    // MARK: The daemon's tab-level word

    /// Whether the owner is watching the session, with the daemon's
    /// `session_in_front` over the rule above. The app alone cannot
    /// tell a background Ghostty tab from the one in front — every
    /// Ghostty window is one process — so the daemon's verdict decides
    /// when it has one: `true` is proof the session's own tab, pane or
    /// terminal is in front (quiet), `false` is proof it is not (keep
    /// the noise, even with its terminal app frontmost), and `nil` —
    /// it cannot be told — leaves the rule as it was.
    static func watching(local: Bool, inFront: Bool?) -> Bool { inFront ?? local }

    /// `session_in_front`'s `in_front`: true, false, or nil for a null,
    /// a refusal or no reply at all — "keep your own rule".
    static func inFront(from reply: CoreReply?) -> Bool? {
        guard let reply, reply.ok, let value = reply.result?["in_front"], !value.isNull else { return nil }
        return value.boolValue
    }

    /// How long a verdict speaks for the session, with the same app in
    /// front: a tab switch inside one app raises no activation, so the
    /// word goes stale on its own.
    static let verdictLife: TimeInterval = 3

    /// The last verdict, whom it was about, and under which frontmost
    /// app it was read.
    struct Verdict: Equatable {
        let session: String
        let inFront: Bool?
        let frontmostPID: Int32?
        let at: Date

        /// The verdict still speaks for `session` now, with `pid` in front.
        func speaks(for session: String, frontmostPID pid: Int32?, now: Date) -> Bool {
            self.session == session && frontmostPID == pid && now.timeIntervalSince(at) < AskingPane.verdictLife
        }
    }
}
