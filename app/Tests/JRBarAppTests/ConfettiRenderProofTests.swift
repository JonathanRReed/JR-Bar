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

    /// The burst as a person sees it, over a desktop under the menu bar:
    /// the pop's first beat, the cone at full spread, and Rest's ribbons
    /// lying on the band — each palette. Written to
    /// `JRBAR_RENDER_PROOF_DIR` (default `/tmp/jrbar-audit`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the confetti frames"))
    func onDesktop() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
                      ?? "/tmp/jrbar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let screenH = 700.0
        let frames: [(String, ConfettiLanding, TimeInterval)] = [
            ("pop", .rest, 0.12), ("spread", .rest, 0.55), ("fall", .rest, 1.2), ("rested", .rest, 3.6),
            ("fade", .fade, 1.1),
        ]
        for palette in ConfettiPalette.allCases {
            for (label, landing, at) in frames {
                var settings = ConfettiSettings(enabled: true)
                settings.landing = landing
                settings.palette = palette
                let viewHeight = ConfettiView.viewHeight(for: landing, screenHeight: screenH)
                var view = ConfettiView(color: ProviderStyle.style(for: "claude").accent, flash: false,
                                        settings: settings, viewHeight: viewHeight,
                                        screenHeight: screenH, bandBottom: 44)
                view.frozen = at
                let scene = ZStack(alignment: .top) {
                    ProofDesktop(dark: true)
                    Rectangle().fill(Color.black.opacity(0.22)).frame(height: 32)
                    UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8,
                                           style: .continuous)
                        .fill(.black).frame(width: 185, height: 32)
                    view.frame(width: 900, height: viewHeight)
                }
                .frame(width: 900, height: viewHeight)
                let renderer = ImageRenderer(content: scene)
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                let png = try #require(NSBitmapImageRep(cgImage: image)
                    .representation(using: .png, properties: [:]))
                try png.write(to: dir.appendingPathComponent("confetti-\(palette.rawValue)-\(label).png"))
            }
        }
    }
}
