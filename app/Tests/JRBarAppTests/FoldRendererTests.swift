import MetalKit
import Testing
@testable import JRBarApp

/// The fold shader compiles at runtime — `swift build` cannot see a
/// Metal syntax error. This suite compiles it on the real GPU and runs
/// one offscreen draw, so a broken shader fails here, not on screen.
@Suite @MainActor struct FoldRendererTests {
    @Test func pipelineBuildsOnTheSystemDevice() throws {
        let renderer = try FoldRenderer(pixelFormat: .bgra8Unorm)
        #expect(renderer.device.name.isEmpty == false)
    }

    @Test func aDrawWithNoFrameIsACleanNoop() throws {
        // No captured frame pushed: the draw must early-out without a
        // drawable or crash — the path the toy hits while capture spins
        // up.
        let renderer = try FoldRenderer(pixelFormat: .bgra8Unorm)
        let view = MTKView(frame: .init(x: 0, y: 0, width: 64, height: 40), device: renderer.device)
        renderer.draw(in: view)
    }
}
