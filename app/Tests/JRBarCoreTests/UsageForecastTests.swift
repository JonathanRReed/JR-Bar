import Foundation
import Testing
@testable import JRBarCore

@Suite("Usage forecast")
struct UsageForecastTests {
    static let now: Double = 1_788_982_892
    static let utc = TimeZone(identifier: "UTC")!

    static func samples(_ points: [(minutesAgo: Double, pct: Double)]) -> [UsageSample] {
        points.map { UsageSample(at: now - $0.minutesAgo * 60, usedPct: $0.pct) }
    }

    @Test("zero pace: nothing burning, the reading says so")
    func zeroPace() {
        let window = CoreUsageWindow(name: "5h", usedPct: 39, resetsAt: Self.now + 2 * 3600)
        let flat = Self.samples([(40, 39), (30, 39), (20, 39), (10, 39), (0, 39)])
        let forecast = UsageForecaster.forecast(window: window, daemon: nil, samples: flat, now: Self.now)
        #expect(forecast.verdict == .comfortable)
        #expect(forecast.source == .local)
        #expect(forecast.ratePctPerHour == 0)
        #expect(forecast.rateText == nil)
        #expect(forecast.headline(now: Date(timeIntervalSince1970: Self.now), timeZone: Self.utc) == "Comfortable: 61 % left, nothing burning right now")
        #expect(!forecast.isCritical)
    }

    @Test("exhausted: 100 % used regardless of pace")
    func exhausted() {
        let window = CoreUsageWindow(name: "5h", usedPct: 100, resetsAt: Self.now + 75 * 60)
        let forecast = UsageForecaster.forecast(window: window, daemon: CoreUsageForecast(exhaustsAt: Self.now - 60, pace: "ahead"), samples: [], now: Self.now)
        #expect(forecast.verdict == .exhausted)
        #expect(forecast.isCritical)
        #expect(forecast.remainingPct == 0)
        #expect(forecast.pace == "ahead")
        #expect(forecast.headline(now: Date(timeIntervalSince1970: Self.now), timeZone: Self.utc) == "Used up: the 5h window resets in 1h 15m")
    }

    @Test("runs out before the reset: local linear extrapolation")
    func runsOutLocally() {
        // 20 % → 60 % over 40 minutes: 60 %/h; 40 % left → 40 minutes.
        let window = CoreUsageWindow(name: "5h", usedPct: 60, resetsAt: Self.now + 3 * 3600)
        let climbing = Self.samples([(40, 20), (30, 30), (20, 40), (10, 50), (0, 60)])
        let forecast = UsageForecaster.forecast(window: window, daemon: nil, samples: climbing, now: Self.now)
        guard case .runsOut(let at) = forecast.verdict else {
            Issue.record("expected runsOut, got \(forecast.verdict)"); return
        }
        #expect(abs(at - (Self.now + 40 * 60)) < 5)
        #expect(abs((forecast.ratePctPerHour ?? 0) - 60) < 0.01)
        #expect(forecast.rateText == "60 %/h")
        #expect(forecast.source == .local)
        #expect(forecast.isCritical)
        let headline = forecast.headline(now: Date(timeIntervalSince1970: Self.now), timeZone: Self.utc)
        #expect(headline.hasPrefix("At this pace the 5h window runs out at "))
        #expect(headline.hasSuffix("(in 40m)"))
    }

    @Test("reset before exhaustion is comfortable even at a real pace")
    func resetFirst() {
        let window = CoreUsageWindow(name: "5h", usedPct: 60, resetsAt: Self.now + 20 * 60)
        let climbing = Self.samples([(40, 20), (30, 30), (20, 40), (10, 50), (0, 60)])
        let forecast = UsageForecaster.forecast(window: window, daemon: nil, samples: climbing, now: Self.now)
        #expect(forecast.verdict == .comfortable)
        #expect(forecast.headline(now: Date(timeIntervalSince1970: Self.now), timeZone: Self.utc) == "Comfortable: 40 % left, resets before you'd hit it")
    }

    @Test("the daemon's forecast wins over the samples")
    func daemonWins() {
        let window = CoreUsageWindow(name: "5h", usedPct: 91, resetsAt: Self.now + 2 * 3600)
        let flat = Self.samples([(40, 91), (0, 91)])
        let daemon = CoreUsageForecast(exhaustsAt: Self.now + 38 * 60, pace: "ahead")
        let forecast = UsageForecaster.forecast(window: window, daemon: daemon, samples: flat, now: Self.now)
        #expect(forecast.source == .daemon)
        #expect(forecast.pace == "ahead")
        guard case .runsOut(let at) = forecast.verdict else {
            Issue.record("expected runsOut, got \(forecast.verdict)"); return
        }
        #expect(at == Self.now + 38 * 60)
        #expect(abs((forecast.ratePctPerHour ?? 0) - 9 / (38.0 / 60)) < 0.01)
    }

    @Test("too few samples: no pace yet")
    func unknown() {
        let window = CoreUsageWindow(name: "7d", usedPct: 61, resetsAt: nil)
        let one = Self.samples([(0, 61)])
        let forecast = UsageForecaster.forecast(window: window, daemon: nil, samples: one, now: Self.now)
        #expect(forecast.verdict == .unknown)
        #expect(forecast.source == UsageForecast.Source.none)
        #expect(forecast.headline(now: Date(timeIntervalSince1970: Self.now), timeZone: Self.utc) == "39 % left · no pace yet")
        // Two samples less than a minute apart are not a pace either.
        let close = Self.samples([(0.5, 60), (0, 61)])
        #expect(UsageForecaster.rate(samples: close, now: Self.now) == nil)
    }

    @Test("a reset inside the lookback restarts the fit")
    func resetRestartsFit() {
        // Climbing, then a drop to 5 %, then climbing again at 30 %/h.
        let samples = Self.samples([(40, 80), (30, 90), (20, 5), (10, 10), (0, 15)])
        let rate = UsageForecaster.rate(samples: samples, now: Self.now)
        #expect(abs((rate ?? 0) - 30) < 0.01)
    }

    @Test("the sample log dedupes quiet stretches and keeps order")
    func sampleLog() {
        var log = UsageSampleLog()
        let usage = CoreUsage(refreshedAt: nil, providers: [
            CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(name: "5h", usedPct: 42), CoreUsageWindow(name: "7d", usedPct: 61)]),
        ])
        log.record(usage, now: Self.now)
        log.record(usage, now: Self.now + 5)          // same value, too soon: dropped
        log.record(usage, now: Self.now + 40)         // same value, spaced out: kept
        log.record(usage, now: Self.now - 100)        // out of order: dropped
        var moved = usage
        moved.providers[0].windows[0].usedPct = 43
        log.record(moved, now: Self.now + 41)         // moved: kept at once
        #expect(log.samples(provider: "claude", window: "5h").map(\.usedPct) == [42, 42, 43])
        #expect(log.samples(provider: "claude", window: "7D").count == 2)
        #expect(log.samples(provider: "codex", window: "5h").isEmpty)
        #expect(!log.isEmpty)
        for i in 0..<(UsageSampleLog.limit + 10) {
            log.record(provider: "codex", window: "5h", usedPct: Double(i % 100), at: Self.now + Double(i) * 31)
        }
        #expect(log.samples(provider: "codex", window: "5h").count == UsageSampleLog.limit)
    }

    @Test("degenerate samples: same instant, falling, or stale never yield a pace")
    func degenerate() {
        let window = CoreUsageWindow(name: "5h", usedPct: 50, resetsAt: Self.now + 3600)
        // Every sample at the same instant: zero spread, no slope.
        let same = [UsageSample(at: Self.now, usedPct: 10), UsageSample(at: Self.now, usedPct: 20), UsageSample(at: Self.now, usedPct: 30)]
        #expect(UsageForecaster.rate(samples: same, now: Self.now) == nil)
        // Steadily falling (a window draining as its lane resets) is a zero pace, never negative.
        let falling = Self.samples([(30, 60), (20, 59.5), (10, 59.2), (0, 59)])
        #expect(UsageForecaster.rate(samples: falling, now: Self.now) == 0)
        #expect(UsageForecaster.forecast(window: window, daemon: nil, samples: falling, now: Self.now).verdict == .comfortable)
        // Samples older than the lookback do not count, even when there are many.
        let stale = Self.samples([(200, 10), (150, 30), (100, 50), (60, 70)])
        #expect(UsageForecaster.rate(samples: stale, now: Self.now) == nil)
        #expect(UsageForecaster.forecast(window: window, daemon: nil, samples: stale, now: Self.now).verdict == .unknown)
        // A daemon forecast with no exhaustion time and no samples still carries its pace word.
        let paceOnly = UsageForecaster.forecast(window: window, daemon: CoreUsageForecast(exhaustsAt: nil, pace: "behind"), samples: [], now: Self.now)
        #expect(paceOnly.verdict == .unknown)
        #expect(paceOnly.pace == "behind")
        // 99.96 % counts as exhausted; 99.9 % does not.
        let nearly = CoreUsageWindow(name: "5h", usedPct: 99.96, resetsAt: nil)
        #expect(UsageForecaster.forecast(window: nearly, daemon: nil, samples: [], now: Self.now).verdict == .exhausted)
        #expect(UsageForecaster.forecast(window: nearly, daemon: nil, samples: [], now: Self.now).headline(now: Date(timeIntervalSince1970: Self.now), timeZone: Self.utc) == "Used up: the 5h window is exhausted")
        let almost = CoreUsageWindow(name: "5h", usedPct: 99.9, resetsAt: nil)
        #expect(UsageForecaster.forecast(window: almost, daemon: nil, samples: [], now: Self.now).verdict == .unknown)
        // A daemon exhaustion in the past is "used up" even below 100 %.
        let past = UsageForecaster.forecast(window: window, daemon: CoreUsageForecast(exhaustsAt: Self.now - 1, pace: nil), samples: [], now: Self.now)
        #expect(past.verdict == .exhausted)
        #expect(past.source == .daemon)
    }

    @Test("relative and clock formatting")
    func formatting() {
        let now = Date(timeIntervalSince1970: Self.now)
        #expect(UsageForecast.relative(to: Self.now + 10, now: now) == "now")
        #expect(UsageForecast.relative(to: Self.now + 4 * 60, now: now) == "in 4m")
        #expect(UsageForecast.relative(to: Self.now + 72 * 60, now: now) == "in 1h 12m")
        #expect(UsageForecast.relative(to: Self.now + 30 * 3600, now: now) == "in 1d 6h")
        #expect(UsageForecast.clock(Self.now, timeZone: Self.utc) == "19:41")
    }
}
