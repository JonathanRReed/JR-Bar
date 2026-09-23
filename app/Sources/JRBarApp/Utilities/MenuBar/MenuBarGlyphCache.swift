import AppKit
import CoreGraphics
import JRBarCore
import OSLog

/// The Item Bar's real glyphs. Under the macOS 27 concealer a hidden
/// app's item has no pixels at all — the agent owns them — so a live
/// capture can only ever show the owner's app icon, and on a curated bar
/// nearly every tile was one. Ice's PR #995 and Bartender for Golden
/// Gate photograph each item while it is legitimately on the row; this
/// does the same: before the first conceal, during a reveal once the
/// pointer has left the row, and in the narrow lift a tile click makes
/// once its menu has closed — never between a click and its answer,
/// since each frame lights the recording indicator and shifts the bar.
/// Each photograph is taken twice and
/// kept only when the two frames agree (a mid-fade frame never lands),
/// lifted off the bar's own material, stored per item and appearance,
/// and re-tinted when the glyph is a template — so the tile draws in the
/// Item Bar's own label colour.
///
/// What reaches the disk is only ever an icon: a glyph up to
/// `persistMaxWidth` wide is filed under Application Support, and a
/// wider one — the width text takes, an event title, a VPN's name, a
/// clock — stays in memory for this run and is photographed afresh the
/// next. Nothing on disk outlives `pruneAge`, whoever owns it.

// MARK: - Pure pixel work

enum MenuBarGlyphProcessing {
    /// A straight (non-premultiplied) RGBA8 raster, row-major, top row
    /// first.
    struct Raster: Equatable, Sendable {
        var width: Int
        var height: Int
        var pixels: [UInt8]

        func pixel(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            let i = (y * width + x) * 4
            return (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]), Double(pixels[i + 3]))
        }
    }

    /// A glyph lifted off the bar: straight RGBA whose alpha is how far
    /// each pixel stands from the bar behind it. A template glyph is
    /// stored black with that alpha — the renderer tints it.
    struct Glyph: Equatable, Sendable {
        var raster: Raster
        var template: Bool
        /// The share of the rect the glyph covers.
        var coverage: Double
    }

    /// Rasterize a capture. The bar is opaque, so the premultiplied read
    /// is the straight one.
    nonisolated static func raster(_ image: CGImage) -> Raster? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // The context writes through the buffer during the draw, so the
        // pointer must live across both calls — never an inout temporary.
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Raster(width: width, height: height, pixels: pixels) : nil
    }

    /// The bar behind the glyph: the per-channel median of the rect's
    /// border ring, where an item's padding shows the material.
    nonisolated static func background(_ raster: Raster) -> (r: Double, g: Double, b: Double) {
        var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
        func take(_ x: Int, _ y: Int) {
            let p = raster.pixel(x, y)
            rs.append(p.r); gs.append(p.g); bs.append(p.b)
        }
        for x in 0..<raster.width {
            take(x, 0)
            if raster.height > 1 { take(x, raster.height - 1) }
        }
        if raster.height > 2 {
            for y in 1..<(raster.height - 1) {
                take(0, y)
                if raster.width > 1 { take(raster.width - 1, y) }
            }
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        return (median(rs), median(gs), median(bs))
    }

    /// Whether two frames of the same rect agree — a mean luma
    /// difference within `tolerance` (0…255). A fade in or out moves
    /// every glyph pixel between the two, so a mid-fade frame never
    /// passes; different sizes never agree.
    nonisolated static func framesAgree(_ a: Raster, _ b: Raster, tolerance: Double = 6) -> Bool {
        guard a.width == b.width, a.height == b.height, !a.pixels.isEmpty else { return false }
        var total = 0.0
        let count = a.width * a.height
        for i in 0..<count {
            let j = i * 4
            let la = 0.2126 * Double(a.pixels[j]) + 0.7152 * Double(a.pixels[j + 1]) + 0.0722 * Double(a.pixels[j + 2])
            let lb = 0.2126 * Double(b.pixels[j]) + 0.7152 * Double(b.pixels[j + 1]) + 0.0722 * Double(b.pixels[j + 2])
            total += abs(la - lb)
        }
        return total / Double(count) <= tolerance
    }

    /// Lift the glyph off the bar. The alpha ramps from `low` to `high`
    /// of RGB distance from the background — the material's own grain
    /// stays transparent, antialiased edges keep their softness. A rect
    /// with next to nothing on it (an undrawn ghost, a frame before the
    /// fade-in) or covered nearly edge to edge (a highlight, a menu
    /// open) is no glyph: nil. A glyph whose opaque pixels are all near
    /// grey is a template and is stored black, for the renderer to tint.
    nonisolated static func extract(_ raster: Raster, low: Double = 14, high: Double = 70,
                                    coverage bounds: ClosedRange<Double> = 0.01...0.85) -> Glyph? {
        let bg = background(raster)
        let count = raster.width * raster.height
        guard count > 0 else { return nil }
        var alphas = [Double](repeating: 0, count: count)
        var opaque = 0
        var grey = 0
        for i in 0..<count {
            let j = i * 4
            let r = Double(raster.pixels[j]), g = Double(raster.pixels[j + 1]), b = Double(raster.pixels[j + 2])
            let distance = ((r - bg.r) * (r - bg.r) + (g - bg.g) * (g - bg.g) + (b - bg.b) * (b - bg.b)).squareRoot()
            let alpha = min(1, max(0, (distance - low) / (high - low)))
            alphas[i] = alpha
            if alpha > 0.5 {
                opaque += 1
                let hi = max(r, g, b), lo = min(r, g, b)
                if hi == 0 || (hi - lo) / hi < 0.2 { grey += 1 }
            }
        }
        let coverage = Double(opaque) / Double(count)
        guard bounds.contains(coverage) else { return nil }
        let template = Double(grey) >= 0.9 * Double(opaque)
        var out = [UInt8](repeating: 0, count: count * 4)
        for i in 0..<count {
            let j = i * 4
            if !template {
                out[j] = raster.pixels[j]
                out[j + 1] = raster.pixels[j + 1]
                out[j + 2] = raster.pixels[j + 2]
            }
            out[j + 3] = UInt8((alphas[i] * 255).rounded())
        }
        return Glyph(raster: Raster(width: raster.width, height: raster.height, pixels: out),
                     template: template, coverage: coverage)
    }

    /// A stable fingerprint of a glyph — FNV-1a over its alpha, coarsely
    /// quantized so the bar's grain never reads as a change. Two photos
    /// of the same glyph hash the same; a sync badge appearing does not.
    nonisolated static func fingerprint(_ glyph: Glyph) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        mix(UInt8(truncatingIfNeeded: glyph.raster.width))
        mix(UInt8(truncatingIfNeeded: glyph.raster.height))
        for i in stride(from: 3, to: glyph.raster.pixels.count, by: 4) {
            mix(glyph.raster.pixels[i] >> 5)
        }
        return hash
    }

    /// The tile width for a glyph `pointWidth` wide: clamped to the Item
    /// Bar's native-width range, so "72°" or a VPN's name reads whole and
    /// a sliver never becomes a hairline.
    nonisolated static func tileWidth(pointWidth: CGFloat) -> CGFloat {
        min(MenuBarBarLayout.maxTileWidth, max(MenuBarBarLayout.minTileWidth, pointWidth.rounded()))
    }
}

// MARK: - The cache

/// Photographed glyphs, per item and appearance, on disk and in memory.
@MainActor
final class MenuBarGlyphCache {
    /// What one photograph is filed under: the owner's bundle (or name,
    /// for a bare helper), the item's identity, and the bar's appearance.
    struct Key: Hashable, Sendable {
        var owner: String
        var itemID: String
        var dark: Bool

        var storageKey: String { "\(owner)|\(itemID)|\(dark ? "dark" : "light")" }

        init(item: MenuBarItem, dark: Bool) {
            owner = item.bundleID ?? item.ownerName
            itemID = item.id
            self.dark = dark
        }
    }

    struct Entry: Codable, Equatable, Sendable {
        var file: String
        /// Points — the rect's own size.
        var width: Double
        var height: Double
        var template: Bool
        var capturedAt: Double
        var fingerprint: UInt64
    }

    /// A tile's face from the cache. Equal when it is the same picture —
    /// the cache hands out one image per photograph, so a face that did
    /// not change compares equal and re-lays nothing.
    struct Face: Equatable {
        var image: NSImage
        var width: CGFloat
        var template: Bool
    }

    nonisolated static let log = Logger(subsystem: "devin.jrbar", category: "menubar")
    /// How many photographs the cache keeps — far past any real bar, so
    /// only an app that names its item afresh every launch ever reaches
    /// it; the oldest go first.
    nonisolated static let maxEntries = 400
    /// No photograph outlives this — pruned whoever owns it. Every
    /// launch photographs the bar before the first conceal, so a glyph
    /// still in use is never this old.
    nonisolated static let pruneAge: TimeInterval = 30 * 24 * 3600
    /// The widest glyph that is ever written to disk, in points. An icon
    /// is 16–24 pt with its padding; past this the item is carrying text
    /// — a calendar title, a VPN's name, a clock, the weather — which is
    /// the person's own words, so it stays in memory for this run only.
    nonisolated static let persistMaxWidth: Double = 30

    /// Whether a photograph `width` points wide may be written to disk.
    nonisolated static func persists(width: Double) -> Bool {
        width <= persistMaxWidth
    }

    /// Whether a photograph taken at `capturedAt` is past `pruneAge` at
    /// `now`.
    nonisolated static func expired(capturedAt: Double, now: Date) -> Bool {
        now.timeIntervalSince1970 - capturedAt > pruneAge
    }

    let directory: URL
    private(set) var index: [String: Entry] = [:]
    private var images: [String: NSImage] = [:]
    /// Bumped on every store — the Item Bar's tiles observe it through
    /// the live tiles' model.
    private(set) var version = 0

    /// `~/Library/Application Support/JR-Bar/MenuBarGlyphs`.
    nonisolated static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("JR-Bar/MenuBarGlyphs", isDirectory: true)
    }

    init(directory: URL = MenuBarGlyphCache.defaultDirectory()) {
        self.directory = directory
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            index = decoded
        }
        // A cache from before the width cap may hold text on disk: those
        // photographs go, file and all, the first time this build opens
        // it.
        let wide = index.filter { !Self.persists(width: $0.value.width) }
        if !wide.isEmpty {
            for key in wide.keys { drop(key) }
            writeIndex()
        }
    }

    /// The glyph for `item` in the bar's current appearance — the other
    /// appearance's template stands in (it re-tints); a coloured one of
    /// the other appearance too, better than an app icon.
    func face(for item: MenuBarItem, dark: Bool) -> Face? {
        let same = Key(item: item, dark: dark)
        let other = Key(item: item, dark: !dark)
        for key in [same, other] {
            guard let entry = index[key.storageKey], let image = load(key, entry) else { continue }
            return Face(image: image, width: CGFloat(entry.width), template: entry.template)
        }
        return nil
    }

    /// How old the photograph for `item` is, in either appearance.
    func age(of item: MenuBarItem, dark: Bool, now: Date = Date()) -> TimeInterval? {
        let entry = index[Key(item: item, dark: dark).storageKey]
        return entry.map { now.timeIntervalSince1970 - $0.capturedAt }
    }

    /// File a glyph. Returns whether the item's picture changed — a new
    /// fingerprint over a remembered one (a first photograph is not a
    /// change). An icon-sized glyph is written with the index; a wider
    /// one is kept in memory only, and takes any older file of the same
    /// item with it. A failed write keeps the glyph in memory for this
    /// run.
    @discardableResult
    func store(_ glyph: MenuBarGlyphProcessing.Glyph, for item: MenuBarItem, dark: Bool,
               pointSize: CGSize, now: Date = Date()) -> Bool {
        let key = Key(item: item, dark: dark)
        let fingerprint = MenuBarGlyphProcessing.fingerprint(glyph)
        let previous = index[key.storageKey]
        let file = Self.fileName(for: key)
        let entry = Entry(file: file, width: pointSize.width, height: pointSize.height,
                          template: glyph.template, capturedAt: now.timeIntervalSince1970,
                          fingerprint: fingerprint)
        index[key.storageKey] = entry
        let image = Self.image(glyph, pointSize: pointSize)
        images[key.storageKey] = image
        let evicted = Self.overflow(index, keeping: key.storageKey)
        for storageKey in evicted { drop(storageKey) }
        if Self.persists(width: entry.width) {
            persist(glyph, file: file)
        } else {
            // The item grew text since its last photograph: the icon on
            // disk is not what it shows any more, and the new face is
            // not for disk at all.
            if let previous, Self.persists(width: previous.width) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(previous.file))
            }
            writeIndex()
        }
        version += 1
        return previous.map { $0.fingerprint != fingerprint } ?? false
    }

    /// Drop every photograph past `pruneAge` at `now`, whoever owns it —
    /// launch housekeeping, and the start of each photograph pass, so a
    /// Mac that never quits still forgets.
    func expire(now: Date = Date()) {
        let old = index.filter { Self.expired(capturedAt: $0.value.capturedAt, now: now) }
        guard !old.isEmpty else { return }
        for key in old.keys { drop(key) }
        writeIndex()
    }

    /// The keys past `maxEntries`, oldest first — never `keeping`, the
    /// photograph just filed.
    nonisolated static func overflow(_ index: [String: Entry], keeping: String,
                                     limit: Int = maxEntries) -> [String] {
        guard index.count > limit else { return [] }
        return index.filter { $0.key != keeping }
            .sorted { ($0.value.capturedAt, $0.key) < ($1.value.capturedAt, $1.key) }
            .prefix(index.count - limit)
            .map(\.key)
    }

    /// Drop the photographs `keep` refuses — it hears each one's owner
    /// (the index keys carry it) and when it was taken.
    func prune(keeping keep: (_ owner: String, _ capturedAt: Date) -> Bool) {
        let gone = index.filter { key, entry in
            !keep(String(key.split(separator: "|").first ?? ""),
                  Date(timeIntervalSince1970: entry.capturedAt))
        }
        guard !gone.isEmpty else { return }
        for key in gone.keys { drop(key) }
        writeIndex()
    }

    /// Forget one photograph, file and all. The caller writes the index.
    private func drop(_ storageKey: String) {
        guard let entry = index.removeValue(forKey: storageKey) else { return }
        images[storageKey] = nil
        // Two keys never share a file name in practice (a 64-bit hash of
        // the key), but a collision must not delete the survivor's PNG.
        guard !index.values.contains(where: { $0.file == entry.file && Self.persists(width: $0.width) })
        else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.file))
    }

    /// The part of the index that is written down: the icon-sized
    /// photographs. A wide one lives in `index` and `images` alone.
    nonisolated static func persisted(_ index: [String: Entry]) -> [String: Entry] {
        index.filter { persists(width: $0.value.width) }
    }

    // MARK: Files

    nonisolated static func fileName(for key: Key) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.storageKey.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx.png", hash)
    }

    private func load(_ key: Key, _ entry: Entry) -> NSImage? {
        if let image = images[key.storageKey] { return image }
        guard let image = NSImage(contentsOf: directory.appendingPathComponent(entry.file)) else {
            return nil
        }
        image.size = NSSize(width: entry.width, height: entry.height)
        image.isTemplate = entry.template
        images[key.storageKey] = image
        return image
    }

    private func persist(_ glyph: MenuBarGlyphProcessing.Glyph, file: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let png = Self.png(glyph.raster) {
                try png.write(to: directory.appendingPathComponent(file), options: .atomic)
            }
            writeIndex()
        } catch {
            Self.log.error("glyph cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeIndex() {
        guard let data = try? JSONEncoder().encode(Self.persisted(index)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }

    /// The glyph as an image of the item's own point size; a template is
    /// marked so SwiftUI and AppKit tint it.
    nonisolated static func image(_ glyph: MenuBarGlyphProcessing.Glyph, pointSize: CGSize) -> NSImage {
        let image = NSImage(size: pointSize)
        if let rep = bitmap(glyph.raster) { image.addRepresentation(rep) }
        image.isTemplate = glyph.template
        return image
    }

    nonisolated static func bitmap(_ raster: MenuBarGlyphProcessing.Raster) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: raster.width,
                                         pixelsHigh: raster.height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bitmapFormat: .alphaNonpremultiplied,
                                         bytesPerRow: raster.width * 4, bitsPerPixel: 32),
              let data = rep.bitmapData else { return nil }
        raster.pixels.withUnsafeBufferPointer { source in
            data.update(from: source.baseAddress!, count: raster.pixels.count)
        }
        return rep
    }

    nonisolated static func png(_ raster: MenuBarGlyphProcessing.Raster) -> Data? {
        bitmap(raster)?.representation(using: .png, properties: [:])
    }
}

// MARK: - The camera

/// Takes the photographs — only of items that are drawn right now, only
/// with Screen Recording already granted (a background pass must never be
/// what raises the consent prompt), and in short passes rather than a
/// loop: every capture lights the recording indicator, which shifts the
/// whole bar, so the camera works in the moments the bar is moving
/// anyway.
@MainActor
final class MenuBarGlyphCamera {
    let cache: MenuBarGlyphCache
    /// One Quartz rect → an image (the live tiles' display filter).
    var capture: @MainActor (CGRect) async -> CGImage?
    /// Whether Screen Recording is granted — checked, never requested.
    var permitted: @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() }
    /// The bar's appearance now.
    var dark: @MainActor () -> Bool = {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    /// A photographed item changed its picture — show-for-updates' feed.
    var onChange: @MainActor (MenuBarItem) -> Void = { _ in }
    /// The item as listed right now, or nil when it is no longer
    /// something to photograph — concealed since, gone, or sharing its
    /// rect with a ghost. Asked before the first frame and after the
    /// second: a photograph is kept only when both answers agree on
    /// where the item stands, so a bar that shifted between the frames
    /// (the recording indicator lighting up) never files a neighbour.
    var locate: @MainActor (MenuBarItem) async -> MenuBarItem? = { $0 }
    /// The gap between a photograph's two frames.
    nonisolated static let frameGap: TimeInterval = 0.15
    /// A photograph younger than this is not retaken on an ordinary pass.
    nonisolated static let freshFor: TimeInterval = 10 * 60

    private var busy = false

    init(cache: MenuBarGlyphCache = MenuBarGlyphCache()) {
        self.cache = cache
        let source = DisplayFilterSource()
        capture = { rect in await source.capture(rect) }
    }

    /// Photograph each item of `items` that stands on one of `rows` and
    /// is not already fresh (or all of them, `force`). One pass at a
    /// time; returns the ids stored.
    @discardableResult
    func photograph(_ items: [MenuBarItem], rows: [CGRect], force: Bool = false,
                    now: @escaping () -> Date = Date.init) async -> [String] {
        guard !busy, !items.isEmpty, permitted() else { return [] }
        busy = true
        defer { busy = false }
        // The age cap holds on a Mac that never quits, too.
        cache.expire(now: now())
        let dark = dark()
        var stored: [String] = []
        for item in items {
            if !force, let age = cache.age(of: item, dark: dark, now: now()), age < Self.freshFor {
                continue
            }
            guard let before = await locate(item),
                  let row = rows.first(where: { $0.intersects(before.bounds) }),
                  let rect = MenuBarTileMath.captureRect(of: before, row: row) else { continue }
            guard let first = await capture(rect).flatMap(MenuBarGlyphProcessing.raster) else { continue }
            try? await Task.sleep(nanoseconds: UInt64(Self.frameGap * 1e9))
            guard let second = await capture(rect).flatMap(MenuBarGlyphProcessing.raster),
                  let after = await locate(item), after.bounds == before.bounds,
                  MenuBarGlyphProcessing.framesAgree(first, second),
                  let glyph = MenuBarGlyphProcessing.extract(second) else { continue }
            if cache.store(glyph, for: item, dark: dark, pointSize: rect.size, now: now()) {
                onChange(item)
            }
            stored.append(item.id)
        }
        return stored
    }
}
