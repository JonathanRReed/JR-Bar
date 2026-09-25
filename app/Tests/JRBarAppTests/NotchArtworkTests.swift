import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Album art is decoded once per cover, small, and off the main thread;
/// the helper's lines are parsed off the main thread too, and a cover
/// re-sent with a pause or a seek is not decoded again.
@Suite("Notch artwork")
@MainActor
struct NotchArtworkTests {
    /// A cover made in memory — a gradient, so it is a real image.
    static func cover(side: Int = 200, hue: CGFloat = 0.02) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(colors: [NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1),
                            NSColor(hue: hue, saturation: 0.9, brightness: 0.4, alpha: 1)])?
            .draw(in: NSRect(x: 0, y: 0, width: side, height: side), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// A monitor the test hands media to by hand; no helper runs.
    private final class ArtMonitor: AlcoveMediaMonitor {
        override func start() { markRunning(true) }
        override func stop() { markRunning(false) }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [Bool] = []
        func note() { lock.withLock { calls.append(Thread.isMainThread) } }
        var count: Int { lock.withLock { calls.count } }
        var anyOnMain: Bool { lock.withLock { calls.contains(true) } }
    }

    @Test("the same cover hits the cache; a new cover misses it; decodes never run on main")
    func cacheHitsAndMisses() {
        let counter = Counter()
        let store = NotchArtworkStore { data in
            counter.note()
            return NotchArtworkStore.decodeCover(data)
        }
        let first = Self.cover(hue: 0.02)
        let second = Self.cover(hue: 0.6)
        var got: [NSImage?] = []
        store.art(for: first) { got.append($0?.image) }
        store.art(for: first) { got.append($0?.image) }   // waits on the same decode
        #expect(got.isEmpty, "nothing is decoded in the asking turn")
        store.flush()
        #expect(got.count == 2)
        #expect(counter.count == 1, "one decode for two askers")
        store.art(for: first) { got.append($0?.image) }
        #expect(got.count == 3, "a decoded cover answers at once")
        #expect(counter.count == 1, "and is not decoded again")
        store.art(for: second) { got.append($0?.image) }
        store.flush()
        #expect(counter.count == 2, "a new cover is")
        #expect(store.decodes == 2)
        #expect(!counter.anyOnMain)
    }

    @Test("the thumbnail is small and the tint is the cover's colour")
    func thumbnailAndTint() throws {
        let art = try #require(NotchArtworkStore.decodeCover(Self.cover(side: 640, hue: 0.6)))
        // The image is sized in the thumbnail's own pixels.
        let size = art.image.size
        #expect(max(size.width, size.height) == CGFloat(NotchArtworkStore.thumbnailPixels))
        let tint = try #require(art.tint?.usingColorSpace(.deviceRGB))
        #expect(tint.blueComponent > tint.redComponent, "a blue cover tints blue")
        #expect(NotchArtworkStore.decodeCover(Data("not an image".utf8)) == nil)
        let huge = Data(count: ShelfUtilityModel.maxArtworkBytes + 1)
        #expect(NotchArtworkStore.decodeCover(huge) == nil, "an oversized payload is refused unread")
    }

    @Test("the card's artwork and tint arrive off the main thread and stay put for a pause")
    func cardArtwork() {
        let monitor = ArtMonitor()
        let utility = ShelfUtilityModel(feed: MediaFeed(monitor: monitor))
        let counter = Counter()
        utility.artworkStore = NotchArtworkStore { data in
            counter.note()
            return NotchArtworkStore.decodeCover(data)
        }
        utility.start()
        defer { utility.stop() }
        let cover = Self.cover(hue: 0.02)
        monitor.onChange?(AlcoveMedia(title: "Midnight City", playing: true, artworkData: cover))
        #expect(utility.artwork == nil, "the decode is not on this turn")
        utility.artworkStore.flush()
        #expect(utility.artwork != nil)
        #expect(utility.artworkTint != nil)
        // A pause re-sends the same cover: nothing is decoded again.
        monitor.onChange?(AlcoveMedia(title: "Midnight City", playing: false, artworkData: cover))
        utility.artworkStore.flush()
        #expect(counter.count == 1)
        #expect(!counter.anyOnMain)
        monitor.onChange?(AlcoveMedia(title: "Silence", playing: true))
        #expect(utility.artwork == nil, "no cover, no art")
    }

    @Test("a headless card decodes in the turn it draws")
    func headlessDecodesInline() {
        let monitor = ArtMonitor()
        let model = NotchCardModel(
            timers: ShelfTimerModel(storeURL: URL(fileURLWithPath:
                NSTemporaryDirectory() + "jrbar-test-timers-\(UUID().uuidString).json")),
            tray: ShelfTrayModel(), utility: ShelfUtilityModel(feed: MediaFeed(monitor: monitor)),
            runtimeEnabled: false)
        model.utility.start()
        defer { model.utility.stop() }
        monitor.onChange?(AlcoveMedia(title: "Midnight City", playing: true, artworkData: Self.cover()))
        #expect(model.utility.artwork != nil)
    }

    @Test("the island's strip gets the same cover, decoded once")
    func islandStrip() {
        var toys = ToysState()
        toys.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: toys,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        defer { withExtendedLifetime(store) {} }
        let toy: NotchToy = store.notch
        let cover = Self.cover(hue: 0.3)
        toy.noteMedia(AlcoveMedia(title: "Papillon", playing: true, artworkData: cover))
        #expect(toy.islandArtwork != nil)
        toy.noteMedia(AlcoveMedia(title: "Papillon", playing: false, artworkData: cover))
        #expect(toy.islandArtwork != nil)
        toy.noteMedia(nil)
        #expect(toy.islandArtwork == nil)
    }

    // MARK: The helper's lines

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var got: [AlcoveMedia?] = []
        private var threads: [Bool] = []
        func add(_ lines: [AlcoveMedia?]) {
            lock.withLock {
                got += lines
                threads.append(Thread.isMainThread)
            }
        }
        var media: [AlcoveMedia?] { lock.withLock { got } }
        var anyOnMain: Bool { lock.withLock { threads.contains(true) } }
    }

    private static func line(title: String, playing: Bool, cover: Data?) -> Data {
        var payload: [String: Any] = ["title": title, "playing": playing]
        if let cover { payload["artworkData"] = cover.base64EncodedString() }
        var data = try! JSONSerialization.data(withJSONObject: payload)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    @Test("lines split across chunks are parsed off the main thread, in order")
    func readerSplitsLines() {
        let lines = Lines()
        let reader = AlcoveMediaLineReader { lines.add($0) }
        let cover = Self.cover(side: 300)
        var stream = Self.line(title: "One", playing: true, cover: cover)
        stream.append(Data("null\n".utf8))
        stream.append(Self.line(title: "Two", playing: false, cover: nil))
        // Hand it over the way a pipe does: in pieces that cut lines.
        var offset = 0
        for size in [7, 4096, 13, 65_536, 1, 200_000] where offset < stream.count {
            let end = min(stream.count, offset + size)
            reader.feed(stream.subdata(in: offset..<end))
            offset = end
        }
        if offset < stream.count { reader.feed(stream.subdata(in: offset..<stream.count)) }
        reader.drain()
        let media = lines.media
        #expect(media.count == 3)
        #expect(media.first??.title == "One")
        #expect(media.first??.artworkData == cover)
        #expect(media[1] == nil, "the helper's null is nothing playing")
        #expect(media.last??.title == "Two")
        #expect(!lines.anyOnMain)
    }

    @Test("a cover re-sent with a pause is the same bytes, not a second decode")
    func readerReusesTheCover() throws {
        let cover = Self.cover(side: 300)
        var last: AlcoveMediaLineReader.Cover?
        let first = AlcoveMediaAdapter.parse(Self.line(title: "One", playing: true, cover: cover).dropLast(),
                                             cover: &last)
        let paused = AlcoveMediaAdapter.parse(Self.line(title: "One", playing: false, cover: cover).dropLast(),
                                              cover: &last)
        let a = try #require(first?.artworkData)
        let b = try #require(paused?.artworkData)
        #expect(a == cover)
        a.withUnsafeBytes { left in
            b.withUnsafeBytes { right in
                #expect(left.baseAddress == right.baseAddress, "the same storage, so later compares are free")
            }
        }
        let other = Self.cover(side: 300, hue: 0.7)
        let next = AlcoveMediaAdapter.parse(Self.line(title: "Two", playing: true, cover: other).dropLast(),
                                            cover: &last)
        #expect(next?.artworkData == other)
        #expect(AlcoveMediaAdapter.parse(Data("null".utf8)) == nil)
    }
}
