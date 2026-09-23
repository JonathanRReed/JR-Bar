import AppKit
import CoreVideo
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Fold without Screen Recording: the wallpaper, laid out the way the
/// desktop lays it out, drawn into the same kind of buffer a capture
/// delivers — rows top first, BGRA.
@Suite("Fold wallpaper")
@MainActor
struct FoldWallpaperTests {
    @Test("the desktop's options map to its layout; nothing said is fill")
    func layoutFromOptions() {
        typealias Key = NSWorkspace.DesktopImageOptionKey
        #expect(FoldWallpaperSource.layout(options: [:]) == .fill)
        let fit: [Key: Any] = [.imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                               .allowClipping: NSNumber(value: false)]
        #expect(FoldWallpaperSource.layout(options: fit) == .fit)
        let stretch: [Key: Any] = [.imageScaling: NSNumber(value: NSImageScaling.scaleAxesIndependently.rawValue)]
        #expect(FoldWallpaperSource.layout(options: stretch) == .stretch)
        let center: [Key: Any] = [.imageScaling: NSNumber(value: NSImageScaling.scaleNone.rawValue)]
        #expect(FoldWallpaperSource.layout(options: center) == .center)
    }

    @Test("fill covers and crops evenly; fit letterboxes; stretch covers; centre keeps size")
    func drawRects() {
        let canvas = CGSize(width: 200, height: 100)
        let square = CGSize(width: 50, height: 50)
        #expect(FoldWallpaperSource.drawRect(image: square, canvas: canvas, layout: .fill)
                == CGRect(x: 0, y: -50, width: 200, height: 200))
        #expect(FoldWallpaperSource.drawRect(image: square, canvas: canvas, layout: .fit)
                == CGRect(x: 50, y: 0, width: 100, height: 100))
        #expect(FoldWallpaperSource.drawRect(image: square, canvas: canvas, layout: .stretch)
                == CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(FoldWallpaperSource.drawRect(image: square, canvas: canvas, layout: .center)
                == CGRect(x: 75, y: 25, width: 50, height: 50))
        #expect(FoldWallpaperSource.drawRect(image: .zero, canvas: canvas, layout: .fill)
                == CGRect(origin: .zero, size: canvas))
    }

    @Test("the frame is the display's pixels, capped at 2560 on the long edge")
    func pixelSizes() {
        #expect(FoldWallpaperSource.pixelSize(points: CGSize(width: 1512, height: 982), scale: 1)
                == CGSize(width: 1512, height: 982))
        let retina = FoldWallpaperSource.pixelSize(points: CGSize(width: 1512, height: 982), scale: 2)
        #expect(retina.width == 2560)
        #expect(abs(retina.height - 982 * 2 * 2560 / 3024) <= 1)
    }

    @Test("the buffer is BGRA, rows top first, the picture where the layout put it")
    func rendersTopFirst() throws {
        // A 1×2 image: red on top, blue underneath.
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let source = try #require(CGContext(
            data: nil, width: 1, height: 2, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        source.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 1, height: 1))    // bottom row
        source.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        source.fill(CGRect(x: 0, y: 1, width: 1, height: 1))    // top row
        let image = try #require(source.makeImage())
        let buffer = try #require(FoldWallpaperSource.render(
            image, into: CGSize(width: 4, height: 8), layout: .stretch,
            fill: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)))
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetIOSurface(buffer) != nil, "the renderer blits IOSurface frames")
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        // BGRA: byte 2 is red, byte 0 is blue.
        let top = (b: base[0], r: base[2])
        let bottom = (b: base[7 * row], r: base[7 * row + 2])
        #expect(top.r > 200 && top.b < 50, "red on top, like a captured frame")
        #expect(bottom.b > 200 && bottom.r < 50)
    }

    @Test("the wallpaper file decodes into a frame off the main actor; a missing one says so")
    func decodesFromDisk() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "jrbar-fold-wallpaper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let source = try #require(CGContext(
            data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 32, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        source.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let green = try #require(source.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: green).representation(using: .png, properties: [:]))
        let url = dir.appending(path: "wall.png")
        try png.write(to: url)
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let result = await FoldWallpaperSource.frame(from: url, into: CGSize(width: 16, height: 8),
                                                     layout: .fill, fill: black)
        let frame = try result.get()
        #expect(CVPixelBufferGetWidth(frame.buffer) == 16)
        #expect(CVPixelBufferGetHeight(frame.buffer) == 8)
        CVPixelBufferLockBaseAddress(frame.buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame.buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(frame.buffer)).assumingMemoryBound(to: UInt8.self)
        #expect(base[1] > 200 && base[2] < 50, "the picture's green, not the fill")

        let missing = await FoldWallpaperSource.frame(from: dir.appending(path: "gone.png"),
                                                      into: CGSize(width: 16, height: 8),
                                                      layout: .fill, fill: black)
        guard case .failure(.noWallpaper) = missing else {
            Issue.record("a missing wallpaper is noWallpaper")
            return
        }
    }

    @Test("an empty canvas makes no buffer")
    func emptyCanvas() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let source = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let image = try #require(source.makeImage())
        #expect(FoldWallpaperSource.render(image, into: .zero, layout: .fill,
                                           fill: CGColor(gray: 0, alpha: 1)) == nil)
    }

    @Test("the fallback switch decodes tolerantly and defaults on")
    func settingDecodes() throws {
        let empty = try JSONDecoder().decode(FoldSettings.self, from: Data("{}".utf8))
        #expect(empty.wallpaperFallback == true)
        var off = FoldSettings()
        off.wallpaperFallback = false
        let round = try JSONDecoder().decode(FoldSettings.self, from: JSONEncoder().encode(off))
        #expect(round.wallpaperFallback == false)
        let junk = try JSONDecoder().decode(FoldSettings.self,
                                            from: Data(#"{"wallpaperFallback": 3}"#.utf8))
        #expect(junk.wallpaperFallback == true)
    }

    @Test("a limited chip names what's held back, in the paused colour")
    func limitedStatus() {
        let status = ToyStatus.limited("Wallpaper only")
        #expect(status.text == "Wallpaper only")
        #expect(status.tint == ToyStatus.paused("x").tint)
    }
}
