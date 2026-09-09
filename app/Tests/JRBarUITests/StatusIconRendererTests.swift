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

    @Test("the settings value maps in either spelling")
    func settingNames() {
        #expect(StatusIconStyle(setting: "glyph") == .glyph)
        #expect(StatusIconStyle(setting: "glyph_ring") == .glyphRing)
        #expect(StatusIconStyle(setting: "ring") == .glyphRing)
        #expect(StatusIconStyle(setting: "glyph_label") == .glyphLabel)
        #expect(StatusIconStyle(setting: "label") == .glyphLabel)
        #expect(StatusIconStyle(setting: nil) == .glyph)
        #expect(StatusIconStyle(setting: "banana") == .glyph)
    }
}
