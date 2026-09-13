import Foundation

/// The one session the buddy is watching — the answer to "what is it
/// doing", carried on the hover line's tail and the floating buddy's
/// caption. The pick mirrors the mood's precedence one level deeper:
/// an open ask outranks a failure, a failure outranks work, and work
/// outranks a finished row still waiting to be reviewed.
public struct BuddyFocus: Equatable, Sendable {
    /// The state word the line ends on.
    public enum Phrase: String, Sendable, CaseIterable {
        case waiting, failed, working, done

        public var text: String {
            switch self {
            case .waiting: return "waiting on you"
            case .failed: return "failed"
            case .working: return "working"
            case .done: return "done"
            }
        }
    }

    /// The session's id, for anything that wants to open it.
    public var id: String
    /// The provider's display name ("Claude", "Codex", …).
    public var provider: String
    /// The session's short label — `SessionLabel.display`, so it reads
    /// the way the panel names it.
    public var session: String
    public var phrase: Phrase

    public init(id: String, provider: String, session: String, phrase: Phrase) {
        self.id = id
        self.provider = provider
        self.session = session
        self.phrase = phrase
    }

    /// "Claude · rename-the-fish — waiting on you".
    public var line: String { "\(provider) · \(session) — \(phrase.text)" }

    /// The most attention-worthy session: the longest-waiting ask first
    /// (the same pick the tap makes), then the freshest failure, then
    /// the most recently touched working run, then a done one. Idle and
    /// ended rows are scenery, not news.
    public static func pick(from sessions: [CoreSession]) -> BuddyFocus? {
        var asking: CoreSession?
        var failed: CoreSession?
        var working: CoreSession?
        var done: CoreSession?
        for session in sessions {
            switch SessionActivity.reduce(session) {
            case .waiting:
                // Longest-unanswered first — an embedded ask with no
                // `openedAt` sorts as never-opened and lands last.
                guard let current = asking else { asking = session; continue }
                if (session.ask?.openedAt ?? .infinity) < (current.ask?.openedAt ?? .infinity) {
                    asking = session
                }
            case .failed: failed = fresher(failed, session)
            case .working: working = fresher(working, session)
            case .done: done = fresher(done, session)
            case .ended, .idle: break
            }
        }
        let picked: (CoreSession, Phrase)?
        if let asking { picked = (asking, .waiting) }
        else if let failed { picked = (failed, .failed) }
        else if let working { picked = (working, .working) }
        else { picked = done.map { ($0, .done) } }
        guard let session = picked?.0, let phrase = picked?.1 else { return nil }
        return BuddyFocus(id: session.id,
                          provider: SessionLabel.providerName(session.provider),
                          session: SessionLabel.display(label: session.label, shortId: session.shortId,
                                                        id: session.id, provider: session.provider),
                          phrase: phrase)
    }

    /// The row that moved most recently; `updatedAt` is a maybe, and a
    /// missing stamp reads as epoch.
    private static func fresher(_ current: CoreSession?, _ session: CoreSession) -> CoreSession {
        guard let current else { return session }
        return (session.updatedAt ?? 0) > (current.updatedAt ?? 0) ? session : current
    }
}

/// The drag's arithmetic — a press becomes a carry past
/// `dragThreshold`, a drop near the dock slot snaps home, and a parked
/// pill is clamped onto the visible screen. Pure so the two panels
/// share it and the tests can pin it.
public enum BuddyPlacement {
    /// Points of travel before a press on the pill becomes a drag —
    /// inside it the press is just a tap.
    public static let dragThreshold: Double = 4
    /// The dock's pull: a drop whose centre lands inside this box around
    /// the slot goes home — generous sideways, tight vertically, because
    /// it docks to the notch, not to anywhere overhead.
    public static let dockReach: Double = 96
    public static let dockDrop: Double = 44

    /// Past the threshold a press is a carry.
    public static func isDrag(dx: Double, dy: Double) -> Bool {
        dx * dx + dy * dy >= dragThreshold * dragThreshold
    }

    /// The dangle: a carried buddy tips toward the travel direction.
    public static func dragTilt(dx: Double) -> Double {
        min(14, max(-14, dx * 0.85))
    }

    /// The dangle settling while the cursor holds still — the tilt eases
    /// away with a ~0.22 s time constant.
    public static func tiltDecay(age: TimeInterval) -> Double {
        age <= 0 ? 1 : exp(-age / 0.22)
    }

    /// Keep the whole pill inside `visible` (a screen's visible frame);
    /// a pill somehow wider than the screen centres instead. This is
    /// what makes a spot saved on a since-unplugged monitor safe.
    public static func clampedCenter(_ center: CGPoint, size: CGSize, inside visible: CGRect) -> CGPoint {
        let x = size.width < visible.width
            ? min(max(center.x, visible.minX + size.width / 2), visible.maxX - size.width / 2)
            : visible.midX
        let y = size.height < visible.height
            ? min(max(center.y, visible.minY + size.height / 2), visible.maxY - size.height / 2)
            : visible.midY
        return CGPoint(x: x, y: y)
    }

    /// The drop rule: centre inside the dock's box means "put it back".
    public static func docksOnDrop(center: CGPoint, slot: CGPoint) -> Bool {
        abs(center.x - slot.x) <= dockReach && abs(center.y - slot.y) <= dockDrop
    }
}
