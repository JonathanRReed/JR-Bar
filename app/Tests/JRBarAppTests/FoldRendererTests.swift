import CoreVideo
import JRBarCore
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

    // MARK: Duo

    /// A Metal-compatible 32BGRA frame, grey everywhere, from `gray(x, y)`
    /// — the shape ScreenCaptureKit hands the sink.
    private static func makeFrame(width: Int, height: Int,
                              gray: (Int, Int) -> UInt8) throws -> CVPixelBuffer {
        var maybeBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &maybeBuffer)
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(maybeBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let v = gray(x, y)
                let i = y * rowBytes + x * 4
                base[i] = v
                base[i + 1] = v
                base[i + 2] = v
                base[i + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private static func makeTarget(_ device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .shared
        return try #require(device.makeTexture(descriptor: desc))
    }

    /// The blue channel of every pixel (the frames are grey).
    private static func grays(_ texture: MTLTexture) -> [Double] {
        var px = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&px, bytesPerRow: texture.width * 4,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return stride(from: 0, to: px.count, by: 4).map { Double(px[$0]) }
    }

    /// A Duo renderer holding `buffer`.
    private static func duoRenderer(_ buffer: CVPixelBuffer) throws -> FoldRenderer {
        let renderer = try FoldRenderer(pixelFormat: .bgra8Unorm)
        renderer.look = .duo
        #expect(renderer.setFullFrame(buffer), "the frame should land in the pyramid")
        #expect(renderer.duoPyramid?.mipmapLevelCount ?? 0 > 1, "a real pyramid, not one level")
        return renderer
    }

    private static func duo(_ renderer: FoldRenderer, theta: Double, blur: Double = 0.6,
                            shade: Double = 2.0 / 3, fadeLength: Double = 0.55) {
        FoldDuoModel.apply(to: &renderer.params, reference: 110, theta: theta, hold: 1,
                           perspective: 0.6, blur: blur, shade: shade,
                           fadeLength: fadeLength, reduceMotion: false)
    }

    /// Mean and standard deviation over a band of rows and columns.
    private static func stats(_ px: [Double], width: Int, rows: Range<Int>,
                              columns: Range<Int>) -> (mean: Double, sd: Double) {
        var values: [Double] = []
        for y in rows { for x in columns { values.append(px[y * width + x]) } }
        let mean = values.reduce(0, +) / Double(max(1, values.count))
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(1, values.count))
        return (mean, variance.squareRoot())
    }

    @Test func duoAtRestIsTheDesktopItself() throws {
        // δ = 0: the Duo pipeline must hand back the captured frame
        // untouched, pixel for pixel, at native size.
        let width = 256, height = 160
        let pattern: (Int, Int) -> UInt8 = { x, y in
            UInt8((x * 7 + y * 13) % 256) ^ (((x / 5 + y / 3) % 2 == 0) ? 0x40 : 0)
        }
        let renderer = try Self.duoRenderer(Self.makeFrame(width: width, height: height, gray: pattern))
        Self.duo(renderer, theta: 110, blur: 1, shade: 1)
        let out = try Self.makeTarget(renderer.device, width: width, height: height)
        #expect(renderer.render(to: out, size: CGSize(width: width, height: height)))
        let px = Self.grays(out)
        var worst = 0.0
        for y in 0..<height {
            for x in 0..<width {
                worst = max(worst, abs(px[y * width + x] - Double(pattern(x, y))))
            }
        }
        #expect(worst <= 1, "the resting frame differs by \(worst)/255")
    }

    @Test func duoKeepsTheHingeSharpWhileTheFarEdgeGoesSoft() throws {
        // A checkerboard mid-fold with no darkening: the hinge band keeps
        // its contrast, the far band's blurs away.
        let width = 256, height = 160
        let renderer = try Self.duoRenderer(Self.makeFrame(width: width, height: height) { x, y in
            ((x / 8) + (y / 8)) % 2 == 0 ? 255 : 0
        })
        Self.duo(renderer, theta: 70, blur: 1, shade: 0)
        let out = try Self.makeTarget(renderer.device, width: width, height: height)
        #expect(renderer.render(to: out, size: CGSize(width: width, height: height)))
        let px = Self.grays(out)
        let input = 127.5
        let hinge = Self.stats(px, width: width, rows: 148..<158, columns: 64..<192)
        let far = Self.stats(px, width: width, rows: 2..<14, columns: 64..<192)
        #expect(hinge.sd >= 0.8 * input, "hinge contrast \(hinge.sd / input)")
        #expect(far.sd < 0.25 * input, "far contrast \(far.sd / input)")
    }

    @Test func duoTakesTheFarEdgeToBlackAndLeavesTheHingeBright() throws {
        // Full motion (a short fade, lid at 75°): the far band is black,
        // the hinge band as bright as the white it shows.
        let width = 256, height = 160
        let renderer = try Self.duoRenderer(Self.makeFrame(width: width, height: height) { _, _ in 255 })
        Self.duo(renderer, theta: 75, fadeLength: 0.3)
        #expect(renderer.params.motion == 1)
        #expect(renderer.params.endFade == 0)
        let out = try Self.makeTarget(renderer.device, width: width, height: height)
        #expect(renderer.render(to: out, size: CGSize(width: width, height: height)))
        let px = Self.grays(out)
        let far = Self.stats(px, width: width, rows: 2..<14, columns: 96..<160)
        let hinge = Self.stats(px, width: width, rows: 148..<158, columns: 16..<240)
        #expect(far.mean < 0.05 * 255, "far band \(far.mean)")
        #expect(hinge.mean >= 0.9 * 255, "hinge band \(hinge.mean)")
    }

    @Test func duoPyramidReadsAsAGaussian() throws {
        // The blur is one pyramid level read as a B-spline — no disc, so
        // no ghost copies. Read levels 2 and 3 with the renderer's own
        // `duoLevel` and compare with a CPU Gaussian of σ 0.82·2^L.
        let n = 256
        let shapes: (Int, Int) -> UInt8 = { x, y in
            var v = 0.25
            if x > 40 && x < 120 && y > 30 && y < 100 { v = 1 }
            let dx = Double(x) - 180, dy = Double(y) - 170
            if dx * dx + dy * dy < 45 * 45 { v = 0.9 }
            if x > 60 && x < 70 && y > 140 && y < 230 { v = 0 }
            return UInt8(v * 255)
        }
        let renderer = try Self.duoRenderer(Self.makeFrame(width: n, height: n, gray: shapes))
        let device = renderer.device
        let probe = """
        struct DuoProbe { float lod; float shift; float pad0; float pad1; };
        fragment float4 duoProbe(FoldOut in [[stage_in]],
                                 texture2d<float> pyramid [[texture(0)]],
                                 constant DuoProbe &q [[buffer(0)]],
                                 sampler s [[sampler(0)]]) {
            return float4(duoLevel(pyramid, s, in.uv, q.lod, q.shift), 1.0);
        }
        """
        let library = try device.makeLibrary(source: FoldRenderer.shaderSource + probe, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "foldVertex")
        desc.fragmentFunction = library.makeFunction(name: "duoProbe")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: desc)
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.mipFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        let sampler = try #require(device.makeSamplerState(descriptor: samplerDesc))
        let queue = try #require(device.makeCommandQueue())
        let out = try Self.makeTarget(device, width: n, height: n)
        let base = (0..<(n * n)).map { Double(shapes($0 % n, $0 / n)) }
        for level in [2.0, 3.0] {
            let command = try #require(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = out
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(renderer.duoPyramid, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            var q = SIMD4<Float>(Float(level), renderer.params.pyramidShift, 0, 0)
            encoder.setFragmentBytes(&q, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            let gpu = Self.grays(out)
            let cpu = Self.gaussian(base, size: n, sigma: FoldDuoModel.levelSigma * pow(2, level))
            let margin = Int(3 * pow(2, level))
            var worst = 0.0
            for y in margin..<(n - margin) {
                for x in margin..<(n - margin) {
                    worst = max(worst, abs(gpu[y * n + x] - cpu[y * n + x]))
                }
            }
            #expect(worst < 6, "level \(level) reads \(worst)/255 off a Gaussian")
        }
    }

    /// A separable Gaussian blur, edges clamped.
    private static func gaussian(_ image: [Double], size n: Int, sigma: Double) -> [Double] {
        let r = Int((sigma * 4).rounded(.up))
        let raw = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = raw.reduce(0, +)
        let kernel = raw.map { $0 / total }
        var rows = [Double](repeating: 0, count: n * n)
        var out = rows
        for y in 0..<n {
            for x in 0..<n {
                var a = 0.0
                for j in -r...r { a += kernel[j + r] * image[y * n + min(n - 1, max(0, x + j))] }
                rows[y * n + x] = a
            }
        }
        for y in 0..<n {
            for x in 0..<n {
                var a = 0.0
                for j in -r...r { a += kernel[j + r] * rows[min(n - 1, max(0, y + j)) * n + x] }
                out[y * n + x] = a
            }
        }
        return out
    }

    @Test func theBlackoutIsSolidBlackWithNoTextureBound() throws {
        // The closed-lid hold draws before any frame exists: the clear is
        // the frame, nothing sampled, in either look.
        for look in FoldLook.allCases {
            let renderer = try FoldRenderer(pixelFormat: .bgra8Unorm)
            renderer.look = look
            #expect(!renderer.canDraw, "no frame yet: nothing to draw")
            FoldDuoModel.applyBlackout(to: &renderer.params)
            #expect(renderer.canDraw, "the blackout needs no texture")
            let out = try Self.makeTarget(renderer.device, width: 64, height: 40)
            #expect(renderer.render(to: out, size: CGSize(width: 64, height: 40)))
            var px = [UInt8](repeating: 7, count: 64 * 40 * 4)
            out.getBytes(&px, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 40), mipmapLevel: 0)
            for i in stride(from: 0, to: px.count, by: 4) {
                #expect(px[i] == 0 && px[i + 1] == 0 && px[i + 2] == 0 && px[i + 3] == 255)
                if px[i] != 0 { break }
            }
        }
    }
}
