import AppKit
import CoreVideo
import Foundation
import MetalKit
import Testing
@testable import JRBarApp

@MainActor
@Suite("Fold far-frame recovery")
struct FoldFarFrameRecoveryTests {
    private func picture(blue: UInt8, red: UInt8) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &created) == kCVReturnSuccess)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<32 {
            for x in 0..<32 {
                let index = y * rowBytes + x * 4
                base[index] = blue
                base[index + 1] = 0
                base[index + 2] = red
                base[index + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func pixels(_ renderer: FoldRenderer) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 96, height: 64, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        let target = try #require(renderer.device.makeTexture(descriptor: descriptor))
        #expect(renderer.render(to: target, size: CGSize(width: 96, height: 64)))
        var result = [UInt8](repeating: 0, count: 96 * 64 * 4)
        target.getBytes(&result, bytesPerRow: 96 * 4,
            from: MTLRegionMake2D(0, 0, 96, 64), mipmapLevel: 0)
        return result
    }

    private func writeProof(_ pixels: [UInt8], named name: String) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JRBAR_RENDER_PROOF"] == "1" else { return }
        let directory = URL(fileURLWithPath: environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/jrbar-audit")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let image = try #require(CGImage(width: 96, height: 64, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 96 * 4, space: colorSpace, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        try FoldRenderProofTests.writePNG(image, to: directory.appendingPathComponent(name + ".png"))
    }

    @Test("a dead far stream replaces its stale red wall with the live blue picture")
    func failedFarStreamUsesFullPicture() throws {
        let full = try picture(blue: 255, red: 0)
        let far = try picture(blue: 0, red: 255)
        let reference = try FoldRenderer(pixelFormat: .bgra8Unorm)
        let renderer = try FoldRenderer(pixelFormat: .bgra8Unorm)
        for value in [reference, renderer] {
            #expect(value.setFullFrame(full))
            FoldPortalModel.apply(to: &value.params, delta: 1, perspective: 0.6,
                blur: 0, shade: 0, frost: 0, hold: 0, usedBuckets: 0, reduceMotion: false)
        }
        let capture = FoldCapture(dual: true)
        var invalidations = 0
        var fullErrors = 0
        FoldCaptureCallbacks.install(on: capture, isCurrent: { true },
            full: { _ = renderer.setFullFrame($0) },
            far: { _ = renderer.setFarFrame($0) },
            farInvalidated: { invalidations += 1; renderer.invalidateFarFrame() },
            cards: { _ in }, failed: { _ in fullErrors += 1 })
        capture.noteFarFrame(far)
        #expect(capture.hasFarFrame)
        let copiedFar = try #require(capture.onFarFrame)
        let expectedPixels = try pixels(reference)
        let stalePixels = try pixels(renderer)
        let staleDiffers = stalePixels != expectedPixels
        #expect(staleDiffers)
        renderer.noteDrawnFrame()
        #expect(!renderer.needsDraw)
        capture.noteFarStreamFailure("Synthetic far-stream failure")
        #expect(renderer.needsDraw)
        #expect(invalidations == 1)
        #expect(!capture.hasFarFrame)
        #expect(fullErrors == 0)
        capture.noteFarFrame(far)
        copiedFar(far)
        capture.noteFarStreamFailure("Duplicate failure")
        #expect(invalidations == 1)
        #expect(!capture.hasFarFrame)
        let recoveredPixels = try pixels(renderer)
        let matchesFullPicture = recoveredPixels == expectedPixels
        #expect(matchesFullPicture)
        try writeProof(expectedPixels, named: "reference-full-blue")
        try writeProof(stalePixels, named: "stale-far-red")
        try writeProof(recoveredPixels, named: "recovered-full")
        capture.onFullFrame?(full)
        let laterFullPixels = try pixels(renderer)
        let stillUsesFullPicture = laterFullPixels == expectedPixels
        #expect(stillUsesFullPicture)
    }

    @Test("far-start refusal invalidates the prior far picture")
    func farStartRefusalUsesFullPicture() throws {
        let full = try picture(blue: 255, red: 0)
        let far = try picture(blue: 0, red: 255)
        let reference = try FoldRenderer(pixelFormat: .bgra8Unorm)
        let renderer = try FoldRenderer(pixelFormat: .bgra8Unorm)
        for value in [reference, renderer] {
            #expect(value.setFullFrame(full))
            FoldPortalModel.apply(to: &value.params, delta: 1, perspective: 0.6,
                blur: 0, shade: 0, frost: 0, hold: 0, usedBuckets: 0, reduceMotion: false)
        }
        let capture = FoldCapture(dual: true)
        capture.onFarFrame = { _ = renderer.setFarFrame($0) }
        capture.onFarFrameInvalidated = { renderer.invalidateFarFrame() }
        capture.noteFarFrame(far)
        let expected = try pixels(reference)
        let stale = try pixels(renderer)
        let initiallyDifferent = stale != expected
        #expect(initiallyDifferent)
        capture.noteFarStartFailure(NSError(domain: "fixture.far-start", code: 1))
        let afterRefusal = try pixels(renderer)
        let matchesFull = afterRefusal == expected
        #expect(matchesFull)
        #expect(!capture.hasFarFrame)
    }

    @Test("capture retirement clears the old far picture even without a current source", arguments: [true, false])
    func retirementUsesFullPicture(sourcePresent: Bool) throws {
        let full = try picture(blue: 255, red: 0)
        let far = try picture(blue: 0, red: 255)
        let reference = try FoldRenderer(pixelFormat: .bgra8Unorm)
        let renderer = try FoldRenderer(pixelFormat: .bgra8Unorm)
        for value in [reference, renderer] {
            #expect(value.setFullFrame(full))
            FoldPortalModel.apply(to: &value.params, delta: 1, perspective: 0.6,
                blur: 0, shade: 0, frost: 0, hold: 0, usedBuckets: 0, reduceMotion: false)
        }
        #expect(renderer.setFarFrame(far))
        let expected = try pixels(reference)
        let stale = try pixels(renderer)
        let initiallyDifferent = stale != expected
        #expect(initiallyDifferent)
        renderer.noteDrawnFrame()
        #expect(!renderer.needsDraw)
        let source: FoldCapture? = sourcePresent ? FoldCapture(dual: true) : nil
        source?.onFarFrame = { _ in }
        FoldCaptureCallbacks.retire(source) { renderer.invalidateFarFrame() }
        #expect(source?.onFarFrame == nil)
        #expect(renderer.needsDraw)
        let afterRetirement = try pixels(renderer)
        let matchesFull = afterRetirement == expected
        #expect(matchesFull)
    }

    @Test("a new far picture makes unchanged Fold uniforms need drawing")
    func arrivingFarFrameInvalidatesDrawCache() throws {
        let full = try picture(blue: 255, red: 0)
        let far = try picture(blue: 0, red: 255)
        let renderer = try FoldRenderer(pixelFormat: .bgra8Unorm)
        #expect(renderer.setFullFrame(full))
        FoldPortalModel.apply(to: &renderer.params, delta: 1, perspective: 0.6,
            blur: 0, shade: 0, frost: 0, hold: 0, usedBuckets: 0, reduceMotion: false)
        let fullPixels = try pixels(renderer)
        renderer.noteDrawnFrame()
        #expect(!renderer.needsDraw)
        #expect(renderer.setFarFrame(far))
        #expect(renderer.needsDraw)
        let firstFarPixels = try pixels(renderer)
        let differsFromFull = firstFarPixels != fullPixels
        #expect(differsFromFull)
        renderer.invalidateFarFrame()
        let fallbackPixels = try pixels(renderer)
        let fallbackMatchesFull = fallbackPixels == fullPixels
        #expect(fallbackMatchesFull)
        renderer.noteDrawnFrame()
        #expect(!renderer.needsDraw)
        #expect(renderer.setFarFrame(far))
        #expect(renderer.needsDraw)
        let freshFarPixels = try pixels(renderer)
        let freshMatchesFar = freshFarPixels == firstFarPixels
        #expect(freshMatchesFar)
        try writeProof(fullPixels, named: "arrival-full-before-far")
        try writeProof(freshFarPixels, named: "arrival-fresh-far-after-fallback")
    }
}
