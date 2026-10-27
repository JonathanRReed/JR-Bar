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

    static var longestProviders: [String] {
        ProviderStyle.table.values.sorted {
            Self.textWidth($0.name, size: 11.5, weight: .medium) > Self.textWidth($1.name, size: 11.5, weight: .medium)
        }.prefix(3).map(\.id)
    }

    @Test(arguments: Set(ProviderID.aliases.values).sorted(), states)
    func everyProviderAndState(provider: String, state: String) async throws {
        let (meter, now) = try Self.makeMeter(provider: provider, state: state)
        try await check([meter], now: now)
    }

    @Test(arguments: ["runs out", "imminent", "comfortable", "mixed kinds", "mixed run outs", "unequal countdowns", "incident"])
    func visibleRowsShareTheLongestFittingForm(state: String) async throws {
        for providers in [["claude", "codex"], ["claude", "codex", "hermes"], Self.longestProviders] {
            var meters: [NotchIslandMeter] = []
            var now = Date(timeIntervalSince1970: UsageForecastSurfaceTests.stamp)
            for (index, provider) in providers.enumerated() {
                let rowState: String
                switch state {
                case "mixed kinds": rowState = index == 0 ? "comfortable" : "runs out"
                case "mixed run outs": rowState = index == 0 ? "imminent" : "runs out"
                case "unequal countdowns": rowState = "comfortable"
                case "incident": rowState = "runs out"
                default: rowState = state
                }
                let fixture = try Self.makeMeter(provider: provider, state: rowState)
                var meter = fixture.0
                now = fixture.1
                if state == "unequal countdowns" { meter.resetsAt = now.timeIntervalSince1970 + Double(index + 1) * 3600 }
                if state == "incident" { meter.incident = index == 1 }
                meters.append(meter)
            }
            try await check(meters, now: now)
        }
    }

    @Test func revealTicksKeepTheFitMeasurementsStable() async throws {
        let fixtures = try ["claude", "codex", "hermes"].map { try Self.makeMeter(provider: $0, state: "runs out") }
        let meters = fixtures.map { $0.0 }
        let now = try #require(fixtures.first?.1)
        let stage = NotchStageModel()
        stage.showContent(level: 1, expanded: true)
        var updates = 0
        var shown: [String: String] = [:]
        let card = NotchCardView(model: UsageForecastSurfaceTests.notchModel(), style: .island, width: 320)
        let rows = card.meterRows(meters, now: now)
            .environment(\.notchStage, stage)
            .onPreferenceChange(NotchMeterCaptionFitEvidence.self) { _ in updates += 1 }
            .onPreferenceChange(NotchMeterCaptionEvidence.self) { shown = $0 }
        let host = NSHostingView(rootView: rows)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 288, height: 72),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await drainMainQueue()
        }
        #expect(shown.count == 3)
        let settledUpdates = updates
        let settledCaptions = shown
        for frame in 0..<16 {
            stage.showContent(level: CGFloat(frame) / 15, expanded: true)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await drainMainQueue()
        }
        #expect(updates == settledUpdates)
        #expect(shown == settledCaptions)
        window.setContentSize(CGSize(width: 348, height: 72))
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await drainMainQueue()
        }
        for meter in meters {
            #expect(shown[meter.id] == NotchMeterCaption(meter: meter, now: now).forms.first)
        }
        #expect(updates > settledUpdates)
        #expect(!window.isVisible)
    }

    @Test(arguments: [false, true])
    func renderedCaptionsHaveTheSameTenPointGlyphSize(dark: Bool) async throws {
        let longest = Self.longestProviders
        for providers in [["claude", "codex"], ["claude", "codex", "hermes"], Array(longest.prefix(2)), longest] {
            let fixtures = try providers.map { try Self.makeMeter(provider: $0, state: "runs out") }
            let meters = fixtures.map { $0.0 }
            let now = try #require(fixtures.first?.1)
            let stage = NotchStageModel()
            stage.noteFace(expanded: true, settled: true)
            #expect(stage.sheet == .settled)
            var captions: [String: String] = [:]
            var fonts: [String: CGFloat] = [:]
            let card = NotchCardView(model: UsageForecastSurfaceTests.notchModel(), style: .island, width: 320)
            let rows = card.meterRows(meters, now: now)
                .frame(width: 288)
                .modifier(NotchSheetReveal())
                .background(.black)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.notchStage, stage)
                .onPreferenceChange(NotchMeterCaptionEvidence.self) { captions = $0 }
                .onPreferenceChange(NotchMeterCaptionFontEvidence.self) { fonts = $0 }
            let host = NSHostingView(rootView: rows)
            let size = CGSize(width: 288, height: CGFloat(meters.count) * 24)
            let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: size)
            defer { window.contentView = nil; window.close() }
            for _ in 0..<6 {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                await drainMainQueue()
            }
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // Only the caption is orange to the left of the fixed bar/percent columns.
            let glyphs = Self.captionGlyphBounds(bitmap, beforeX: 176 * 2)
            #expect(!window.isVisible)
            #expect(captions.count == meters.count)
            #expect(Set(captions.values).count == 1)
            #expect(fonts.values.allSatisfy { $0 == 10 }, "\(providers): selected fonts \(fonts)")
            #expect(glyphs.count == meters.count, "\(providers): caption bounds \(glyphs)")
            #expect(Set(glyphs.map(\.height)).count == 1, "\(providers): glyph heights \(glyphs)")
            #expect(Set(glyphs.map(\.width)).count == 1, "\(providers): glyph widths \(glyphs)")
            let text = try #require(captions.values.first)
            let reference = try ProofRender.render(Text(text).font(.system(size: 10)).monospacedDigit()
                .foregroundStyle(dark ? Color(red: 1, green: 159 / 255, blue: 10 / 255)
                    : Color(red: 1, green: 149 / 255, blue: 0)).fixedSize().background(.black),
                size: CGSize(width: 176, height: 24), dark: dark, settle: 0)
            let expected = try #require(Self.captionGlyphBounds(reference, beforeX: reference.pixelsWide).first)
            for glyph in glyphs {
                #expect(glyph.size == expected.size, "\(providers): rendered \(glyph.size), 10 pt reference \(expected.size)")
            }
        }
    }

    static func captionGlyphBounds(_ bitmap: NSBitmapImageRep, beforeX: Int) -> [CGRect] {
        var result: [CGRect] = []
        var bounds: CGRect?
        for y in 0..<bitmap.pixelsHigh {
            var xs: [Int] = []
            for x in 0..<min(beforeX, bitmap.pixelsWide) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8, color.greenComponent > 0.45, color.greenComponent < 0.75,
                   color.blueComponent < 0.15, color.alphaComponent > 0.8 { xs.append(x) }
            }
            if let first = xs.first, let last = xs.last {
                let line = CGRect(x: first, y: y, width: last - first + 1, height: 1)
                bounds = bounds.map { $0.union(line) } ?? line
            } else if let finished = bounds {
                result.append(finished)
                bounds = nil
            }
        }
        if let bounds { result.append(bounds) }
        return result
    }

    private static func makeMeter(provider: String, state: String) throws -> (NotchIslandMeter, Date) {
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
        return (meter, now)
    }

    private static func textWidth(_ text: String, size: CGFloat, weight: Font.Weight = .regular) -> CGFloat {
        NSHostingView(rootView: Text(text).font(.system(size: size, weight: weight)).monospacedDigit().fixedSize())
            .fittingSize.width
    }

    private func check(_ meters: [NotchIslandMeter], now: Date) async throws {
        let card = NotchCardView(model: UsageForecastSurfaceTests.notchModel(), style: .island, width: 320)
        for width: CGFloat in [288, 348] {
            var captions: [String: String] = [:]
            var widths: [String: CGFloat] = [:]
            var fonts: [String: CGFloat] = [:]
            let row = card.meterRows(meters, now: now)
                .frame(width: width)
                .onPreferenceChange(NotchMeterCaptionEvidence.self) { captions = $0 }
                .onPreferenceChange(NotchMeterCaptionWidthEvidence.self) { widths = $0 }
                .onPreferenceChange(NotchMeterCaptionFontEvidence.self) { fonts = $0 }
                .environment(\.renderSnapshot, true)
            let host = NSHostingView(rootView: row)
            let size = CGSize(width: width, height: CGFloat(meters.count) * 24)
            let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: width, height: size.height),
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
            var sharedForms: [NotchMeterCaption.Kind: Int] = [:]
            for meter in meters {
                let caption = NotchMeterCaption(meter: meter, now: now)
                guard caption.text != nil else { continue }
                let available = try #require(widths[meter.id])
                let fitting = caption.forms.firstIndex { Self.textWidth($0, size: 10) <= available + 0.5 }
                    ?? (caption.forms.count - 1)
                sharedForms[caption.kind] = max(sharedForms[caption.kind] ?? 0, fitting)
            }
            let runOutPrefixes = meters.compactMap { meter -> String? in
                guard NotchMeterCaption(meter: meter, now: now).kind == .runOut,
                      let text = captions[meter.id] else { return nil }
                return text.hasPrefix("Runs out ") ? "Runs out" : "Out"
            }
            #expect(Set(runOutPrefixes).count <= 1)
            for meter in meters {
                if NotchMeterCaption(meter: meter, now: now).text != nil {
                    let shown = try #require(captions[meter.id])
                    let available = try #require(widths[meter.id])
                    let font = try #require(fonts[meter.id])
                    let text = NSHostingView(rootView: Text(shown).font(.system(size: font)).monospacedDigit().fixedSize())
                    let caption = NotchMeterCaption(meter: meter, now: now)
                    #expect(caption.help.contains(try #require(caption.text)))
                    let shared = try #require(sharedForms[caption.kind])
                    #expect(shown == caption.forms[shared])
                    #expect(font == 10)
                    #expect(text.fittingSize.width <= available + 0.5,
                        "\(meter.provider), row \(width): '\(shown)' needs \(text.fittingSize.width), slot has \(available)")
                } else {
                    #expect(captions[meter.id] == nil)
                }
            }
        }
    }
}
