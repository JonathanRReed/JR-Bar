import Foundation
import JRBarCore
import QuartzCore
import Testing
@testable import JRBarApp

/// The panels hung from the notch share one curve and one fade helper;
/// their own timings stay theirs. No panel is ordered in here.
@Suite("Notch surface motion")
@MainActor
struct NotchSurfaceMotionTests {
    @Test("the shared curve is the one the surfaces used to paste")
    func sharedCurve() {
        let curve = NotchMotion.panelCurve
        #expect(curve.x1 == 0.2 && curve.y1 == 0.9 && curve.x2 == 0.3 && curve.y2 == 1.0)
        let timing = NotchSurfaceMotion.panelCurve
        var first = [Float](repeating: 0, count: 2)
        var second = [Float](repeating: 0, count: 2)
        timing.getControlPoint(at: 1, values: &first)
        timing.getControlPoint(at: 2, values: &second)
        #expect(first == [0.2, 0.9])
        #expect(second == [0.3, 1.0])
    }

    @Test("the notch's own panels no longer paste the curve")
    func noPastedCurves() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp")
        for file in ["NotchHUD.swift", "ScreenBarPeek.swift", "ScreenBarController.swift",
                     "Toys/Notch/NotchCardPanel.swift"] {
            let text = try String(contentsOf: sources.appending(path: file), encoding: .utf8)
            #expect(!text.contains("controlPoints: 0.2, 0.9, 0.3, 1.0"), "\(file) reads NotchSurfaceMotion.panelCurve")
            #expect(text.contains("NotchSurfaceMotion."), "\(file) fades through the shared helper")
        }
    }
}
