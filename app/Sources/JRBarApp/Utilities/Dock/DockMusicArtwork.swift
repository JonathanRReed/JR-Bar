import AppKit
import CoreImage
import ImageIO
import JRBarCore
import SwiftUI

/// The player needs a larger cover than the notch's 96-pixel thumbnail.
@MainActor
enum DockMusicArtwork {
    struct Cover {
        let image: NSImage
        let tint: Color
    }
    private struct Entry {
        let key: ArtworkPrint
        let cover: Cover?
    }
    private static var entries: [Entry] = []

    static func cover(for data: Data) -> Cover? {
        let key = ArtworkPrint(data)
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let hit = entries.remove(at: index)
            entries.append(hit)
            return hit.cover
        }
        let cover = decode(data)
        entries.append(Entry(key: key, cover: cover))
        if entries.count > 4 { entries.removeFirst() }
        return cover
    }

    private static func decode(_ data: Data) -> Cover? {
        guard data.count <= ShelfUtilityModel.maxArtworkBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: thumbnail, size: CGSize(width: thumbnail.width, height: thumbnail.height))
        let rgb = ShelfUtilityModel.averageColor(of: CIImage(cgImage: thumbnail))
        let tint = rgb.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .primary
        return Cover(image: image, tint: tint)
    }
}
