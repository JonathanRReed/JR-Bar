import JRBarTestSupport
import AppKit
import Foundation
import JRBarCore
import JRBarLEDS
import QuartzCore
import Testing
@testable import JRBarApp

@Suite("Screen Bar moving gradient proof", .serialized, .renderProofAppearance)
@MainActor
struct ScreenBarMotionRenderProofTests {
    /// Freeze values from the animation actually installed on each gradient.
    /// Offscreen layer rendering does not advance the compositor's clock.
    private func freeze(_ view: ScreenBarView, milliseconds: Int) throws {
        var gradients = 0
        for case let layer as CAGradientLayer in view.layer?.sublayers ?? [] {
            guard let animation = layer.animation(forKey: "jrbar.loop") as? CAKeyframeAnimation else { continue }
            let times = try #require(animation.keyTimes?.map(\.doubleValue))
            let values = try #require(animation.values as? [[CGColor]])
            let phase = Double(milliseconds) / (animation.duration * 1_000)
            let high = times.firstIndex { $0 >= phase } ?? (times.count - 1)
            let low = max(0, high - 1)
            let span = times[high] - times[low]
            let fraction = CGFloat(span > 0 ? (phase - times[low]) / span : 0)
            let colors = try zip(values[low], values[high]).map { a, b in
                let x = try #require(a.components)
                let y = try #require(b.components)
                let components = zip(x, y).map { $0 + ($1 - $0) * fraction }
                return try #require(CGColor(colorSpace: ScreenBarGradientFrames.colorSpace, components: components))
            }
            layer.removeAllAnimations()
            layer.colors = colors
            gradients += 1
        }
        #expect(gradients >= 1, "the proof must sample installed motion")
        if gradients == 0 {
            print("PROOF layers=\((view.layer?.sublayers ?? []).map { String(describing: type(of: $0)) + String(describing: $0.animationKeys()) })")
        }
    }

    @Test("frame and installed keyframe paths show a moving gradient at three phases",
          .enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func motionFrames() async throws {
        let transfer = try #require(CoreStripTransfer(channelGains: [1, 0.38, 1]))
        let composition = LEDSComposition(base: .gradient(RGB8(r: 219, g: 112, b: 77), RGB8(r: 41, g: 97, b: 207)),
                                          motion: .roll(periodMs: 1_000, leftward: true), brightness: 100)
        let sampler = LEDSSampler(program: try LEDSProgram.parse(LEDSComposer.compose(composition).text, ledCount: 8))
        let plan = try #require(ScreenBarLightTransfer.plan(sampler: sampler, transfer: transfer))
        var images: [Data] = []
        var sampledColors: [[RGB]] = []
        for time in [400, 650, 900] {
            let scene = NSView(frame: CGRect(x: 0, y: 0, width: 780, height: 108))
            scene.wantsLayer = true
            scene.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
            for (index, title) in ["Frame clock", "Installed keyframes"].enumerated() {
                let label = NSTextField(labelWithString: "\(title)  \(time) ms")
                label.textColor = .white
                label.frame = CGRect(x: 20 + index * 390, y: 74, width: 350, height: 20)
                scene.addSubview(label)
            }
            let direct = ScreenBarView(frame: CGRect(x: 20, y: 26, width: 350, height: 24))
            let keyed = ScreenBarView(frame: CGRect(x: 410, y: 26, width: 350, height: 24))
            scene.addSubview(direct)
            scene.addSubview(keyed)
            direct.relayout()
            keyed.relayout()
            let colors = ScreenBarLightTransfer.colors(sampler.rawCodes(atMilliseconds: plan.loopStartMs + time),
                                                        brightness: sampler.brightness, transfer: transfer)
            sampledColors.append(colors)
            direct.display(colors: colors)
            // Keep the lead installed while its worker builds; sample its
            // actual values below rather than waiting on real time.
            keyed.gradientRenderer = { plan, width, _ in
                ScreenBarGradientFrames.build(plan: plan, width: width, reduced: false)
            }
            keyed.play(plan: plan, anchor: CACurrentMediaTime() + 60)
            await keyed.waitForKeyframes()
            try freeze(keyed, milliseconds: time)
            let bitmap = try #require(scene.bitmapImageRepForCachingDisplay(in: scene.bounds))
            scene.cacheDisplay(in: scene.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            images.append(png)
            try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
            try png.write(to: ProofRender.directory.appendingPathComponent("screen-bar-motion-\(time)ms.png"))
            keyed.stopKeyframes()
        }
        #expect(Set(images).count == 3)
        #expect(Set(sampledColors).count == 3, "the light itself moves between proof frames")
    }
}
