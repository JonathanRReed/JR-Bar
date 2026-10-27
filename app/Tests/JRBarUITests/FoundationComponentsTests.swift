import AppKit
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarUI

@Suite("UI foundation")
struct FoundationComponentsTests {
    let now: Double = 1_800_000_000
    let locale = Locale(identifier: "en_US")
    let zone = TimeZone(secondsFromGMT: 0)!

    @Test @MainActor func settingsGroupsInsetBareRowsWithoutPaddingStandardRowsTwice() {
        func height(_ view: some View) -> CGFloat {
            NSHostingView(rootView: view.frame(width: 320).fixedSize(horizontal: false, vertical: true)).fittingSize.height
        }
        let row = SettingsRow("Update channel") { Text("Stable") }
        let bare = HStack { Text("Update channel"); Spacer(); Text("Stable") }
        #expect(height(SettingsGroup { bare }) >= height(row))
        #expect(abs(height(SettingsGroup { row }) - height(row)) < 1)
        #expect(abs(height(SettingsGroup { bare.settingsRowInsets() }) - height(row)) < 1)
    }

    @Test @MainActor func tokensMatchApprovedDefaults() {
        #expect(JRBarTokens.TypeStyle.allCases.map(\.size) == [26, 22, 17, 15, 13, 13, 12, 11, 11])
        #expect(JRBarTokens.TypeStyle.allCases.map(\.lineHeight) == [32, 28, 22, 20, 18, 18, 16, 14, 14])
        #expect(JRBarTokens.Motion.allCases.map(\.duration) == [0.1, 0.14, 0.16, 0.25, 0.18, 0.08])
        #expect([16, 20, 28, 40].map { JRBarTokens.Radius.providerTile(size: CGFloat($0)) } == [5, 6, 8, 11])
        #expect(ProviderLogoTile(provider: "grok").size == 20)
        #expect(ProviderPalette.hex(for: "Claude") == "#D97757")
        #expect(ProviderPalette.displayName(for: "openai-api") == "OpenAI API")
        #expect(ProviderPalette.logoID(for: "codex") == "openai")
        #expect(StateDot.State.working.breathDuration == 1.6)
        #expect(StateDot.State.asking.breathDuration == 1)
        #expect(StateDot.State.done.breathDuration == nil)
    }

    @Test func windowsKeepTheirOwnNumbersAndResetTimes() {
        let short = CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: now + 2520)
        let week = CoreUsageWindow(name: "7d", usedPct: 18, resetsAt: now + 86400)
        let provider = CoreProviderUsage(id: "claude", windows: [short, week], state: "ready")
        let a = UsageGaugeReading(window: short, provider: provider, now: now, locale: locale, timeZone: zone)
        let b = UsageGaugeReading(window: week, provider: provider, now: now, locale: locale, timeZone: zone)
        #expect(a.percentUsed == 42)
        #expect(b.percentUsed == 18)
        #expect(a.footnote == "in 42m")
        #expect(b.footnote == "Sat 8\u{202F}AM")
    }

    @Test func resetFormattingUsesClockLocaleAndDay() {
        // Thursday 1 January 2026, 13:00 UTC.
        let clock = 1_767_272_400.0
        #expect(UsageGaugeReading.resetTime(clock + 6000, now: clock, locale: locale, timeZone: zone) == "2:40\u{202F}PM")
        #expect(UsageGaugeReading.resetTime(clock + 86400, now: clock, locale: locale, timeZone: zone) == "Fri 1\u{202F}PM")
        let german = UsageGaugeReading.resetTime(clock + 6000, now: clock, locale: Locale(identifier: "de_DE"), timeZone: zone)
        #expect(german == "14:40")
        #expect(UsageGaugeReading.interval(59) == "<1m")
        #expect(UsageGaugeReading.interval(10800) == "3h")
        #expect(UsageGaugeReading.interval(259200) == "3d")
    }

    @Test func expiredOrExplicitlyElapsedWindowSuppressesOldPercent() {
        var window = CoreUsageWindow(name: "5h", usedPct: 93, resetsAt: now)
        let provider = CoreProviderUsage(id: "claude", windows: [window], state: "ready")
        let reading = UsageGaugeReading(window: window, provider: provider, now: now)
        #expect(reading.percentUsed == nil)
        #expect(reading.elapsed)
        #expect(reading.footnote == "<1m ago")
        window.resetsAt = now + 3600
        window.elapsed = true
        #expect(UsageGaugeReading(window: window, provider: provider, now: now).percentUsed == nil)
    }

    @Test func staleAgeOccursOnceOutsideResetFootnoteAndAdvancesFromArrival() {
        let window = CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: now + 2520)
        for availability in ["missing_recent", "source_idle", "failing"] {
            var provider = CoreProviderUsage(id: "claude", windows: [window], state: "ready", readAt: now - 120)
            provider.availability = availability
            let reading = UsageGaugeReading(window: window, provider: provider, now: now)
            #expect(reading.stale)
            #expect(reading.percentUsed == 42)
            #expect(reading.footnote == "in 42m")
            #expect(UsageGaugeReading.age(provider: provider, now: now, snapshotReceivedAt: now) == "Read 2m ago")
            provider.readAt = nil
            provider.lastGoodAgeSeconds = 2400
            #expect(UsageGaugeReading.age(provider: provider, now: now + 60, snapshotReceivedAt: now) == "Read 41m ago")
        }
    }

    @Test func hiddenOffAndUnsupportedSourcesNeverOfferOldNumbers() {
        let window = CoreUsageWindow(name: "7d", usedPct: 77)
        for availability in ["absent", "not_found"] {
            var provider = CoreProviderUsage(id: "claude", windows: [window])
            provider.availability = availability
            #expect(UsageGaugeReading(window: window, provider: provider, now: now).percentUsed == nil)
        }
        let off = CoreProviderUsage(id: "claude", windows: [window], reason: CoreProviderUsage.usageOffReason)
        #expect(UsageGaugeReading(window: window, provider: off, now: now).percentUsed == nil)
        let sessions = CoreProviderUsage(id: "pi", windows: [window], quotaSource: false)
        #expect(UsageGaugeReading(window: window, provider: sessions, now: now).percentUsed == nil)
    }

    @Test func valuesClampWithoutInventingMissingMeasurements() {
        for (raw, expected) in [(0.0, 0.0), (100, 100), (99.6, 99.6), (150, 100), (-4, 0)] {
            let window = CoreUsageWindow(name: "Monthly", usedPct: raw)
            let provider = CoreProviderUsage(id: "claude", windows: [window])
            #expect(UsageGaugeReading(window: window, provider: provider, now: now).percentUsed == expected)
        }
        for raw in [nil, Double.nan, Double.infinity] {
            let window = CoreUsageWindow(name: "Monthly", usedPct: raw)
            let provider = CoreProviderUsage(id: "claude", windows: [window])
            #expect(UsageGaugeReading(window: window, provider: provider, now: now).percentUsed == nil)
        }
        #expect(UsageGaugeRow.orderedWindowNames(["Monthly", "7d", "5h", "7d", "7d Opus"]) == ["5h", "7d", "Monthly", "7d Opus"])
    }
    @Test @MainActor func missingGaugeHasNoTrackOrLayoutHeight() {
        let missing = NSHostingView(rootView: JRBarGauge(value: nil).frame(width: 64).fixedSize())
        let measured = NSHostingView(rootView: JRBarGauge(value: 0).frame(width: 64).fixedSize())
        #expect(missing.fittingSize.height == 0)
        #expect(measured.fittingSize.height == 4)
    }

    @Test @MainActor func paceTickExtendsBeyondTheSixPointBar() throws {
        let gauge = JRBarGauge(value: 42, tint: .black, height: 6, pace: 52)
            .frame(width: 100).padding(.vertical, 4).background(.white)
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: gauge)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / host.bounds.height
        func paintedHeight(at pointX: CGFloat) -> CGFloat {
            let x = Int(pointX * CGFloat(bitmap.pixelsWide) / host.bounds.width)
            let rows = (0..<bitmap.pixelsHigh).filter { y in
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return pixel.redComponent < 0.8
            }
            return CGFloat(rows.count) / scale
        }
        #expect(paintedHeight(at: 20) == 6)
        #expect(paintedHeight(at: 52) == 10)
    }

    @Test @MainActor func anUnusedActionHandlerDoesNotAddARow() {
        let provider = CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(name: "5h", usedPct: 42)])
        let plain = UsageGaugeRow(provider: provider, name: "Claude", now: now, style: .compact)
        let routed = UsageGaugeRow(provider: provider, name: "Claude", now: now, style: .compact, onAction: {})
        let plainHost = NSHostingView(rootView: plain.frame(width: 320).fixedSize(horizontal: false, vertical: true))
        let routedHost = NSHostingView(rootView: routed.frame(width: 320).fixedSize(horizontal: false, vertical: true))
        #expect(plainHost.fittingSize.height == routedHost.fittingSize.height)
    }

    @Test @MainActor func aGoneProviderFitsOneCompactRow() {
        var provider = CoreProviderUsage(id: "kiro", windows: [CoreUsageWindow(name: "5h", usedPct: 77)], action: "Hide")
        provider.availability = "not_found"
        provider.statusText = "Not found on this Mac"
        let row = UsageGaugeRow(provider: provider, name: "Kiro", now: now, style: .compact, onAction: {})
        let host = NSHostingView(rootView: row.frame(width: 320).fixedSize(horizontal: false, vertical: true))
        #expect(host.fittingSize.height == 36)
    }

    @Test func marksClearTheApprovedContentAndGlassPlates() {
        let surfaces: [(ProviderMarkInk.Surface, ProviderMarkInk.RGB)] = [
            (.darkPlate, ProviderMarkInk.darkSurface), (.lightPlate, ProviderMarkInk.lightSurface),
            (.blackPlate, .black),
            (.darkGlass, ProviderMarkInk.darkGlassSurface), (.lightGlass, ProviderMarkInk.lightGlassSurface)
        ]
        for provider in ProviderPalette.hexes.keys {
            let color = ProviderPalette.nsColor(for: provider).usingColorSpace(.sRGB)!
            let accent = ProviderMarkInk.RGB(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
            for (surface, background) in surfaces {
                let ink = ProviderMarkInk.ink(accent, on: surface)
                #expect(ink.contrast(with: ProviderMarkInk.plate(accent, over: background)) >= 2.999,
                        "\(provider) on \(surface)")
            }
        }
    }

    @Test @MainActor func increasedContrastStrengthensNeutralInk() throws {
        let standard = NSColor(JRBarTokens.Ink.Palette().stale).usingColorSpace(.sRGB)!
        let increased = NSColor(JRBarTokens.Ink.Palette(increased: true).stale).usingColorSpace(.sRGB)!
        #expect(increased.alphaComponent >= 0.70)
        #expect(increased.alphaComponent >= standard.alphaComponent)
    }
}
