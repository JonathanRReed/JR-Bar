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

/// The band coupled to our notch island: while the island is drawn the
/// strip stops floating — it runs edge to edge under the island and a
/// black housing continues the island's silhouette, so the pair reads as
/// one continuous shape with the LED strip inset. All rects are in view
/// coordinates (y grows upward; the window's top is the screen's top).
public struct ScreenBarCoupling: Equatable, Sendable {
    /// The LED strip: the island's full width — its end caps kiss the
    /// island's side edges — at the band's usual seat under the notch.
    public var band: CGRect
    /// The black housing continuing the island's silhouette: square where
    /// its top runs up into the island's face, the notch profile's radius
    /// on its bottom corners.
    public var housing: CGRect
    /// The housing's bottom corner radius — the notch profile's own.
    public var cornerRadius: CGFloat

    public init(band: CGRect, housing: CGRect, cornerRadius: CGFloat) {
        self.band = band
        self.housing = housing
        self.cornerRadius = cornerRadius
    }
}

/// `screen_bar_notch_profile`: which MacBook's notch the tray's bottom
/// corners copy. `NSScreen` reports the slot's *size* (the safe-area
/// inset, the auxiliary areas) but never its corner radius, so the
/// radius comes from the machine: `auto` reads `hw.model`, the named
/// rows are the override when the guess is wrong — or when the desk runs
/// something Apple's table doesn't cover — and `custom` hands the
/// `screen_bar_notch_corner` slider outright.
public enum NotchProfile: String, CaseIterable, Sendable {
    case auto
    case macbookAir13 = "macbook_air_13"
    case macbookAir15 = "macbook_air_15"
    case macbookPro14 = "macbook_pro_14"
    case macbookPro16 = "macbook_pro_16"
    case custom

    /// Anything stored, and nothing, resolves to `auto`.
    public init(setting: String?) {
        self = setting.flatMap(NotchProfile.init(rawValue:)) ?? .auto
    }

    public var title: String {
        switch self {
        case .auto: return "Automatic"
        case .macbookAir13: return "MacBook Air 13″"
        case .macbookAir15: return "MacBook Air 15″"
        case .macbookPro14: return "MacBook Pro 14″"
        case .macbookPro16: return "MacBook Pro 16″"
        case .custom: return "Custom"
        }
    }

    /// The hardware cutout's bottom corner in points — measured ~8 on
    /// every notched MacBook (the top corners are ~4; only the bottom
    /// pair meets our tray). `custom` is the one case that differs: the
    /// `screen_bar_notch_corner` slider's value, clamped to sanity.
    public func cornerRadius(manual: CGFloat? = nil) -> CGFloat {
        if self == .custom {
            return manual.map { min(16, max(0, $0)) } ?? Self.standardCornerRadius
        }
        return Self.standardCornerRadius
    }

    /// The measured notch bottom corner, shared by every notched MacBook.
    public static let standardCornerRadius: CGFloat = 8

    /// `hw.model` — "Mac16,8" on this MacBook Pro — for the settings
    /// row's detected-model note.
    public static var machineModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var name = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &name, &size, nil, 0)
        return String(decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                      as: UTF8.self)
    }

    /// A friendlier family name for `machineModel` in settings copy —
    /// "MacBook Pro" for MacBookPro18,3, the raw identifier for a VM or
    /// a desktop (whose "notch" is drawn, not machined).
    public static var machineFamily: String {
        let model = machineModel
        if model.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if model.hasPrefix("MacBookAir") { return "MacBook Air" }
        return model.isEmpty ? "this Mac" : model
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
    /// Margin kept next to the notch when a flank's room is measured:
    /// the island's shoulder (12) draws there when the island is ours, so
    /// a claim that tight is not honestly usable. The drawn claim itself
    /// reaches the notch edge — `wingSlotRect` anchors it there.
    public static let wingContentInnerReserve: CGFloat = 16
    /// Room left at the window's outer edge.
    public static let wingContentOuterInset: CGFloat = 6
    /// The gap between a notch-less chip and the band's end.
    public static let wingSlotGap: CGFloat = 5
    /// A notch-less screen has no flank to measure, so a slot claims a
    /// fixed reach beside the band…
    public static let notchlessWingClaim: CGFloat = 120
    /// …but only draws a capsule this wide, hugging the band's end.
    public static let notchlessSlotMaxWidth: CGFloat = 84
    public static let notchlessSlotHeight: CGFloat = 18
    /// The tray's chin: how far the wings' shared black shape hangs below
    /// the bezel's bottom edge while a wing claims room. Zero: the ears
    /// end exactly where the hardware ends. A 6 pt chin read as the
    /// notch grown downward — "expanding past the notch" (owner,
    /// 2026-09-16) — on a bar whose menu bar is 33 pt to the notch's 32.
    public static let wingTrayChin: CGFloat = 0

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
            // The claim anchors at the notch's edge and reaches outward
            // through the measured room — the chip merges with the notch
            // instead of floating a `wingContentInnerReserve` gap off it.
            // It spans the notch's own depth at the window's top, flush
            // with the screen's edge: the drawn lobe IS the notch's ear,
            // not a pill centred in the menu-bar strip.
            let usable = min(sideExtent, extent) - wingContentOuterInset
            guard usable >= wingContentMinUsable else { return nil }
            let height = geometry.notchDepth
            let y = size.height - geometry.notchDepth
            switch side {
            case .left:
                return CGRect(x: sideExtent - usable, y: y, width: usable, height: height)
            case .right:
                return CGRect(x: size.width - sideExtent, y: y,
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

    // MARK: Island coupling (our notch island drawn under the band)

    /// Black the housing keeps above the strip while a grown island's face
    /// is already behind it — the lip never shows; it only guarantees the
    /// housing meets the island's own black.
    public static let coupledLip: CGFloat = 4
    /// Black the housing keeps under the strip — the chin that seats the
    /// light inside the shared silhouette.
    public static let coupledChin: CGFloat = 3
    /// Slack the coupled window keeps under the housing's bottom edge so
    /// the silhouette's corner curve never clips the window's bounds.
    public static let coupledSlack: CGFloat = 1

    /// The height the coupled window needs: the strip's notch-anchored
    /// seat plus the housing's chin and a point of slack below it.
    public static func coupledWindowHeight(notchDepth: CGFloat) -> CGFloat {
        max(0, notchDepth) - ScreenBarDesign.verticalInset + ScreenBarDesign.bandHeight
            + coupledChin + coupledSlack
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
    /// claim is ignored. `chin` is `wingTrayChin` while a wing claims
    /// room: the tray hangs that far below the bezel, growing the window
    /// so the band drops clear of it. `coupledIsland` is our notch
    /// island's live frame while it is drawn: the window then grows to
    /// reach the island's side edges (the strip kisses them) and to seat
    /// the housing under the band — toward the island, never smaller.
    public static func windowFrame(screenFrame frame: CGRect, slotWidth measuredSlot: CGFloat, notchDepth: CGFloat,
                                   auxiliaryLeft leftWidth: CGFloat, auxiliaryRight rightWidth: CGFloat, hardwareSlot: CGFloat,
                                   wrapMenuBar: Bool, gapWidth: CGFloat? = nil, wingLength: CGFloat? = nil,
                                   capsule: AlcoveCapsule? = nil, contentExtent: CGFloat = 0,
                                   chin: CGFloat = 0, coupledIsland: CGRect? = nil) -> CGRect {
        let notchWidth = resolvedNotchWidth(slotWidth: measuredSlot, gapWidth: gapWidth)
        let wing = wrapMenuBar
            ? wingWidth(auxiliaryLeft: leftWidth, auxiliaryRight: rightWidth, hardwareSlot: hardwareSlot,
                        notchWidth: notchWidth, manual: wingLength)
            : 0
        let side = capsule == nil ? max(wing, max(0, contentExtent)) : wing
        let base = AlcoveGeometry.windowFrame(screenFrame: frame, notchWidth: notchWidth, wing: side,
                                              notchDepth: notchDepth, capsule: capsule,
                                              windowHeight: { windowHeight(notchDepth: $0) + chin })
        guard let coupledIsland, coupledIsland.width > 0 else { return base }
        let width = min(frame.width, max(base.width, coupledIsland.width))
        let centerX = min(frame.maxX - width / 2.0, max(frame.minX + width / 2.0, coupledIsland.midX))
        let height = max(base.height, coupledWindowHeight(notchDepth: notchDepth))
        return CGRect(x: centerX - width / 2.0, y: frame.maxY - height, width: width, height: height)
    }

    /// The panel's frame in screen coordinates, measured off `screen`.
    /// With a `capsule` the band follows Alcove instead of the notch
    /// (`AlcoveGeometry.windowFrame`); with a `coupledIsland` the window
    /// grows to the island's side edges and seats the housing.
    public static func windowFrame(for screen: NSScreen, wrapMenuBar: Bool, gapWidth: CGFloat? = nil,
                                   wingLength: CGFloat? = nil, capsule: AlcoveCapsule? = nil,
                                   contentExtent: CGFloat = 0, chin: CGFloat = 0,
                                   coupledIsland: CGRect? = nil) -> NSRect {
        let left = screen.auxiliaryTopLeftArea, right = screen.auxiliaryTopRightArea
        return windowFrame(screenFrame: screen.frame, slotWidth: slotWidth(of: screen), notchDepth: notchDepth(of: screen),
                           auxiliaryLeft: left?.width ?? 0, auxiliaryRight: right?.width ?? 0,
                           hardwareSlot: left != nil && right != nil ? right!.origin.x - left!.maxX : 0,
                           wrapMenuBar: wrapMenuBar, gapWidth: gapWidth, wingLength: wingLength, capsule: capsule,
                           contentExtent: contentExtent, chin: chin, coupledIsland: coupledIsland)
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

    /// The coupled band and its housing inside a window of `size`, given
    /// the island's `island` rect in the same view coordinates. The strip
    /// keeps its usual seat — top edge `verticalInset` above the notch's
    /// bottom edge — but spans the island's full width so its end caps
    /// kiss the island's side edges. The housing is the strip's black
    /// seat: its top runs up behind the island's bottom corner
    /// (`cornerRadius`), or just `coupledLip` above the strip when a
    /// grown island's face is already there, and its bottom edge —
    /// `coupledChin` under the strip — carries the profile's radius, so
    /// island and band read as one continuous black shape with the LED
    /// strip inset.
    public static func coupledBand(in size: NSSize, island: CGRect, notchDepth: CGFloat,
                                   cornerRadius: CGFloat) -> ScreenBarCoupling {
        let radius = max(0, cornerRadius)
        let stripTop = max(0, notchDepth - ScreenBarDesign.verticalInset)
        let stripBottom = stripTop + ScreenBarDesign.bandHeight
        let islandBottom = size.height - island.minY
        let housingTop = max(0, min(islandBottom - radius, stripTop - coupledLip))
        let housingBottom = stripBottom + coupledChin
        return ScreenBarCoupling(
            band: CGRect(x: island.minX, y: size.height - stripBottom,
                         width: max(0, island.width), height: stripBottom - stripTop),
            housing: CGRect(x: island.minX, y: size.height - housingBottom,
                            width: max(0, island.width), height: housingBottom - housingTop),
            cornerRadius: radius)
    }
}
