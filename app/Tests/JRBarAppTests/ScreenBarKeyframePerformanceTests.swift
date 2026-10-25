import AppKit
import Darwin
import Foundation
import JRBarCore
import JRBarLEDS
import QuartzCore
import Testing
@testable import JRBarApp

@Suite("Screen Bar precomputed light", .serialized)
struct ScreenBarKeyframePerformanceTests {
    @Test("linked keyframes follow raw PWM light at every sampled instant")
    func transferredCurve() throws {
        let transfer = try #require(CoreStripTransfer(channelGains: [1, 0.38, 1]))
        let program = try LEDSProgram.parse("#10121F 250ms linear\n#000000 250ms linear\nrepeat", ledCount: 8)
        let sampler = LEDSSampler(program: program)
        let plan = try #require(ScreenBarLightTransfer.plan(sampler: sampler, transfer: transfer))
        for t in stride(from: 0, through: 1_500, by: 7) {
            let expected = ScreenBarLightTransfer.colors(sampler.rawCodes(atMilliseconds: t), brightness: sampler.brightness,
                                                         transfer: transfer)
            let actual = plan.codes(atMilliseconds: t).map(\.rgb)
            for (a, b) in zip(actual, expected) {
                #expect(abs(a.r - b.r) <= 2.0 / 255)
                #expect(abs(a.g - b.g) <= 2.0 / 255)
                #expect(abs(a.b - b.b) <= 2.0 / 255)
            }
        }
    }

    @Test("linked fades stay within two codes at Screen Bar brightness 30 through 40")
    func dimTransferredCurve() throws {
        let transfer = try #require(CoreStripTransfer(channelGains: [1, 0.38, 1]))
        for brightness in [30, 35, 40] {
            let text = "brightness \(brightness)\n#DB704D #2961CF #DB704D #2961CF #DB704D #2961CF #DB704D #2961CF\nroll-left 1s linear\nrepeat"
            let sampler = LEDSSampler(program: try LEDSProgram.parse(text, ledCount: 8))
            let plan = try #require(ScreenBarLightTransfer.plan(sampler: sampler, transfer: transfer))
            var worst = 0.0
            for t in 0...2_000 {
                let expected = ScreenBarLightTransfer.colors(sampler.rawCodes(atMilliseconds: t),
                                                             brightness: sampler.brightness, transfer: transfer)
                for (a, b) in zip(plan.codes(atMilliseconds: t).map(\.rgb), expected) {
                    worst = max(worst, abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
                }
            }
            #expect(worst <= 2.0 / 255, "brightness=\(brightness), error=\(worst * 255) codes")
        }
    }

    @Test("a busy linked gradient retries at two codes before falling back")
    func relaxedLinkedPlan() throws {
        let transfer = try #require(CoreStripTransfer(channelGains: [1, 0.38, 1]))
        let composed = LEDSComposer.compose(LEDSComposition(
            base: .gradient(RGB8(r: 255, g: 10, b: 150), RGB8(r: 10, g: 200, b: 255)),
            motion: .roll(periodMs: 1_000, leftward: true), brightness: 100))
        let sampler = LEDSSampler(program: try LEDSProgram.parse(composed.text, ledCount: 8))
        let strict = try #require(LEDSKeyframePlan.render(sampler: sampler, tolerance: 1,
            maxKeyframes: .max, sampleColors: { t in
                ScreenBarLightTransfer.colors(sampler.rawCodes(atMilliseconds: t),
                                              brightness: sampler.brightness, transfer: transfer)
            }))
        #expect(strict.keyframeCount > LEDSKeyframePlan.defaultMaxKeyframes)
        let plan = try #require(ScreenBarLightTransfer.plan(sampler: sampler, transfer: transfer))
        #expect(plan.keyframeCount <= LEDSKeyframePlan.defaultMaxKeyframes)
        var worst = 0.0
        for t in 0...2_000 {
            let expected = ScreenBarLightTransfer.colors(sampler.rawCodes(atMilliseconds: t),
                                                         brightness: sampler.brightness, transfer: transfer)
            for (a, b) in zip(plan.codes(atMilliseconds: t).map(\.rgb), expected) {
                worst = max(worst, abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
            }
        }
        #expect(worst <= 2.0 / 255)
    }

    @MainActor
    final class GradientGate {
        var pending: CheckedContinuation<ScreenBarGradientFrames, Never>?
        var request: (LEDSKeyframePlan, CGFloat, Bool)?
        func render(_ plan: LEDSKeyframePlan, _ width: CGFloat, _ reduced: Bool) async -> ScreenBarGradientFrames {
            request = (plan, width, reduced)
            return await withCheckedContinuation { pending = $0 }
        }
        func finish() {
            guard let request, let pending else { return }
            self.pending = nil
            pending.resume(returning: ScreenBarGradientFrames.build(plan: request.0, width: request.1, reduced: request.2))
        }
        func started() async {
            for _ in 0..<1_000 {
                if pending != nil { return }
                await Task.yield()
            }
            Issue.record("gradient worker did not reach its gate")
        }
    }

    @MainActor
    @Test("the 60 Hz fallback runs until gradient animation installation")
    func gradientHandoff() async throws {
        let gate = GradientGate()
        let controller = ScreenBarController(reduceMotionOverride: false,
            gradientRenderer: { await gate.render($0, $1, $2) })
        controller.apply(programText: "#10121F 250ms linear\n#000000 250ms linear\nrepeat")
        controller.show()
        defer { gate.finish(); controller.hide() }
        await gate.started()
        #expect(controller.keyframesRunning && !controller.keyframesInstalled)
        #expect(controller.clockRunning)
        #expect(controller.fallbackFrameRate?.preferred == 60)
        #expect(controller.fallbackFrameRate?.minimum == 24)
        gate.finish()
        await controller.waitForPlanBuilds()
        #expect(controller.keyframesInstalled && !controller.clockRunning)
    }

    @MainActor
    @Test("fallback frames preserve a pending gradient and stopping rejects its late installation")
    func pendingGradientFrames() async throws {
        let gate = GradientGate()
        let sampler = LEDSSampler(program: try LEDSProgram.parse("#10121F 250ms linear\n#000000 250ms linear\nrepeat", ledCount: 8))
        let plan = try #require(LEDSKeyframePlan.render(sampler: sampler))
        let view = ScreenBarView(frame: CGRect(x: 0, y: 0, width: 220, height: 24))
        view.relayout()
        view.gradientRenderer = { await gate.render($0, $1, $2) }
        view.play(plan: plan, anchor: CACurrentMediaTime())
        await gate.started()
        view.display(colors: [RGB(r: 1, g: 0, b: 0)], preservingPendingKeyframes: true)
        #expect(view.isPlayingKeyframes && !view.keyframesInstalled)
        view.stopKeyframes()
        gate.finish()
        await view.waitForKeyframes()
        #expect(!view.isPlayingKeyframes && !view.keyframesInstalled)
        #expect((view.layer?.sublayers ?? []).allSatisfy { $0.animationKeys()?.isEmpty != false })
    }

    @Test("uniform keyframe stops share immutable colours")
    func uniformColorsShareStorage() {
        let codes = Array(repeating: RGB8(r: 77, g: 112, b: 191), count: 8)
        let plan = LEDSKeyframePlan(lead: nil, loop: nil, loopStartMs: 0, finalCodes: codes)
        let frames = ScreenBarGradientFrames.build(plan: plan, width: 220, reduced: false)
        #expect(frames.rest.count > 50)
        let objects = Set(frames.rest.map { ObjectIdentifier($0) })
        #expect(objects.count == 1)
    }

    @MainActor
    @Test("layer keyframes install offscreen and stop without a frame clock")
    func layerPlayback() async throws {
        let sampler = LEDSSampler(program: try LEDSProgram.parse("#10121F 250ms linear\n#000000 250ms linear\nrepeat", ledCount: 8))
        let plan = try #require(LEDSKeyframePlan.render(sampler: sampler))
        let view = ScreenBarView(frame: CGRect(x: 0, y: 0, width: 220, height: 12))
        view.relayout()
        view.play(plan: plan, anchor: CACurrentMediaTime())
        await view.waitForKeyframes()
        #expect(view.isPlayingKeyframes)
        let layers = view.layer?.sublayers ?? []
        let hasAnimations = layers.contains { $0.animationKeys()?.isEmpty == false }
        #expect(hasAnimations == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        view.stopKeyframes()
        #expect(!view.isPlayingKeyframes)
        #expect(layers.allSatisfy { $0.animationKeys()?.isEmpty != false })
    }

    @MainActor
    @Test("linked playback hands off the fallback clock at the hardware anchor")
    func linkedController() async throws {
        let controller = ScreenBarController(reduceMotionOverride: false)
        let transfer = try #require(CoreStripTransfer(channelGains: [1, 0.38, 1]))
        let epoch = Date().timeIntervalSince1970 - 0.2
        controller.apply(programText: "#10121F 250ms linear\n#000000 250ms linear\nrepeat",
                         anchorEpoch: epoch, stripTransfer: transfer)
        controller.show()
        defer { controller.hide() }
        await controller.waitForPlanBuilds()
        #expect(controller.keyframesRunning)
        #expect(!controller.clockRunning)
        #expect(controller.programAnchorEpoch == epoch)
        controller.hide()
        #expect(!controller.clockRunning && !controller.keyframesRunning)
    }

    private func cpu() -> Double {
        var stamp = timespec()
        precondition(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &stamp) == 0)
        return Double(stamp.tv_sec) + Double(stamp.tv_nsec) / 1e9
    }

    @MainActor
    @Test("ten seconds of linked light uses layer playback",
          .enabled(if: ProcessInfo.processInfo.environment["JRBAR_PERF_ISOLATED"] == "1"))
    func playbackCost() async throws {
        let transfer = try #require(CoreStripTransfer(channelGains: [1, 0.38, 1]))
        let sampler = LEDSSampler(program: try LEDSProgram.parse("#10121F 250ms linear\n#000000 250ms linear\nrepeat", ledCount: 8))
        let view = ScreenBarView(frame: CGRect(x: 0, y: 0, width: 220, height: 12))
        view.relayout()
        let plan = try #require(ScreenBarLightTransfer.plan(sampler: sampler, transfer: transfer))
        // Virtual display ticks cover ten seconds without waiting on a
        // display or putting a window on the desktop. This times CPU work,
        // not compositor work or ten seconds of elapsed playback.
        for run in 0..<5 {
            let start = cpu()
            for tick in 0..<600 {
                let codes = sampler.rawCodes(atMilliseconds: tick * 1_000 / 60)
                view.display(colors: ScreenBarLightTransfer.colors(codes, brightness: sampler.brightness, transfer: transfer))
            }
            let legacy = cpu() - start
            let install = cpu()
            view.play(plan: plan, anchor: CACurrentMediaTime())
            await view.waitForKeyframes()
            let setup = cpu() - install
            #expect(view.isPlayingKeyframes)
            print("PERF screen run=\(run) virtual_seconds=10 legacy_callbacks=600 playback_callbacks=0 legacy_main_cpu_seconds=\(legacy) setup_main_cpu_seconds=\(setup)")
            view.stopKeyframes()
        }
    }

    @MainActor
    @Test("linked light retains its gradient in an offscreen render",
          .enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func linkedRender() async throws {
        let transfer = try #require(CoreStripTransfer(channelGains: [1, 0.38, 1]))
        let sampler = LEDSSampler(program: try LEDSProgram.parse("#10121F", ledCount: 8))
        let plan = try #require(ScreenBarLightTransfer.plan(sampler: sampler, transfer: transfer))
        let view = ScreenBarView(frame: CGRect(x: 0, y: 0, width: 220, height: 24))
        view.relayout()
        view.play(plan: plan, anchor: CACurrentMediaTime())
        await view.waitForKeyframes()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
        try data.write(to: ProofRender.directory.appendingPathComponent("screen-bar-linked-keyframes.png"))
        view.stopKeyframes()
    }

    @Test("visibility parks occluded fallback clocks")
    func occlusion() {
        var visibility = ScreenBarVisibility()
        visibility.shown = true
        #expect(visibility.live)
        visibility.occluded = true
        #expect(!visibility.live)
    }
}
