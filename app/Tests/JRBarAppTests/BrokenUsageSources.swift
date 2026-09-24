import Foundation
@testable import JRBarCore

/// The panel's broken-source readings, shared so every usage surface is
/// held to the same rule: the live check's stale Claude, 37 minutes past
/// its 5h reset and wanting "Reconnect Claude", and its stale Grok, an
/// hour past and wanting "Run grok login". Beside them, the readings
/// that keep today's words: a stale source with no fix, a healthy one
/// past its reset, and a healthy one with a reset still ahead.
enum BrokenUsageSources {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// One provider with a single 5h window, `resetsIn` seconds from `now`.
    static func provider(_ id: String, _ pct: Double?, state: String? = nil, fidelity: String? = nil,
                         resetsIn: Double? = 3 * 3600, forecast: CoreUsageForecast? = nil,
                         incident: String? = nil, action: String? = nil) -> CoreProviderUsage {
        let reset = resetsIn.map { now.timeIntervalSince1970 + $0 }
        return CoreProviderUsage(id: id, windows: [CoreUsageWindow(key: "5h", name: "5h", usedPct: pct, resetsAt: reset)],
                                 fidelity: fidelity, state: state, forecast: forecast, action: action, incident: incident)
    }

    static var claude: CoreProviderUsage {
        provider("claude", 19, state: "stale", resetsIn: -37 * 60, action: "Reconnect Claude")
    }

    static var grok: CoreProviderUsage {
        provider("grok", 31, state: "stale", resetsIn: -3600, action: "Run grok login")
    }

    /// Stale, and nothing to do about it: the next reading may yet come.
    static var staleWithoutFix: CoreProviderUsage { provider("gemini", 19, state: "stale", resetsIn: -60) }

    /// Healthy and past its reset: the daemon's next pass brings the new
    /// window, so waiting for it is true. A fix-it on a ready source is
    /// not a broken one.
    static var healthyPast: CoreProviderUsage { provider("codex", 40, state: "ready", resetsIn: -60, action: "Retry") }

    static var healthyAhead: CoreProviderUsage { provider("devin", 40, state: "ready", action: "Retry") }

    /// Each reading with what a surface says where its 5h countdown goes.
    static var resetWords: [(usage: CoreProviderUsage, words: String)] {
        [
            (claude, "Reconnect Claude"),
            (grok, "Run grok login"),
            (staleWithoutFix, "reset — waiting for a new reading"),
            (healthyPast, "reset — waiting for a new reading"),
            (healthyAhead, "resets in 3h 00m"),
        ]
    }
}
