import Foundation
import Testing
@testable import JRBarCore

@Suite("Usage forecast evidence")
struct UsageForecastEvidenceTests {
    static let now: Double = 1_800_000_000

    @Test("a passed reset keeps the number and pauses every prediction")
    func elapsedWindow() {
        for used in [42.0, 100.0] {
            let window = CoreUsageWindow(name: "5h", usedPct: used, resetsAt: Self.now)
            let forecast = UsageForecaster.forecast(window: window,
                daemon: CoreUsageForecast(exhaustsAt: Self.now + 600, pace: "ahead"),
                samples: [], now: Self.now)
            #expect(forecast.usedPct == used)
            #expect(forecast.verdict == .guarded(reason: "window_elapsed"))
            #expect(!forecast.isCritical)
            #expect(forecast.rateText == nil)
            #expect(forecast.projectedAtReset(now: Self.now) == nil)
            #expect(forecast.headline(now: Date(timeIntervalSince1970: Self.now)).contains("waiting for a new reading"))
        }
    }

    @Test("state pushes do not invent new samples for an unchanged reading")
    func readingClock() {
        var log = UsageSampleLog()
        let provider = CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(name: "5h", usedPct: 42)],
                                         state: "ready", observedAt: Self.now, readAt: Self.now - 600)
        let usage = CoreUsage(refreshedAt: Self.now, providers: [provider])
        log.record(usage, now: Self.now)
        log.record(usage, now: Self.now + 90)
        #expect(log.samples(provider: "claude", window: "5h") == [UsageSample(at: Self.now - 600, usedPct: 42)])
        var stale = usage
        stale.providers[0].state = "stale"
        stale.providers[0].readAt = Self.now + 90
        stale.providers[0].windows[0].usedPct = 55
        log.record(stale, now: Self.now + 90)
        #expect(log.samples(provider: "claude", window: "5h").count == 1)
    }

    @Test("future, invalid and duplicate observations cannot create a pace")
    func invalidSamples() {
        let valid = [UsageSample(at: Self.now - 600, usedPct: 10), UsageSample(at: Self.now, usedPct: 20)]
        let noisy = [UsageSample(at: .nan, usedPct: 80), UsageSample(at: Self.now + 600, usedPct: 90),
                     UsageSample(at: Self.now - 300, usedPct: .infinity), UsageSample(at: Self.now - 200, usedPct: -10)]
        #expect(UsageForecaster.rate(samples: Array(valid.reversed()) + noisy, now: Self.now) == 60)
        #expect(UsageForecaster.rate(samples: [valid[0], valid[0]], now: Self.now) == nil)
        var log = UsageSampleLog()
        for sample in noisy { log.record(provider: "claude", window: "5h", usedPct: sample.usedPct, at: sample.at) }
        #expect(log.samples(provider: "claude", window: "5h").count == 1)
    }

    @Test("a guarded rate cannot draw a projection or promise another agent")
    func guardedProjection() {
        var forecast = UsageForecast(window: "5h", usedPct: 42, resetsAt: Self.now + 3600,
                                     verdict: .guarded(reason: "stale_samples"), ratePctPerHour: 10, source: .daemon)
        forecast.workingAgents = 2
        #expect(forecast.projectedAtReset(now: Self.now) == nil)
        #expect(forecast.rateText == nil)
        #expect(SessionAwarePace.roomForOneMore(forecast, now: Self.now) == nil)
    }
    @Test("insufficient readings are not a paused connection",
          arguments: ["insufficient_samples", "insufficient_span"])
    func initialReadings(reason: String) {
        let forecast = UsageForecast(window: "7d", usedPct: 53, resetsAt: 2000,
            verdict: .guarded(reason: reason), ratePctPerHour: nil, source: .daemon)
        #expect(forecast.verdictWord() == "No pace yet")
        #expect(forecast.projectedAtReset(now: 1000) == nil)
    }

    @Test("stale and disconnected forecasts remain paused",
          arguments: ["stale_samples", "monitor_offline", "clock_regressed"])
    func pausedReadings(reason: String) {
        let forecast = UsageForecast(window: "7d", usedPct: 53, resetsAt: 2000,
            verdict: .guarded(reason: reason), ratePctPerHour: nil, source: .none)
        #expect(forecast.verdictWord() == "Paused")
    }

}
