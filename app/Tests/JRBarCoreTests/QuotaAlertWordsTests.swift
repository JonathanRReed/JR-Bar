import Foundation
import Testing
@testable import JRBarCore

@Suite("Quota alert words")
struct QuotaAlertWordsTests {
    static let now: Double = 1_800_000_000
    static let settings = SettingsDocument(.object(["quota_alerts_enabled": .bool(true)]))

    static func usage(resetsIn seconds: Double) -> CoreUsage {
        let five = CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 81, resetsAt: now + seconds)
        let week = CoreUsageWindow(key: "weekly", name: "7d", usedPct: 30, resetsAt: now + 3 * 86400)
        return CoreUsage(providers: [CoreProviderUsage(id: "claude", windows: [five, week])])
    }

    static func event(_ label: String?) -> CoreEvent {
        CoreEvent(id: "q", kind: "quota_crossed", label: label, notify: true, provider: "claude", detail: "80%")
    }

    @Test func theBannerNamesTheWindowTheAmountAndTheReset() {
        let state = CoreState(usage: Self.usage(resetsIn: 45 * 60))
        let banner = EventPolicy.delivery(for: Self.event("Claude five-hour"), state: state,
                                          settings: Self.settings, now: Self.now).notification
        #expect(banner?.title == "Claude 5-hour window: 80% used")
        #expect(banner?.body.hasPrefix("Resets in ") == true)
        #expect(banner?.body.hasSuffix(".") == true)
        #expect(banner?.body.contains("Claude") == false, "the body does not repeat the provider")
    }

    @Test func theWeeklyWindowIsMatchedByItsKey() {
        let words = QuotaAlertWords.crossed(Self.event("Claude weekly"), provider: "Claude",
                                            usage: Self.usage(resetsIn: 3600), now: Self.now)
        #expect(words.title == "Claude 7-day window: 80% used")
        #expect(words.body.hasPrefix("Resets "))
    }

    @Test func withoutALiveReadingTheBannerStillSaysWhatHappened() {
        let words = QuotaAlertWords.crossed(Self.event("Claude five-hour"), provider: "Claude", usage: nil, now: Self.now)
        #expect(words.title == "Claude usage: 80% used")
        #expect(words.body == "The Usage Center shows when it resets.")
    }
}
