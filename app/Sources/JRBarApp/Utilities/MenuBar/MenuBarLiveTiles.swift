import AppKit
import JRBarCore
import Observation
import ScreenCaptureKit

/// The Item Bar's live-tile math, pure so a test can pin it: which
/// items can be captured at all, the exact Quartz rect a capture asks
/// for, its output pixel size, and the per-item refresh throttle.
enum MenuBarTileMath {
    /// The per-item throttle: a capture fresher than this is still
    /// current. There is no refresh loop any more — the bar takes one
    /// pass when it opens, because every capture lights the
    /// screen-recording indicator and that shifts the whole bar.
    nonisolated static let refreshInterval: TimeInterval = 0.5
    /// Output captures land at this scale — menu bar tiles are small
    /// enough that 2× is indistinguishable from the native factor.
    nonisolated static let captureScale: CGFloat = 2

    /// The Quartz rect to capture for an item: its bounds clipped to
    /// the menu bar row's band. An item macOS has parked off the row
    /// has no on-screen pixels to capture — nil, and the tile falls
    /// back to the owner's icon. A sliver under the lister's minimum
    /// width is a mid-reflow frame, not a capture.
    nonisolated static func captureRect(of item: MenuBarItem, row: CGRect) -> CGRect? {
        let clipped = item.bounds.intersection(row)
        guard !clipped.isNull, clipped.width >= MenuBarItemLister.minItemWidth,
              clipped.height > 0 else { return nil }
        return clipped
    }

    /// The items a pass captures — on-row only, in bar order.
    nonisolated static func capturableItems(_ items: [MenuBarItem], row: CGRect) -> [MenuBarItem] {
        items.filter { captureRect(of: $0, row: row) != nil }
    }

    /// The output pixel size for a capture rect at `scale` — a capture
    /// asks for whole pixels, never zero.
    nonisolated static func pixelSize(for rect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        (max(1, Int((rect.width * scale).rounded())),
         max(1, Int((rect.height * scale).rounded())))
    }

    /// The per-item throttle: a capture fresher than `interval` is
    /// still current — an early tick (the bar's `open` fires one) must
    /// not double-pay a capture.
    nonisolated static func needsRefresh(lastCapturedAt: Date?, now: Date,
                                         interval: TimeInterval) -> Bool {
        guard let lastCapturedAt else { return true }
        return now.timeIntervalSince(lastCapturedAt) >= interval
    }
}

/// Live thumbnails for the Item Bar's tiles. When the bar opens each
/// tile standing on the row gets one `SCScreenshotManager` one-shot of
/// the item's on-screen rect — the covered item is still rendered
/// under our shutter, and the capture filter excludes this app's
/// windows, so what lands is the item itself, not the cover. One pass,
/// not a loop: a 2 Hz loop lit the screen-recording indicator the whole
/// time the bar was up, and the indicator shifts the whole bar.
/// Everything a pass cannot see — a concealed app has no pixels at all —
/// comes from `MenuBarGlyphCache`, photographed while it was drawn.
///
/// Without Screen Recording (or when a capture simply fails) the tile
/// keeps the photographed glyph or the owner app's icon. Nothing is
/// faked: `images` only ever holds real captures.
@MainActor
@Observable
final class MenuBarLiveTiles {
    /// Item id → latest capture. The bar's SwiftUI half reads it.
    private(set) var images: [String: NSImage] = [:]

    /// Each capture's point width — the tile takes it.
    var imageWidths: [String: CGFloat] { images.mapValues(\.size.width) }

    /// The items to keep fresh — the bar supplies its tile list.
    var itemsProvider: @MainActor () -> [MenuBarItem] = { [] }
    /// The displays' menu bar rows in Quartz coordinates — each item
    /// captures against the row it actually stands on.
    var rowRects: @MainActor () -> [CGRect] = { MenuBarItemLister.menuBarRows() }
    /// Whether an item has on-screen pixels worth capturing. A
    /// concealed item's Accessibility ghost reports a frozen on-row
    /// frame while the agent owns its pixels — capturing that rect
    /// lands a picture of empty bar, so the utility marks ghosts
    /// uncapturable and the tile falls back to the owner's icon.
    var isCapturable: @MainActor (MenuBarItem) -> Bool = { _ in true }
    /// Seam: capture one Quartz rect of the main display → an image,
    /// or nil when capture is impossible. Tests stub it.
    var capture: @MainActor (CGRect) async -> CGImage?

    private var passTask: Task<Void, Never>?
    /// When each item last captured — the throttle's memory.
    private var capturedAt: [String: Date] = [:]

    init() {
        let source = DisplayFilterSource()
        capture = { rect in await source.capture(rect) }
    }

    /// The bar opened: one capture pass. Safe to call twice — a second
    /// call replaces the pass in flight.
    func start() {
        passTask?.cancel()
        passTask = Task { [weak self] in
            await self?.refreshOnce()
        }
    }

    /// The bar closed: cancel a pass in flight and drop the captures —
    /// nothing keeps paying for a surface that is not on screen.
    func stop() {
        passTask?.cancel()
        passTask = nil
        images = [:]
        capturedAt = [:]
    }

    isolated deinit {
        passTask?.cancel()
    }

    /// One capture pass: prune ids that left the bar, then capture each
    /// due, capturable item in turn. Sequential on purpose — a burst of
    /// parallel one-shots is a burst of WindowServer work. A pass that
    /// was replaced or stopped takes no further captures.
    func refreshOnce() async {
        let rows = rowRects()
        let items = itemsProvider()
        let ids = Set(items.map(\.id))
        images = images.filter { ids.contains($0.key) }
        capturedAt = capturedAt.filter { ids.contains($0.key) }
        for item in items {
            if Task.isCancelled { return }
            // The item's own bar — a tile on a secondary display's strip
            // captures the rect there, never the main row's math.
            let row = rows.first { $0.intersects(item.bounds) }
            guard isCapturable(item), let row,
                  let rect = MenuBarTileMath.captureRect(of: item, row: row),
                  MenuBarTileMath.needsRefresh(lastCapturedAt: capturedAt[item.id],
                                               now: Date(),
                                               interval: MenuBarTileMath.refreshInterval)
            else { continue }
            if let cgImage = await capture(rect) {
                images[item.id] = NSImage(cgImage: cgImage,
                                          size: NSSize(width: rect.width, height: rect.height))
                capturedAt[item.id] = Date()
            }
        }
    }
}

/// The ScreenCaptureKit half of the tile capture: builds the display
/// filter — the main display's composite minus this app's windows, so
/// a shutter-covered item captures as itself, not as the cover — and
/// caches it, because a `SCShareableContent` fetch per tile per tick
/// would be a WindowServer round-trip storm. A failed fetch (no Screen
/// Recording) is cached too, so a denied permission is not repolled
/// every tile.
@MainActor
final class DisplayFilterSource {
    /// How long a shareable-content fetch — or a failed one — stays
    /// valid. Display changes land within seconds, and a pass or a
    /// photograph pair lands well inside it.
    nonisolated static let ttl: TimeInterval = 5

    /// The raw content listing — one fetch feeds every display's
    /// filter, so a multi-display bar still pays once per ttl.
    private var cachedContent: (at: Date, content: SCShareableContent?)?
    /// One filter per display, built on demand from the cached content.
    private var filters: [CGDirectDisplayID: SCContentFilter] = [:]

    private func filter(for rect: CGRect) async -> SCContentFilter? {
        if cachedContent == nil || Date().timeIntervalSince(cachedContent!.at) >= Self.ttl {
            cachedContent = (Date(), try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true))
            filters = [:]
        }
        guard let shareable = cachedContent?.content else { return nil }
        // The display whose bounds contain the rect — a secondary-bar
        // item captures from its own display, not the main one.
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        let display = shareable.displays.first(where: { $0.frame.contains(mid) })
            ?? shareable.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? shareable.displays.first
        guard let display else { return nil }
        if let filter = filters[display.displayID] { return filter }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ours = shareable.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: ours,
                                     exceptingWindows: [])
        filters[display.displayID] = filter
        return filter
    }

    /// One Quartz rect of whichever display holds it → an image, or nil
    /// on any failure — no permission, no display, a mid-reflow frame.
    /// The caller's icon fallback is the honest answer.
    func capture(_ rect: CGRect) async -> CGImage? {
        guard let filter = await filter(for: rect) else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        let size = MenuBarTileMath.pixelSize(for: rect, scale: MenuBarTileMath.captureScale)
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                           configuration: configuration)
    }
}
