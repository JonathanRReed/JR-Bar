import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Usage window inspection")
struct UsageWindowInspectionTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func inspect(_ window: CoreUsageWindow, provider: CoreProviderUsage? = nil,
                         live: Bool = true) -> UsageWindowInspection {
        let provider = provider ?? CoreProviderUsage(id: "claude", windows: [window], fidelity: "official",
                                                     state: "ready", readAt: now.timeIntervalSince1970 - 60)
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-inspection-tests.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(sessions: [CoreSession(id: "fixture", provider: provider.id, mode: "working")],
                                   usage: CoreUsage(providers: [provider]))))
        if !live { core.handle(.disconnected(reason: "Fixture disconnect")) }
        let forecast = UsageCenterStore.forecast(for: provider, window: window, core: core, now: now)
        return UsageWindowInspection(provider: provider, window: window, forecast: forecast, isLive: live, now: now)
    }

    @Test("each window explains its own forecast and sample evidence")
    func perWindowForecast() {
        let fiveHour = CoreUsageWindow(name: "5h", usedPct: 20, resetsAt: now.timeIntervalSince1970 + 3600,
                                       forecast: CoreUsageForecast(pace: "under", samples: 30, ratePctPerHour: 1))
        let weekly = CoreUsageWindow(name: "7d", usedPct: 53, resetsAt: now.timeIntervalSince1970 + 86400,
                                     forecast: CoreUsageForecast(pace: "guarded", reason: "insufficient_span", samples: 2))
        let provider = CoreProviderUsage(id: "claude", windows: [fiveHour, weekly], fidelity: "official", state: "ready")
        let primary = inspect(fiveHour, provider: provider)
        let secondary = inspect(weekly, provider: provider)
        #expect(primary.verdictText == "Resets first")
        #expect(primary.forecastEvidence == "Monitor forecast · 30 quota readings")
        #expect(secondary.amountText == "53% used")
        #expect(secondary.verdictText == "No pace yet")
        #expect(secondary.explanation.contains("pace needs about 30 min of readings"))
        #expect(secondary.forecastEvidence == "Monitor forecast · 2 quota readings")
        #expect(UsageCenterStore.featuredWindow(of: provider)?.id == weekly.id)
    }

    @Test("Argon inspection names its own pool and keeps its weekly reading")
    func argonPoolEvidence() {
        let window = CoreUsageWindow(key: "gemini-argon-weekly", name: "Gemini 4 Argon Weekly",
                                     usedPct: 64, resetsAt: now.timeIntervalSince1970 + 432000,
                                     forecast: CoreUsageForecast(pace: "guarded", reason: "insufficient_samples", samples: 1))
        let provider = CoreProviderUsage(id: "antigravity", windows: [window], fidelity: "official", state: "ready")
        let result = inspect(window, provider: provider)
        #expect(result.inspectLabel == "Inspect Gemini 4 Argon Weekly window, 64 percent used")
        #expect(result.amountText == "64% used")
        #expect(result.resetText == "resets in 5d 0h")
        #expect(result.forecastEvidence == "Monitor forecast · 1 quota reading")
    }

    @Test("a secondary window never borrows the primary's sample count")
    func noBorrowedEvidence() {
        let fiveHour = CoreUsageWindow(name: "5h", usedPct: 20)
        let weekly = CoreUsageWindow(name: "7d", usedPct: 30)
        let provider = CoreProviderUsage(id: "claude", windows: [fiveHour, weekly], state: "ready",
                                         forecast: CoreUsageForecast(pace: "under", samples: 93, ratePctPerHour: 1))
        #expect(inspect(fiveHour, provider: provider).forecastEvidence == "Monitor forecast · 93 quota readings")
        let secondary = inspect(weekly, provider: provider)
        #expect(secondary.verdictText == "No pace yet")
        #expect(secondary.forecastEvidence == "A pace needs two quota readings a minute apart.")
    }

    @Test("offline inspection preserves the reading and pauses predictions")
    func offlineReading() {
        let window = CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: now.timeIntervalSince1970 + 3600,
                                     forecast: CoreUsageForecast(pace: "under", samples: 12, ratePctPerHour: 1))
        let result = inspect(window, live: false)
        #expect(result.amountText == "42% used")
        #expect(result.readingNotice == "Monitor disconnected. This is the last reading.")
        #expect(result.verdictText == "Paused")
        #expect(result.forecastEvidence == nil)
        #expect(result.explanation == "Forecasts resume when the monitor reconnects.")
        #expect(result.readingAge == "Read 1m ago")
    }

    @Test("stale and disabled readings cannot present active forecast evidence")
    func inactiveReadings() {
        let window = CoreUsageWindow(name: "5h", usedPct: 42, forecast: CoreUsageForecast(pace: "under", samples: 12, ratePctPerHour: 1))
        for state in ["stale", "disabled", "off", "needs_consent", "error", "unavailable", "source_not_found"] {
            let provider = CoreProviderUsage(id: "claude", windows: [window], state: state,
                                             observedAt: now.timeIntervalSince1970 - 60, readAt: now.timeIntervalSince1970 - 3600)
            let result = inspect(window, provider: provider)
            #expect(result.readingNotice != nil)
            #expect(result.verdictText == "Paused")
            #expect(result.forecastEvidence == nil)
            #expect(result.readingAge == "Read 1h 00m ago")
        }
    }

    @Test("unknown and invalid quota amounts remain unknown")
    func unknownAmounts() {
        let values: [Double?] = [nil, .nan, .infinity, -1, 101]
        for used in values {
            let window = CoreUsageWindow(name: "7d", usedPct: used)
            let result = inspect(window)
            #expect(result.amountText == "No quota reading")
            #expect(result.verdictText == "No reading")
            #expect(result.forecastEvidence == nil)
            #expect(result.inspectLabel == "Inspect 7-day window, no quota reading")
        }
    }

    @Test("missing and invalid reading times and resets do not become dates")
    func unknownTimes() {
        let values: [Double?] = [nil, 0, -1, .nan, .infinity, now.timeIntervalSince1970 + 60]
        for at in values {
            let provider = CoreProviderUsage(id: "claude", state: "ready", readAt: at)
            let window = CoreUsageWindow(name: "5h", usedPct: 42)
            let result = inspect(window, provider: provider)
            #expect(result.readingDate == nil)
            #expect(result.readingAge == "Reading time unavailable")
        }
        for reset in values.dropLast() {
            #expect(inspect(CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: reset)).resetText == "Reset time unavailable")
        }
        let elapsed = inspect(CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: now.timeIntervalSince1970 - 60))
        #expect(elapsed.resetText.contains("waiting for a new reading"))
        #expect(elapsed.verdictText == "Paused")
    }

    @Test("known zero and one-sample evidence are distinct from missing counts")
    func sampleCounts() {
        for count in [0, 1] {
            let window = CoreUsageWindow(name: "5h", usedPct: 0,
                                         forecast: CoreUsageForecast(pace: "guarded", reason: "insufficient_samples", samples: count))
            let result = inspect(window)
            #expect(result.amountText == "0% used")
            #expect(result.forecastEvidence == "Monitor forecast · \(count) quota reading\(count == 1 ? "" : "s")")
        }
        let invalid = CoreUsageWindow(name: "5h", usedPct: 20, forecast: CoreUsageForecast(pace: "under", samples: -1))
        #expect(inspect(invalid).forecastEvidence == "Monitor forecast")
    }

    @Test("invalid resets cannot promise that the reset wins or already happened")
    func invalidResetConfidence() {
        let invalidResets: [Double?] = [nil, .nan, .infinity, 0, -1, Double.greatestFiniteMagnitude,
                                       Date.distantFuture.timeIntervalSince1970 + 1]
        for reset in invalidResets {
            let window = CoreUsageWindow(name: "7d", usedPct: 42, resetsAt: reset,
                                         forecast: CoreUsageForecast(pace: "under", samples: 12, ratePctPerHour: 1))
            let result = inspect(window)
            #expect(result.amountText == "42% used")
            #expect(result.resetText == "Reset time unavailable")
            #expect(result.verdictText != "Resets first")
            #expect(!result.explanation.contains("resets before"))
            #expect(!result.explanation.contains("window reset"))
            #expect(result.displayForecast.resetsAt == nil)
            #expect(result.displayForecast.projectedAtReset(now: now.timeIntervalSince1970) == nil)
            if let value = reset, value.isFinite && value <= 0 {
                #expect(result.forecastEvidence == nil)
            } else {
                #expect(result.forecastEvidence == "Monitor forecast · 12 quota readings")
            }
        }
    }

    @Test("a valid future reset keeps its supported forecast and evidence")
    func validResetConfidence() {
        let reset = now.timeIntervalSince1970 + 86400
        let window = CoreUsageWindow(name: "7d", usedPct: 42, resetsAt: reset,
                                     forecast: CoreUsageForecast(pace: "under", samples: 12, ratePctPerHour: 1))
        let result = inspect(window)
        #expect(result.resetText == "resets in 1d 0h")
        #expect(result.verdictText == "Resets first")
        #expect(result.explanation.contains("resets before"))
        #expect(result.forecastEvidence == "Monitor forecast · 12 quota readings")
        #expect(result.displayForecast.resetsAt == reset)
    }

    @Test("model and reference windows explain their scope")
    func scope() {
        var model = CoreUsageWindow(name: "Model weekly", usedPct: 10, bindable: false)
        #expect(inspect(model).scopeText == "This window is not used to choose the account's headline limit.")
        model.detail = true
        #expect(inspect(model).scopeText == "For reference. This window does not drive the account limit.")
    }
}
