import JRBarTestSupport
import AppKit
import Darwin
import Foundation
import JRBarCore
import JRBarLEDS
import QuartzCore
import Testing
@testable import JRBarApp

@Suite("Screen Bar precomputed light", .serialized, .renderProofAppearance)
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

    /// The program One at a Time plays for a working provider, as the daemon
    /// sent it on 2026-11-14: three dim lit LEDs rolling across eight, six
    /// two-second rolls a pass. With the owner's calibration the band played
    /// it from the 60 Hz frame clock.
    static let rollingWork = """
        brightness 141
        #0E040A #0E050D #0A040E #000000 #000000 #000000 #000000 #000000 250ms cosine
        roll-right 2s linear
        roll-right 2s linear
        roll-right 2s linear
        roll-right 2s linear
        roll-right 2s linear
        roll-right 2s linear
        repeat
        """

    private func rollingWorkSampler() throws -> (LEDSSampler, CoreStripTransfer) {
        let transfer = try #require(CoreStripTransfer(channelGains: [0.3, 0.31797572544642855, 1.3034388950892857]))
        let program = try LEDSProgram.parse(Self.rollingWork, ledCount: 8)
        let sampler = LEDSSampler(program: program, ledCount: 8,
                                  initialCodes: Array(repeating: RGB8(r: 0, g: 0, b: 0), count: 8),
                                  outputLedCount: ScreenBarGeometry.ledCount)
        return (sampler, transfer)
    }

    @Test("a dim roll whose 8-bit steps cannot be keyframed plays as the fade they approximate, not from the frame clock")
    func dimRollPlaysSmooth() throws {
        let (sampler, transfer) = try rollingWorkSampler()
        // Every step of the strip, within two display codes, is thousands of keyframes.
        let stepped = try #require(LEDSKeyframePlan.render(sampler: sampler, tolerance: 2, maxKeyframes: .max,
            sampleColors: { t in
                ScreenBarLightTransfer.colors(sampler.rawCodes(atMilliseconds: t), brightness: sampler.brightness,
                                              transfer: transfer)
            }))
        #expect(stepped.keyframeCount > LEDSKeyframePlan.defaultMaxKeyframes)

        let plan = try #require(ScreenBarLightTransfer.plan(sampler: sampler, transfer: transfer),
                                "the band keeps its 60 Hz clock for this program")
        #expect(plan.keyframeCount <= LEDSKeyframePlan.defaultMaxKeyframes)
        #expect(plan.loop != nil)

        // The plan stays within two display codes of the smooth fade for two whole passes.
        var worst = 0.0
        for t in stride(from: 0, through: 24_500, by: 3) {
            let expected = ScreenBarLightTransfer.colors(light: sampler.smoothRawLight(atMilliseconds: t),
                                                         brightness: sampler.brightness, transfer: transfer)
            for (a, b) in zip(plan.codes(atMilliseconds: t).map(\.rgb), expected) {
                worst = max(worst, abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
            }
        }
        #expect(worst <= 2.0 / 255, "error=\(worst * 255) codes")
    }

    @Test("the smooth fade is never a whole strip step away from the strip's own state")
    func smoothLightStaysWithinOneStep() throws {
        let programs = [
            Self.rollingWork,
            "#10121F 250ms linear\n#000000 250ms linear\nrepeat",
            "brightness 40\n#DB704D #2961CF #DB704D #2961CF #DB704D #2961CF #DB704D #2961CF\nroll-left 1s linear\nrepeat",
            "#FF0000 1s ease\n#0000FF 400ms cosine 200ms\nroll-right 3s ease\nrepeat 2\n#00FF00 500ms",
            "0:#FFFFFF 3:#102030 700ms\nroll-left 900ms\n#000000",
        ]
        for text in programs {
            let sampler = LEDSSampler(program: try LEDSProgram.parse(text, ledCount: 8))
            var worst = 0.0
            for t in stride(from: 0, through: 30_000, by: 7) {
                for (stepped, smooth) in zip(sampler.rawCodes(atMilliseconds: t), sampler.smoothRawLight(atMilliseconds: t)) {
                    worst = max(worst, abs(Double(stepped.r) - smooth.r * 255), abs(Double(stepped.g) - smooth.g * 255),
                                abs(Double(stepped.b) - smooth.b * 255))
                }
            }
            #expect(worst < 1.0, "program \(text.prefix(24)): \(worst) codes")
        }
    }

    /// Knight Rider cycling between two providers, as the audit matrix
    /// delivers it: bright sweeps that reverse every 857 ms.
    static let cyclingSweep = """
        #164880 #091E35 #000000 #000000 #000000 #000000 #000000 #091E35 400ms cosine
        roll-right 1800ms linear
        roll-left 1800ms linear
        #6C3C2C #2D1912 #000000 #000000 #000000 #000000 #000000 #2D1912 400ms cosine
        roll-right 857ms linear
        roll-left 857ms linear
        #6C3C2C #2D1912 #000000 #000000 #000000 #000000 #000000 #2D1912 171ms cosine
        roll-right 857ms linear
        roll-left 857ms linear
        repeat
        """

    @Test("a fast sweep under a strong calibration plays from keyframes within five display codes of its fade")
    func fastSweepPlaysSmooth() throws {
        let transfer = try #require(CoreStripTransfer(channelGains: [0.3, 0.31797572544642855, 1.3034388950892857]))
        let text = "brightness 141\n" + Self.cyclingSweep
        let sampler = LEDSSampler(program: try LEDSProgram.parse(text, ledCount: 8), ledCount: 8,
                                  outputLedCount: ScreenBarGeometry.ledCount)
        let plan = try #require(ScreenBarLightTransfer.plan(sampler: sampler, transfer: transfer))
        #expect(plan.keyframeCount <= LEDSKeyframePlan.defaultMaxKeyframes)
        var worst = 0.0
        for t in stride(from: 0, through: 16_000, by: 3) {
            let expected = ScreenBarLightTransfer.colors(light: sampler.smoothRawLight(atMilliseconds: t),
                                                         brightness: sampler.brightness, transfer: transfer)
            for (a, b) in zip(plan.codes(atMilliseconds: t).map(\.rgb), expected) {
                worst = max(worst, abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
            }
        }
        #expect(worst <= Double(ScreenBarLightTransfer.smoothTolerances.upperBound) / 255, "error=\(worst * 255) codes")
    }

    /// `scripts/audit_lights.py` writes every program the daemon's matrix
    /// delivers (animations by mixes by provider counts by states) to
    /// `delivered-programs.json`. With `JRBAR_AUDIT_PROGRAMS` naming that
    /// file, this plans each one under a strong calibration and counts how
    /// it would play: the strip's own steps, the smooth fade, or the frame
    /// clock. Without it the test has nothing to read and says so.
    @Test("every program the daemon delivers plays from keyframes under a strong calibration")
    func deliveredProgramsPlan() throws {
        guard let path = ProcessInfo.processInfo.environment["JRBAR_AUDIT_PROGRAMS"], !path.isEmpty else { return }
        struct Row: Decodable { let leds: Int; let program: String; let `case`: String }
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let transfer = try #require(CoreStripTransfer(channelGains: [0.3, 0.31797572544642855, 1.3034388950892857]))
        var stepped = 0, smooth = 0, clock: [String] = [], seen = Set<String>()
        for row in rows where row.leds == 8 && seen.insert(row.program).inserted {
            // The band's own brightness, the way the daemon sends it.
            let text = row.program.replacingOccurrences(of: #"(?m)^brightness \d+$"#, with: "brightness 141",
                                                        options: .regularExpression)
            guard let program = try? LEDSProgram.parse(text, ledCount: 8) else { continue }
            let sampler = LEDSSampler(program: program, ledCount: 8, outputLedCount: ScreenBarGeometry.ledCount)
            if sampler.isStatic { continue }
            var exact: LEDSKeyframePlan?
            for tolerance in 1...2 where exact == nil {
                if let plan = LEDSKeyframePlan.render(sampler: sampler, tolerance: tolerance, maxKeyframes: .max,
                    sampleColors: { t in
                        ScreenBarLightTransfer.colors(sampler.rawCodes(atMilliseconds: t),
                                                      brightness: sampler.brightness, transfer: transfer)
                    }), plan.keyframeCount <= LEDSKeyframePlan.defaultMaxKeyframes { exact = plan }
            }
            if exact != nil {
                stepped += 1
            } else if ScreenBarLightTransfer.smoothPlan(sampler: sampler, transfer: transfer) != nil {
                smooth += 1
            } else {
                clock.append(row.case)
            }
        }
        print("AUDIT stepped \(stepped) smooth \(smooth) frame clock \(clock.count)")
        for name in clock.prefix(40) { print("AUDIT frame clock:", name) }
        #expect(stepped + smooth > 0)
        #expect(clock.isEmpty, "\(clock.count) delivered programs still need the 60 Hz frame clock")
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
