import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The Usage Center card's "read ... ago" counts from when the numbers were
/// read, not from the daemon's last attempt: a stale reading kept through
/// failed polls must not say it was read a minute ago.
@Suite("Usage reading age")
struct UsageReadingAgeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(observedAgo: Double?, readAgo: Double?, state: String = "stale") -> CoreProviderUsage {
        let stamp = now.timeIntervalSince1970
        return CoreProviderUsage(id: "claude", state: state,
                                 observedAt: observedAgo.map { stamp - $0 },
                                 readAt: readAgo.map { stamp - $0 })
    }

    @Test("a stale card whose poll failed a minute ago still says its numbers are five hours old")
    func staleNamesTheReadingsAge() {
        let stale = row(observedAgo: 60, readAgo: 5 * 3600)
        #expect(ProviderUsageCard.readingAgeText(stale, now: now) == "read 5h 00m ago")
    }

    @Test("a live card reads from its own time")
    func liveNamesTheAttempt() {
        let live = row(observedAgo: 90, readAgo: nil, state: "ready")
        #expect(ProviderUsageCard.readingAgeText(live, now: now) == "read 1m ago")
        let sameTime = row(observedAgo: 90, readAgo: 90, state: "ready")
        #expect(ProviderUsageCard.readingAgeText(sameTime, now: now) == "read 1m ago")
    }

    @Test("a daemon that does not send read_at keeps the caption it always had")
    func olderDaemon() {
        let old = row(observedAgo: 2 * 86_400 + 3 * 3600, readAgo: nil)
        #expect(ProviderUsageCard.readingAgeText(old, now: now) == "read 2d 3h ago")
    }

    @Test("with no time at all there is no caption")
    func noTime() {
        #expect(ProviderUsageCard.readingAgeText(row(observedAgo: nil, readAgo: nil), now: now) == nil)
    }
}
