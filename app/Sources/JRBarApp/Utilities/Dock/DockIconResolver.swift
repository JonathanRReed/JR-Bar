import AppKit

/// Renders the cached app icon at the preview size.
@MainActor
enum DockIconResolver {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()
    static func icon(appURL: URL, pointSize: CGFloat, scale: CGFloat) -> NSImage {
        let source = ExternalFileMetadata.shared.icon(appURL)
        let key = "\(appURL.path)|\(ExternalFileMetadata.shared.version)|\(ObjectIdentifier(source))|\(pointSize)|\(scale)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = rasterized(source, pointSize: pointSize, scale: scale)
        cache.setObject(image, forKey: key)
        return image
    }

    static func bundleIcon(for url: URL) -> NSImage? {
        ExternalFileMetadata.shared.cachedIcon(url)
    }

    /// Draw `source` into a fresh bitmap and return an image whose
    /// point size is `pointSize` — a real Retina asset instead of a
    /// rep SwiftUI rescales per frame. The pixel target is capped at
    /// the source's best representation so a 32 px rep is never
    /// smeared across a 2× canvas and called sharp; the view still
    /// draws it large, just honestly.
    static func rasterized(_ source: NSImage, pointSize: CGFloat, scale: CGFloat) -> NSImage {
        let points = NSSize(width: pointSize, height: pointSize)
        let wanted = Int((pointSize * max(1, scale)).rounded())
        let best = source.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        // Never draw past the source's best rep — a 32 px icon stays a
        // 32 px asset rather than a smeared 112 px one. Reps that
        // report no pixel size (vector) get the full target.
        let pixels = max(1, best > 0 ? min(wanted, best) : wanted)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else {
            source.size = points
            return source
        }
        rep.size = points
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: points),
                    from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: points)
        image.addRepresentation(rep)
        return image
    }
}
