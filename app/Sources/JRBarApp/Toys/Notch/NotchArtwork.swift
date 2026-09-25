import AppKit
import CoreImage
import ImageIO
import JRBarCore

/// Album art, decoded once per cover and off the main thread: a
/// thumbnail just big enough for the card's 48-point artwork on a Retina
/// screen, and the cover's tint, made together on a background queue.
/// The island's idle strip and the card's media row both read what it
/// hands back. Before, the strip decoded the full cover 15 times a
/// second while the breath ran (11–55 ms a second on the main thread),
/// and the card decoded it on every read.
@MainActor
final class NotchArtworkStore {
    static let shared = NotchArtworkStore()

    /// One decoded cover.
    struct Art: @unchecked Sendable {
        /// The thumbnail — at most `thumbnailPixels` on its long side.
        let image: NSImage
        /// The cover's own colour, made readable on black; nil for art
        /// too grey to have one (`ShelfUtilityModel.readableTint`).
        let tint: NSColor?
    }

    /// The thumbnail's long side in pixels: the card's 48-point art at 2×.
    nonisolated static let thumbnailPixels = 96
    /// Covers kept decoded — the playing one and a few before it, so a
    /// skip back does not decode again.
    nonisolated static let cacheLimit = 4

    /// How a cover is decoded. Runs on `queue`; the tests hand in a
    /// counter.
    let decode: @Sendable (Data) -> Art?
    /// Where decodes run.
    nonisolated let queue = DispatchQueue(label: "jrbar.notch-artwork", qos: .userInitiated)
    /// Decodes started — the tests' window on the cache.
    private(set) var decodes = 0

    /// Cache and waiting lists key on the cover's `ArtworkPrint`: the
    /// helper resends the same cover on every media line, and a byte
    /// compare of up to `maxArtworkBytes` per lookup was the cost.
    private var cache: [(print: ArtworkPrint, art: Art?)] = []
    private var waiting: [(print: ArtworkPrint, waiters: [@MainActor (Art?) -> Void])] = []
    private let inbox = Inbox()

    init(decode: @escaping @Sendable (Data) -> Art? = NotchArtworkStore.decodeCover) {
        self.decode = decode
    }

    /// Hands `done` the art for `data`: at once for a cover decoded
    /// before, otherwise once the background decode lands. nil for data
    /// that is not an image or is larger than a cover should be.
    /// `inline` decodes on the spot — a headless surface (a test, a
    /// render proof) that draws in the same turn and has no frame to
    /// protect.
    func art(for data: Data, inline: Bool = false, _ done: @escaping @MainActor (Art?) -> Void) {
        let print = ArtworkPrint(data)
        if let index = cache.firstIndex(where: { $0.print == print }) {
            // Most recent last, so the oldest cover leaves first.
            let hit = cache.remove(at: index)
            cache.append(hit)
            done(hit.art)
            return
        }
        if inline {
            decodes += 1
            let art = decode(data)
            remember(print, art)
            done(art)
            return
        }
        if let index = waiting.firstIndex(where: { $0.print == print }) {
            waiting[index].waiters.append(done)
            return
        }
        waiting.append((print, [done]))
        decodes += 1
        let decode = self.decode
        let inbox = self.inbox
        queue.async { [weak self] in
            inbox.put(print, decode(data))
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.deliver() }
            }
        }
    }

    /// Hands every finished decode to whoever waits for it — the main
    /// queue's next turn after a decode, or `flush`.
    func deliver() {
        for (print, art) in inbox.take() {
            remember(print, art)
            guard let index = waiting.firstIndex(where: { $0.print == print }) else { continue }
            let waiters = waiting.remove(at: index).waiters
            for waiter in waiters { waiter(art) }
        }
    }

    private func remember(_ print: ArtworkPrint, _ art: Art?) {
        cache.append((print, art))
        if cache.count > Self.cacheLimit { cache.removeFirst(cache.count - Self.cacheLimit) }
    }

    /// Waits for every decode asked for so far and delivers it now — for
    /// a render proof or a test that draws in the same turn.
    func flush() {
        queue.sync {}
        deliver()
    }

    /// The decode itself: an ImageIO thumbnail — the full cover is never
    /// drawn — and the tint read off it. Off the main thread.
    nonisolated static func decodeCover(_ data: Data) -> Art? {
        guard data.count <= ShelfUtilityModel.maxArtworkBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: thumbnail,
                            size: NSSize(width: thumbnail.width, height: thumbnail.height))
        let tint = ShelfUtilityModel.averageColor(of: CIImage(cgImage: thumbnail)).flatMap {
            ShelfUtilityModel.readableTint(red: $0.red, green: $0.green, blue: $0.blue)
        }.map { NSColor(hue: $0.hue, saturation: $0.saturation, brightness: $0.brightness, alpha: 1) }
        return Art(image: image, tint: tint)
    }

    /// Finished decodes on their way from the queue to the main thread.
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var done: [(ArtworkPrint, Art?)] = []

        func put(_ print: ArtworkPrint, _ art: Art?) {
            lock.withLock { done.append((print, art)) }
        }

        func take() -> [(ArtworkPrint, Art?)] {
            lock.withLock {
                defer { done = [] }
                return done
            }
        }
    }
}
