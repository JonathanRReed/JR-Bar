import AppKit
import Foundation
import Testing
@testable import JRBarUI

@Suite("Quota notice render proof")
@MainActor
struct QuotaNoticeRenderProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func spentQuotaHasNormalMenuInk() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/jrbar-quota-proof")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let appearance = try #require(NSAppearance(named: .aqua))
        for (name, fraction, verdict) in [
            ("spent", 1.0, StatusMeter.PaceVerdict.exhausted),
            ("near-limit", 0.95, StatusMeter.PaceVerdict.runsOut)
        ] {
            let canvas = NSImage(size: NSSize(width: 340, height: 70))
            appearance.performAsCurrentDrawingAppearance {
                canvas.lockFocus()
                NSColor.white.setFill()
                NSRect(x: 0, y: 0, width: 340, height: 70).fill()
                let renderer = StatusIconRenderer()
                let meter = StatusMeter(id: "claude", name: "Claude", glyph: .symbol("circle"),
                                        fraction: fraction, paceVerdict: verdict)
                for (index, style) in [StatusIconStyle.metersPercent, .compactPercent, .glyphRing].enumerated() {
                    let spec = StatusIconSpec(style: style, ringFraction: fraction, meters: [meter])
                    let image = renderer.image(for: spec)
                    let x = CGFloat(14 + index * 110)
                    let width = image.size.width * 2
                    let height = image.size.height * 2
                    image.draw(in: NSRect(x: x, y: 18, width: width, height: height))
                }
                canvas.unlockFocus()
            }
            let tiff = try #require(canvas.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("quota-\(name).png"))
        }
    }
}
