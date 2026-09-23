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
    /// `SessionAwarePace` found no agent of this provider working here:
    /// the measured rate is history, and the window holds where it is
    /// until one starts. The verdict was softened from `runsOut`.
    public var heldIdle = false
    /// How many of this provider's agents are working here, when a
    /// surface told `SessionAwarePace`; nil when nobody counted.
    public var workingAgents: Int?

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
            if heldIdle {
                return "Holding at \(left) % left: no agent is working on it here"
            }
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

// MARK: - Where the window lands, in words

extension UsageForecast {
    /// Where the window will stand when it resets if the current rate
    /// holds, in percent — past 100 when it would run out first. Nil
    /// without a reading, a rate, or a reset ahead; a window already used
    /// up stands where it is. The Usage Center's rings draw it as a ghost
    /// arc ahead of the used one.
    public func projectedAtReset(now: Double) -> Double? {
        guard let used = usedPct, let resetsAt, resetsAt > now else { return nil }
        if verdict == .exhausted { return used }
        if heldIdle { return used }
        guard let rate = ratePctPerHour, rate > UsageForecaster.idleRate else { return nil }
        return used + rate * (resetsAt - now) / 3600
    }

    /// The verdict as one or two words for a chip: "Used up", "Runs out
    /// 16:42", "Resets first", "Holding", "No pace yet", "Paused", "No
    /// reading" — the same facts `headline` spells out.
    public func verdictWord(timeZone: TimeZone = .current) -> String {
        switch verdict {
        case .exhausted: return "Used up"
        case .runsOut(let at): return "Runs out \(Self.clock(at, timeZone: timeZone))"
        case .comfortable:
            if heldIdle { return "Holding" }
            if let rate = ratePctPerHour, rate <= UsageForecaster.idleRate { return "Not burning" }
            return resetsAt != nil ? "Resets first" : "Comfortable"
        case .unknown: return "No pace yet"
        case .guarded: return "Paused"
        case .unmeasured: return "No reading"
        }
    }
}

/// Pace that knows what is running. A line through percentages alone
/// keeps projecting the last slope while every agent sits idle, and has
/// no idea three more just started; JR-Bar sees the sessions, so it can
/// say both. The count is this Mac's working sessions of the provider —
/// quota spent elsewhere (a chat in the browser, another Mac) is not in
/// it, which is why an idle hold is worded "here".
public enum SessionAwarePace {
    /// With nothing working, a `runsOut` verdict is history rather than a
    /// forecast: the window holds where it is until an agent starts. Any
    /// other verdict passes through, stamped with the count.
    public static func adjust(_ forecast: UsageForecast, working: Int) -> UsageForecast {
        var adjusted = forecast
        adjusted.workingAgents = working
        if working == 0, case .runsOut = forecast.verdict {
            adjusted.verdict = .comfortable
            adjusted.heldIdle = true
        }
        return adjusted
    }

    /// Would one more agent, burning what each working one burns now, run
    /// the window out before it resets? Nil when there is nothing to
    /// divide (no agent working, no rate, no reset, no reading).
    public static func roomForOneMore(_ forecast: UsageForecast, now: Double) -> Bool? {
        guard let working = forecast.workingAgents, working > 0,
              let used = forecast.usedPct, used < 99.95,
              let rate = forecast.ratePctPerHour, rate > UsageForecaster.idleRate,
              let resetsAt = forecast.resetsAt, resetsAt > now else { return nil }
        let withOneMore = rate / Double(working) * Double(working + 1)
        let exhaustsAt = now + (100 - used) / withOneMore * 3600
        return exhaustsAt >= resetsAt
    }

    /// "room for one more" / "one more would run it out" — for a tooltip
    /// or the Usage Center's source line.
    public static func roomText(_ forecast: UsageForecast, now: Double) -> String? {
        switch roomForOneMore(forecast, now: now) {
        case true?: return "room for one more agent"
        case false?: return "one more agent would run it out before the reset"
        case nil: return nil
        }
    }
}
