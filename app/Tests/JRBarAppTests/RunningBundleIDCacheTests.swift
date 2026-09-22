import Foundation
import Testing
@testable import JRBarApp

@Suite("Running bundle-ID cache")
@MainActor
struct RunningBundleIDCacheTests {
    @Test("repeated reads cache an empty snapshot")
    func cachesEmptySnapshot() {
        var reads = 0
        let cache = RunningBundleIDCache(
            read: { reads += 1; return [] },
            monotonic: { 10 }
        )

        #expect(cache.snapshot().isEmpty)
        #expect(cache.snapshot().isEmpty)
        #expect(reads == 1)
    }

    @Test("the bounded fallback refreshes an expired snapshot")
    func refreshesAfterExpiry() {
        var now: TimeInterval = 10
        var reads = 0
        let cache = RunningBundleIDCache(
            refreshInterval: 15,
            read: { reads += 1; return ["app.\(reads)"] },
            monotonic: { now }
        )

        #expect(cache.snapshot() == ["app.1"])
        now = 24.999
        #expect(cache.snapshot() == ["app.1"])
        now = 25
        #expect(cache.snapshot() == ["app.2"])
    }

    @Test("explicit invalidation refreshes before expiry")
    func invalidationRefreshes() {
        var reads = 0
        let cache = RunningBundleIDCache(
            read: { reads += 1; return ["app.\(reads)"] },
            monotonic: { 10 }
        )

        #expect(cache.snapshot() == ["app.1"])
        cache.invalidate()
        #expect(cache.snapshot() == ["app.2"])
    }

    @Test("a monotonic clock rollback cannot extend a stale snapshot")
    func clockRollbackRefreshes() {
        var now: TimeInterval = 10
        var reads = 0
        let cache = RunningBundleIDCache(
            read: { reads += 1; return ["app.\(reads)"] },
            monotonic: { now }
        )

        #expect(cache.snapshot() == ["app.1"])
        now = 9
        #expect(cache.snapshot() == ["app.2"])
    }
}
