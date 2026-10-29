import JRBarTestSupport
import AppKit
@testable import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@Suite(.renderProofAppearance) struct StudioPlaybackCycleTests {
    @Test func showsFirmwareSeedFrameInLoopDuration() {
        let program = "0:#804020 0ms\n0:#000000 1100ms cosine\n0:#804020 1100ms cosine\nrepeat"
        #expect(StudioFleetPreview.playbackCycle(program: program, ledCount: 8) == "2.217 s / loop")
    }

    @Test func showsScannerTimingWithoutChangingItsParameters() {
        let program = "0:#804020 0ms\n0:#000000 924ms cosine\n0:#804020 924ms cosine\nrepeat"
        #expect(StudioFleetPreview.playbackCycle(program: program, ledCount: 8) == "1.865 s / loop")
    }

    @Test func doesNotInventPeriodForStaticOrInvalidPrograms() {
        #expect(StudioFleetPreview.playbackCycle(program: "off", ledCount: 8) == nil)
        #expect(StudioFleetPreview.playbackCycle(program: "invalid", ledCount: 8) == nil)
    }
    @Test @MainActor func currentPreviewShowsItsMeasuredCycle() async {
        let core = CoreModel(socketPath: "/tmp/jrbar-studio-period-unused.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        let lights = EffectStudioLights(core: core)
        let program = "0:#804020 0ms\n0:#000000 1100ms cosine\n0:#804020 1100ms cosine\nrepeat"
        lights.requestPreview = { _, _ in
            StudioFleetPreview(program: program, label: "Two providers", played: "round_robin",
                               reason: "Each provider keeps its sweep.", warnings: [], ledCount: 8)
        }
        await lights.refreshPreviews()
        #expect(lights.playbackCycle == "2.217 s / loop")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    @MainActor func measuredCycleRenderProof() async throws {
        let core = CoreModel(socketPath: "/tmp/jrbar-studio-period-render-unused.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        let lights = EffectStudioLights(core: core)
        let program = "0:#804020 0ms\n0:#000000 1100ms cosine\n0:#804020 1100ms cosine\nrepeat"
        lights.requestPreview = { _, _ in
            StudioFleetPreview(program: program, label: "Two providers", played: "round_robin",
                               reason: "Each provider keeps its sweep.", warnings: [], ledCount: 8)
        }
        await lights.refreshPreviews()
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
                            ?? "/tmp/jrbar-studio-period-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let view = StudioWhatPlays(lights: lights).padding(16).frame(width: 600, height: 210)
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
            renderer.proposedSize = ProposedViewSize(width: 600, height: 210)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("studio-cycle-\(dark).png"))
        }
    }
}
