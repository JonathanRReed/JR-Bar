import JRBarCore
import Testing
@testable import JRBarUI

@Suite("UI foundation")
struct FoundationComponentsTests {
    let now: Double = 1_800_000_000

    @Test func tokensMatchApprovedDefaults() {
        #expect(JRBarTokens.TypeStyle.allCases.map(\.size) == [26, 17, 13, 12, 11])
        #expect(JRBarTokens.Motion.allCases.map(\.duration) == [0.1, 0.14, 0.16, 0.25])
        #expect(ProviderPalette.hex(for: "Claude") == "#D97757")
        #expect(ProviderPalette.logoID(for: "codex") == "openai")
    }

    @Test func windowsKeepTheirOwnNumbersAndResetTimes() {
        let short = CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: now + 3600)
        let week = CoreUsageWindow(name: "7d", usedPct: 18, resetsAt: now + 86400)
        let provider = CoreProviderUsage(id: "claude", windows: [short, week], state: "ready")
        let a = UsageGaugeReading(window: short, provider: provider, now: now)
        let b = UsageGaugeReading(window: week, provider: provider, now: now)
        #expect(a.percentUsed == 42)
        #expect(b.percentUsed == 18)
        #expect(a.footnote == "Resets in 1h 0m")
        #expect(b.footnote == "Resets in 1d 0h")
    }

    @Test func expiredWindowSuppressesOldPercentEvenWhenSourceSaysReady() {
        let window = CoreUsageWindow(name: "5h", usedPct: 93, resetsAt: now)
        let provider = CoreProviderUsage(id: "claude", windows: [window], state: "ready")
        let reading = UsageGaugeReading(window: window, provider: provider, now: now)
        #expect(reading.percentUsed == nil)
        #expect(reading.elapsed)
        #expect(reading.footnote == "Reset <1m ago · awaiting reading")
    }

    @Test func staleUsesReadingAgeAndAvailability() {
        let window = CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: now + 3600)
        for availability in ["missing_recent", "source_idle", "failing"] {
            var provider = CoreProviderUsage(id: "claude", windows: [window], state: "ready",
                                             observedAt: now, readAt: now - 120)
            provider.availability = availability
            let reading = UsageGaugeReading(window: window, provider: provider, now: now)
            #expect(reading.stale)
            #expect(reading.percentUsed == 42)
            #expect(reading.footnote == "Read 2m ago · Resets in 1h 0m")
        }
    }

    @Test func absentAndNotFoundDoNotOfferOldNumbers() {
        let window = CoreUsageWindow(name: "7d", usedPct: 77)
        for availability in ["absent", "not_found"] {
            var provider = CoreProviderUsage(id: "claude", windows: [window])
            provider.availability = availability
            #expect(UsageGaugeReading(window: window, provider: provider, now: now).percentUsed == nil)
        }
    }
}
