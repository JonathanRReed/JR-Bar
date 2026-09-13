import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// Render proof for the Confetti work: freeze a burst ~0.9 s in and
/// write one 2× PNG per landing mode × palette to
/// `/tmp/confetti-proof`. Manual evidence for the review, not a golden
/// test — the pieces are a fresh roll every run. It only runs when
/// `JRBAR_RENDER_PROOF=1` is in the environment, so the regular suite
/// never writes files.
@Suite("Confetti render proof")
@MainActor
struct ConfettiRenderProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write /tmp/confetti-proof PNGs"))
    func snapshots() throws {
        let dir = URL(fileURLWithPath: "/tmp/confetti-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let screenH = 900.0
        var written: [String] = []
        for landing in ConfettiLanding.allCases {
            for palette in ConfettiPalette.allCases {
                var settings = ConfettiSettings(enabled: true)
                settings.landing = landing
                settings.palette = palette
                let viewHeight = ConfettiView.viewHeight(for: landing, screenHeight: screenH)
                var view = ConfettiView(color: ConfettiView.toysTint, flash: false,
                                        settings: settings, viewHeight: viewHeight,
                                        screenHeight: screenH, bandBottom: 44)
                view.frozen = 0.9
                let renderer = ImageRenderer(content: view.frame(width: 1440, height: viewHeight))
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    Issue.record("render failed for \(landing.rawValue)/\(palette.rawValue)")
                    continue
                }
                let name = "confetti-\(landing.rawValue)-\(palette.rawValue).png"
                try png.write(to: dir.appendingPathComponent(name))
                written.append(name)
            }
        }
        #expect(written.count == 9)
    }
}
