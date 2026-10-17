import AppKit
import CoreGraphics
import JRBarCore

/// The Menu Bar utility's glyph camera: the Item Bar's tile pictures,
/// photographed while an item is still drawn.
extension MenuBarUtility {
    /// The menu bar's appearance — the icon's, which follows the
    /// wallpaper under the bar, not the app's.
    func barIsDark() -> Bool {
        let appearance = host?.barAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The items among `items` that stand on a bar and are someone
    /// else's to photograph — never ours, never the protected system
    /// items.
    func onRowItems(in items: [MenuBarItem]) -> [MenuBarItem] {
        let rows = MenuBarItemLister.menuBarRows()
        return items.filter { Self.photographable($0, among: items, rows: rows) }
    }

    /// Whether `item` can be photographed as itself: someone else's
    /// (never ours, never a protected system item, never the «), on a
    /// row, and alone in its rect. Two listed items sharing a stretch of
    /// bar means one of them is a ghost over the other, and a photograph
    /// of that rect could file one app's glyph under the other's name.
    /// Pure so a test pins it.
    nonisolated static func photographable(_ item: MenuBarItem, among items: [MenuBarItem],
                                           rows: [CGRect]) -> Bool {
        guard !hideAllTargets([item]).isEmpty,
              rows.contains(where: { $0.intersects(item.bounds) }) else { return false }
        return !items.contains { other in
            other.id != item.id && other.bounds.intersection(item.bounds).width >= 4
        }
    }

    /// Drop every photograph more than a month old, whoever owns it — a
    /// glyph still in use is re-taken whenever the Item Bar opens, so only
    /// the forgotten ones reach the cap. Launch-time housekeeping, a beat
    /// after the camera is set; each photograph pass holds the same cap
    /// after that.
    func pruneGlyphs() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.glyphCamera?.cache.expire()
        }
    }

    /// The photographed glyph for an item in the bar's appearance.
    func glyphFace(for item: MenuBarItem) -> MenuBarGlyphCache.Face? {
        glyphCamera?.cache.face(for: item, dark: barIsDark())
    }

    /// One photograph pass, off the caller's stack.
    func photograph(_ items: [MenuBarItem]) {
        guard let camera = glyphCamera, !items.isEmpty else { return }
        Task { [weak self] in
            let stored = await camera.photograph(items, rows: MenuBarItemLister.menuBarRows())
            if !stored.isEmpty { self?.bar.glyphsChanged(); self?.refreshEarFeed() }
        }
    }
}
