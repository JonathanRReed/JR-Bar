import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// What a burst costs to draw: 60 frames across its life rasterized
/// through `ImageRenderer` into a 2× bitmap of Jonathan's 1512 × 982
/// screen, the method the design doc measured the old burst with. The
/// budgets are Standard p90 ≤ 3.5 ms and Big ≤ 5 ms a frame on the dev
/// Mac. Offline raster only approximates the live path (the card quotes
/// the live one, measured), and a busy Mac reads slow — so it runs only
/// with `JRBAR_PERF_PROOF=1`, on its own: never in the everyday suite,
/// and not alongside the render proofs, whose drawing would crowd its
/// timings over budget.
///
/// The provider rows pin the heavy marks (Hermes' 882 segments, Devin's):
/// a mark is rastered once a burst into a template image, so a burst of
/// them must cost what a burst of plain letters does — the `pi` case is
/// that baseline. Glyphs-only draws every piece as a mark or letter, so
/// its budget is the letter baseline's own ~6 ms at Big, not the mixed
/// recipe's.
@Suite("Confetti perf proof", .serialized)
@MainActor
struct ConfettiPerfProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_PERF_PROOF"] == "1",
                   "set JRBAR_PERF_PROOF=1 to time the confetti frames"),
          arguments: [
              ("claude", ConfettiIntensity.standard, ConfettiShapes.mixed, 3.5),
              ("claude", .big, .mixed, 5.0),
              ("hermes", .big, .mixed, 5.0),
              ("devin", .big, .mixed, 5.0),
              ("hermes", .big, .glyphs, 9.0),
              ("devin", .big, .glyphs, 9.0),
              ("pi", .big, .glyphs, 9.0),
          ])
    func frameCost(provider: String, intensity: ConfettiIntensity, shapes: ConfettiShapes,
                   budget: Double) throws {
        let look = ConfettiView.look(.provider, tint: ProviderStyle.style(for: provider).accent,
                                     provider: provider)
        var recipe = ConfettiRenderProofTests.recipe(.notch, .rest, look: look, shapes: shapes)
        recipe.intensity = intensity
        let burst = ConfettiBurst(stage: ConfettiRenderProofTests.laptop(), recipe: recipe, seed: 11)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        // Like the overlay: the burst's glyphs are set once and kept.
        let marks = ConfettiMarks()
        func frame(at time: Double) throws -> Double {
            var view = ConfettiView(burst: burst, look: look, flash: false, marks: marks)
            view.frozen = time
            let context = try #require(CGContext(data: nil, width: 3024, height: 1964, bitsPerComponent: 8,
                                                 bytesPerRow: 0, space: space,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: 2, y: 2)
            let renderer = ImageRenderer(content: view.frame(width: 1512, height: 982))
            let start = DispatchTime.now().uptimeNanoseconds
            renderer.render { _, draw in draw(context) }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        _ = try frame(at: 0.5)
        var times: [Double] = []
        for step in 0..<60 { times.append(try frame(at: 0.15 + Double(step) * 0.06)) }
        times.sort()
        let p50 = times[30], p90 = times[54]
        print(String(format: "confetti perf %@ %@ %@: %d pieces, p50 %.2f ms, p90 %.2f ms a frame at 2× (budget %.1f ms)",
                     provider, intensity.rawValue, shapes.rawValue, burst.pieces.count, p50, p90, budget))
        #expect(p90 <= budget, "\(provider)/\(shapes.rawValue) \(intensity) p90 \(p90) ms is over its \(budget) ms budget")
    }
}
