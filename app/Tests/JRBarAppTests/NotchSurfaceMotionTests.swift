import AppKit
import JRBarCore
import QuartzCore
import Testing
@testable import JRBarApp

/// The panels hung from the notch share one curve and one fade helper;
/// their own timings stay theirs. No panel is ordered in here.
@Suite("Notch surface motion")
@MainActor
struct NotchSurfaceMotionTests {
    private final class Panel: NSPanel {
        var ordersOut = 0
        override func orderFrontRegardless() {}
        override func orderOut(_ sender: Any?) { ordersOut += 1 }
    }

    @Test("an old dismiss cannot retire a reopened panel, even at zero alpha")
    func reopenedPanelRejectsOldDismiss() {
        let panel = Panel()
        var finish: (() -> Void)?
        var retired = false
        NotchSurfaceMotion.dismiss(panel, duration: 1, reducedDuration: 1,
                                   animate: { _, completion in finish = completion },
                                   then: { retired = true })
        NotchSurfaceMotion.present(panel, from: 0, duration: 0, reducedDuration: 0)
        panel.alphaValue = 0
        finish?()
        #expect(panel.ordersOut == 0)
        #expect(!retired)
    }

    @Test("only the newest dismiss can retire a panel that was hidden twice")
    func newerDismissOwnsCompletion() {
        let panel = Panel()
        var finishes: [() -> Void] = []
        NotchSurfaceMotion.dismiss(panel, duration: 1, reducedDuration: 1, stillGone: { true },
                                   animate: { _, completion in finishes.append(completion) })
        NotchSurfaceMotion.present(panel, duration: 0, reducedDuration: 0)
        NotchSurfaceMotion.dismiss(panel, duration: 1, reducedDuration: 1, stillGone: { true },
                                   animate: { _, completion in finishes.append(completion) })
        finishes[0]()
        #expect(panel.ordersOut == 0)
        finishes[1]()
        #expect(panel.ordersOut == 1)
    }

    @Test("another panel's transition does not cancel this panel's dismissal")
    func panelsHaveIndependentTransitions() {
        let panel = Panel()
        let other = Panel()
        var finish: (() -> Void)?
        NotchSurfaceMotion.dismiss(panel, duration: 1, reducedDuration: 1, stillGone: { true },
                                   animate: { _, completion in finish = completion })
        NotchSurfaceMotion.present(other, duration: 0, reducedDuration: 0)
        finish?()
        #expect(panel.ordersOut == 1)
        #expect(other.ordersOut == 0)
    }

    @Test("the current dismiss still respects its owner's visibility guard")
    func visibilityGuardStillApplies() {
        let panel = Panel()
        var finish: (() -> Void)?
        NotchSurfaceMotion.dismiss(panel, duration: 1, reducedDuration: 1, stillGone: { false },
                                   animate: { _, completion in finish = completion })
        finish?()
        #expect(panel.ordersOut == 0)
    }

    @Test("a directly recast shadow's fade invalidates its previous dismissal")
    func directFadeRejectsOldDismiss() {
        let panel = Panel()
        var finish: (() -> Void)?
        NotchSurfaceMotion.dismiss(panel, duration: 1, reducedDuration: 1,
                                   animate: { _, completion in finish = completion })
        NotchSurfaceMotion.fade(panel, to: 1, duration: 0, reducedDuration: 0, curve: nil)
        panel.alphaValue = 0
        finish?()
        #expect(panel.ordersOut == 0)
    }

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
