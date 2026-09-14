import Foundation

/// One observation of a usage window, kept so the app can extrapolate a
/// pace when the daemon sends no `forecast`.
public struct UsageSample: Hashable, Sendable, Codable {
    public var at: Double
    public var usedPct: Double

    public init(at: Double, usedPct: Double) {
        self.at = at
        self.usedPct = usedPct
    }
}

/// A bounded log of samples per provider and window, fed from every
/// `state` document. A sample is kept when the percentage moved or half a
/// minute has passed, so a quiet hour costs a couple of entries.
public struct UsageSampleLog: Hashable, Sendable {
    public static let limit = 240
    public static let minimumSpacing: Double = 30

    private var table: [String: [UsageSample]] = [:]

    public init() {}

    private static func key(_ provider: String, _ window: String) -> String { provider + "|" + window.lowercased() }

    public mutating func record(_ usage: CoreUsage?, now: Double) {
        guard let usage else { return }
        for provider in usage.providers {
            for window in provider.windows {
                // A window with no reading is not a window at zero: a
                // sample of 0 would drag every pace this log computes.
                guard let usedPct = window.usedPct else { continue }
                // `identity` keeps two accounts of one provider apart.
                record(provider: provider.identity, window: window.name, usedPct: usedPct, at: now)
            }
        }
    }

    public mutating func record(provider: String, window: String, usedPct: Double, at: Double) {
        let key = Self.key(provider, window)
        var samples = table[key] ?? []
        if let last = samples.last {
            if last.usedPct == usedPct, at - last.at < Self.minimumSpacing { return }
            if at < last.at { return }
        }
        samples.append(UsageSample(at: at, usedPct: usedPct))
        if samples.count > Self.limit { samples.removeFirst(samples.count - Self.limit) }
        table[key] = samples
    }

    public func samples(provider: String, window: String) -> [UsageSample] {
        table[Self.key(provider, window)] ?? []
    }

    public var isEmpty: Bool { table.isEmpty }
}

/// What a usage window is heading for, and the one line that says so.
public struct UsageForecast: Hashable, Sendable {
    public enum Verdict: Hashable, Sendable {
        /// Nothing left; the window has to reset first.
        case exhausted
        /// The pace reaches 100 % before the reset.
        case runsOut(exhaustsAt: Double)
        /// The reset comes first (or nothing is burning).
        case comfortable
        /// Too little information for a pace.
        case unknown
        /// The daemon measured the window and refused the pace, with the
        /// reason (`insufficient_samples`, `reset_boundary`, `stale_samples`,
        /// `clock_regressed`, ...). A guarded verdict can never be
        /// overridden by the app's own weaker local fit — the daemon's
        /// guard is the authority (T28).
        case guarded(reason: String)
        /// The window exists and the provider stated no number at all, so
        /// there is nothing to have a pace about. Distinct from `unknown`,
        /// which is a known percentage with too few samples.
        case unmeasured
    }

    public enum Source: String, Hashable, Sendable {
        case daemon, local, none
    }

    public var window: String
    /// Nil when the provider stated no number for this window.
    public var usedPct: Double?
    public var resetsAt: Double?
    public var verdict: Verdict
    /// Percent of the window burned per hour, when known.
    public var ratePctPerHour: Double?
    public var source: Source
    /// The daemon's own word (`ahead`, `on`, `under`, `exhausted`,
    /// `guarded`), passed through.
    public var pace: String?
    /// The daemon's reason a pace was refused, when `pace == "guarded"`.
    public var guardReason: String?

    public init(window: String, usedPct: Double?, resetsAt: Double?, verdict: Verdict, ratePctPerHour: Double?, source: Source, pace: String? = nil, guardReason: String? = nil) {
        self.window = window
        self.usedPct = usedPct
        self.resetsAt = resetsAt
        self.verdict = verdict
        self.ratePctPerHour = ratePctPerHour
        self.source = source
        self.pace = pace
        self.guardReason = guardReason
    }

    /// How much of the window is left — nil when nobody measured it. A
    /// window with no reading has no "left", and 100 would be a promise.
    public var remainingPct: Double? { usedPct.map { max(0, min(100, 100 - $0)) } }

    public var isCritical: Bool {
        switch verdict {
        case .exhausted, .runsOut: return true
        default: return false
        }
    }

    /// The one-line reading, e.g. "At this pace the 5h window runs out at
    /// 16:42 (in 1h 12m)" or "Comfortable: 61 % left, resets before you'd
    /// hit it".
    public func headline(now: Date, timeZone: TimeZone = .current) -> String {
        guard let remainingPct else {
            // Nothing was measured: say so, and say the one thing that IS
            // known -- when the window turns over.
            if let resetsAt {
                return "No reading for the \(window) window · resets \(Self.relative(to: resetsAt, now: now))"
            }
            return "No reading for the \(window) window"
        }
        let left = Int(remainingPct.rounded())
        switch verdict {
        case .exhausted:
            if let resetsAt {
                return "Used up: the \(window) window resets \(Self.relative(to: resetsAt, now: now))"
            }
            return "Used up: the \(window) window is exhausted"
        case .runsOut(let at):
            return "At this pace the \(window) window runs out at \(Self.clock(at, timeZone: timeZone)) (\(Self.relative(to: at, now: now)))"
        case .comfortable:
            if let rate = ratePctPerHour, rate <= UsageForecaster.idleRate {
                return "Comfortable: \(left) % left, nothing burning right now"
            }
            if resetsAt != nil {
                return "Comfortable: \(left) % left, resets before you'd hit it"
            }
            return "Comfortable: \(left) % left at this pace"
        case .unknown:
            return "\(left) % left · no pace yet"
        case .guarded(let reason):
            return "\(left) % left · \(Self.guardText(reason))"
        case .unmeasured:
            // Unreachable: a window with no reading has no `remainingPct`.
            return "No reading for the \(window) window"
        }
    }

    /// The human reading of a daemon guard reason — one short clause that
    /// names why the pace is paused, never a fabricated prediction.
    public static func guardText(_ reason: String) -> String {
        switch reason {
        case "insufficient_samples": return "pace needs more readings"
        case "insufficient_span": return "pace needs about 30 min of readings"
        case "reset_boundary": return "window just reset; pace resumes as readings arrive"
        case "stale_samples": return "readings stopped; pace paused"
        case "clock_regressed": return "clock moved backwards; pace paused"
        default: return "no pace yet"
        }
    }

    /// "~2.4 %/h" for the card's pace column.
    public var rateText: String? {
        guard let rate = ratePctPerHour, rate > UsageForecaster.idleRate else { return nil }
        return rate >= 10 ? String(format: "%.0f %%/h", rate) : String(format: "%.1f %%/h", rate)
    }

    public static func clock(_ epoch: Double, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    /// "in 1h 12m", "in 4m", "now", "2 d ago" is never needed: resets are ahead.
    public static func relative(to epoch: Double, now: Date) -> String {
        let seconds = Int(epoch - now.timeIntervalSince1970)
        if seconds <= 30 { return "now" }
        let minutes = (seconds + 30) / 60
        if minutes < 60 { return "in \(max(1, minutes))m" }
        let hours = minutes / 60
        if hours < 24 { return String(format: "in %dh %02dm", hours, minutes % 60) }
        return "in \(hours / 24)d \(hours % 24)h"
    }
}

/// The forecast math: the daemon's `forecast` when it sends one, else a
/// linear fit over the recent samples.
public enum UsageForecaster {
    /// Below this many percent per hour nothing is burning.
    public static let idleRate: Double = 0.05
    /// Samples older than this do not shape the pace.
    public static let lookback: Double = 45 * 60
    public static let minimumSamples = 2

    /// Percent per hour from the samples after the last reset (a drop of
    /// more than a point), least-squares over the lookback. Nil with fewer
    /// than two usable samples or less than a minute of spread.
    public static func rate(samples: [UsageSample], now: Double) -> Double? {
        var recent = samples.filter { now - $0.at <= lookback }
        if let drop = recent.indices.dropFirst().last(where: { recent[$0].usedPct < recent[$0 - 1].usedPct - 1 }) {
            recent = Array(recent[drop...])
        }
        guard recent.count >= minimumSamples else { return nil }
        let span = recent.last!.at - recent.first!.at
        guard span >= 60 else { return nil }
        let meanT = recent.map(\.at).reduce(0, +) / Double(recent.count)
        let meanP = recent.map(\.usedPct).reduce(0, +) / Double(recent.count)
        var num = 0.0, den = 0.0
        for sample in recent {
            num += (sample.at - meanT) * (sample.usedPct - meanP)
            den += (sample.at - meanT) * (sample.at - meanT)
        }
        guard den > 0 else { return nil }
        return max(0, num / den * 3600)
    }

    public static func forecast(window: CoreUsageWindow, daemon: CoreUsageForecast?, samples: [UsageSample], now: Double) -> UsageForecast {
        let resetsAt = window.resetsAt
        // The window exists and nobody said how full it is. There is no
        // pace to compute and no comfort to promise: reading nil as 0 is
        // what made an unmeasured window say "plenty left".
        guard let used = window.usedPct else {
            return UsageForecast(window: window.name, usedPct: nil, resetsAt: resetsAt, verdict: .unmeasured,
                                 ratePctPerHour: nil, source: .none, pace: daemon?.pace)
        }
        if used >= 99.95 {
            return UsageForecast(window: window.name, usedPct: used, resetsAt: resetsAt, verdict: .exhausted, ratePctPerHour: nil, source: daemon != nil ? .daemon : .local, pace: daemon?.pace)
        }
        if let daemon {
            // The daemon's guard is the authority: when it refused the
            // pace the app must not quietly fit one over weaker evidence.
            if daemon.pace == "guarded" {
                return UsageForecast(window: window.name, usedPct: used, resetsAt: resetsAt,
                                     verdict: .guarded(reason: daemon.reason ?? "unknown"),
                                     ratePctPerHour: daemon.ratePctPerHour, source: .daemon,
                                     pace: daemon.pace, guardReason: daemon.reason)
            }
            if let exhaustsAt = daemon.exhaustsAt {
                let hours = (exhaustsAt - now) / 3600
                let rate = hours > 0 ? (100 - used) / hours : nil
                let verdict: UsageForecast.Verdict
                if exhaustsAt <= now {
                    verdict = .exhausted
                } else if let resetsAt, resetsAt <= exhaustsAt {
                    verdict = .comfortable
                } else {
                    verdict = .runsOut(exhaustsAt: exhaustsAt)
                }
                return UsageForecast(window: window.name, usedPct: used, resetsAt: resetsAt, verdict: verdict, ratePctPerHour: rate, source: .daemon, pace: daemon.pace)
            }
            // A daemon answer with a pace but no date ("under": idle or
            // the reset wins) still counts as its verdict: the local fit
            // only ever runs when the daemon said nothing at all.
            if let pace = daemon.pace, pace == "under" || pace == "on" {
                return UsageForecast(window: window.name, usedPct: used, resetsAt: resetsAt,
                                     verdict: .comfortable, ratePctPerHour: daemon.ratePctPerHour,
                                     source: .daemon, pace: pace)
            }
            // `ahead`/`exhausted` with no date is a protocol anomaly:
            // honest unknown, never a locally fabricated date.
            if daemon.pace != nil {
                return UsageForecast(window: window.name, usedPct: used, resetsAt: resetsAt,
                                     verdict: .unknown, ratePctPerHour: daemon.ratePctPerHour,
                                     source: .daemon, pace: daemon.pace)
            }
        }
        guard let rate = rate(samples: samples, now: now) else {
            return UsageForecast(window: window.name, usedPct: used, resetsAt: resetsAt, verdict: .unknown, ratePctPerHour: nil, source: .none, pace: daemon?.pace)
        }
        if rate <= idleRate {
            return UsageForecast(window: window.name, usedPct: used, resetsAt: resetsAt, verdict: .comfortable, ratePctPerHour: rate, source: .local, pace: daemon?.pace)
        }
        let exhaustsAt = now + (100 - used) / rate * 3600
        if let resetsAt, resetsAt <= exhaustsAt {
            return UsageForecast(window: window.name, usedPct: used, resetsAt: resetsAt, verdict: .comfortable, ratePctPerHour: rate, source: .local, pace: daemon?.pace)
        }
        return UsageForecast(window: window.name, usedPct: used, resetsAt: resetsAt, verdict: .runsOut(exhaustsAt: exhaustsAt), ratePctPerHour: rate, source: .local, pace: daemon?.pace)
    }
}
