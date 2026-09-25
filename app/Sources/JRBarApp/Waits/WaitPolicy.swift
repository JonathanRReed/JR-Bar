import Foundation

/// How a wait is drawn, by how long it has lasted. The libraries.dev
/// rule, made native: under two seconds a wait draws nothing (a flash
/// of motion reads as a glitch); from two seconds a small orb says
/// something is on its way; past three the element doing the work gets
/// a border beam as well.
enum WaitStage: Int, Comparable, Sendable, CaseIterable {
    /// Under `WaitPolicy.orbAfter`: nothing is drawn.
    case quiet
    /// From `WaitPolicy.orbAfter`: a `ThinkingOrb` beside the status.
    case orb
    /// From `WaitPolicy.beamAfter`: the orb, and a `BorderBeam` on the
    /// element doing the work.
    case beam

    static func < (lhs: WaitStage, rhs: WaitStage) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Whether the orb is drawn at this stage.
    var showsOrb: Bool { self >= .orb }
    /// Whether the beam is drawn at this stage.
    var showsBeam: Bool { self == .beam }
}

/// The thresholds, and the only clock arithmetic a wait needs. Pure, so
/// every rule runs in a test with a clock the test drives.
enum WaitPolicy {
    /// A wait shorter than this draws nothing at all.
    static let orbAfter: TimeInterval = 2
    /// From here the working element gets its beam too.
    static let beamAfter: TimeInterval = 3

    /// The stage a wait that started at `since` is in at `now`. No wait
    /// (`since` nil) is `.quiet`; a clock that reads earlier than the
    /// start (a wall-clock step back) is too, never a stage from the
    /// future.
    static func stage(since: Date?, now: Date) -> WaitStage {
        guard let since else { return .quiet }
        let elapsed = now.timeIntervalSince(since)
        if elapsed >= beamAfter { return .beam }
        if elapsed >= orbAfter { return .orb }
        return .quiet
    }

    /// The moments after `now` when the stage of a wait that started at
    /// `since` changes — what a `TimelineView(.explicit(…))` waits for,
    /// so a live wait costs two scheduled updates rather than a frame
    /// clock. Empty with no wait and once the beam is on.
    static func boundaries(since: Date?, after now: Date) -> [Date] {
        guard let since else { return [] }
        return [orbAfter, beamAfter]
            .map { since.addingTimeInterval($0) }
            .filter { $0 > now }
    }

    /// The dates a `TimelineView(.explicit(…))` runs a wait on: its start
    /// and both thresholds, past ones included, framed by
    /// `ExplicitTimeline`. The view renders at the latest of them it has
    /// reached, so `stage(since:now:)` read at the context's date is
    /// exactly the stage — never one a clock read a hair early or late
    /// would give — and nothing ticks in between. Empty with no wait.
    static func schedule(since: Date?) -> [Date] {
        guard let since else { return [] }
        return ExplicitTimeline.moments([since, since.addingTimeInterval(orbAfter),
                                         since.addingTimeInterval(beamAfter)])
    }

    /// Whether anything about this wait is still to change — false with
    /// no wait, and once the last threshold has passed.
    static func isLive(since: Date?, now: Date) -> Bool {
        !boundaries(since: since, after: now).isEmpty
    }
}
