import JRBarTestSupport
import AppKit
@testable import JRBarCore
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Notch caption fit proofs", .serialized, .renderProofAppearance)
@MainActor
struct NotchMeterCaptionRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled),
        arguments: [false, true], ["2-rows", "3-rows", "longest-2-rows", "longest-3-rows"])
    func settledCard(dark: Bool, fixture: String) throws {
        let rows = fixture.contains("2-rows") ? 2 : 3
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let at = try #require(calendar.nextDate(after: now.addingTimeInterval(3600),
            matching: DateComponents(hour: 23, minute: 5), matchingPolicy: .nextTime))
        let providers = fixture.hasPrefix("longest")
            ? NotchMeterCaptionFitTests.longestProviders : ["claude", "codex", "hermes"]
        let ids = Array(providers.prefix(rows))
        let usage = ids.map {
            CoreProviderUsage(id: $0, windows: [CoreUsageWindow(name: "5h", usedPct: 70,
                resetsAt: at.timeIntervalSince1970 + 4 * 3600)],
                forecast: CoreUsageForecast(exhaustsAt: at.timeIntervalSince1970, pace: "ahead", ratePctPerHour: 15))
        }
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-notch-fit-proof.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(sessions: ids.map {
            CoreSession(id: $0 + ":fixture", provider: $0, label: "Sample task", mode: "working")
        }, usage: CoreUsage(providers: usage))))
        let model = UsageForecastSurfaceTests.notchModel()
        model.focus = ScreenBarFocus(style: ProviderStyle.style(for: "claude"),
            label: "Sample task", word: "Working", clickSession: nil)
        model.rows = NotchIsland.summarize(core.sessions).rows
        model.meters = UsageCenterStore.notchMeters(core: core, now: now)
        #expect(model.meters.count == rows)
        #expect(model.meters.allSatisfy { NotchMeterCaption(meter: $0, now: now).tone == .attention })
        model.pinned = true
        defer { model.pinned = false }
        let stage = NotchStageModel()
        stage.noteFace(expanded: true, settled: true)
        #expect(stage.sheet == .settled)
        let card = NotchCardView(model: model, style: .island, width: 320, stillTurn: 1, stillReduced: true)
        let face = VStack(spacing: 0) {
            Color.clear.frame(height: 36)
            card
        }
        .frame(width: 320)
        .background(NotchSilhouette(notchDepth: 32, restingRadius: 8, notchWidth: 185).fill(.black))
        var captions: [String: String] = [:]
        var widths: [String: CGFloat] = [:]
        var fonts: [String: CGFloat] = [:]
        let scene = face.padding(20).background(Color(white: dark ? 0.18 : 0.87))
            .onPreferenceChange(NotchMeterCaptionEvidence.self) { captions = $0 }
            .onPreferenceChange(NotchMeterCaptionWidthEvidence.self) { widths = $0 }
            .onPreferenceChange(NotchMeterCaptionFontEvidence.self) { fonts = $0 }
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.notchStage, stage)
            .environment(\.renderSnapshot, true)
        let size = CGSize(width: 360, height: 1)
        let name = "notch-caption-size-\(fixture)-\(dark ? "dark" : "light")"
        try ProofRender.write(scene, size: size, name: name, dark: dark)
        let data = try Data(contentsOf: ProofRender.directory.appendingPathComponent(name + ".png"))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        var headerInk = 0
        for y in Int(66 * scale)..<Int(81 * scale) {
            for x in Int(71 * scale)..<Int(155 * scale) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.alphaComponent > 0.8, color.redComponent > 0.8,
                   color.greenComponent > 0.8, color.blueComponent > 0.8 {
                    headerInk += 1
                }
            }
        }
        #expect(headerInk > 10, "The offscreen proof must paint the card's header")
        #expect(captions.count == rows)
        #expect(Set(captions.values).count == 1)
        let glyphs = NotchMeterCaptionFitTests.captionGlyphBounds(bitmap, beforeX: Int(218 * scale))
            .filter { $0.width > 30 }
        #expect(glyphs.count == rows)
        #expect(Set(glyphs.map(\.height)).count == 1, "Rendered caption bounds: \(glyphs)")
        #expect(Set(glyphs.map(\.width)).count == 1, "Rendered caption bounds: \(glyphs)")
        for meter in model.meters {
            let text = try #require(captions[meter.id])
            let width = try #require(widths[meter.id])
            let font = try #require(fonts[meter.id])
            #expect(font == 10)
            let measured = NSHostingView(rootView: Text(text).font(.system(size: font)).monospacedDigit().fixedSize())
            #expect(measured.fittingSize.width <= width + 0.5)
        }
    }
}
