import Foundation

/// Alcove's live capsule as far as the window list tells it: where it is
/// centred, how wide it is, and how far it hangs below the top of the screen.
/// All in AppKit screen points (x to the right, the screen's own frame).
public struct AlcoveCapsule: Equatable, Sendable {
    public var centerX: CGFloat
    public var width: CGFloat
    /// Distance from the screen's top edge to the capsule's bottom edge.
    public var depth: CGFloat

    public init(centerX: CGFloat, width: CGFloat, depth: CGFloat) {
        self.centerX = centerX
        self.width = width
        self.depth = depth
    }
}

/// One row of `CGWindowListCopyWindowInfo`, reduced to plain values so the
/// selection can be tested without a window server. `bounds` is in the
/// window list's coordinates: origin at the top-left of the primary display,
/// y growing downward.
public struct AlcoveWindowRow: Equatable, Sendable {
    public var ownerName: String
    public var ownerPID: Int
    public var number: Int
    public var layer: Int
    public var alpha: Double
    public var bounds: CGRect

    public init(ownerName: String, ownerPID: Int = 0, number: Int, layer: Int, alpha: Double = 1, bounds: CGRect) {
        self.ownerName = ownerName
        self.ownerPID = ownerPID
        self.number = number
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }
}

/// Port of `alcove_window_probe.select_alcove_window_values` and the capsule
/// half of `virtual_device.virtual_window_frame_for_screen`, with one change:
/// the Python then measured the capsule's alpha silhouette through a screen
/// capture; here the window's bounds are the capsule, so a window that does
/// not hang from the top of the screen (Alcove's settings, its onboarding)
/// is never taken for one.
public enum AlcoveGeometry {
    /// `CGWindowList` reports an owner name, not a bundle id.
    public static let ownerName = "Alcove"
    public static let bundleIdentifier = "com.henrikruscon.Alcove"
    /// `ALCOVE_MAX_WIDTH`: wider than this is not a capsule.
    public static let maxWidth: CGFloat = 520
    /// An expanded live activity runs a few times the notch's depth; a
    /// window deeper than this is a panel, not the capsule.
    public static let maxDepth: CGFloat = 260
    public static let minWidth: CGFloat = 40
    /// How far below the screen's top edge a capsule window may start.
    public static let topTolerance: CGFloat = 2
    /// `virtual_window_frame_for_screen`: the band never follows narrower than this.
    public static let minFollowWidth: CGFloat = 140
    /// Alcove 1.7.9 draws the capsule inside one fixed transparent window
    /// (624×320 on this Mac) hung from the top of the screen; its bounds say
    /// nothing about the capsule. Such a window is a "container", and the
    /// capsule inside it can only be estimated from what Alcove exposes to
    /// accessibility: the controls it lays out inside the capsule, which sit
    /// this far inside the capsule's edges.
    public static let accessibilityHorizontalPadding: CGFloat = 14
    public static let accessibilityBottomPadding: CGFloat = 4
    /// Content lower than this in the container is not part of the capsule.
    public static let accessibilityContentMaxTop: CGFloat = 60

    /// The capsule among `rows`, for the screen whose AppKit frame is
    /// `screenFrame` on a primary display `primaryHeight` points tall.
    public static func select(rows: [AlcoveWindowRow], screenFrame: CGRect, primaryHeight: CGFloat) -> AlcoveCapsule? {
        // The screen's top edge in window-list coordinates.
        let screenTop = primaryHeight - screenFrame.maxY
        var best: (key: (CGFloat, CGFloat, Int, Int), capsule: AlcoveCapsule)?
        for row in rows where row.ownerName == ownerName {
            let b = row.bounds
            guard row.number > 0, row.alpha > 0.01,
                  b.width.isFinite, b.height.isFinite, b.minX.isFinite, b.minY.isFinite,
                  b.width >= minWidth, b.width <= maxWidth, b.height >= 1, b.height <= maxDepth else { continue }
            guard b.minY <= screenTop + topTolerance, b.minY >= screenTop - topTolerance else { continue }
            let centerX = b.midX
            guard centerX >= screenFrame.minX, centerX <= screenFrame.maxX else { continue }
            let capsule = AlcoveCapsule(centerX: centerX, width: b.width, depth: b.maxY - screenTop)
            let key = (b.minY, -b.width, -row.layer, -row.number)
            if let current = best {
                if key < current.key { best = (key, capsule) }
            } else {
                best = (key, capsule)
            }
        }
        return best?.capsule
    }

    /// The topmost Alcove window hanging from the screen's top edge that is
    /// too wide to be the capsule itself: the container the capsule is drawn
    /// in. nil when Alcove shows nothing at the top.
    public static func containerWindow(rows: [AlcoveWindowRow], screenFrame: CGRect, primaryHeight: CGFloat) -> AlcoveWindowRow? {
        let screenTop = primaryHeight - screenFrame.maxY
        return rows.filter { row in
            row.ownerName == ownerName && row.number > 0 && row.alpha > 0.01
                && row.bounds.width > maxWidth && row.bounds.width < screenFrame.width
                && abs(row.bounds.minY - screenTop) <= topTolerance
                && row.bounds.midX >= screenFrame.minX && row.bounds.midX <= screenFrame.maxX
        }.min { ($0.layer, $0.number) > ($1.layer, $1.number) }
    }

    /// The capsule estimated from the accessibility frames of the content
    /// Alcove lays out inside a container window (window-list coordinates):
    /// their union near the window's top, padded out to the capsule's edges.
    /// nil when nothing is laid out there (Alcove is hiding the capsule).
    public static func capsule(fromContentFrames frames: [CGRect], container: CGRect, screenFrame: CGRect, primaryHeight: CGFloat) -> AlcoveCapsule? {
        let screenTop = primaryHeight - screenFrame.maxY
        var union: CGRect?
        for frame in frames where frame.width > 0 && frame.height > 0 && frame.width < container.width && frame.height < container.height {
            guard frame.minY - container.minY <= accessibilityContentMaxTop, container.contains(frame) else { continue }
            union = union.map { $0.union(frame) } ?? frame
        }
        guard let union else { return nil }
        let width = min(maxWidth, max(minWidth, union.width + 2 * accessibilityHorizontalPadding))
        let depth = min(maxDepth, max(1, union.maxY + accessibilityBottomPadding - screenTop))
        return AlcoveCapsule(centerX: union.midX, width: width, depth: depth)
    }

    /// The Screen Bar window's frame when a capsule is being followed: the
    /// band matches the capsule's width exactly (growing past the notch for
    /// an expanded live activity, narrowing below it once it collapses),
    /// follows its centre, and hangs from its measured bottom edge.
    ///
    /// - Parameters:
    ///   - notchWidth: the notch slot the classic geometry would use.
    ///   - wing: the classic wing width on each side.
    ///   - notchDepth: the screen's safe-area inset.
    ///   - windowHeight: `ScreenBarGeometry.windowHeight(notchDepth:)`.
    public static func windowFrame(screenFrame frame: CGRect, notchWidth classicNotchWidth: CGFloat, wing classicWing: CGFloat,
                                   notchDepth: CGFloat, capsule: AlcoveCapsule?, windowHeight: (CGFloat) -> CGFloat) -> CGRect {
        var notchWidth = classicNotchWidth
        var wing = classicWing
        var depth = notchDepth
        var centerX = frame.midX
        if let capsule {
            let target = max(minFollowWidth, capsule.width)
            if target >= notchWidth {
                wing = (target - notchWidth) / 2.0
            } else {
                notchWidth = target
                wing = 0
            }
            depth = max(depth, capsule.depth)
            centerX = capsule.centerX
        }
        notchWidth = min(notchWidth, frame.width - 8.0)
        wing = min(wing, max(0, (frame.width - notchWidth) / 2.0 - 4.0))
        let width = notchWidth + 2.0 * wing
        let height = windowHeight(depth)
        centerX = min(frame.maxX - width / 2.0, max(frame.minX + width / 2.0, centerX))
        return CGRect(x: centerX - width / 2.0, y: frame.maxY - height, width: width, height: height)
    }
}

private func < (lhs: (CGFloat, CGFloat, Int, Int), rhs: (CGFloat, CGFloat, Int, Int)) -> Bool {
    if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
    if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
    if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
    return lhs.3 < rhs.3
}
