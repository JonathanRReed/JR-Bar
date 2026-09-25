import Foundation
import Testing
@testable import JRBarApp

/// The prune's installed-app answers: a found app is kept for a while,
/// a missing one is asked every time.
@Suite("Installed bundle cache")
@MainActor
struct InstalledBundleCacheTests {
    @Test("a found app is not asked again until its answer ages")
    func foundIsCached() {
        var now: TimeInterval = 100
        var asked: [String] = []
        let cache = InstalledBundleCache(ttl: 600, lookUp: { asked.append($0); return true },
                                         monotonic: { now })
        #expect(cache.isInstalled("io.example.app"))
        #expect(cache.isInstalled("io.example.app"))
        #expect(asked == ["io.example.app"])
        now = 699.9
        #expect(cache.isInstalled("io.example.app"))
        #expect(asked.count == 1)
        now = 700
        #expect(cache.isInstalled("io.example.app"))
        #expect(asked.count == 2, "an aged answer is asked again")
    }

    @Test("a missing app is asked every time, so an install shows at once")
    func missingIsAskedAgain() {
        var installed = false
        var asks = 0
        let cache = InstalledBundleCache(lookUp: { _ in asks += 1; return installed }, monotonic: { 5 })
        #expect(!cache.isInstalled("io.example.later"))
        #expect(!cache.isInstalled("io.example.later"))
        installed = true
        #expect(cache.isInstalled("io.example.later"))
        #expect(asks == 3)
    }
}
