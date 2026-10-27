import CoreGraphics
import Foundation
import Testing
@testable import JRBarApp

/// The Duo's hidden still-capture switch: off until a person sets the key,
/// never for the Room, and a fresh preferences domain says off. Then the
/// size and colour space a stream films in.
@Suite("Fold capture mode")
struct FoldCaptureModeTests {
    private func defaults(_ body: (UserDefaults) -> Void) {
        let name = "devin.jrbar.test.foldcapture.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        body(suite)
        suite.removePersistentDomain(forName: name)
    }

    @Test("the live stream is the default; the still stays off until the key is set")
    func offByDefault() {
        defaults { suite in
            #expect(!FoldCaptureMode.stillWanted(defaults: suite, dual: false))
            suite.set(false, forKey: FoldCaptureMode.stillKey)
            #expect(!FoldCaptureMode.stillWanted(defaults: suite, dual: false))
            suite.set(true, forKey: FoldCaptureMode.stillKey)
            #expect(FoldCaptureMode.stillWanted(defaults: suite, dual: false))
        }
        #expect(FoldCaptureMode.stillKey == "jrbar.foldStillCapture")
    }

    @Test("the Room's two streams never turn into a still")
    func roomIgnoresIt() {
        defaults { suite in
            suite.set(true, forKey: FoldCaptureMode.stillKey)
            #expect(!FoldCaptureMode.stillWanted(defaults: suite, dual: true))
        }
    }

    /// One display as a capture filter reports it: its size in points and
    /// its point-to-pixel scale, and the backing store the overlay draws.
    private struct Display {
        let points: CGSize
        let scale: Double
        var backing: CGSize { CGSize(width: points.width * scale, height: points.height * scale) }
    }

    @Test("the Duo films the display's own backing pixels at 1x and 2x, the overlay's drawable size")
    func duoFilmsBackingPixels() {
        let displays: [Display] = [
            Display(points: CGSize(width: 1512, height: 982), scale: 2),    // 14-inch Retina default
            Display(points: CGSize(width: 1800, height: 1169), scale: 2),   // the same panel at More Space
            Display(points: CGSize(width: 1728, height: 1117), scale: 2),   // 16-inch Retina default
            Display(points: CGSize(width: 1440, height: 900), scale: 1),    // a 1x panel
            Display(points: CGSize(width: 1512, height: 982), scale: 1),
        ]
        for display in displays {
            let size = FoldCapture.streamSize(points: display.points,
                                              pointPixelScale: display.scale, dual: false)
            #expect(size == display.backing,
                    "\(display.points) at \(display.scale)x films \(size), backing \(display.backing)")
        }
        // The bug this pins: 1512x982 points on a 3024x1964 panel.
        let retina = FoldCapture.streamSize(points: CGSize(width: 1512, height: 982),
                                            pointPixelScale: 2, dual: false)
        #expect(retina == CGSize(width: 3024, height: 1964))
        // A scale nobody reported never shrinks the picture under 1x.
        let unknown = FoldCapture.streamSize(points: CGSize(width: 1512, height: 982),
                                             pointPixelScale: .nan, dual: false)
        #expect(unknown == CGSize(width: 1512, height: 982))
    }

    @Test("the Room keeps its earlier size: points, capped at 2560 on the long edge")
    func roomKeepsItsSize() {
        let retina = FoldCapture.streamSize(points: CGSize(width: 1512, height: 982),
                                            pointPixelScale: 2, dual: true)
        #expect(retina == CGSize(width: 1512, height: 982))
        let wide = FoldCapture.streamSize(points: CGSize(width: 3200, height: 1800),
                                          pointPixelScale: 1, dual: true)
        #expect(wide == CGSize(width: 2560, height: 1440))
    }

    @Test("a wide-gamut panel folds in Display P3, any other in sRGB")
    func colourFollowsThePanel() {
        #expect(FoldColour.spaceName(wideGamut: true) == CGColorSpace.displayP3)
        #expect(FoldColour.spaceName(wideGamut: false) == CGColorSpace.sRGB)
    }
}
