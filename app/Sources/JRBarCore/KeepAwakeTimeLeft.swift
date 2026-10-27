import Foundation

/// The cup's steam: how much of a timed Keep Awake session is left, in a
/// few steps the eye can read. Full steam while more than half the session
/// remains, then less, then a wisp for the last quarter and the final five
/// minutes, and no steam once nothing holds the Mac. A hold with no end
/// (until the agents finish, until turned off, while a command runs)
/// steams steadily. Stepped, never animated per second: the card reads it
/// on the countdown's existing redraw.
public enum KeepAwakeSteam: Int, Comparable, Sendable, CaseIterable {
    case none = 0
    case faint
    case low
    case full

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The step for `left` seconds of a session `total` seconds long.
    public static func level(left: TimeInterval, total: TimeInterval?) -> KeepAwakeSteam {
        guard left > 0 else { return .none }
        if left <= KeepAwakeHeadsUp.lead { return .faint }
        guard let total, total > 0 else { return .full }
        let fraction = left / total
        if fraction > 0.5 { return .full }
        if fraction > 0.25 { return .low }
        return .faint
    }

    /// The cup with heat waves while it steams, the plain cup without.
    public var symbol: String { self == .none ? "cup.and.saucer.fill" : "cup.and.heat.waves.fill" }

    /// How strongly the waves draw.
    public var opacity: Double {
        switch self {
        case .none: return 0
        case .faint: return 0.3
        case .low: return 0.6
        case .full: return 1
        }
    }

    /// For VoiceOver and tooltips.
    public var words: String {
        switch self {
        case .none: return "not held"
        case .faint: return "almost over"
        case .low: return "under half left"
        case .full: return "held"
        }
    }
}

extension KeepAwakeReading {
    /// The steam for this hold at `now`.
    public func steam(now: Date) -> KeepAwakeSteam {
        guard holding else { return .none }
        guard case .lease(.until(let end)) = state else { return .full }
        let total = startedAt.map { end.timeIntervalSince($0) }
        return KeepAwakeSteam.level(left: end.timeIntervalSince(now), total: total)
    }
}

/// The one notice before a timed Keep Awake session lets go: five minutes
/// ahead, "Awake for 5 more minutes", with **+30 min** to carry on. Only a
/// countdown the Mac is actually held on gets one, and only when it is
/// longer than the lead. Pure: the app schedules one event at `fireAt`,
/// and drops it the moment the plan changes.
public struct KeepAwakeHeadsUp: Equatable, Sendable {
    /// How far ahead of the end the notice comes.
    public static let lead: TimeInterval = 5 * 60
    /// What "+30 min" adds.
    public static let extra: TimeInterval = 30 * 60
    /// The daemon's cap on one lease.
    public static let longestLease: TimeInterval = 24 * 60 * 60
    /// One notice at a time, replaced rather than stacked.
    public static let identifier = "keep-awake-heads-up"

    /// When the session ends.
    public let end: Date

    public init(end: Date) { self.end = end }

    public var fireAt: Date { end.addingTimeInterval(-Self.lead) }

    /// The plan for `reading` at `now`, or nil when there is nothing to warn
    /// about: no countdown, a hold that is paused or failed, or less than
    /// the lead left.
    public static func plan(for reading: KeepAwakeReading, now: Date) -> KeepAwakeHeadsUp? {
        guard reading.holding, !reading.releaseFailed, reading.suspended == nil,
              case .lease(.until(let end)) = reading.state,
              end.timeIntervalSince(now) > lead else { return nil }
        return KeepAwakeHeadsUp(end: end)
    }

    public var title: String { "Awake for 5 more minutes" }

    /// "The Mac can sleep at 14:32. +30 min keeps it awake longer."
    public func body(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let clock = UsageDateFormatters.shared.withFormatter(locale: locale, timeZone: timeZone,
                                                             format: .template("jmm")) {
            $0.string(from: end)
        }
        return "The Mac can sleep at \(clock). +30 min keeps it awake longer."
    }

    /// The new end for "+30 min" at `now`, kept inside one lease's day.
    public static func extendedEnd(from end: Date, now: Date) -> Date {
        let wanted = max(end, now).addingTimeInterval(extra)
        return min(wanted, now.addingTimeInterval(longestLease))
    }
}
