import AppKit
import JRBarCore
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Run-out display preference", .serialized)
@MainActor
struct RunOutSurfaceTests {
    static func configure(_ style: UsageRunOutStyle, core: CoreModel) {
        core.apply(.settings(CoreSettings(generation: 1, schema: 3,
            document: ["usage_run_out_style": .string(style.rawValue)])))
    }

    @Test(arguments: UsageRunOutStyle.allCases)
    func everyDisplayReadsTheSavedStyle(style: UsageRunOutStyle) throws {
        let (panel, store, original) = UsageForecastSurfaceTests.fixture("runs out")
        Self.configure(style, core: panel.core)
        let offsets: [Double] = [30, 65 * 60, 200 * 60, 22 * 3600, 2 * 86400, 6 * 86400, 9 * 86400]
        for offset in offsets {
            var provider = original
            let at = panel.now.timeIntervalSince1970 + offset
            provider.windows[0].resetsAt = at + 3600
            provider.forecast = CoreUsageForecast(exhaustsAt: at, pace: "ahead")
            panel.core.apply(.state(CoreState(sessions: panel.core.sessions, usage: CoreUsage(providers: [provider]))))
            let window = try #require(provider.windows.first)
            let row = PanelProviderSection(store: panel, composition: PanelComposition(store: panel)).gauge(provider)
            let reading = row.reading(for: window)
            let expected = UsageTime.runsOut(at: at, now: panel.now.timeIntervalSince1970, style: style)
            #expect(reading.footnote == expected)
            #expect(reading.forecastHelp.contains(expected))
            let inspection = UsageProviderDetail(provider: provider, store: store, showCost: true).inspection(for: window)
            #expect(inspection.verdictText == expected)
            #expect(inspection.explanation.hasPrefix(expected))
            let meter = try #require(UsageCenterStore.notchMeters(core: panel.core, now: panel.now).first)
            let caption = NotchMeterCaption(meter: meter, now: panel.now)
            #expect(caption.text == expected)
            #expect(caption.help.contains(expected))
            #expect(caption.forms == UsageTime.runOutForms(at: at, now: panel.now.timeIntervalSince1970, style: style))
        }
    }

    @Test(arguments: ["en_US", "en_GB"], UsageRunOutStyle.allCases)
    func localizedSurfacesAndAllFitForms(localeID: String, style: UsageRunOutStyle) throws {
        let locale = Locale(identifier: localeID)
        let zone = TimeZone(identifier: "America/Chicago")!
        let pairs: [(String, String)] = [
            ("2027-01-11T18:00:00Z", "2027-01-11T21:20:00Z"),
            ("2027-01-12T05:50:00Z", "2027-01-12T06:10:00Z"),
            ("2027-01-11T18:00:00Z", "2027-01-12T16:00:00Z"),
            ("2027-01-11T18:00:00Z", "2027-01-13T16:00:00Z"),
            ("2027-01-11T18:00:00Z", "2027-01-17T16:00:00Z"),
            ("2027-01-11T18:00:00Z", "2027-01-20T16:00:00Z"),
            ("2027-03-13T18:00:00Z", "2027-03-14T17:00:00Z"),
            ("2027-11-06T17:00:00Z", "2027-11-07T18:00:00Z"),
        ]
        for (start, end) in pairs {
            let now = ISO8601DateFormatter().date(from: start)!
            let at = ISO8601DateFormatter().date(from: end)!.timeIntervalSince1970
            let window = CoreUsageWindow(name: "7d", usedPct: 70, resetsAt: at + 3600)
            let provider = CoreProviderUsage(id: "claude", windows: [window])
            var forecast = UsageForecast(window: "7d", usedPct: 70, resetsAt: at + 3600,
                verdict: .runsOut(exhaustsAt: at), ratePctPerHour: 10, source: .daemon)
            forecast.runOutStyle = style
            let reading = UsageGaugeReading(window: window, provider: provider, now: now.timeIntervalSince1970,
                locale: locale, timeZone: zone, forecast: forecast)
            let forms = UsageTime.runOutForms(at: at, now: now.timeIntervalSince1970,
                locale: locale, timeZone: zone, style: style)
            #expect(reading.footnote == forms[0])
            #expect(reading.footnoteForms == forms)
            #expect(reading.forecastHelp.contains(forms[0]))
            #expect(forecast.verdictWord(timeZone: zone, now: now, locale: locale) == forms[0])
            #expect(forecast.headline(now: now, timeZone: zone, locale: locale).hasPrefix(forms[0]))
            let (panel, _, _) = UsageForecastSurfaceTests.fixture("runs out")
            let original = try #require(UsageCenterStore.notchMeters(core: panel.core, now: panel.now).first)
            var meter = original
            meter.usage = provider
            meter.forecast = forecast
            let caption = NotchMeterCaption(meter: meter, now: now, locale: locale, timeZone: zone)
            #expect(caption.forms == forms)
            #expect(caption.help.contains(forms[0]))
        }
    }

    @Test(arguments: UsageRunOutStyle.allCases)
    func dayCaptionsFitTogetherAtTenPoints(style: UsageRunOutStyle) async throws {
        let (panel, _, original) = UsageForecastSurfaceTests.fixture("runs out")
        Self.configure(style, core: panel.core)
        // Include different forecast lengths together so each kind shares one form.
        for days in [0, 1, 2, 6, 9] {
            let ids = Array(NotchMeterCaptionFitTests.longestProviders.prefix(3))
            let providers = ids.enumerated().map { index, id in
                var provider = original
                provider.id = id
                let offset = Double(days * 86400 + (index + 1) * 3600)
                let at = panel.now.timeIntervalSince1970 + offset
                provider.windows[0].resetsAt = at + 3600
                provider.forecast = CoreUsageForecast(exhaustsAt: at, pace: "ahead")
                return provider
            }
            let sessions = ids.map { CoreSession(id: $0 + ":fixture", provider: $0, label: "Sample task", mode: "working") }
            panel.core.apply(.state(CoreState(sessions: sessions, usage: CoreUsage(providers: providers))))
            let meters = UsageCenterStore.notchMeters(core: panel.core, now: panel.now)
            #expect(meters.count == 3)
            try await checkFit(meters, now: panel.now)
        }
    }

    private func checkFit(_ meters: [NotchIslandMeter], now: Date) async throws {
        let card = NotchCardView(model: UsageForecastSurfaceTests.notchModel(), style: .island, width: 320)
        for width: CGFloat in [248, 272, 288, 348] {
            var captions: [String: String] = [:]
            var fits: [String: NotchMeterCaptionFit] = [:]
            var fonts: [String: CGFloat] = [:]
            let rows = card.meterRows(meters, now: now).frame(width: width)
                .onPreferenceChange(NotchMeterCaptionEvidence.self) { captions = $0 }
                .onPreferenceChange(NotchMeterCaptionFitEvidence.self) { fits = $0 }
                .onPreferenceChange(NotchMeterCaptionFontEvidence.self) { fonts = $0 }
            let host = NSHostingView(rootView: rows)
            let frame = CGRect(x: -20000, y: -20000, width: width, height: 96)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: frame.size)
            defer { window.contentView = nil; window.close() }
            for _ in 0..<6 {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                await drainMainQueue()
            }
            #expect(captions.count == meters.count)
            let shared = fits.values.map(\.fittingForm).max() ?? 0
            for meter in meters {
                let caption = NotchMeterCaption(meter: meter, now: now)
                let shown = try #require(captions[meter.id])
                let fit = try #require(fits[meter.id])
                #expect(shown == caption.forms[shared])
                #expect(fonts[meter.id] == 10)
                let measured = NSHostingView(rootView: Text(shown).font(.system(size: 10)).monospacedDigit().fixedSize())
                #expect(measured.fittingSize.width <= (fit.available ?? 0) + 0.5,
                    "\(shown) at row width \(width)")
            }
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled), arguments: UsageRunOutStyle.allCases)
    func renderProofs(style: UsageRunOutStyle) throws {
        let (panel, usage, original) = UsageForecastSurfaceTests.fixture("runs out")
        Self.configure(style, core: panel.core)
        var provider = original
        let at = panel.now.timeIntervalSince1970 + 52 * 3600
        provider.windows = [CoreUsageWindow(name: "7d", usedPct: 70, resetsAt: at + 3600)]
        provider.forecast = CoreUsageForecast(exhaustsAt: at, pace: "ahead")
        panel.core.apply(.state(CoreState(sessions: panel.core.sessions, usage: CoreUsage(providers: [provider]))))
        try WindowsRenderProofTests.write("s2-panel-\(style.rawValue)", size: CGSize(width: 372, height: 70)) {
            PanelProviderSection(store: panel, composition: PanelComposition(store: panel)).gauge(provider)
        }
        let detail = UsageProviderDetail(provider: provider, store: usage, showCost: true)
        let inspection = try #require(detail.inspections.first)
        try WindowsRenderProofTests.write("s2-headline-\(style.rawValue)", size: CGSize(width: 600, height: 280)) {
            UsageForecastSummary(inspection: inspection).padding(16)
        }
        let meters = UsageCenterStore.notchMeters(core: panel.core, now: panel.now)
        let card = NotchCardView(model: UsageForecastSurfaceTests.notchModel(), style: .island, width: 320)
        try WindowsRenderProofTests.write("s2-notch-\(style.rawValue)", size: CGSize(width: 320, height: 60)) {
            card.meterRows(meters, now: panel.now).padding(16).background(.black)
        }
        let settingsFixture = try SettingsRenderProofTests.fixture()
        defer { settingsFixture.toys.shutdown() }
        let seededSettings = try #require(settingsFixture.core.settings)
        let document = SettingsDocument(seededSettings.document)
            .replacing("usage_run_out_style", with: .string(style.rawValue))
        panel.core.apply(.settings(CoreSettings(generation: 2, schema: CoreProtocol.knownSettingsSchema,
            document: document.root)))
        let settings = SettingsStore(core: panel.core)
        try WindowsRenderProofTests.write("s2-setting-\(style.rawValue)", size: CGSize(width: 600, height: 550)) {
            Form { SettingsUsageOptions(store: settings) }.formStyle(.grouped)
        }
    }
}
