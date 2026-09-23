import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// The Item Bar's photographed glyphs: lifting a glyph off the bar,
/// rejecting mid-fade frames, filing per item and appearance, and the
/// native-width tiles they buy.
@Suite("Menu Bar — the glyph cache")
struct MenuBarGlyphCacheTests {
    typealias Raster = MenuBarGlyphProcessing.Raster

    /// A `size`² raster of `bg` with a `glyph`-coloured square of side
    /// `side` in the middle.
    private func raster(size: Int = 16, bg: (UInt8, UInt8, UInt8) = (40, 40, 44),
                        glyph: (UInt8, UInt8, UInt8)? = (240, 240, 240),
                        side: Int = 6, offset: Int = 0) -> Raster {
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        let lo = (size - side) / 2 + offset
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let inside = glyph != nil && x >= lo && x < lo + side && y >= lo && y < lo + side
                let c = inside ? glyph! : bg
                pixels[i] = c.0; pixels[i + 1] = c.1; pixels[i + 2] = c.2; pixels[i + 3] = 255
            }
        }
        return Raster(width: size, height: size, pixels: pixels)
    }

    private func cgImage(_ raster: Raster) -> CGImage {
        let provider = CGDataProvider(data: Data(raster.pixels) as CFData)!
        return CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: raster.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    private func item(_ id: String, bundle: String? = "com.example.app", x: CGFloat = 100) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: 1, ownerName: "Example",
                    bounds: CGRect(x: x, y: 0, width: 16, height: 16), title: nil,
                    windowID: 1, bundleID: bundle)
    }

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-glyphs-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: Pixels

    @Test("a grey glyph on the bar lifts off as a template: black, alpha where it stood")
    func templateExtraction() throws {
        let glyph = try #require(MenuBarGlyphProcessing.extract(raster()))
        #expect(glyph.template)
        #expect(abs(glyph.coverage - 36.0 / 256.0) < 0.001)
        let centre = glyph.raster.pixel(8, 8)
        #expect(centre.a == 255 && centre.r == 0)
        #expect(glyph.raster.pixel(0, 0).a == 0, "the bar itself is transparent")
    }

    @Test("a coloured glyph keeps its colour and is not re-tinted")
    func colouredExtraction() throws {
        let glyph = try #require(MenuBarGlyphProcessing.extract(raster(glyph: (230, 40, 30))))
        #expect(!glyph.template)
        let centre = glyph.raster.pixel(8, 8)
        #expect(centre.r == 230 && centre.a == 255)
    }

    @Test("an empty rect (an undrawn ghost) and a solid block (a highlight) are no glyph")
    func rejectsEmptyAndSolid() {
        #expect(MenuBarGlyphProcessing.extract(raster(glyph: nil)) == nil)
        #expect(MenuBarGlyphProcessing.extract(raster(side: 16)) == nil)
    }

    @Test("the background is the border's median — a glyph touching one edge does not move it")
    func backgroundMedian() {
        let bg = MenuBarGlyphProcessing.background(raster(side: 6, offset: 5))
        #expect(bg.r == 40 && bg.g == 40 && bg.b == 44)
    }

    @Test("two frames agree only when nothing faded between them")
    func midFade() {
        let settled = raster()
        #expect(MenuBarGlyphProcessing.framesAgree(settled, settled))
        let fading = raster(glyph: (120, 120, 120))
        #expect(!MenuBarGlyphProcessing.framesAgree(settled, fading))
        #expect(!MenuBarGlyphProcessing.framesAgree(settled, raster(size: 12)))
        var grain = settled
        grain.pixels[0] &+= 3
        #expect(MenuBarGlyphProcessing.framesAgree(settled, grain), "the material's grain is not a fade")
    }

    @Test("a fingerprint ignores the bar's grain and sees a new badge")
    func fingerprint() throws {
        let a = try #require(MenuBarGlyphProcessing.extract(raster()))
        var noisy = raster()
        noisy.pixels[4 * 17] &+= 2
        let b = try #require(MenuBarGlyphProcessing.extract(noisy))
        #expect(MenuBarGlyphProcessing.fingerprint(a) == MenuBarGlyphProcessing.fingerprint(b))
        let moved = try #require(MenuBarGlyphProcessing.extract(raster(offset: 2)))
        #expect(MenuBarGlyphProcessing.fingerprint(a) != MenuBarGlyphProcessing.fingerprint(moved))
    }

    // MARK: Native-width tiles

    @Test("a glyph tile takes the item's own width, clamped; an icon stays square")
    func tileWidths() {
        #expect(MenuBarGlyphProcessing.tileWidth(pointWidth: 10) == MenuBarBarLayout.minTileWidth)
        #expect(MenuBarGlyphProcessing.tileWidth(pointWidth: 58.4) == 58)
        #expect(MenuBarGlyphProcessing.tileWidth(pointWidth: 400) == MenuBarBarLayout.maxTileWidth)
        #expect(MenuBarBarLayout.tileWidth(glyphWidth: nil) == MenuBarBarLayout.tileSize)
        #expect(MenuBarBarLayout.rowWidth(widths: [30, 58, 22])
                == 110 + 2 * MenuBarBarLayout.tileGap)
        #expect(MenuBarBarLayout.rowWidth(itemCount: 3)
                == MenuBarBarLayout.rowWidth(widths: [30, 30, 30]))
    }

    @Test("the bar hangs under the icon's ‹ when given, and never leaves the screen")
    func anchoredFrame() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let widths: [CGFloat] = [30, 58]
        let free = MenuBarBarLayout.frame(widths: widths, menuBarDepth: 37, on: screen)
        #expect(free.maxX == screen.maxX - MenuBarBarLayout.edgeMargin)
        let anchored = MenuBarBarLayout.frame(widths: widths, menuBarDepth: 37, on: screen,
                                              anchorMaxX: 1100)
        #expect(anchored.maxX == 1100)
        #expect(anchored.width == free.width)
        let offLeft = MenuBarBarLayout.frame(widths: widths, menuBarDepth: 37, on: screen,
                                             anchorMaxX: 20)
        #expect(offLeft.minX == screen.minX + MenuBarBarLayout.edgeMargin)
    }

    @MainActor
    @Test("tile widths follow live captures first, then glyphs, then the square")
    func modelWidths() {
        let model = MenuBarBarModel()
        model.items = [item("a"), item("b"), item("c")]
        model.glyphs = ["b": MenuBarGlyphCache.Face(image: NSImage(), width: 64, template: true)]
        #expect(model.tileWidths(liveWidths: ["a": 44]) == [44, 64, MenuBarBarLayout.tileSize])
    }

    // MARK: The cache on disk

    @MainActor
    @Test("a glyph files per item and appearance, survives a relaunch, and knows when it changed")
    func cacheRoundTrip() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = MenuBarGlyphCache(directory: dir)
        let tile = item("Example·Sync")
        let glyph = try #require(MenuBarGlyphProcessing.extract(raster()))
        #expect(!cache.store(glyph, for: tile, dark: true, pointSize: CGSize(width: 22, height: 24)),
                "a first photograph is not a change")
        #expect(cache.face(for: tile, dark: true)?.width == 22)
        #expect(cache.face(for: tile, dark: false)?.template == true, "the other appearance stands in")
        #expect(!cache.store(glyph, for: tile, dark: true, pointSize: CGSize(width: 22, height: 24)))
        let moved = try #require(MenuBarGlyphProcessing.extract(raster(offset: 2)))
        #expect(cache.store(moved, for: tile, dark: true, pointSize: CGSize(width: 22, height: 24)))

        let reopened = MenuBarGlyphCache(directory: dir)
        let face = try #require(reopened.face(for: tile, dark: true))
        #expect(face.width == 22)
        #expect(face.template)
        #expect(face.image.isTemplate)
        #expect(reopened.face(for: item("other"), dark: true) == nil)
    }

    @MainActor
    @Test("a glyph wide enough to carry text is kept in memory only and never reaches the disk")
    func wideGlyphsStayInMemory() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = MenuBarGlyphCache(directory: dir)
        let vpn = item("Example·VPN")
        let glyph = try #require(MenuBarGlyphProcessing.extract(raster()))
        // A VPN's name, a clock, an event title: 58 pt of the person's words.
        cache.store(glyph, for: vpn, dark: true, pointSize: CGSize(width: 58, height: 24))
        #expect(cache.face(for: vpn, dark: true)?.width == 58, "this run still wears it")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!files.contains { $0.hasSuffix(".png") }, "no picture of it is written")
        #expect(MenuBarGlyphCache(directory: dir).face(for: vpn, dark: true) == nil,
                "a relaunch photographs it afresh")
        // The cap is the icon's width, inclusive.
        #expect(MenuBarGlyphCache.persists(width: MenuBarGlyphCache.persistMaxWidth))
        #expect(!MenuBarGlyphCache.persists(width: MenuBarGlyphCache.persistMaxWidth + 0.5))
    }

    @MainActor
    @Test("an icon that grows text takes its file with it")
    func glyphThatGrowsText() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = MenuBarGlyphCache(directory: dir)
        let clock = item("Example·Timer")
        let glyph = try #require(MenuBarGlyphProcessing.extract(raster()))
        cache.store(glyph, for: clock, dark: true, pointSize: CGSize(width: 20, height: 24))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.count == 1)
        cache.store(glyph, for: clock, dark: true, pointSize: CGSize(width: 64, height: 24))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.isEmpty)
        #expect(MenuBarGlyphCache(directory: dir).index.isEmpty)
    }

    @MainActor
    @Test("a cache written before the width cap drops its wide photographs on first open")
    func legacyWideEntriesGo() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wide = MenuBarGlyphCache.Entry(file: "wide.png", width: 72, height: 24, template: true,
                                           capturedAt: Date().timeIntervalSince1970, fingerprint: 1)
        let icon = MenuBarGlyphCache.Entry(file: "icon.png", width: 22, height: 24, template: true,
                                           capturedAt: Date().timeIntervalSince1970, fingerprint: 2)
        try JSONEncoder().encode(["a|wide|dark": wide, "a|icon|dark": icon])
            .write(to: dir.appendingPathComponent("index.json"))
        try Data([1]).write(to: dir.appendingPathComponent("wide.png"))
        try Data([1]).write(to: dir.appendingPathComponent("icon.png"))
        let cache = MenuBarGlyphCache(directory: dir)
        #expect(Array(cache.index.keys) == ["a|icon|dark"])
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!files.contains("wide.png"))
        #expect(files.contains("icon.png"))
        #expect(MenuBarGlyphCache(directory: dir).index.count == 1, "the index on disk says so too")
    }

    @MainActor
    @Test("nothing outlives thirty days, whoever owns it — and a photograph pass holds the cap")
    func ageCap() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = MenuBarGlyphCache(directory: dir)
        let glyph = try #require(MenuBarGlyphProcessing.extract(raster()))
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        cache.store(glyph, for: item("running", bundle: "com.apple.finder"), dark: true,
                    pointSize: CGSize(width: 16, height: 16),
                    now: now.addingTimeInterval(-MenuBarGlyphCache.pruneAge - 60))
        cache.store(glyph, for: item("fresh", bundle: "com.example.fresh"), dark: true,
                    pointSize: CGSize(width: 16, height: 16), now: now.addingTimeInterval(-3600))
        cache.expire(now: now)
        #expect(Set(cache.index.keys.map { String($0.split(separator: "|")[1]) }) == ["fresh"],
                "an app still installed and running is no exemption")
        #expect(MenuBarGlyphCache(directory: dir).index.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.count == 1)

        // The camera expires at the start of every pass.
        let camera = MenuBarGlyphCamera(cache: cache)
        camera.permitted = { true }
        camera.dark = { true }
        camera.capture = { _ in self.cgImage(self.raster()) }
        let later = now.addingTimeInterval(MenuBarGlyphCache.pruneAge)
        _ = await camera.photograph([item("new")], rows: [CGRect(x: 0, y: 0, width: 2000, height: 24)],
                                    now: { later })
        #expect(cache.index.keys.contains { $0.contains("|new|") })
        #expect(!cache.index.keys.contains { $0.contains("|fresh|") }, "a month on, the pass forgot it")
    }

    @MainActor
    @Test("pruning drops the photographs of apps that are gone, and hears when each was taken")
    func prune() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = MenuBarGlyphCache(directory: dir)
        let glyph = try #require(MenuBarGlyphProcessing.extract(raster()))
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 1_000 + MenuBarGlyphCache.pruneAge)
        cache.store(glyph, for: item("a", bundle: "keep.app"), dark: true,
                    pointSize: CGSize(width: 16, height: 16), now: old)
        cache.store(glyph, for: item("b", bundle: "gone.app"), dark: true,
                    pointSize: CGSize(width: 16, height: 16), now: old)
        cache.store(glyph, for: item("c", bundle: "quiet.app"), dark: true,
                    pointSize: CGSize(width: 16, height: 16), now: recent)
        var heard: [String: Date] = [:]
        cache.prune { owner, capturedAt in
            heard[owner] = capturedAt
            return owner == "keep.app" || capturedAt >= recent
        }
        #expect(heard["gone.app"] == old)
        #expect(Set(cache.index.keys.map { String($0.split(separator: "|")[0]) }) == ["keep.app", "quiet.app"])
        #expect(MenuBarGlyphCache(directory: dir).index.count == 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }
        #expect(files.count == 2, "a pruned photograph takes its file with it")
    }

    @Test("past the cap the oldest photographs go first, never the one just filed")
    func overflow() {
        func entry(_ at: Double) -> MenuBarGlyphCache.Entry {
            MenuBarGlyphCache.Entry(file: "\(at).png", width: 16, height: 16, template: true,
                                    capturedAt: at, fingerprint: 0)
        }
        let index = ["a": entry(3), "b": entry(1), "c": entry(2), "new": entry(0)]
        #expect(MenuBarGlyphCache.overflow(index, keeping: "new", limit: 4).isEmpty)
        #expect(MenuBarGlyphCache.overflow(index, keeping: "new", limit: 2) == ["b", "c"])
    }

    @MainActor
    @Test("filing past the cap evicts on disk too")
    func cacheCap() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = MenuBarGlyphCache(directory: dir)
        let glyph = try #require(MenuBarGlyphProcessing.extract(raster()))
        for n in 0...MenuBarGlyphCache.maxEntries {
            cache.store(glyph, for: item("item\(n)"), dark: true,
                        pointSize: CGSize(width: 16, height: 16),
                        now: Date(timeIntervalSince1970: Double(n)))
        }
        #expect(cache.index.count == MenuBarGlyphCache.maxEntries)
        #expect(cache.face(for: item("item0"), dark: true) == nil, "the oldest went")
        #expect(cache.face(for: item("item\(MenuBarGlyphCache.maxEntries)"), dark: true) != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }
        #expect(files.count == MenuBarGlyphCache.maxEntries)
    }

    // MARK: The camera

    @MainActor
    @Test("the camera keeps a photograph only when its two frames agree, and skips fresh ones")
    func camera() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let camera = MenuBarGlyphCamera(cache: MenuBarGlyphCache(directory: dir))
        camera.permitted = { true }
        camera.dark = { true }
        var frames = [cgImage(raster()), cgImage(raster())]
        var captures = 0
        camera.capture = { _ in
            captures += 1
            return frames.isEmpty ? nil : frames.removeFirst()
        }
        let row = CGRect(x: 0, y: 0, width: 2000, height: 24)
        let tile = item("a")
        #expect(await camera.photograph([tile], rows: [row]) == ["a"])
        #expect(captures == 2)
        // Fresh: an ordinary pass takes nothing.
        #expect(await camera.photograph([tile], rows: [row]).isEmpty)
        #expect(captures == 2)
        // A mid-fade pair is refused even when forced.
        frames = [cgImage(raster()), cgImage(raster(glyph: (110, 110, 110)))]
        #expect(await camera.photograph([tile], rows: [row], force: true).isEmpty)
        // A changed picture reaches onChange.
        var changed: [String] = []
        camera.onChange = { changed.append($0.id) }
        frames = [cgImage(raster(offset: 2)), cgImage(raster(offset: 2))]
        #expect(await camera.photograph([tile], rows: [row], force: true) == ["a"])
        #expect(changed == ["a"])
    }

    @MainActor
    @Test("a photograph is kept only while the item stays drawn and unmoved across both frames")
    func cameraLocate() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let camera = MenuBarGlyphCamera(cache: MenuBarGlyphCache(directory: dir))
        camera.permitted = { true }
        camera.dark = { true }
        var captured: [CGRect] = []
        camera.capture = { rect in
            captured.append(rect)
            return self.cgImage(self.raster())
        }
        let row = CGRect(x: 0, y: 0, width: 2000, height: 24)
        let tile = item("a", x: 100)

        // The bar shifted between the frames: refused.
        var answers = [item("a", x: 100), item("a", x: 70)]
        camera.locate = { _ in answers.isEmpty ? nil : answers.removeFirst() }
        #expect(await camera.photograph([tile], rows: [row]).isEmpty)

        // Concealed (or joined by a ghost) after the first frame: refused.
        answers = [item("a", x: 100)]
        #expect(await camera.photograph([tile], rows: [row]).isEmpty)

        // Nothing to photograph at all: no capture is taken.
        captured = []
        camera.locate = { _ in nil }
        #expect(await camera.photograph([tile], rows: [row]).isEmpty)
        #expect(captured.isEmpty)

        // Listed somewhere new but steady: the capture follows the fresh frame.
        camera.locate = { _ in self.item("a", x: 300) }
        #expect(await camera.photograph([tile], rows: [row]) == ["a"])
        #expect(captured.allSatisfy { $0.minX == 300 })
    }

    @MainActor
    @Test("only someone else's drawn item, alone in its rect, is photographable")
    func photographable() {
        let row = CGRect(x: 0, y: 0, width: 2000, height: 24)
        let a = item("a", bundle: "com.example.a", x: 100)
        let b = item("b", bundle: "com.example.b", x: 140)
        #expect(MenuBarUtility.photographable(a, among: [a, b], rows: [row], concealed: []))
        #expect(!MenuBarUtility.photographable(a, among: [a, b], rows: [row], concealed: ["com.example.a"]),
                "a concealed app's frame is a ghost")
        let ghost = item("g", bundle: "com.example.g", x: 106)
        #expect(!MenuBarUtility.photographable(a, among: [a, ghost], rows: [row], concealed: []),
                "a ghost over the item makes its rect ambiguous")
        let parked = item("p", bundle: "com.example.p", x: 100)
        let offRow = MenuBarItem(id: "p", ownerPID: 1, ownerName: "Example",
                                 bounds: CGRect(x: 100, y: -40, width: 16, height: 16),
                                 title: nil, windowID: 1, bundleID: parked.bundleID)
        #expect(!MenuBarUtility.photographable(offRow, among: [offRow], rows: [row], concealed: []))
        let clock = MenuBarItem(id: "Control Center·Clock", ownerPID: 1, ownerName: "Control Center",
                                bounds: CGRect(x: 400, y: 0, width: 60, height: 24), title: "Clock",
                                windowID: 1, bundleID: "com.apple.controlcenter")
        #expect(!MenuBarUtility.photographable(clock, among: [clock], rows: [row], concealed: []))
    }

    @MainActor
    @Test("no Screen Recording, no photographs — a background pass never raises the prompt")
    func cameraNeedsPermission() async {
        let camera = MenuBarGlyphCamera(cache: MenuBarGlyphCache(directory: tempDirectory()))
        camera.permitted = { false }
        var captures = 0
        camera.capture = { _ in captures += 1; return nil }
        let result = await camera.photograph([item("a")], rows: [CGRect(x: 0, y: 0, width: 2000, height: 24)])
        #expect(result.isEmpty)
        #expect(captures == 0)
    }

    @MainActor
    @Test("the bar's single capture pass replaces the loop")
    func singlePass() async throws {
        let tiles = MenuBarLiveTiles()
        var captures = 0
        let image = cgImage(raster())
        tiles.capture = { _ in captures += 1; return image }
        tiles.rowRects = { [CGRect(x: 0, y: 0, width: 2000, height: 24)] }
        tiles.itemsProvider = { [self.item("a")] }
        tiles.start()
        for _ in 0..<50 where captures == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(captures == 1, "one pass, not a 2 Hz loop")
        #expect(tiles.imageWidths["a"] == 16)
        tiles.stop()
    }
}
