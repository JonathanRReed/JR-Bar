import Foundation

/// The panel's tiny per-provider sparkline: the last `count` calendar days
/// of `usage_history` reduced to one number per day (total tokens), oldest
/// first, a zero for every day the daemon did not report, and a 0…1
/// normalisation for drawing. Pure, so it can be tested without a daemon.
public enum UsageSparkline {
    public static let days = 7

    /// Tokens per day for the `count` days ending on `endingOn` (inclusive),
    /// oldest first. Days the history lacks are 0.
    public static func tokensPerDay(_ history: UsageHistory, endingOn end: Date = Date(), count: Int = days,
                                    calendar: Calendar = .current) -> [Double] {
        guard count > 0 else { return [] }
        var byDay: [String: Double] = [:]
        for day in history.days { byDay[day.date, default: 0] += Double(day.totalTokens) }
        let today = calendar.startOfDay(for: end)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        // The calendar's zone, not the process's: the daemon's dates are in
        // its own local calendar and a formatter left on the default zone
        // shifts every day by one on a machine that disagrees.
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return (0..<count).reversed().map { back -> Double in
            guard let date = calendar.date(byAdding: .day, value: -back, to: today) else { return 0 }
            return byDay[formatter.string(from: date)] ?? 0
        }
    }

    /// `values` scaled so the largest is 1; all zeros stay zeros (a flat
    /// line at the baseline, never a divide by zero).
    public static func normalised(_ values: [Double]) -> [Double] {
        guard let peak = values.max(), peak > 0 else { return values.map { _ in 0 } }
        return values.map { max(0, $0) / peak }
    }

    /// True when there is anything to draw: at least one non-zero day.
    public static func hasSignal(_ values: [Double]) -> Bool { values.contains { $0 > 0 } }
}
