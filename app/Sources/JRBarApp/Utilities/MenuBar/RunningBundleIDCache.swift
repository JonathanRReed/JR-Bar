import Foundation

/// A short-lived snapshot of the running-app universe used by menu-bar
/// concealment. Workspace notifications invalidate it promptly; the bounded
/// fallback refresh still discovers helpers that do not produce one.
@MainActor
final class RunningBundleIDCache {
    static let fallbackRefreshInterval: TimeInterval = 15

    private let refreshInterval: TimeInterval
    private let read: @MainActor () -> Set<String>
    private let monotonic: () -> TimeInterval
    private var cached: Set<String>?
    private var refreshedAt: TimeInterval?

    init(
        refreshInterval: TimeInterval = fallbackRefreshInterval,
        read: @escaping @MainActor () -> Set<String>,
        monotonic: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.refreshInterval = max(0, refreshInterval)
        self.read = read
        self.monotonic = monotonic
    }

    func snapshot() -> Set<String> {
        let now = monotonic()
        if let cached, let refreshedAt,
           now.isFinite, refreshedAt.isFinite,
           now >= refreshedAt, now - refreshedAt < refreshInterval {
            return cached
        }
        let value = read()
        cached = value
        refreshedAt = now.isFinite ? now : nil
        return value
    }

    func invalidate() {
        cached = nil
        refreshedAt = nil
    }
}
