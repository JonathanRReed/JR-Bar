import AppKit

/// Where a tile's image comes from and how it lands on the glass.
///
/// The old path — `NSWorkspace.icon(forFile:)` on whatever `bundleURL`
/// carried — produced the generic white-page icon for apps Launch
/// Services can't describe (the "blown-out white squares"), and handed
/// SwiftUI a multi-rep `NSImage` it rescaled every frame (the blur).
/// Resolution is now a chain — the running app's own Dock icon, the
/// bundle's declared icon, the workspace's read — and the winner is
/// rasterized once at the display's pixel density, then cached, so a
/// magnification frame never re-queries the workspace. MainActor —
/// icons are a view-thread concern anyway.
@MainActor
enum DockIconResolver {
    /// `(bundleID, render size, scale)` → finished image. App icons
    /// change on app update, not mid-session; a stale hour is fine.
    private static let cache = NSCache<NSString, NSImage>()

    /// The finished tile image: `pointSize`×`pointSize` *points* whose
    /// bitmap is `pointSize × scale` *pixels*. Always returns an image
    /// — the dashed placeholder is the last resort, never a blank.
    static func icon(for item: DockItem, pointSize: CGFloat, scale: CGFloat) -> NSImage {
        let key = "\(item.bundleID)|\(Int(pointSize))|\(Int(scale))|\(item.trashIsEmpty)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image: NSImage
        if let source = sourceImage(for: item) {
            image = rasterized(source, pointSize: pointSize, scale: scale)
        } else {
            image = placeholder(for: item, pointSize: pointSize)
        }
        cache.setObject(image, forKey: key)
        return image
    }

    /// A file or folder's icon — the workspace read, rasterized and
    /// cached like an app icon so folder-stack cells and tray tiles
    /// are sharp too. Deliberately not `bundleIcon`-first: documents
    /// have no bundle to interrogate.
    static func icon(fileURL: URL, pointSize: CGFloat, scale: CGFloat) -> NSImage {
        let key = "file|\(fileURL.path)|\(Int(pointSize))|\(Int(scale))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = rasterized(NSWorkspace.shared.icon(forFile: fileURL.path),
                               pointSize: pointSize, scale: scale)
        cache.setObject(image, forKey: key)
        return image
    }

    /// An app's icon by file URL — the same chain the item path uses,
    /// for callers (the Enhance preview) that hold a URL, not a tile.
    static func icon(appURL: URL, pointSize: CGFloat, scale: CGFloat) -> NSImage {
        let key = "url|\(appURL.path)|\(Int(pointSize))|\(Int(scale))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let source = bundleIcon(for: appURL) ?? NSWorkspace.shared.icon(forFile: appURL.path)
        let image = rasterized(source, pointSize: pointSize, scale: scale)
        cache.setObject(image, forKey: key)
        return image
    }

    /// First real icon the item can produce, highest fidelity first:
    /// the running app's icon (what Apple's Dock actually shows),
    /// the bundle's declared icon, then the workspace's read — which
    /// is last because it happily returns the generic white page.
    static func sourceImage(for item: DockItem) -> NSImage? {
        if item.isTrash {
            // NSWorkspace special-cases ~/.Trash with the real can.
            return NSWorkspace.shared.icon(forFile: DockModel.trashURL.path)
        }
        if item.isFolder || item.isTrayItem {
            // The folder glyph / the document's own icon.
            return item.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        if let pid = item.processIdentifier,
           let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            return icon
        }
        if let url = item.bundleURL {
            return bundleIcon(for: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    /// The icon the bundle itself declares — `CFBundleIconFile` /
    /// `CFBundleIconName` resolved through the bundle so asset-catalog
    /// icons load too. More honest than the workspace's read when the
    /// file URL is odd (a `.app` inside a wrapper, a quarantined copy).
    static func bundleIcon(for url: URL) -> NSImage? {
        guard let bundle = Bundle(url: url),
              let raw = (bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String)
                  ?? (bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String),
              !raw.isEmpty else { return nil }
        let name = (raw as NSString).deletingPathExtension
        return bundle.image(forResource: raw) ?? bundle.image(forResource: name)
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

    /// The last resort: a recognisable symbol at the right size —
    /// better than the workspace's blank white page.
    private static func placeholder(for item: DockItem, pointSize: CGFloat) -> NSImage {
        let image = NSImage(systemSymbolName: item.isTrash ? "trash" : "app.dashed",
                            accessibilityDescription: item.name)
        image?.size = NSSize(width: pointSize, height: pointSize)
        return image ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
    }
}
