import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Usage reset budget")
struct UsageResetBudgetTests {
    let now: Double = 1_800_000_000

    private func forecast(used: Double? = 72, resetIn: Double? = 4 * 3600,
                          rate: Double? = 9, verdict: UsageForecast.Verdict = .comfortable,
                          source: UsageForecast.Source = .local) -> UsageForecast {
        UsageForecast(window: "5h", usedPct: used, resetsAt: resetIn.map { now + $0 },
                      verdict: verdict, ratePctPerHour: rate, source: source)
    }

    private func budget(_ forecast: UsageForecast, provider: CoreProviderUsage = CoreProviderUsage(id: "claude"),
                        window: CoreUsageWindow = CoreUsageWindow(name: "5h", usedPct: 72),
                        live: Bool = true) -> UsageResetBudget? {
        UsageResetBudget.make(provider: provider, window: window, forecast: forecast, isLive: live, now: now)
    }

    @Test("rate comparison uses the quota left and time to its reset")
    func quotaBudget() throws {
        let result = try #require(budget(forecast()))
        #expect(result.recentRate == 9)
        #expect(result.rateToReset == 7)
        #expect(result.exceedsBudget)
        #expect(result.recentText == "≈ 9.0 %/h")
        #expect(result.budgetText == "≤ 7.0 %/h")
        #expect(budget(forecast(rate: 4))?.exceedsBudget == false)
        #expect(budget(forecast(rate: 7))?.exceedsBudget == false)
    }

    @Test("the displayed limit never rounds up")
    func roundsLimitDown() throws {
        let result = try #require(budget(forecast(used: 72.1)))
        #expect(result.budgetText == "≤ 6.9 %/h")
        let small = try #require(budget(forecast(used: 99.8, resetIn: 7 * 86400)))
        #expect(small.budgetText == "≤ 0.001 %/h")
        #expect(UsageResetBudget(recentRate: 1, rateToReset: 0.0000099).budgetText == "≤ 0.000009 %/h")
        #expect(budget(forecast(used: 99.999999, resetIn: 7 * 86400)) == nil)
    }

    @Test("reported pace wins over a moving exhaustion countdown")
    func reportedRate() throws {
        let provider = CoreProviderUsage(id: "claude", forecast: CoreUsageForecast(exhaustsAt: now + 3600, pace: "ahead", ratePctPerHour: 4), readAt: now)
        let result = try #require(budget(forecast(rate: 28, source: .daemon), provider: provider))
        #expect(result.recentRate == 4)
        #expect(!result.exceedsBudget)
        let own = CoreUsageWindow(name: "5h", usedPct: 72, forecast: CoreUsageForecast(pace: "under", ratePctPerHour: 8))
        #expect(budget(forecast(source: .daemon), provider: provider, window: own)?.recentRate == 8)
    }

    @Test("legacy exhaustion projections use the reading clock and stay fixed between readings")
    func anchoredProjectionRate() throws {
        let window = CoreUsageWindow(name: "5h", usedPct: 72, resetsAt: now + 6 * 3600)
        let daemon = CoreUsageForecast(exhaustsAt: now + 4 * 3600, pace: "under")
        let provider = CoreProviderUsage(id: "claude", forecast: daemon, observedAt: now + 3600, readAt: now)
        let firstForecast = UsageForecaster.forecast(window: window, daemon: daemon, samples: [], now: now)
        let laterForecast = UsageForecaster.forecast(window: window, daemon: daemon, samples: [], now: now + 3600)
        let first = try #require(UsageResetBudget.make(provider: provider, window: window, forecast: firstForecast, isLive: true, now: now))
        let later = try #require(UsageResetBudget.make(provider: provider, window: window, forecast: laterForecast, isLive: true, now: now + 3600))
        #expect(first.recentRate == 7)
        #expect(later.recentRate == first.recentRate)
        let oldDaemon = CoreProviderUsage(id: "claude", forecast: daemon, observedAt: now)
        #expect(UsageResetBudget.make(provider: oldDaemon, window: window, forecast: laterForecast, isLive: true, now: now + 3600)?.recentRate == 7)
    }

    @Test("an unanchored or invalid daemon projection cannot supply a recent pace")
    func missingProjectionEvidence() {
        let fixtureForecast = forecast(source: .daemon)
        let daemon = CoreUsageForecast(exhaustsAt: now + 3600, pace: "ahead")
        #expect(budget(fixtureForecast, provider: CoreProviderUsage(id: "claude", forecast: daemon)) == nil)
        for at in [0, -1, now + 60, Double.nan, Double.infinity] {
            #expect(budget(fixtureForecast, provider: CoreProviderUsage(id: "claude", forecast: daemon, readAt: at)) == nil)
            let reported = CoreUsageForecast(exhaustsAt: now + 3600, pace: "ahead", ratePctPerHour: 9)
            #expect(budget(fixtureForecast, provider: CoreProviderUsage(id: "claude", forecast: reported, readAt: at)) == nil)
        }
        let invalid = CoreProviderUsage(id: "claude", forecast: CoreUsageForecast(exhaustsAt: now - 60, pace: "ahead"), readAt: now)
        #expect(budget(fixtureForecast, provider: invalid) == nil)
        let invalidReported = CoreProviderUsage(id: "claude", forecast: CoreUsageForecast(exhaustsAt: now + 3600, pace: "ahead", ratePctPerHour: .nan), readAt: now)
        #expect(budget(fixtureForecast, provider: invalidReported) == nil)
    }

    @Test("paused, unknown, used up and idle forecasts have no budget comparison")
    func unsupportedForecasts() {
        let verdicts: [UsageForecast.Verdict] = [.guarded(reason: "insufficient_span"), .unknown, .unmeasured, .exhausted]
        for verdict in verdicts {
            #expect(budget(forecast(verdict: verdict)) == nil)
        }
        var idle = forecast()
        idle.heldIdle = true
        #expect(budget(idle) == nil)
        #expect(budget(forecast(source: .none)) == nil)
        #expect(budget(forecast(rate: 0)) == nil)
        #expect(budget(forecast(rate: nil)) == nil)
    }

    @Test("offline and stale quota readings do not offer a current spending limit")
    func staleAndOffline() {
        #expect(budget(forecast(), live: false) == nil)
        #expect(budget(forecast(), provider: CoreProviderUsage(id: "claude", fidelity: "stale", state: "stale")) == nil)
        #expect(budget(forecast(), provider: CoreProviderUsage(id: "claude", state: "disabled")) == nil)
        #expect(budget(forecast(), provider: CoreProviderUsage(id: "claude", state: "signed_out")) == nil)
    }

    @Test("missing, invalid and elapsed measurements never become numbers")
    func invalidInputs() {
        let usedValues: [Double?] = [nil, -.infinity, .nan, -1, 100, 101]
        for used in usedValues {
            #expect(budget(forecast(used: used)) == nil)
        }
        let resetValues: [Double?] = [nil, -1, 0, .infinity, .nan]
        for reset in resetValues {
            #expect(budget(forecast(resetIn: reset)) == nil)
        }
        let rateValues: [Double?] = [nil, -1, .infinity, .nan]
        for rate in rateValues {
            #expect(budget(forecast(rate: rate)) == nil)
        }
        let reference = CoreUsageWindow(name: "5h", usedPct: 72, bindable: false)
        #expect(budget(forecast(), window: reference) == nil)
        var detail = CoreUsageWindow(name: "Monthly", usedPct: 72)
        detail.detail = true
        #expect(budget(forecast(), window: detail) == nil)
        #expect(UsageResetBudget.make(provider: CoreProviderUsage(id: "claude"), window: detail,
                                     forecast: forecast(), isLive: true, now: .infinity) == nil)
    }
}
