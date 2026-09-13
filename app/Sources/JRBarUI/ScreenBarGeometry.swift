import AppKit
import JRBarCore

/// Constants from `screen_bar_design.py`, the reviewed Screen Bar design.
public enum ScreenBarDesign {
    public static let bandHeight: CGFloat = 6.0
    public static let compactBandHeight: CGFloat = 5.0
    public static let glowHeight: CGFloat = 14.0
    public static let windowWidth: CGFloat = 260.0
    public static let minBandWidth: CGFloat = 180.0
    public static let maxBandWidth: CGFloat = 420.0
    public static let edgeInset: CGFloat = 8.0
    public static let verticalInset: CGFloat = 1.0
    public static let cornerRadius: CGFloat = 3.0
    public static let outlineAlpha: CGFloat = 0.24
    public static let haloAlpha: CGFloat = 0.16
}

/// Ports of the geometry helpers in `virtual_device.py`. Lives in JRBarUI
/// so the pure halves — the wing and frame arithmetic — are unit-tested
/// (`ScreenBarGeometryTests`); the `NSScreen` members are thin measurers
/// over them.
/// Which side of the notch a content wing sits on.
public enum ScreenBarWingSide: Sendable, Equatable {
    case left, right
}

/// The slot-geometry facts a content wing was claimed with, so the view
/// can lay its chips out and the interaction can hit-test them without
/// re-measuring the screen.
public struct ScreenBarWingGeometry: Equatable, Sendable {
    /// The notch gap the window is centred on — the measured slot, or the
    /// `screen_bar_gap_width` override.
    public var notchWidth: CGFloat = 0
    public var notchDepth: CGFloat = 0
    /// The band's own span — the width the window would have with no
    /// content claim — so a notch-less chip hugs the band even when a
    /// manual `screen_bar_wing_length` widened it.
    public var bandSpan: CGFloat = 0
    /// Each side's measured claim (`contentWingExtent`/`notchlessWingClaim`);
    /// 0 means the side has no slot or no room — nothing draws there.
    public var leftExtent: CGFloat = 0
    public var rightExtent: CGFloat = 0

    public init(notchWidth: CGFloat = 0, notchDepth: CGFloat = 0, bandSpan: CGFloat = 0,
                leftExtent: CGFloat = 0, rightExtent: CGFloat = 0) {
        self.notchWidth = notchWidth
        self.notchDepth = notchDepth
        self.bandSpan = bandSpan
        self.leftExtent = leftExtent
        self.rightExtent = rightExtent
    }
}

public enum ScreenBarGeometry {
    public static let ledCount = 8
    /// Automatic wings hug the notch tightly (`WING_AUTO_LENGTH`).
    public static let wingAutoLength: CGFloat = 14.0
    public static let wingSafetyMargin: CGFloat = 28.0
    public static let wingMinUsable: CGFloat = 24.0
    public static let fallbackNotchDepth: CGFloat = 32.0
    /// The Python default (`screen_bar_min_glow`), which scales the outline.
    public static let minGlow: CGFloat = 0.25

    // MARK: Content wings (`screen_bar_notch_wings`)

    /// The most a side may reach past the notch's edge for a status slot.
    /// The space right beside the notch is the last the menu bar fills, so
    /// a modest chip there is safe on all but genuinely crowded menu bars;
    /// the cap keeps a wide-open flank from becoming a banner.
    public static let wingContentMaxExtent: CGFloat = 132
    /// A slot narrower than this truncates past usefulness — it collapses
    /// rather than overdraw the menu area.
    public static let wingContentMinUsable: CGFloat = 34
    /// Clearance kept next to the notch itself: the island's shoulder
    /// (12) draws there when the island is ours, and the gap reads the
    /// same when it is not.
    public static let wingContentInnerReserve: CGFloat = 16
    /// Room left at the window's outer edge.
    public static let wingContentOuterInset: CGFloat = 6
    /// A notched slot's capsule height, vertically centred in the notch's
    /// own band at menu-bar height.
    public static let wingSlotHeight: CGFloat = 22
    /// The gap between a notch-less chip and the band's end.
    public static let wingSlotGap: CGFloat = 5
    /// A notch-less screen has no flank to measure, so a slot claims a
    /// fixed reach beside the band…
    public static let notchlessWingClaim: CGFloat = 120
    /// …but only draws a capsule this wide, hugging the band's end.
    public static let notchlessSlotMaxWidth: CGFloat = 84
    public static let notchlessSlotHeight: CGFloat = 18

    /// The screen the Screen Bar belongs on: the first with a safe-area
    /// inset (the notched built-in), else the main screen.
    public static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    public static func notchDepth(of screen: NSScreen) -> CGFloat {
        let depth = screen.safeAreaInsets.top
        return depth >= 1.0 ? depth : 0.0
    }

    public static func hasNotch(_ screen: NSScreen) -> Bool { notchDepth(of: screen) > 0 }

    /// The system-reported gap between the notch's left and right areas.
    public static func slotWidth(of screen: NSScreen) -> CGFloat {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = right.origin.x - left.maxX
            if width >= 120.0 { return max(180.0, min(320.0, width)) }
        }
        return ScreenBarDesign.windowWidth
    }

    /// How far the glow may extend past each side of the notch
    /// (`wing_width_for_screen`), from the menu-bar areas' own numbers —
    /// pure so the geometry rules are testable without a screen.
    ///
    /// `manual` is `screen_bar_wing_length`: points of wing per side. A
    /// positive value wins outright — even on a screen that reports no
    /// auxiliary areas at all; nil, or a stored 0, is Automatic: the
    /// `wingAutoLength` cap applied to the room left once each area backs
    /// off `wingSafetyMargin` from its outer edge and, when the notch gap
    /// is set wider than the hardware slot, the overhang that eats into it.
    public static func wingWidth(auxiliaryLeft leftWidth: CGFloat, auxiliaryRight rightWidth: CGFloat,
                                 hardwareSlot: CGFloat, notchWidth: CGFloat, manual wingLength: CGFloat? = nil) -> CGFloat {
        if let wingLength, wingLength > 0 { return wingLength }
        guard leftWidth > 0, rightWidth > 0 else { return 0 }
        var overhang: CGFloat = 0
        if hardwareSlot > 0, notchWidth > hardwareSlot { overhang = (notchWidth - hardwareSlot) / 2.0 }
        let room = min(leftWidth - wingSafetyMargin - overhang, rightWidth - wingSafetyMargin - overhang)
        if room < wingMinUsable { return 0 }
        return max(0, min(wingAutoLength, room))
    }

    /// The same, measured off `screen`.
    public static func wingWidth(of screen: NSScreen, notchWidth: CGFloat, manual wingLength: CGFloat? = nil) -> CGFloat {
        if let wingLength, wingLength > 0 { return wingLength }
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return 0 }
        return wingWidth(auxiliaryLeft: left.width, auxiliaryRight: right.width,
                         hardwareSlot: right.origin.x - left.maxX, notchWidth: notchWidth)
    }

    /// How far past the notch's edge a content wing may claim on one side,
    /// measured off that side's menu-bar area — the same bookkeeping
    /// `wingWidth` does for the glow, but sized for a status chip instead
    /// of capped at `wingAutoLength`. 0 means the flank cannot honestly
    /// host a slot: the window claims nothing there and the slot's content
    /// stays in the peek instead.
    public static func contentWingExtent(auxiliaryWidth: CGFloat, hardwareSlot: CGFloat, notchWidth: CGFloat) -> CGFloat {
        guard auxiliaryWidth > 0 else { return 0 }
        var overhang: CGFloat = 0
        if hardwareSlot > 0, notchWidth > hardwareSlot { overhang = (notchWidth - hardwareSlot) / 2.0 }
        let usable = auxiliaryWidth - wingSafetyMargin - overhang
            - wingContentInnerReserve - wingContentOuterInset
        guard usable >= wingContentMinUsable else { return 0 }
        return min(usable + wingContentInnerReserve + wingContentOuterInset, wingContentMaxExtent)
    }

    /// The side's measured claim off `screen`; 0 when the screen has no
    /// such menu-bar area (the notch-less path claims `notchlessWingClaim`
    /// instead — there is no safe area to ask).
    public static func contentWingExtent(of screen: NSScreen, side: ScreenBarWingSide, notchWidth: CGFloat) -> CGFloat {
        let left = screen.auxiliaryTopLeftArea, right = screen.auxiliaryTopRightArea
        guard let left, let right else { return 0 }
        let area = side == .left ? left : right
        return contentWingExtent(auxiliaryWidth: area.width,
                                 hardwareSlot: right.origin.x - left.maxX, notchWidth: notchWidth)
    }

    /// A slot's capsule rect inside a window of `size` — view coordinates
    /// (origin bottom-left). `geometry` is the claim `windowFrame` was
    /// built with; an unclaimed side (extent 0) gets no rect, and a
    /// measured extent that left less than `wingContentMinUsable`
    /// collapses the same way. The chip never outgrows the measured
    /// claim — a manual `screen_bar_wing_length` widening the window does
    /// not widen the wing into unmeasured room. On a notch-less screen
    /// the chips flank the band at its own height, hugging its ends.
    public static func wingSlotRect(_ side: ScreenBarWingSide, in size: NSSize,
                                    geometry: ScreenBarWingGeometry) -> CGRect? {
        let extent = side == .left ? geometry.leftExtent : geometry.rightExtent
        guard extent > 0 else { return nil }
        let sideExtent = max(0, (size.width - geometry.notchWidth) / 2.0)
        if geometry.notchDepth > 0 {
            let usable = min(sideExtent, extent) - wingContentInnerReserve - wingContentOuterInset
            guard usable >= wingContentMinUsable else { return nil }
            let height = min(wingSlotHeight, max(14, geometry.notchDepth - 8))
            let y = size.height - geometry.notchDepth + (geometry.notchDepth - height) / 2.0
            switch side {
            case .left:
                return CGRect(x: wingContentOuterInset, y: y, width: usable, height: height)
            case .right:
                return CGRect(x: size.width - wingContentOuterInset - usable, y: y,
                              width: usable, height: height)
            }
        }
        let band = bandRect(in: size, preferredSpan: geometry.bandSpan > 0 ? geometry.bandSpan : nil)
        let height = notchlessSlotHeight
        let y = min(max(1, band.midY - height / 2.0), max(1, size.height - height - 1))
        switch side {
        case .left:
            let width = min(notchlessSlotMaxWidth, max(0, band.minX - wingSlotGap - wingContentOuterInset))
            guard width >= wingContentMinUsable else { return nil }
            return CGRect(x: band.minX - wingSlotGap - width, y: y, width: width, height: height)
        case .right:
            let width = min(notchlessSlotMaxWidth, max(0, size.width - band.maxX - wingSlotGap - wingContentOuterInset))
            guard width >= wingContentMinUsable else { return nil }
            return CGRect(x: band.maxX + wingSlotGap, y: y, width: width, height: height)
        }
    }

    /// `screen_bar_runtime._window_height_for_notch_depth`.
    public static func windowHeight(notchDepth: CGFloat) -> CGFloat {
        max(max(0, notchDepth) + ScreenBarDesign.bandHeight, ScreenBarDesign.bandHeight + ScreenBarDesign.glowHeight + 2.0)
    }

    /// The notch width the caller's settings resolve to — the
    /// `screen_bar_gap_width` override when it is set, else the measured
    /// slot. `windowFrame` derives the same value internally; the view
    /// needs it to place the wing slots.
    public static func resolvedNotchWidth(slotWidth measuredSlot: CGFloat, gapWidth: CGFloat? = nil) -> CGFloat {
        if let gapWidth, gapWidth > 0 { return gapWidth }
        return measuredSlot
    }

    /// The panel's frame from measured values (`virtual_window_frame_for_screen`),
    /// pure for tests. `gapWidth` is `screen_bar_gap_width`: the manual
    /// width of the notch gap the band is centred on — nil or 0 measures
    /// the slot. `wingLength` is `screen_bar_wing_length`, per `wingWidth`.
    /// `contentExtent` is the content wings' per-side claim
    /// (`contentWingExtent`, or `notchlessWingClaim` where there is no
    /// safe area to measure); it widens the window without widening the
    /// band. While a capsule is followed the flanks belong to it, so the
    /// claim is ignored.
    public static func windowFrame(screenFrame frame: CGRect, slotWidth measuredSlot: CGFloat, notchDepth: CGFloat,
                                   auxiliaryLeft leftWidth: CGFloat, auxiliaryRight rightWidth: CGFloat, hardwareSlot: CGFloat,
                                   wrapMenuBar: Bool, gapWidth: CGFloat? = nil, wingLength: CGFloat? = nil,
                                   capsule: AlcoveCapsule? = nil, contentExtent: CGFloat = 0) -> CGRect {
        let notchWidth = resolvedNotchWidth(slotWidth: measuredSlot, gapWidth: gapWidth)
        let wing = wrapMenuBar
            ? wingWidth(auxiliaryLeft: leftWidth, auxiliaryRight: rightWidth, hardwareSlot: hardwareSlot,
                        notchWidth: notchWidth, manual: wingLength)
            : 0
        let side = capsule == nil ? max(wing, max(0, contentExtent)) : wing
        return AlcoveGeometry.windowFrame(screenFrame: frame, notchWidth: notchWidth, wing: side,
                                          notchDepth: notchDepth, capsule: capsule, windowHeight: windowHeight(notchDepth:))
    }

    /// The panel's frame in screen coordinates, measured off `screen`.
    /// With a `capsule` the band follows Alcove instead of the notch
    /// (`AlcoveGeometry.windowFrame`).
    public static func windowFrame(for screen: NSScreen, wrapMenuBar: Bool, gapWidth: CGFloat? = nil,
                                   wingLength: CGFloat? = nil, capsule: AlcoveCapsule? = nil,
                                   contentExtent: CGFloat = 0) -> NSRect {
        let left = screen.auxiliaryTopLeftArea, right = screen.auxiliaryTopRightArea
        return windowFrame(screenFrame: screen.frame, slotWidth: slotWidth(of: screen), notchDepth: notchDepth(of: screen),
                           auxiliaryLeft: left?.width ?? 0, auxiliaryRight: right?.width ?? 0,
                           hardwareSlot: left != nil && right != nil ? right!.origin.x - left!.maxX : 0,
                           wrapMenuBar: wrapMenuBar, gapWidth: gapWidth, wingLength: wingLength, capsule: capsule,
                           contentExtent: contentExtent)
    }

    /// `screen_bar_design.rounded_band_bounds`: a centered, bounded band that
    /// never degenerates into a hairline.
    public static func roundedBandBounds(totalWidth: CGFloat, preferredWidth: CGFloat? = nil, edgeInset: CGFloat = ScreenBarDesign.edgeInset) -> (left: CGFloat, right: CGFloat) {
        let width = max(0, totalWidth)
        let inset = max(0, edgeInset)
        let available = max(0, width - 2.0 * inset)
        if available <= 0 { return (width / 2.0, width / 2.0) }
        var requested = preferredWidth.map { max(0, $0) } ?? available
        if available >= ScreenBarDesign.minBandWidth { requested = max(ScreenBarDesign.minBandWidth, requested) }
        let bandWidth = min(available, min(ScreenBarDesign.maxBandWidth, requested))
        let left = (width - bandWidth) / 2.0
        return (left, left + bandWidth)
    }

    /// The rounded status band inside a window of `size` (`_rounded_status_band`).
    /// `preferredSpan` is the width the band's own window would have had
    /// (notch plus the glow wings) — passing it keeps the band hugging the
    /// notch when the window is wider because a content wing claimed the
    /// flanks.
    public static func bandRect(in size: NSSize, preferredSpan: CGFloat? = nil) -> NSRect {
        let (left, right) = roundedBandBounds(totalWidth: size.width,
                                              preferredWidth: preferredSpan.map { max(0, $0 - 2.0 * ScreenBarDesign.edgeInset) })
        let bandWidth = max(0, right - left)
        let bandHeight = min(ScreenBarDesign.bandHeight, max(1.0, size.height - ScreenBarDesign.verticalInset))
        let y = min(ScreenBarDesign.verticalInset, max(0, size.height - bandHeight))
        return NSRect(x: left, y: y, width: bandWidth, height: bandHeight)
    }
}
