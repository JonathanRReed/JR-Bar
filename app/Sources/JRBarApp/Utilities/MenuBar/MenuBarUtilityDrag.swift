import AppKit
import CoreGraphics
import JRBarCore

/// ⌘-drag across the icon. macOS moves the item itself: JR-Bar holds the
/// bar still for the press and the beat after the drop
/// (`MenuBarPointerGate`), then reads once where the item landed and says
/// so (`MenuBarPositionDiff`). It writes nothing and fights nothing; the
/// press and its release come from the reveal's own monitor (see
/// `dividerDragPressed` and `dividerDragReleased`), and nothing is posted:
/// the pointer never moves.
extension MenuBarUtility {
    /// Every display's menu bar row, the one the icon stands on first.
    func dragBarRows() -> [CGRect] {
        if let dragRows { return dragRows() }
        let rows = MenuBarItemLister.menuBarRows()
        let primary = rows.first ?? MenuBarItemLister.menuBarRow()
        return [primary] + rows.filter { $0 != primary }
    }

    /// The icon's span on x as the person sees it: the real icon.
    func currentIconSpan() -> ClosedRange<CGFloat>? {
        if let dragIconSpan { return dragIconSpan() }
        if let frame = host?.boundaryFrame { return frame.minX...frame.maxX }
        return nil
    }

    /// A point from AppKit's screen space (the reveal's monitor) in
    /// Quartz's, where the listing measures.
    static func quartzPoint(_ point: NSPoint) -> CGPoint {
        let top = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: point.x, y: top - point.y)
    }

    // MARK: A tile dragged out of the Item Bar

    /// An Item Bar tile dropped at `screenPoint` (AppKit): on the bar
    /// right of the icon it asks to show its app, left of it to tuck it
    /// away. A drop anywhere else changes nothing. The drag is the Item
    /// Bar's own session — nothing is posted, the pointer is the person's.
    /// A position is the person's to move, so a drop across the icon is
    /// answered with the ⌘-drag that does it.
    func tileDropped(_ item: MenuBarItem, at screenPoint: NSPoint) {
        guard settings().enabled, settings().provider == .jrbar else { return }
        guard let icon = currentIconSpan(), let row = dragBarRows().first else { return }
        let point = Self.quartzPoint(screenPoint)
        guard row.insetBy(dx: 0, dy: -MenuBarDragRules.slack).contains(point) else { return }
        guard let section = MenuBarDragRules.tileDropSection(
            dropX: point.x, icon: icon, current: effectiveSection(for: item)) else { return }
        guideDrag(item: item, to: section)
    }
}

/// The pure rules of a drop near the icon, so a test pins each one.
enum MenuBarDragRules {
    /// A drop this close to the icon's edge is on the icon.
    nonisolated static let slack: CGFloat = 3
    /// How long a drop's note stands under the icon.
    nonisolated static let noteSeconds: TimeInterval = 4

    /// The section a tile dropped at `dropX` asks for against the icon's
    /// span: right of the icon shows it, left of it tucks it away, on the
    /// icon nothing. nil when the tile is already there.
    nonisolated static func tileDropSection(dropX: CGFloat, icon: ClosedRange<CGFloat>,
                                            current: MenuBarItemSection) -> MenuBarItemSection? {
        if dropX > icon.upperBound + slack { return current == .shown ? nil : .shown }
        if dropX < icon.lowerBound - slack { return current == .shown ? .hidden : nil }
        return nil
    }
}
