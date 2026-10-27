import Foundation

/// One plain line for a card whose window is nearly spent: another provider
/// the person uses has most of the same window left.
///
/// It states a fact and nothing more. It never suggests switching, never
/// acts, and never invents a lane: a provider counts only when the daemon
/// says it has a quota source, is signed in, and measured the same kind of
/// window (`5h` against `5h`, `7d` against `7d`). A reading the daemon marks
/// stale is used as the last good reading and says so.
public struct HeadroomElsewhere: Hashable, Sendable {
    /// The provider row that has the headroom (`identity`, so two accounts
    /// of one provider stay apart).
    public let identity: String
    public let providerID: String
    /// The shared window's short name: `5h`, `7d`, `Daily` or `Monthly`.
    public let window: String
    /// Whole percent left in that window, 0...100.
    public let remainingPercent: Int
    /// The reading is the last good one, not a fresh one.
    public let stale: Bool
    /// When that reading was taken, epoch seconds.
    public let readAt: Double?

    /// A window at or above this share spent is "nearly spent".
    public static let nearLimitUsedPercent: Double = 90
    /// Another provider counts as having plenty when at least this share of
    /// the same window is left.
    public static let plentyLeftPercent: Double = 50

    /// The window kinds two providers can honestly share. A credit balance,
    /// a CLI cap or a model's own cap is not comparable across providers.
    static let comparableWindows: Set<String> = ["5h", "7d", "Daily", "Monthly"]

    /// The best other provider for `provider`'s tightest window, or nil when
    /// the card is not nearly spent or nobody else has plenty left.
    public static func find(
        for provider: CoreProviderUsage,
        among providers: [CoreProviderUsage],
        now: Date
    ) -> HeadroomElsewhere? {
        guard let tight = nearLimitWindow(of: provider, now: now) else { return nil }
        var best: HeadroomElsewhere?
        for other in providers where other.id != provider.id {
            guard let candidate = headroom(of: other, window: tight, now: now) else { continue }
            guard let current = best else { best = candidate; continue }
            let moreLeft = candidate.remainingPercent > current.remainingPercent
            let tiedButFresher = candidate.remainingPercent == current.remainingPercent && current.stale && !candidate.stale
            if moreLeft || tiedButFresher { best = candidate }
        }
        return best
    }

    /// The short name of `provider`'s headline window when it is nearly
    /// spent, still open, and comparable.
    static func nearLimitWindow(of provider: CoreProviderUsage, now: Date) -> String? {
        guard countsAsReading(provider),
              let window = provider.headlineWindow,
              window.bindable, !window.detail,
              let used = window.usedPct, used >= nearLimitUsedPercent,
              isOpen(window, now: now),
              comparableWindows.contains(window.shortName)
        else { return nil }
        return window.shortName
    }

    private static func headroom(of provider: CoreProviderUsage, window name: String, now: Date) -> HeadroomElsewhere? {
        guard countsAsReading(provider) else { return nil }
        let lanes = provider.windows.filter {
            $0.bindable && !$0.detail && $0.shortName == name && $0.usedPct != nil && isOpen($0, now: now)
        }
        // The tightest lane of that kind is the honest one to quote.
        guard let lane = lanes.max(by: { ($0.usedPct ?? 0) < ($1.usedPct ?? 0) }), let used = lane.usedPct else { return nil }
        let left = 100 - used
        guard left >= plentyLeftPercent else { return nil }
        return HeadroomElsewhere(
            identity: provider.identity,
            providerID: provider.id,
            window: name,
            remainingPercent: Int(min(100, max(0, left)).rounded(.down)),
            stale: provider.isStale,
            readAt: provider.readingAt
        )
    }

    /// A provider whose numbers can be quoted: it has a quota source, is
    /// signed in, has not been switched off, and reported or kept a reading.
    private static func countsAsReading(_ provider: CoreProviderUsage) -> Bool {
        guard provider.quotaSource, !provider.isSignedOut, !provider.windows.isEmpty else { return false }
        switch provider.state?.lowercased() {
        case "ready", "stale", "ok": return true
        default: return false
        }
    }

    /// A window whose reset has passed describes a window that is over.
    private static func isOpen(_ window: CoreUsageWindow, now: Date) -> Bool {
        guard let reset = window.resetsAt else { return true }
        return reset > now.timeIntervalSince1970
    }

    /// The provider's used percentage, with the supplied age when stale.
    public func line(providerName: String, ago: String?) -> String {
        if stale {
            let age = ago.map { "stale, read \($0) ago" } ?? "stale"
            return "\(providerName) was at \(UsageNumber.percent(Double(100 - remainingPercent))) used in this \(window) window (\(age))."
        }
        return "\(providerName) is at \(UsageNumber.percent(Double(100 - remainingPercent))) used in this \(window) window."
    }
}
