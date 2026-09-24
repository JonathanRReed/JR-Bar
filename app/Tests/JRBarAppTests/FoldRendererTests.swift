import CoreVideo
import MetalKit
import Testing
@testable import JRBarApp

/// The fold shader compiles at runtime — `swift build` cannot see a
/// Metal syntax error. This suite compiles it on the real GPU and runs
/// real offscreen draws, so a broken shader — or a blur uniform that
/// never reaches the fragment — fails here, not on screen.
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

    @Test func theBlurKnobVisiblySoftensTheFarWall() throws {
        // The user-facing check for the depth blur: a high-frequency
        // checkerboard is the "captured desktop", the room is drawn
        // mid-fold at blur 0 and blur 1, and the far wall's contrast
        // must collapse — the mip chain and the blurStrength uniform
        // both have to really work for that to happen.
        let renderer = try FoldRenderer(pixelFormat: .bgra8Unorm)
        let width = 128, height = 128
        var maybeBuffer: CVPixelBuffer?
        // IOSurface-backed and Metal-compatible — what ScreenCaptureKit
        // hands the sink; a plain CPU buffer can't wrap as a texture.
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                    kCVPixelFormatType_32BGRA,
                                    attrs as CFDictionary,
                                    &maybeBuffer) == kCVReturnSuccess)
        let buffer = try #require(maybeBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let on = ((x / 8) + (y / 8)) % 2 == 0
                let v: UInt8 = on ? 255 : 0
                base[y * stride + x * 4 + 0] = v
                base[y * stride + x * 4 + 1] = v
                base[y * stride + x * 4 + 2] = v
                base[y * stride + x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(renderer.setFullFrame(buffer), "the frame should blit into the room textures")

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 256, height: 160, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .shared
        let target = try #require(renderer.device.makeTexture(descriptor: desc))

        // The far wall's contrast: the summed absolute horizontal
        // gradient across the top band — the far end of the room,
        // where the defocus runs strongest. Void rows add nothing to
        // either side, so coverage differences can't fake a pass.
        func farWallContrast(blur: Double) -> Double? {
            FoldPortalModel.apply(to: &renderer.params, delta: 1.0,
                                  perspective: 0.6, blur: blur, shade: 0.7,
                                  frost: 0.65, usedBuckets: 0,
                                  reduceMotion: false)
            guard renderer.render(to: target, size: CGSize(width: 256, height: 160)) else {
                return nil
            }
            var px = [UInt8](repeating: 0, count: 256 * 160 * 4)
            target.getBytes(&px, bytesPerRow: 256 * 4,
                            from: MTLRegionMake2D(0, 0, 256, 160), mipmapLevel: 0)
            var gradient = 0.0
            for y in 10..<50 {
                for x in 1..<256 {
                    let i = (y * 256 + x) * 4
                    gradient += abs(Double(px[i]) - Double(px[i - 4]))
                }
            }
            return gradient
        }

        let sharp = try #require(farWallContrast(blur: 0))
        let blurred = try #require(farWallContrast(blur: 1))
        #expect(sharp > 1000, "the checkerboard should render with contrast")
        #expect(blurred < sharp * 0.6,
                "blur 1 should collapse the far wall's contrast (\(blurred) vs \(sharp))")
    }

    @Test func holdInPlaceCounterRotatesTheContentPlane() throws {
        // The viewer-compensation term must actually reach the GPU: at
        // a full hold the content plane takes the front-view mapping,
        // so a mid-fold render can't match the same render with the
        // hold at 0 — the far wall's pixels have to move.
        let renderer = try FoldRenderer(pixelFormat: .bgra8Unorm)
        let width = 128, height = 128
        var maybeBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                    kCVPixelFormatType_32BGRA,
                                    attrs as CFDictionary,
                                    &maybeBuffer) == kCVReturnSuccess)
        let buffer = try #require(maybeBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let on = ((x / 8) + (y / 8)) % 2 == 0
                let v: UInt8 = on ? 255 : 0
                base[y * rowBytes + x * 4 + 0] = v
                base[y * rowBytes + x * 4 + 1] = v
                base[y * rowBytes + x * 4 + 2] = v
                base[y * rowBytes + x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(renderer.setFullFrame(buffer))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 256, height: 160, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .shared
        let target = try #require(renderer.device.makeTexture(descriptor: desc))

        func pixels(hold: Double) -> [UInt8]? {
            FoldPortalModel.apply(to: &renderer.params, delta: 1.0,
                                  perspective: 1.0, blur: 0, shade: 0.7,
                                  frost: 0, hold: hold,
                                  usedBuckets: 0, reduceMotion: false)
            guard renderer.render(to: target, size: CGSize(width: 256, height: 160)) else {
                return nil
            }
            var px = [UInt8](repeating: 0, count: 256 * 160 * 4)
            target.getBytes(&px, bytesPerRow: 256 * 4,
                            from: MTLRegionMake2D(0, 0, 256, 160), mipmapLevel: 0)
            return px
        }

        let riding = try #require(pixels(hold: 0))
        let held = try #require(pixels(hold: 1))
        var differ = 0
        for i in stride(from: 0, to: riding.count, by: 4) {
            if abs(Int(riding[i]) - Int(held[i])) > 12 { differ += 1 }
        }
        #expect(differ > 2000,
                "hold should visibly move the content plane (\(differ) px differ)")
    }
}
