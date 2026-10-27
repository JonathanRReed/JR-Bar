import AppKit
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Notch meter captions fit", .serialized)
@MainActor
struct NotchMeterCaptionFitTests {
    nonisolated static let states = ["runs out", "imminent", "used up", "comfortable", "no pace yet",
        "held idle", "stale", "guarded", "reset passed", "source fix", "no reset"]

    @Test(arguments: Set(ProviderID.aliases.values).sorted(), states)
    func everyProviderAndState(provider: String, state: String) async throws {
        let (panel, _, original) = UsageForecastSurfaceTests.fixture(state, providerID: provider)
        var usage = original
        let now = try #require(DateComponents(calendar: Calendar(identifier: .gregorian),
            timeZone: .current, year: 2027, month: 1, day: 15, hour: 21, minute: 5).date)
        panel.now = now
        let stamp = now.timeIntervalSince1970
        usage.windows[0].resetsAt = stamp + 4 * 3600
        if usage.forecast?.exhaustsAt != nil { usage.forecast?.exhaustsAt = stamp + 2 * 3600 }
        if state == "imminent" {
            usage.forecast = CoreUsageForecast(exhaustsAt: stamp + 40 * 60,
                pace: "ahead", ratePctPerHour: 45)
        }
        if ["reset passed", "source fix"].contains(state) {
            usage.windows[0].resetsAt = stamp - 1
        }
        if state == "no reset" { usage.windows[0].resetsAt = nil }
        panel.core.apply(.state(CoreState(sessions: panel.core.sessions, usage: CoreUsage(providers: [usage]))))
        var meter = try #require(UsageCenterStore.notchMeters(core: panel.core, now: panel.now).first)
        if state == "source fix" { meter.fix = "Reconnect \(ProviderStyle.style(for: provider).name)" }
        let card = NotchCardView(model: UsageForecastSurfaceTests.notchModel(), style: .island, width: 320)
        for width: CGFloat in [288, 348] {
            var captions: [String: String] = [:]
            var widths: [String: CGFloat] = [:]
            var fonts: [String: CGFloat] = [:]
            let row = card.meterRow(meter, now: panel.now)
                .frame(width: width)
                .onPreferenceChange(NotchMeterCaptionEvidence.self) { captions = $0 }
                .onPreferenceChange(NotchMeterCaptionWidthEvidence.self) { widths = $0 }
                .onPreferenceChange(NotchMeterCaptionFontEvidence.self) { fonts = $0 }
                .environment(\.renderSnapshot, true)
            let host = NSHostingView(rootView: row)
            let size = CGSize(width: width, height: 24)
            let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: width, height: 24),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: size)
            defer { window.contentView = nil; window.close() }
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
                await drainMainQueue()
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(!window.isVisible)
            #expect(host.fittingSize.width == width)
            if NotchMeterCaption(meter: meter, now: panel.now).text != nil {
                let shown = try #require(captions[meter.id])
                let available = try #require(widths[meter.id])
                let font = try #require(fonts[meter.id])
                let text = NSHostingView(rootView: Text(shown).font(.system(size: font)).monospacedDigit().fixedSize())
                let caption = NotchMeterCaption(meter: meter, now: panel.now)
                #expect(caption.help.contains(try #require(caption.text)))
                let longestFit = caption.forms.first {
                    NSHostingView(rootView: Text($0).font(.system(size: 10)).monospacedDigit().fixedSize())
                        .fittingSize.width <= available + 0.5
                }
                #expect(shown == (longestFit ?? caption.forms.last))
                #expect(longestFit == nil || font == 10)
                #expect(text.fittingSize.width <= available + 0.5,
                    "\(provider), \(state), row \(width): '\(shown)' needs \(text.fittingSize.width), slot has \(available)")
            } else {
                #expect(captions.isEmpty)
            }
        }
    }
}
