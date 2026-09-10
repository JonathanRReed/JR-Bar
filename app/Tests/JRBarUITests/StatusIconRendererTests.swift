import AppKit
import Testing
@testable import JRBarUI

@Suite("Status item icon renderer")
struct StatusIconRendererTests {
    static func pixels(_ image: NSImage) -> [UInt8] {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: rep.bitmapData, count: rep.bytesPerRow * 36))
    }

    @Test("every style renders an 18×18 image and they differ from each other")
    func styles() {
        let renderer = StatusIconRenderer()
        let glyph = renderer.image(for: StatusIconSpec(style: .glyph))
        let ring = renderer.image(for: StatusIconSpec(style: .glyphRing, ringFraction: 0.42))
        let label = renderer.image(for: StatusIconSpec(style: .glyphLabel))
        for image in [glyph, ring, label] {
            #expect(image.size == NSSize(width: 18, height: 18))
            #expect(image.isTemplate, "with no tint and no warning, images are templates")
        }
        #expect(Self.pixels(glyph) != Self.pixels(ring), "the ring changes the picture")
        #expect(Self.pixels(glyph) == Self.pixels(label), "the label style draws the same glyph; the text is the button's title")
        #expect(StatusIconRenderer.label(active: 2, needsYou: 1, ready: 0) == "1 ask · 2 working")
        #expect(StatusIconRenderer.label(active: 0, needsYou: 0, ready: 0) == nil)
        #expect(StatusIconRenderer.label(active: 1, needsYou: 2, ready: 3, failed: 1) == "2 asks · 1 failed · 1 working · 3 done")
    }

    @Test("the ring turns amber at 80 % and red at 95 %, which drops the template flag")
    func warnings() {
        let renderer = StatusIconRenderer()
        let calm = renderer.image(for: StatusIconSpec(style: .glyphRing, ringFraction: 0.5))
        let amber = renderer.image(for: StatusIconSpec(style: .glyphRing, ringFraction: 0.85))
        let red = renderer.image(for: StatusIconSpec(style: .glyphRing, ringFraction: 0.97))
        #expect(calm.isTemplate)
        #expect(!amber.isTemplate)
        #expect(!red.isTemplate)
        #expect(Self.pixels(amber) != Self.pixels(red))
        #expect(StatusIconSpec(style: .glyphRing, ringFraction: 0.8).ringWarning == .amber)
        #expect(StatusIconSpec(style: .glyphRing, ringFraction: 0.95).ringWarning == .red)
        #expect(StatusIconSpec(style: .glyph, ringFraction: 0.99).ringWarning == .none, "no ring, no warning")
        let tinted = renderer.image(for: StatusIconSpec(style: .glyph, tintHex: "#00E5FF"))
        #expect(!tinted.isTemplate)
        #expect(Self.pixels(tinted) != Self.pixels(renderer.image(for: StatusIconSpec(style: .glyph))))
    }

    @Test("images are cached by spec, with the ring fraction bucketed")
    func caching() {
        let renderer = StatusIconRenderer()
        let a = renderer.image(for: StatusIconSpec(style: .glyphRing, ringFraction: 0.421))
        let b = renderer.image(for: StatusIconSpec(style: .glyphRing, ringFraction: 0.429))
        let c = renderer.image(for: StatusIconSpec(style: .glyphRing, ringFraction: 0.50))
        #expect(a === b, "a 1 % move is the same bucket")
        #expect(a !== c)
        #expect(renderer.cachedCount == 2)
        #expect(renderer.image(for: StatusIconSpec(style: .glyph)) === renderer.image(for: StatusIconSpec(style: .glyph)))
    }

    @Test("the settings value maps in either spelling, and the default is the meters")
    func settingNames() {
        #expect(StatusIconStyle(setting: "glyph") == .glyph)
        #expect(StatusIconStyle(setting: "glyph_ring") == .glyphRing)
        #expect(StatusIconStyle(setting: "ring") == .glyphRing)
        #expect(StatusIconStyle(setting: "glyph_label") == .glyphLabel)
        #expect(StatusIconStyle(setting: "label") == .glyphLabel)
        #expect(StatusIconStyle(setting: "meters") == .meters)
        #expect(StatusIconStyle(setting: "meters_percent") == .metersPercent)
        #expect(StatusIconStyle(setting: "percent") == .metersPercent)
        #expect(StatusIconStyle(setting: nil) == .meters, "no setting means the useful one")
        #expect(StatusIconStyle(setting: "banana") == .meters)
        #expect(StatusIconStyle.meters.isMeters && StatusIconStyle.metersPercent.isMeters)
        #expect(!StatusIconStyle.glyph.isMeters)
    }
}

@Suite("Menu bar meters")
struct StatusMetersTests {
    static func meter(_ id: String, _ fraction: Double, approximate: Bool = false) -> StatusMeter {
        StatusMeter(id: id, name: id.capitalized, glyph: .symbol("circle"), fraction: fraction, approximate: approximate)
    }

    static func pixels(_ image: NSImage) -> [UInt8] {
        let width = Int(image.size.width * 2), height = Int(image.size.height * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: rep.bitmapData, count: rep.bytesPerRow * height))
    }

    @Test("the strip is menu-bar tall and grows one cell per provider")
    func sizeGrowsWithProviders() {
        let one = StatusIconRenderer.size(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.2)]))
        let two = StatusIconRenderer.size(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.2), Self.meter("codex", 0.5)]))
        let three = StatusIconRenderer.size(for: StatusIconSpec(style: .meters, meters: [
            Self.meter("claude", 0.2), Self.meter("codex", 0.5), Self.meter("gemini", 0.9),
        ]))
        #expect(one.height == StatusIconRenderer.barHeight)
        #expect(two.height == StatusIconRenderer.barHeight)
        #expect(two.width > one.width)
        #expect(three.width > two.width)
        // Every extra provider costs the same: one cell plus its gap.
        #expect(abs((two.width - one.width) - (three.width - two.width)) <= 1)
        #expect(one.width > StatusIconRenderer.size.width, "a metered strip is wider than the old square glyph")
    }

    @Test("the percent style is wider than the bare meters, and the overflow adds its own width")
    func widths() {
        let meters = [Self.meter("claude", 0.16), Self.meter("codex", 0.83)]
        let bare = StatusIconRenderer.size(for: StatusIconSpec(style: .meters, meters: meters))
        let percent = StatusIconRenderer.size(for: StatusIconSpec(style: .metersPercent, meters: meters))
        let overflow = StatusIconRenderer.size(for: StatusIconSpec(style: .meters, meters: meters, overflow: 3))
        #expect(percent.width > bare.width)
        #expect(overflow.width > bare.width)
        // Nothing to meter yet still leaves a mark to click on.
        #expect(StatusIconRenderer.size(for: StatusIconSpec(style: .meters)).width > 0)
    }

    @Test("a meter turns amber at 80 % and red at 95 %, which drops the template flag")
    func thresholds() {
        #expect(Self.meter("claude", 0.79).warning == .none)
        #expect(Self.meter("claude", 0.80).warning == .amber)
        #expect(Self.meter("claude", 0.94).warning == .amber)
        #expect(Self.meter("claude", 0.95).warning == .red)
        #expect(Self.meter("claude", 1.0).warning == .red)

        let renderer = StatusIconRenderer()
        let calm = renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.4)]))
        let amber = renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.85)]))
        let red = renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.97)]))
        #expect(calm.isTemplate, "a quiet strip follows the menu bar's own colour")
        #expect(!amber.isTemplate)
        #expect(!red.isTemplate)
        #expect(Self.pixels(amber) != Self.pixels(red))
        #expect(StatusIconSpec(style: .meters, meters: [Self.meter("a", 0.5), Self.meter("b", 0.97)]).meterWarning == .red,
                "the worst window sets the strip's warning")
        #expect(StatusIconSpec(style: .meters, meters: [Self.meter("a", 0.5), Self.meter("b", 0.85)]).meterWarning == .amber)
        #expect(StatusIconSpec(style: .meters, meters: [Self.meter("a", 0.5)]).meterWarning == .none)
    }

    @Test("a live state dot colours the strip; a quiet one leaves it a template")
    func stateDot() {
        let renderer = StatusIconRenderer()
        let meters = [Self.meter("claude", 0.3)]
        let idle = renderer.image(for: StatusIconSpec(style: .meters, meters: meters, dot: .idle))
        let working = renderer.image(for: StatusIconSpec(style: .meters, tintHex: "#00E5FF", meters: meters, dot: .working, phase: 0.5))
        let ask = renderer.image(for: StatusIconSpec(style: .meters, meters: meters, dot: .ask, phase: 0.5))
        let done = renderer.image(for: StatusIconSpec(style: .meters, meters: meters, dot: .done))
        #expect(idle.isTemplate)
        #expect(!working.isTemplate && !ask.isTemplate && !done.isTemplate)
        #expect(Self.pixels(working) != Self.pixels(ask))
        #expect(Self.pixels(ask) != Self.pixels(done))
        #expect(idle.size == working.size, "the dot never changes the width")
        #expect(StatusDotState.working.animates && StatusDotState.ask.animates)
        #expect(!StatusDotState.idle.animates && !StatusDotState.done.animates)
    }

    @Test("the breathing phase moves the picture but is bucketed, so 2 Hz costs three images")
    func breathing() {
        let renderer = StatusIconRenderer()
        let meters = [Self.meter("claude", 0.3)]
        func image(_ phase: Double) -> NSImage {
            renderer.image(for: StatusIconSpec(style: .meters, meters: meters, dot: .working, phase: phase))
        }
        #expect(Self.pixels(image(0)) != Self.pixels(image(0.5)))
        #expect(image(0.5) === image(0.51), "a phase inside the bucket is the same image")
        _ = image(0.25); _ = image(0.75)
        #expect(renderer.cachedCount <= 5)
        // A still dot ignores the phase entirely: one image, whatever the clock says.
        let quiet = StatusIconRenderer()
        #expect(quiet.image(for: StatusIconSpec(style: .meters, meters: meters, dot: .done, phase: 0.1))
                === quiet.image(for: StatusIconSpec(style: .meters, meters: meters, dot: .done, phase: 0.9)))
    }

    @Test("meters are cached by bucketed fraction, and a moved meter redraws")
    func caching() {
        let renderer = StatusIconRenderer()
        let a = renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.421)]))
        let b = renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.429)]))
        let c = renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.62)]))
        #expect(a === b)
        #expect(a !== c)
        #expect(renderer.cachedCount == 2)
    }

    @Test("the strip reads itself out for VoiceOver and the tooltip")
    func readout() {
        let spec = StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.16), Self.meter("codex", 0.83, approximate: true)],
                                  overflow: 2, dot: .ask)
        let label = StatusIconRenderer.accessibilityLabel(spec)
        #expect(label.contains("needs you"))
        #expect(label.contains("Claude 16 %"))
        #expect(label.contains("Codex ~83 %"))
        #expect(label.contains("2 more"))
        #expect(StatusIconRenderer.accessibilityLabel(StatusIconSpec(style: .glyph)) == "JR-Bar")
    }
}
