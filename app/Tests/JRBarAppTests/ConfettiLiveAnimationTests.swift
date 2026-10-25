import AppKit
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Confetti live animation", .serialized)
struct ConfettiLiveAnimationTests {
    private nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["JRBAR_CONFETTI_LIVE_PROOF"] == "1"
            && ProcessInfo.processInfo.environment["JRBAR_INTERACTIVE_TESTS"] == "1"
    }

    private final class Draws {
        var count = 0
    }

    private final class OffscreenPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private enum ProofError: Error {
        case controlUnavailable
    }

    @Test("live confetti continues drawing with a ticking native Canvas control", .enabled(if: enabled))
    func liveFramesContinue() async throws {
        let meter = ConfettiDrawMeter()
        let control = Draws()
        let settings = ConfettiSettings()
        let shot = ConfettiShot(provider: nil, tint: .red, moment: .plain)
        let plan = ConfettiToy.plan(settings, shot: shot, densityScale: 1, everyone: [], season: nil)
        let burst = ConfettiBurst(stage: .reference, recipe: plan.recipe, seed: 17)
        let content = HStack(spacing: 0) {
            ConfettiView(burst: burst, look: plan.look, flash: false, meter: meter, marks: ConfettiMarks())
                .frame(width: 600, height: 400)
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                let tick = context.date.timeIntervalSince1970
                Canvas { canvas, size in
                    control.count += 1
                    let phase = tick.truncatingRemainder(dividingBy: 1)
                    let rect = CGRect(x: phase * max(0, size.width - 10), y: 0, width: 10, height: 10)
                    canvas.fill(Path(rect), with: .color(.blue))
                }
                .frame(width: 40, height: 400)
            }
        }
        let hosting = NSHostingView(rootView: content)
        let frame = NSRect(x: -30000, y: -30000, width: 640, height: 400)
        let panel = OffscreenPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        defer {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        panel.setFrame(frame, display: false)
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(panel.frame) }) else {
            print("CONTROL_UNAVAILABLE: AppKit did not retain the offscreen frame")
            throw ProofError.controlUnavailable
        }
        WindowPresenter.automatic.order(panel)
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(panel.frame) }) else {
            panel.orderOut(nil)
            print("CONTROL_UNAVAILABLE: AppKit moved the panel onto a display")
            throw ProofError.controlUnavailable
        }
        hosting.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()

        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: .seconds(2))
        var earlyControl: Int?
        var earlyConfetti: Int?
        while clock.now < deadline, !Task.isCancelled {
            if clock.now >= started.advanced(by: .milliseconds(500)), earlyControl == nil {
                earlyControl = control.count
                earlyConfetti = meter.summary()?.frames ?? 0
            }
            await Task.yield()
        }
        let controlFrames = control.count
        let confettiFrames = meter.summary()?.frames ?? 0
        print("CONFETTI_LIVE_PROOF control=\(earlyControl ?? 0)->\(controlFrames) confetti=\(earlyConfetti ?? 0)->\(confettiFrames)")
        guard let earlyControl, controlFrames > earlyControl + 2 else {
            print("CONTROL_UNAVAILABLE: offscreen native animation did not keep drawing")
            throw ProofError.controlUnavailable
        }
        let early = try #require(earlyConfetti)
        #expect(confettiFrames > early + 2,
                "The native Canvas control kept drawing, but live Confetti stopped after its initial frames")
    }
}
