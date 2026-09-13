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
public enum ScreenBarGeometry {
    public static let ledCount = 8
    /// Automatic wings hug the notch tightly (`WING_AUTO_LENGTH`).
    public static let wingAutoLength: CGFloat = 14.0
    public static let wingSafetyMargin: CGFloat = 28.0
    public static let wingMinUsable: CGFloat = 24.0
    public static let fallbackNotchDepth: CGFloat = 32.0
    /// The Python default (`screen_bar_min_glow`), which scales the outline.
    public static let minGlow: CGFloat = 0.25

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

    /// `screen_bar_runtime._window_height_for_notch_depth`.
    public static func windowHeight(notchDepth: CGFloat) -> CGFloat {
        max(max(0, notchDepth) + ScreenBarDesign.bandHeight, ScreenBarDesign.bandHeight + ScreenBarDesign.glowHeight + 2.0)
    }

    /// The panel's frame from measured values (`virtual_window_frame_for_screen`),
    /// pure for tests. `gapWidth` is `screen_bar_gap_width`: the manual
    /// width of the notch gap the band is centred on — nil or 0 measures
    /// the slot. `wingLength` is `screen_bar_wing_length`, per `wingWidth`.
    public static func windowFrame(screenFrame frame: CGRect, slotWidth measuredSlot: CGFloat, notchDepth: CGFloat,
                                   auxiliaryLeft leftWidth: CGFloat, auxiliaryRight rightWidth: CGFloat, hardwareSlot: CGFloat,
                                   wrapMenuBar: Bool, gapWidth: CGFloat? = nil, wingLength: CGFloat? = nil,
                                   capsule: AlcoveCapsule? = nil) -> CGRect {
        var notchWidth = measuredSlot
        if let gapWidth, gapWidth > 0 { notchWidth = gapWidth }
        let wing = wrapMenuBar
            ? wingWidth(auxiliaryLeft: leftWidth, auxiliaryRight: rightWidth, hardwareSlot: hardwareSlot,
                        notchWidth: notchWidth, manual: wingLength)
            : 0
        return AlcoveGeometry.windowFrame(screenFrame: frame, notchWidth: notchWidth, wing: wing,
                                          notchDepth: notchDepth, capsule: capsule, windowHeight: windowHeight(notchDepth:))
    }

    /// The panel's frame in screen coordinates, measured off `screen`.
    /// With a `capsule` the band follows Alcove instead of the notch
    /// (`AlcoveGeometry.windowFrame`).
    public static func windowFrame(for screen: NSScreen, wrapMenuBar: Bool, gapWidth: CGFloat? = nil,
                                   wingLength: CGFloat? = nil, capsule: AlcoveCapsule? = nil) -> NSRect {
        let left = screen.auxiliaryTopLeftArea, right = screen.auxiliaryTopRightArea
        return windowFrame(screenFrame: screen.frame, slotWidth: slotWidth(of: screen), notchDepth: notchDepth(of: screen),
                           auxiliaryLeft: left?.width ?? 0, auxiliaryRight: right?.width ?? 0,
                           hardwareSlot: left != nil && right != nil ? right!.origin.x - left!.maxX : 0,
                           wrapMenuBar: wrapMenuBar, gapWidth: gapWidth, wingLength: wingLength, capsule: capsule)
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
    public static func bandRect(in size: NSSize) -> NSRect {
        let (left, right) = roundedBandBounds(totalWidth: size.width)
        let bandWidth = max(0, right - left)
        let bandHeight = min(ScreenBarDesign.bandHeight, max(1.0, size.height - ScreenBarDesign.verticalInset))
        let y = min(ScreenBarDesign.verticalInset, max(0, size.height - bandHeight))
        return NSRect(x: left, y: y, width: bandWidth, height: bandHeight)
    }
}
