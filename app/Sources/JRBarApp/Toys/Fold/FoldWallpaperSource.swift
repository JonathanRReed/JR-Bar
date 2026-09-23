import AppKit
import CoreVideo

/// Where the fold's frames come from. `FoldCapture` films the built-in
/// display through ScreenCaptureKit; `FoldWallpaperSource` stands in
/// when Screen Recording isn't granted. The toy drives either through
/// the same arming band, the same tracker and the same renderer — only
/// the pixels differ, so the motion can't.
@MainActor
protocol FoldFrameSource: AnyObject {
    /// True once a complete frame has been handed to `onFullFrame`.
    var hasFrame: Bool { get }
    /// Why the source stopped, for the card's diagnostic line.
    var lastError: String? { get }
    var onFullFrame: (@MainActor (CVPixelBuffer) -> Void)? { get set }
    var onFarFrame: (@MainActor (CVPixelBuffer) -> Void)? { get set }
    var onCards: (@MainActor ([PortalDepth.Card]) -> Void)? { get set }
    var onError: (@MainActor (String) -> Void)? { get set }
    func start() async throws
    func stop() async
}

extension FoldCapture: FoldFrameSource {}

enum FoldWallpaperError: LocalizedError {
    case noWallpaper
    case noBuffer

    var errorDescription: String? {
        switch self {
        case .noWallpaper: return "no wallpaper image to fold"
        case .noBuffer: return "couldn't make a wallpaper frame"
        }
    }
}

/// Fold without Screen Recording (Mac Duo's Replay and Foldy's sample
/// wallpaper do the same): the built-in display's wallpaper — which
/// `NSWorkspace.desktopImageURL` hands over with no permission at all —
/// becomes the room's far wall, with no window cards in front of it.
/// Drawn once per arming into an IOSurface-backed buffer the renderer
/// blits exactly like a captured frame, laid out the way the desktop
/// lays it out (fill, fit, stretch or centre). The decode and the draw
/// run off the main actor — a 6K wallpaper is a real decode, and the
/// lid is already moving when the fold arms. No stream, no purple
/// indicator, nothing to stop but the buffer.
@MainActor
final class FoldWallpaperSource: FoldFrameSource {
    private(set) var hasFrame = false
    private(set) var lastError: String?
    var onFullFrame: (@MainActor (CVPixelBuffer) -> Void)?
    var onFarFrame: (@MainActor (CVPixelBuffer) -> Void)?
    var onCards: (@MainActor ([PortalDepth.Card]) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    private var buffer: CVPixelBuffer?
    /// Bumped by every start and stop: a decode that finishes after a
    /// stop (or a newer start) hands nothing over.
    private var generation = 0

    func start() async throws {
        guard let screen = FoldOverlayWindow.builtinScreen() else {
            throw FoldCaptureError.noBuiltinDisplay
        }
        let workspace = NSWorkspace.shared
        guard let url = workspace.desktopImageURL(for: screen) else {
            lastError = FoldWallpaperError.noWallpaper.localizedDescription
            throw FoldWallpaperError.noWallpaper
        }
        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        let layout = Self.layout(options: options)
        let fill = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB)?.cgColor
            ?? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let pixels = Self.pixelSize(points: screen.frame.size, scale: screen.backingScaleFactor)
        generation += 1
        let mine = generation
        let result = await Self.frame(from: url, into: pixels, layout: layout, fill: fill)
        guard mine == generation else { return }
        let buffer: CVPixelBuffer
        switch result {
        case .success(let frame):
            buffer = frame.buffer
        case .failure(let error):
            lastError = error.localizedDescription
            throw error
        }
        self.buffer = buffer
        hasFrame = true
        onCards?([])
        onFarFrame?(buffer)
        onFullFrame?(buffer)
    }

    func stop() async {
        generation += 1
        buffer = nil
        hasFrame = false
    }

    /// A finished frame crossing back from the decode. The buffer is
    /// made and filled on the decode's task and only read after that.
    struct Frame: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    /// Reads the picture at `url` and draws it into a frame, on a task
    /// of its own so the main actor never waits on the decode.
    nonisolated static func frame(from url: URL, into pixels: CGSize, layout: Layout,
                                  fill: CGColor) async -> Result<Frame, FoldWallpaperError> {
        await Task.detached(priority: .userInitiated) {
            guard let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return .failure(.noWallpaper) }
            guard let buffer = render(cgImage, into: pixels, layout: layout, fill: fill) else {
                return .failure(.noBuffer)
            }
            return .success(Frame(buffer: buffer))
        }.value
    }

    // MARK: Pure layout

    /// How the desktop lays its picture out, from its image options.
    enum Layout: Equatable, Sendable {
        case fill, fit, stretch, center
    }

    /// The desktop's own reading of its options: proportional scaling
    /// clips (fill) unless clipping is off (fit), axes-independent
    /// stretches, and no scaling centres. Missing options are fill —
    /// the system default.
    static func layout(options: [NSWorkspace.DesktopImageOptionKey: Any]) -> Layout {
        let raw = (options[.imageScaling] as? NSNumber)?.uintValue
            ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue
        let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        switch NSImageScaling(rawValue: raw) {
        case .scaleAxesIndependently: return .stretch
        case .scaleNone: return .center
        case .scaleProportionallyDown, .scaleProportionallyUpOrDown:
            return clipping ? .fill : .fit
        default: return .fill
        }
    }

    /// Where the picture lands on a canvas of `canvas` pixels, top-left
    /// origin. Fill covers and crops the overflow evenly, fit letterboxes,
    /// stretch covers exactly, centre keeps the image's own pixels.
    nonisolated static func drawRect(image: CGSize, canvas: CGSize, layout: Layout) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: canvas) }
        let size: CGSize
        switch layout {
        case .stretch:
            return CGRect(origin: .zero, size: canvas)
        case .center:
            size = image
        case .fill, .fit:
            let sx = canvas.width / image.width
            let sy = canvas.height / image.height
            let s = layout == .fill ? max(sx, sy) : min(sx, sy)
            size = CGSize(width: image.width * s, height: image.height * s)
        }
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The frame the renderer gets: the display's pixels, capped at
    /// 2560 on the long edge like the capture — the fold defocuses the
    /// picture anyway.
    static func pixelSize(points: CGSize, scale: CGFloat) -> CGSize {
        let full = CGSize(width: points.width * scale, height: points.height * scale)
        let cap = min(1, 2560 / max(1, max(full.width, full.height)))
        return CGSize(width: (full.width * cap).rounded(), height: (full.height * cap).rounded())
    }

    /// Draws `image` into a new BGRA, IOSurface-backed, Metal-compatible
    /// buffer — the same shape a ScreenCaptureKit frame arrives in, rows
    /// top first — over `fill` for any letterbox.
    nonisolated static func render(_ image: CGImage, into pixels: CGSize, layout: Layout,
                                   fill: CGColor) -> CVPixelBuffer? {
        let width = Int(pixels.width), height = Int(pixels.height)
        guard width > 0, height > 0 else { return nil }
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &created) == kCVReturnSuccess,
              let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(fill)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        // The layout is top-left; CoreGraphics draws bottom-left, and the
        // bitmap's first row is the top — flip the rect, not the image.
        let rect = drawRect(image: CGSize(width: image.width, height: image.height),
                            canvas: CGSize(width: width, height: height), layout: layout)
        context.draw(image, in: CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY,
                                       width: rect.width, height: rect.height))
        return buffer
    }
}
