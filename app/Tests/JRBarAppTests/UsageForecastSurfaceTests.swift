import AppKit
@testable import JRBarCore
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Forecasts stay connected to usage views", .serialized)
@MainActor
struct UsageForecastSurfaceTests {
    static let stamp = 1_800_000_000.0

    static func notchModel() -> NotchCardModel {
        let power = AlcovePowerState(hasBattery: true, onAC: true, charging: false, percent: 100, fullyCharged: true)
        let timers = ShelfTimerModel(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-forecast-timers-\(UUID().uuidString).json"), schedulingEnabled: false)
        let tray = ShelfTrayModel(defaults: ScratchDefaults.open(ScratchDefaults.suiteName("forecast-notch")))
        return NotchCardModel(timers: timers, tray: tray, utility: ShelfUtilityModel(power: power), runtimeEnabled: false)
    }

    static func fixture(_ state: String, providerID: String = "claude") -> (PanelStore, UsageCenterStore, CoreProviderUsage) {
        let exhausted = state == "used up"
        var provider = CoreProviderUsage(id: providerID, windows: [
            CoreUsageWindow(name: "5h", usedPct: exhausted ? 100 : 70, resetsAt: stamp + 4 * 3600),
            CoreUsageWindow(name: "7d", usedPct: 20, resetsAt: stamp + 2 * 86400),
        ], fidelity: state == "stale" ? "stale" : "official", state: state == "stale" ? "stale" : "ready",
            forecast: CoreUsageForecast(exhaustsAt: stamp + 2 * 3600, pace: "ahead", ratePctPerHour: 15), readAt: stamp - 60)
        if state == "comfortable" { provider.forecast = CoreUsageForecast(pace: "under", ratePctPerHour: 1) }
        if state == "no pace yet" { provider.forecast = nil }
        if state == "guarded" { provider.forecast = CoreUsageForecast(pace: "guarded", reason: "reset_boundary") }
        if state == "no quota" { provider.quotaSource = false; provider.windows = [] }
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-forecast-fixture.sock")
        core.handle(.connected)
        let sessions = state == "held idle" ? [] : [CoreSession(id: providerID + ":fixture", provider: providerID, label: "Sample task", mode: "working")]
        core.apply(.state(CoreState(aggregate: CoreAggregate(mode: sessions.isEmpty ? "idle" : "working", active: sessions.count),
            sessions: sessions, usage: CoreUsage(refreshedAt: stamp, providers: [provider]))))
        let panel = PanelStore(core: core, draftsDefaults: UserDefaults(suiteName: ScratchDefaults.suiteName("jrbar.forecast"))!, screenBarShown: false)
        panel.now = Date(timeIntervalSince1970: stamp)
        panel.screenHeight = 1200
        panel.animationsArmed = false
        let usage = UsageCenterStore(core: core)
        usage.now = panel.now
        return (panel, usage, provider)
    }

    @Test(arguments: ["runs out", "used up", "comfortable", "no pace yet", "held idle", "stale", "guarded"])
    func allThreeViewsUseTheSessionAwareForecast(_ state: String) async throws {
        let (panel, store, provider) = Self.fixture(state)
        let window = try #require(provider.windows.first)
        let row = PanelProviderSection(store: panel, composition: PanelComposition(store: panel)).gauge(provider)
        #expect(row.onOpen != nil)
        let reading = row.reading(for: window)
        let meter = try #require(UsageCenterStore.notchMeters(core: panel.core, now: panel.now).first)
        let caption = NotchMeterCaption(meter: meter, now: panel.now)
        #expect(meter.forecast == store.forecast(for: provider, window: window))
        #expect(caption.forecast == reading.forecast)
        #expect(caption.tone == reading.captionTone)
        if ["runs out", "used up"].contains(state) {
            #expect(caption.text == reading.footnote)
            #expect(caption.help.contains(try #require(caption.reset)))
        } else {
            #expect(caption.text == PanelStore.countdown(to: window.resetsAt, now: panel.now, fix: provider.staleFix))
            #expect(caption.tone == .secondary)
        }
        let detail = UsageProviderDetail(provider: provider, store: store, showCost: true)
        let inspection = try #require(detail.inspections.first)
        #expect(detail.quotaRow.onInspect != nil)
        #expect(detail.quotaRow.forecasts[window.id] == inspection.displayForecast)
        switch state {
        case "runs out":
            #expect(reading.forecast?.isCritical == true)
            #expect(reading.captionTone == .attention)
            #expect(reading.footnote.hasPrefix("Runs out "))
            #expect(reading.footnote != reading.resetFootnote)
            #expect(reading.forecastHelp.contains(reading.resetFootnote))
            #expect(inspection.verdictText.hasPrefix("Runs out "))
            #expect(inspection.explanation.contains("at this pace"))
            #expect(inspection.projectedText == "At this pace 130% by the reset")
            #expect(inspection.budget?.exceedsBudget == true)
        case "used up":
            #expect(reading.forecast?.verdict == .exhausted)
            #expect(reading.footnote == "Used up")
            #expect(reading.captionTone == .failure)
            #expect(inspection.verdictText == "Used up")
            #expect(inspection.budget == nil)
        case "comfortable":
            #expect(reading.forecast?.verdict == .comfortable)
            #expect(reading.captionTone == .secondary)
            #expect(inspection.verdictText == "Resets first")
            #expect(inspection.projectedText == "At this pace 74% by the reset")
            #expect(inspection.budget?.exceedsBudget == false)
        case "no pace yet":
            #expect(reading.forecast?.verdict == .unknown)
            #expect(inspection.verdictText == "No pace yet")
            #expect(inspection.projectedText == nil)
            #expect(inspection.budget == nil)
        case "held idle":
            #expect(reading.forecast?.heldIdle == true)
            #expect(inspection.verdictText == "Holding")
            #expect(inspection.explanation.contains("no agent is working"))
            #expect(inspection.projectedText == nil)
            #expect(inspection.budget == nil)
        case "stale":
            #expect(reading.stale)
            #expect(reading.forecast == nil)
            #expect(inspection.verdictText == "Paused")
            #expect(inspection.readingNotice == "This reading is stale.")
            #expect(inspection.projectedText == nil)
            #expect(inspection.budget == nil)
        default:
            #expect(reading.forecast?.verdict == .guarded(reason: "reset_boundary"))
            #expect(inspection.verdictText == "Paused")
            #expect(inspection.projectedText == nil)
            #expect(inspection.budget == nil)
        }
        if !["runs out", "used up"].contains(state) {
            #expect(reading.footnote == reading.resetFootnote)
            #expect(reading.captionTone == .secondary)
        }
        let shownRows = try await evidence(UsageGaugeEvidence.self, view: PanelProviderSection(store: panel, composition: PanelComposition(store: panel)))
        let shownForecasts = try await evidence(UsageForecastEvidence.self, view: detail)
        #expect(shownRows[window.id] == reading, "The panel must render its forecast reading")
        #expect(shownForecasts[window.id + ".verdict"] == inspection.displayForecast, "Usage Center must render its verdict")
        #expect(shownForecasts[window.id + ".headline"] == inspection.displayForecast, "Usage Center must render its forecast sentence")
        let card = NotchCardView(model: Self.notchModel(), style: .island, width: 320)
        let shownCaptions = try await evidence(NotchMeterCaptionEvidence.self, view: card.meterRow(meter, now: panel.now))
        #expect(shownCaptions[meter.id] == caption.text, "The notch must render the same verdict")
        // A secondary window never borrows the short window's run-out.
        let week = try #require(provider.windows.last)
        #expect(row.reading(for: week).captionTone == .secondary)
    }

    @Test func imminentRunOutAndResetBoundaries() throws {
        let (panel, _, original) = Self.fixture("runs out")
        var provider = original
        provider.windows[0].forecast = CoreUsageForecast(exhaustsAt: Self.stamp + 40 * 60, pace: "ahead", ratePctPerHour: 45)
        let section = PanelProviderSection(store: panel, composition: PanelComposition(store: panel))
        let soon = section.gauge(provider).reading(for: provider.windows[0])
        #expect(soon.footnote == "Runs out in 40m")
        provider.windows[0].resetsAt = Self.stamp - 1
        let reset = section.gauge(provider).reading(for: provider.windows[0])
        #expect(reset.elapsed)
        #expect(reset.forecast == nil)
        #expect(reset.captionTone == .secondary)
    }

    @Test func futureDayRunOutKeepsItsMinutes() {
        let at = Self.stamp + 86400 + 12 * 60
        let window = CoreUsageWindow(name: "7d", usedPct: 70, resetsAt: Self.stamp + 2 * 86400)
        let forecast = UsageForecast(window: "7d", usedPct: 70, resetsAt: window.resetsAt,
            verdict: .runsOut(exhaustsAt: at), ratePctPerHour: 1, source: .daemon)
        let reading = UsageGaugeReading(window: window, provider: CoreProviderUsage(id: "codex", windows: [window]),
            now: Self.stamp, locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!, forecast: forecast)
        #expect(reading.footnote == "Runs out 8:12\u{202F}AM")
        #expect(reading.footnote != "Runs out " + reading.resetFootnote)
    }

    @Test func warningRowsKeepTheCompactHeight() {
        for state in ["runs out", "used up"] {
            let (panel, _, original) = Self.fixture(state)
            for imminent in [false, true] {
                var provider = original
                if imminent, state == "runs out" {
                    provider.windows[0].forecast = CoreUsageForecast(exhaustsAt: Self.stamp + 40 * 60, pace: "ahead", ratePctPerHour: 45)
                }
                let row = PanelProviderSection(store: panel, composition: PanelComposition(store: panel)).gauge(provider)
                for width: CGFloat in [320, 372] {
                    let host = NSHostingView(rootView: row.frame(width: width).fixedSize(horizontal: false, vertical: true))
                    #expect(host.fittingSize.height == 36)
                    #expect(PanelComposition.usageHeight(provider) == 36)
                }
            }
        }
    }

    @Test func notchCaptionFitsTheExistingRow() throws {
        let (panel, _, original) = Self.fixture("runs out")
        var provider = original
        let at = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone.current,
            year: 2027, month: 1, day: 15, hour: 12, minute: 45).date!.timeIntervalSince1970
        panel.now = Date(timeIntervalSince1970: at - 2 * 3600)
        provider.windows[0].resetsAt = at + 2 * 3600
        provider.forecast = CoreUsageForecast(exhaustsAt: at, pace: "ahead", ratePctPerHour: 15)
        panel.core.apply(.state(CoreState(sessions: panel.core.sessions, usage: CoreUsage(providers: [provider]))))
        let meter = try #require(UsageCenterStore.notchMeters(core: panel.core, now: panel.now).first)
        let caption = NotchMeterCaption(meter: meter, now: panel.now, locale: Locale(identifier: "en_US"))
        #expect(caption.text?.replacingOccurrences(of: "\u{202F}", with: " ") == "Runs out 12:45 PM")
        var baseline = meter
        baseline.forecast = nil
        let card = NotchCardView(model: Self.notchModel(), style: .island, width: 320)
        for width: CGFloat in [248, 272, 288, 348] {
            let before = NSHostingView(rootView: card.meterRow(baseline, now: panel.now).frame(maxWidth: width)
                .fixedSize(horizontal: false, vertical: true))
            let after = NSHostingView(rootView: card.meterRow(meter, now: panel.now).frame(maxWidth: width)
                .fixedSize(horizontal: false, vertical: true))
            #expect(after.fittingSize.height == before.fittingSize.height)
            #expect(after.fittingSize.width <= width)
            if before.fittingSize.width == width {
                #expect(after.fittingSize.width == before.fittingSize.width)
            }
        }
        provider.windows[0].forecast = CoreUsageForecast(exhaustsAt: at - 80 * 60, pace: "ahead", ratePctPerHour: 45)
        panel.core.apply(.state(CoreState(sessions: panel.core.sessions, usage: CoreUsage(providers: [provider]))))
        let soon = try #require(UsageCenterStore.notchMeters(core: panel.core, now: panel.now).first)
        #expect(NotchMeterCaption(meter: soon, now: panel.now).text == "Runs out in 40m")
    }

    @Test func notchUsageRemainsOptional() throws {
        let (panel, _, _) = Self.fixture("runs out")
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true, showUsage: false)
        let owner = ToysStore(core: panel.core, settings: SettingsStore(core: panel.core), state: state,
            cardModel: Self.notchModel(), notchRuntimeEnabled: false)
        let toy = try #require(owner.notch)
        toy.islandVisible = true
        toy.noteInputsChanged()
        #expect(toy.reconcileInputs.meters.isEmpty)
        owner.state.notch.showUsage = true
        toy.noteInputsChanged()
        #expect(!toy.reconcileInputs.meters.isEmpty)
        owner.state.notch.showUsage = false
        toy.noteInputsChanged()
        #expect(toy.reconcileInputs.meters.isEmpty)
    }

    @Test func unavailableReadingsNeverPromiseARunOut() throws {
        for state in ["needs_sign_in", "disabled", "needs_consent", "error", "unavailable", "source_not_found"] {
            let (panel, store, original) = Self.fixture("runs out")
            var provider = original
            provider.state = state
            let reading = PanelProviderSection(store: panel, composition: PanelComposition(store: panel)).gauge(provider).reading(for: provider.windows[0])
            let detail = UsageProviderDetail(provider: provider, store: store, showCost: true)
            #expect(reading.forecast == nil)
            #expect(detail.inspections.first?.budget == nil)
        }
        for availability in ["failing", "source_idle", "missing_recent", "not_found", "absent"] {
            let (_, store, original) = Self.fixture("runs out")
            var provider = original
            provider.availability = availability
            let inspection = UsageProviderDetail(provider: provider, store: store, showCost: true).inspection(for: provider.windows[0])
            #expect(inspection.verdictText == "Paused")
            #expect(inspection.projectedText == nil)
            #expect(inspection.budget == nil)
        }
        let (_, store, provider) = Self.fixture("no quota")
        #expect(UsageProviderDetail(provider: provider, store: store, showCost: true).inspections.isEmpty)
    }

    @Test func providerFactsAndReferenceWindowsStayAvailable() throws {
        let (panel, store, original) = Self.fixture("runs out")
        var provider = original
        provider.account = UsageAccount(plan: "Sample plan", label: "Sample account", fidelity: "official")
        provider.creditsRemaining = 12
        provider.resetCredits = 2
        provider.tokens = CoreUsageTokens(input: 2000, cachedInput: 3000, output: 1000)
        provider.estimatedCostUSD = 1.25
        var reference = CoreUsageWindow(name: "Monthly", usedPct: 8)
        reference.detail = true
        provider.windows.append(reference)
        panel.core.apply(.state(CoreState(sessions: panel.core.sessions, usage: CoreUsage(providers: [provider]))))
        let detail = UsageProviderDetail(provider: provider, store: store, showCost: true)
        #expect(detail.facts.account.contains("Sample plan"))
        #expect(detail.facts.account.contains("Sample account"))
        #expect(detail.facts.credits?.contains("2 reset credits") == true)
        #expect(detail.facts.counters != nil)
        #expect(detail.facts.estimatedCost != nil)
        #expect(detail.facts.readingAge != nil)
        #expect(detail.quotaRow.provider.windows.map(\.name) == ["5h", "7d"])
        #expect(detail.inspections.map(\.window.name) == ["5h", "7d"])
    }

    private func evidence<P: PreferenceKey, V: View>(_ key: P.Type, view: V) async throws -> P.Value where P.Value: Equatable & Sendable {
        var result = P.defaultValue
        let root = view.onPreferenceChange(key) { result = $0 }
            .environment(\.renderSnapshot, true).environment(\.ledPreviewsHeld, true)
        let host = NSHostingView(rootView: root)
        let size = NSSize(width: 720, height: 10000)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            await drainMainQueue()
        }
        return result
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func forecastRenderProofs() throws {
        let (panel, usage, runningOut) = Self.fixture("runs out")
        let (_, _, usedUp) = Self.fixture("used up", providerID: "codex")
        panel.core.apply(.state(CoreState(aggregate: CoreAggregate(mode: "working", active: 1), sessions: panel.core.sessions,
            usage: CoreUsage(refreshedAt: Self.stamp, providers: [runningOut, usedUp]))))
        for width: CGFloat in [372, 320] {
            try WindowsRenderProofTests.write("forecast-panel-\(Int(width))", size: CGSize(width: width, height: 360), plate: .glass, requiresKey: false) {
                PanelView(store: panel, panelWidth: width)
            }
        }
        var imminent = runningOut
        imminent.windows[0].forecast = CoreUsageForecast(exhaustsAt: Self.stamp + 40 * 60, pace: "ahead", ratePctPerHour: 45)
        panel.core.apply(.state(CoreState(aggregate: CoreAggregate(mode: "working", active: 1), sessions: panel.core.sessions,
            usage: CoreUsage(refreshedAt: Self.stamp, providers: [imminent, usedUp]))))
        for width: CGFloat in [372, 320] {
            try WindowsRenderProofTests.write("forecast-panel-imminent-\(Int(width))", size: CGSize(width: width, height: 360), plate: .glass, requiresKey: false) {
                PanelView(store: panel, panelWidth: width)
            }
        }
        try WindowsRenderProofTests.write("forecast-detail", size: CGSize(width: 720, height: 560), requiresKey: false) {
            UsageProviderDetail(provider: runningOut, store: usage, showCost: true).padding(JRBarTokens.Space.xxl)
        }
    }
}
