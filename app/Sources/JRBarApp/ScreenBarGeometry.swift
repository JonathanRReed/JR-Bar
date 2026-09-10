import AppKit
import JRBarCore

/// Constants from `screen_bar_design.py`, the reviewed Screen Bar design.
enum ScreenBarDesign {
    static let bandHeight: CGFloat = 6.0
    static let compactBandHeight: CGFloat = 5.0
    static let glowHeight: CGFloat = 14.0
    static let windowWidth: CGFloat = 260.0
    static let minBandWidth: CGFloat = 180.0
    static let maxBandWidth: CGFloat = 420.0
    static let edgeInset: CGFloat = 8.0
    static let verticalInset: CGFloat = 1.0
    static let cornerRadius: CGFloat = 3.0
    static let outlineAlpha: CGFloat = 0.24
    static let haloAlpha: CGFloat = 0.16
}

/// Ports of the geometry helpers in `virtual_device.py`.
enum ScreenBarGeometry {
    static let ledCount = 8
    /// Automatic wings hug the notch tightly (`WING_AUTO_LENGTH`).
    static let wingAutoLength: CGFloat = 14.0
    static let wingSafetyMargin: CGFloat = 28.0
    static let wingMinUsable: CGFloat = 24.0
    static let fallbackNotchDepth: CGFloat = 32.0
    /// The Python default (`screen_bar_min_glow`), which scales the outline.
    static let minGlow: CGFloat = 0.25

    /// The screen the Screen Bar belongs on: the first with a safe-area
    /// inset (the notched built-in), else the main screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func notchDepth(of screen: NSScreen) -> CGFloat {
        let depth = screen.safeAreaInsets.top
        return depth >= 1.0 ? depth : 0.0
    }

    static func hasNotch(_ screen: NSScreen) -> Bool { notchDepth(of: screen) > 0 }

    /// The system-reported gap between the notch's left and right areas.
    static func slotWidth(of screen: NSScreen) -> CGFloat {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = right.origin.x - left.maxX
            if width >= 120.0 { return max(180.0, min(320.0, width)) }
        }
        return ScreenBarDesign.windowWidth
    }

    /// How far the glow may extend past each side of the notch (`wing_width_for_screen`).
    static func wingWidth(of screen: NSScreen, notchWidth: CGFloat) -> CGFloat {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
              left.width > 0, right.width > 0 else { return 0 }
        let hardwareSlot = right.origin.x - left.maxX
        var overhang: CGFloat = 0
        if hardwareSlot > 0, notchWidth > hardwareSlot { overhang = (notchWidth - hardwareSlot) / 2.0 }
        let room = min(left.width - wingSafetyMargin - overhang, right.width - wingSafetyMargin - overhang)
        if room < wingMinUsable { return 0 }
        return max(0, min(wingAutoLength, room))
    }

    /// `screen_bar_runtime._window_height_for_notch_depth`.
    static func windowHeight(notchDepth: CGFloat) -> CGFloat {
        max(max(0, notchDepth) + ScreenBarDesign.bandHeight, ScreenBarDesign.bandHeight + ScreenBarDesign.glowHeight + 2.0)
    }

    /// The panel's frame in screen coordinates (`virtual_window_frame_for_screen`).
    /// With a `capsule` the band follows Alcove instead of the notch
    /// (`AlcoveGeometry.windowFrame`).
    static func windowFrame(for screen: NSScreen, wrapMenuBar: Bool, capsule: AlcoveCapsule? = nil) -> NSRect {
        let notchWidth = slotWidth(of: screen)
        let wing = wrapMenuBar ? wingWidth(of: screen, notchWidth: notchWidth) : 0
        return AlcoveGeometry.windowFrame(screenFrame: screen.frame, notchWidth: notchWidth, wing: wing,
                                          notchDepth: notchDepth(of: screen), capsule: capsule, windowHeight: windowHeight(notchDepth:))
    }

    /// `screen_bar_design.rounded_band_bounds`: a centered, bounded band that
    /// never degenerates into a hairline.
    static func roundedBandBounds(totalWidth: CGFloat, preferredWidth: CGFloat? = nil, edgeInset: CGFloat = ScreenBarDesign.edgeInset) -> (left: CGFloat, right: CGFloat) {
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
    static func bandRect(in size: NSSize) -> NSRect {
        let (left, right) = roundedBandBounds(totalWidth: size.width)
        let bandWidth = max(0, right - left)
        let bandHeight = min(ScreenBarDesign.bandHeight, max(1.0, size.height - ScreenBarDesign.verticalInset))
        let y = min(ScreenBarDesign.verticalInset, max(0, size.height - bandHeight))
        return NSRect(x: left, y: y, width: bandWidth, height: bandHeight)
    }
}
