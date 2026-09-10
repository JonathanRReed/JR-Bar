import Foundation
import Testing
@testable import JRBarCore

/// A window the provider reports **without a number** (`used_pct: null`) is
/// not a window at zero. Decoding it as `0` drew a full green bar and said
/// "plenty left" about a balance nobody had measured, which is a confident
/// lie -- the one thing a quota display must never be.
@Suite("A usage window with no reading")
struct UnknownUsageWindowTests {
    static let now: Double = 1_788_982_892
    static let utc = TimeZone(identifier: "UTC")!

    static func window(_ json: String) throws -> CoreUsageWindow {
        try JSONDecoder().decode(CoreUsageWindow.self, from: Data(json.utf8))
    }

    @Test("used_pct null decodes as unknown, not as zero")
    func decodesAsUnknown() throws {
        let unknown = try Self.window(#"{"name":"7d","used_pct":null,"resets_at":1789300000.0}"#)
        #expect(unknown.usedPct == nil)
        #expect(unknown.isUnknown)
        // The window is still there, and so is everything else it knows.
        #expect(unknown.name == "7d")
        #expect(unknown.resetsAt == 1789300000.0)

        // A key that never arrived is no more a reading than an explicit null.
        #expect(try Self.window(#"{"name":"7d"}"#).usedPct == nil)
        // Nor is a malformed one: a string or a NaN is not the provider
        // saying "zero", and it must not take the whole document down.
        #expect(try Self.window(#"{"name":"7d","used_pct":"lots"}"#).usedPct == nil)
        #expect(try Self.window(#"{"name":"7d","used_pct":true}"#).usedPct == nil)

        // A real zero is a reading and stays one.
        let zero = try Self.window(#"{"name":"5h","used_pct":0}"#)
        #expect(zero.usedPct == 0)
        #expect(!zero.isUnknown)
    }

    @Test("unknown reads as unknown everywhere it is printed or spoken")
    func rendersAsUnknown() throws {
        let unknown = try Self.window(#"{"name":"7d","used_pct":null}"#)
        #expect(unknown.percentText == "—")
        #expect(unknown.spokenPercent == "no reading")
        // Never a number, never blank: a blank column reads as calm.
        #expect(unknown.percentText != "0%")
        #expect(!unknown.percentText.isEmpty)

        let measured = try Self.window(#"{"name":"5h","used_pct":42.4}"#)
        #expect(measured.percentText == "42%")
        #expect(measured.spokenPercent == "42 percent used")
        #expect(UsageWindowLabel.percent(nil) == UsageWindowLabel.unknownPercent)
        #expect(UsageWindowLabel.spoken(0) == "0 percent used")
    }

    @Test("the forecast says there is no reading rather than promising room")
    func forecastIsUnmeasured() throws {
        let unknown = try Self.window(#"{"name":"7d","used_pct":null,"resets_at":\#(Self.now + 3600)}"#)
        let forecast = UsageForecaster.forecast(window: unknown, daemon: nil, samples: [], now: Self.now)
        #expect(forecast.verdict == .unmeasured)
        #expect(forecast.usedPct == nil)
        // No "100 % left", which is what `remainingPct` would have said.
        #expect(forecast.remainingPct == nil)
        #expect(!forecast.isCritical)
        #expect(forecast.rateText == nil)
        let line = forecast.headline(now: Date(timeIntervalSince1970: Self.now), timeZone: Self.utc)
        #expect(line == "No reading for the 7d window · resets in 1h 00m")
        #expect(!line.contains("Comfortable"))
        #expect(!line.contains("left"))

        // Even a daemon forecast cannot conjure a balance out of no reading.
        let withDaemon = UsageForecaster.forecast(window: unknown,
                                                 daemon: CoreUsageForecast(exhaustsAt: Self.now + 600, pace: "ahead"),
                                                 samples: [UsageSample(at: Self.now - 600, usedPct: 10),
                                                           UsageSample(at: Self.now, usedPct: 40)],
                                                 now: Self.now)
        #expect(withDaemon.verdict == .unmeasured)
        #expect(withDaemon.usedPct == nil)

        let noReset = try Self.window(#"{"name":"Credits","used_pct":null}"#)
        #expect(UsageForecaster.forecast(window: noReset, daemon: nil, samples: [], now: Self.now)
            .headline(now: Date(timeIntervalSince1970: Self.now), timeZone: Self.utc) == "No reading for the Credits window")
    }

    @Test("an unmeasured window feeds no sample into the pace")
    func neverSampled() throws {
        var log = UsageSampleLog()
        let usage = CoreUsage(refreshedAt: nil, providers: [
            CoreProviderUsage(id: "codex", windows: [
                CoreUsageWindow(name: "5h", usedPct: 12.5),
                CoreUsageWindow(name: "7d", usedPct: nil),
            ]),
        ])
        log.record(usage, now: Self.now)
        log.record(usage, now: Self.now + 600)
        #expect(log.samples(provider: "codex", window: "5h").count == 2)
        // A zero here would have dragged the 7d pace toward "nothing burning".
        #expect(log.samples(provider: "codex", window: "7d").isEmpty)
    }
}
