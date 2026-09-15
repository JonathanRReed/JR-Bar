import AppKit
import JRBarCore
import Observation
import ScreenCaptureKit

/// The Item Bar's live-tile math, pure so a test can pin it: which
/// items can be captured at all, the exact Quartz rect a capture asks
/// for, its output pixel size, and the per-item refresh throttle.
enum MenuBarTileMath {
    /// The tile refresh cadence — ~2 Hz while the bar is up, and zero
    /// work while it is not (the loop only runs between `open` and
    /// `close`).
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

/// Live thumbnails for the Item Bar's tiles. While the bar is up each
/// tile shows a `SCScreenshotManager` one-shot of the item's on-screen
/// rect — the covered item is still rendered under our shutter, and
/// the capture filter excludes this app's windows, so what lands is
/// the item itself, not the cover. One-shots, not a stream: no
/// persistent capture, and the loop only exists between `open` and
/// `close`, so a hidden menu bar costs zero captures.
///
/// Without Screen Recording (or when a capture simply fails) the tile
/// keeps the owner app's icon — the fallback the bar has always had.
/// Nothing is faked: `images` only ever holds real captures.
@MainActor
@Observable
final class MenuBarLiveTiles {
    /// Item id → latest capture. The bar's SwiftUI half reads it.
    private(set) var images: [String: NSImage] = [:]

    /// The items to keep fresh — the bar supplies its tile list.
    var itemsProvider: @MainActor () -> [MenuBarItem] = { [] }
    /// The menu bar row in Quartz coordinates.
    var rowRect: @MainActor () -> CGRect = { MenuBarItemLister.menuBarRow() }
    /// Seam: capture one Quartz rect of the main display → an image,
    /// or nil when capture is impossible. Tests stub it.
    var capture: @MainActor (CGRect) async -> CGImage?

    private var loopTask: Task<Void, Never>?
    /// When each item last captured — the throttle's memory.
    private var capturedAt: [String: Date] = [:]

    init() {
        let source = DisplayFilterSource()
        capture = { rect in await source.capture(rect) }
    }

    /// The bar opened: start the ~2 Hz loop. Safe to call twice.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshOnce()
                try? await Task.sleep(nanoseconds: UInt64(MenuBarTileMath.refreshInterval * 1e9))
            }
        }
    }

    /// The bar closed: cancel the loop and drop the captures — nothing
    /// keeps paying for a surface that is not on screen.
    func stop() {
        loopTask?.cancel()
        loopTask = nil
        images = [:]
        capturedAt = [:]
    }

    isolated deinit {
        loopTask?.cancel()
    }

    /// One capture pass: prune ids that left the bar, then capture each
    /// due, capturable item in turn. Sequential on purpose — a burst of
    /// parallel one-shots is a burst of WindowServer work, and 2 Hz is
    /// the cadence, not the goal.
    func refreshOnce() async {
        let row = rowRect()
        let items = itemsProvider()
        let ids = Set(items.map(\.id))
        images = images.filter { ids.contains($0.key) }
        capturedAt = capturedAt.filter { ids.contains($0.key) }
        for item in items {
            guard let rect = MenuBarTileMath.captureRect(of: item, row: row),
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
private final class DisplayFilterSource {
    /// How long a filter — or a failed fetch — stays valid. Display
    /// changes land within seconds, and the tiles are a 2 Hz preview.
    nonisolated static let ttl: TimeInterval = 5

    private var cached: (at: Date, filter: SCContentFilter?)?

    private func filter() async -> SCContentFilter? {
        if let cached, Date().timeIntervalSince(cached.at) < Self.ttl {
            return cached.filter
        }
        let shareable = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        let display = shareable?.displays.first(where: { $0.displayID == mainID })
            ?? shareable?.displays.first
        guard let shareable, let display else {
            cached = (Date(), nil)
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ours = shareable.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: ours,
                                     exceptingWindows: [])
        cached = (Date(), filter)
        return filter
    }

    /// One Quartz rect of the main display → an image, or nil on any
    /// failure — no permission, no display, a mid-reflow frame. The
    /// caller's icon fallback is the honest answer.
    func capture(_ rect: CGRect) async -> CGImage? {
        guard let filter = await filter() else { return nil }
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
