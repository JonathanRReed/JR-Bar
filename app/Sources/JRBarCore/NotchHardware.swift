import Foundation

/// What kind of top edge a display has — the one fact every notch
/// surface branches on.
public enum NotchDisplayKind: String, Equatable, Sendable {
    /// A real camera housing: the screen reports both menu-bar areas
    /// with a gap between them.
    case notched
    /// "Simulate notch" on a screen without one: a synthetic housing.
    case simulated
    /// The built-in panel of a Mac without a notch.
    case builtInNotchless
    /// Any other display. The island floats as a pill.
    case external
}

/// One display's top-edge measurements, exactly as AppKit reports them —
/// plain numbers, so the geometry below is a pure function and the tests
/// can stand in a 14-inch, a 16-inch, an external monitor and a second
/// screen without owning any of them.
public struct NotchScreenMetrics: Equatable, Sendable {
    /// `NSScreen.frame`: global coordinates, origin bottom-left.
    public var frame: CGRect
    /// `NSScreen.safeAreaInsets.top`.
    public var safeAreaTop: CGFloat
    /// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`.
    public var auxLeft: CGRect?
    public var auxRight: CGRect?
    /// `NSScreen.backingScaleFactor`.
    public var backingScale: CGFloat
    /// `CGDisplayIsBuiltin`.
    public var isBuiltIn: Bool

    public init(frame: CGRect, safeAreaTop: CGFloat = 0, auxLeft: CGRect? = nil,
                auxRight: CGRect? = nil, backingScale: CGFloat = 2, isBuiltIn: Bool = false) {
        self.frame = frame
        self.safeAreaTop = safeAreaTop
        self.auxLeft = auxLeft
        self.auxRight = auxRight
        self.backingScale = backingScale
        self.isBuiltIn = isBuiltIn
    }
}

/// The pixel grid a window's edges live on. A frame that lands between
/// device pixels is resampled by the compositor: a soft edge, and a
/// hairline of menu bar showing between the island and the hardware.
/// Snapping outward only ever grows a surface by less than one pixel.
public enum NotchPixelGrid {
    /// A usable scale: 1 for anything non-finite or below 1.
    public static func sanitized(_ scale: CGFloat) -> CGFloat {
        scale.isFinite && scale >= 1 ? scale : 1
    }

    /// `value` rounded to the nearest device pixel.
    public static func nearest(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let scale = sanitized(scale)
        return (value * scale).rounded() / scale
    }

    /// `rect` grown outward to whole device pixels on every side.
    public static func snapOut(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let scale = sanitized(scale)
        // A tolerance so a coordinate that is a whole pixel up to float
        // noise (663.5 * 2 = 1327.0000000001) does not grow a pixel.
        let eps: CGFloat = 1e-4
        let minX = ((rect.minX * scale) + eps).rounded(.down) / scale
        let maxX = ((rect.maxX * scale) - eps).rounded(.up) / scale
        let minY = ((rect.minY * scale) + eps).rounded(.down) / scale
        let maxY = ((rect.maxY * scale) - eps).rounded(.up) / scale
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}

/// The notch of one display, resolved: where the hardware (or the
/// synthetic housing) is, in global screen coordinates and on whole
/// device pixels. Everything that hangs from the notch — the island's
/// bare housing, the card's anchor, the confetti's landing — reads these
/// numbers, so no surface carries its own idea of how wide the notch is.
public struct NotchHardware: Equatable, Sendable {
    public var kind: NotchDisplayKind
    /// The notch's rectangle, flush with the screen's top edge: snapped
    /// outward to the pixel grid and bled one device pixel past each
    /// side, so the island fully covers the hardware's anti-aliased
    /// edge. `.zero` when the display has no notch.
    public var rect: CGRect

    public init(kind: NotchDisplayKind, rect: CGRect) {
        self.kind = kind
        self.rect = rect
    }

    /// A notch (real or simulated) exists to hang from.
    public var hasSlot: Bool { kind == .notched || kind == .simulated }
    public var centerX: CGFloat { rect.midX }
    public var width: CGFloat { rect.width }
    /// The depth the island hugs; 0 on a display with no notch.
    public var depth: CGFloat { rect.height }

    /// The synthetic housing "Simulate notch" draws on a notch-less
    /// screen: a laptop notch's measure.
    public static let simulatedWidth: CGFloat = 200
    public static let simulatedDepth: CGFloat = 32
    /// Device pixels the real notch's rectangle bleeds past each side.
    public static let seamBleedPixels: CGFloat = 1

    /// The area rects AppKit hands back, in global coordinates. They
    /// come back in the screen's own space on some systems, which on a
    /// display that is not at the origin lands them outside the
    /// screen's frame — then they are moved by the frame's origin. A
    /// rect that already sits inside the frame is global and untouched.
    public static func globalAux(_ rect: CGRect, in frame: CGRect) -> CGRect {
        let tolerance = frame.insetBy(dx: -1, dy: -1)
        if frame.origin == .zero || tolerance.contains(rect) { return rect }
        return rect.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    /// Resolve `metrics`. A real notch needs both areas and a gap
    /// between them; a depth with no gap (a screen mid-reconfiguration)
    /// is not a notch. `simulated` draws a synthetic housing where there
    /// is none.
    public static func resolve(_ metrics: NotchScreenMetrics, simulated: Bool) -> NotchHardware {
        let frame = metrics.frame
        let scale = NotchPixelGrid.sanitized(metrics.backingScale)
        if let left = metrics.auxLeft.map({ globalAux($0, in: frame) }),
           let right = metrics.auxRight.map({ globalAux($0, in: frame) }),
           right.minX > left.maxX {
            let reported = metrics.safeAreaTop >= 1 ? metrics.safeAreaTop : max(left.height, right.height)
            if reported >= 1 {
                let bleed = seamBleedPixels / scale
                let raw = CGRect(x: left.maxX - bleed, y: frame.maxY - reported,
                                 width: right.minX - left.maxX + 2 * bleed, height: reported)
                var rect = NotchPixelGrid.snapOut(raw, scale: scale)
                rect = rect.intersection(frame)
                // The top edge is the screen's: never a pixel short of it.
                rect.size.height += frame.maxY - rect.maxY
                return NotchHardware(kind: .notched, rect: rect)
            }
        }
        if simulated {
            let raw = CGRect(x: frame.midX - simulatedWidth / 2, y: frame.maxY - simulatedDepth,
                             width: simulatedWidth, height: simulatedDepth)
            return NotchHardware(kind: .simulated, rect: NotchPixelGrid.snapOut(raw, scale: scale))
        }
        return NotchHardware(kind: metrics.isBuiltIn ? .builtInNotchless : .external, rect: .zero)
    }
}

extension NotchIslandLayout {
    /// `frame` grown to whole device pixels — the window never rests, or
    /// passes, between pixels — and never narrower or shallower than
    /// the notch it hangs from. A spring's overshoot-free landing and
    /// its rounding both stay clear of a gap against the hardware's edge.
    public static func settled(_ frame: CGRect, scale: CGFloat, over notch: CGRect?) -> CGRect {
        floored(NotchPixelGrid.snapOut(frame, scale: scale), over: notch)
    }

    /// `frame`, never narrower or shallower than the notch it hangs from
    /// but left where it is between device pixels. A shape drawn by the
    /// view on a stage is anti-aliased and moves smoothly; only the
    /// window that lands has to sit on the grid (`settled`).
    public static func floored(_ frame: CGRect, over notch: CGRect?) -> CGRect {
        guard let notch, !notch.isEmpty, frame.maxY >= notch.maxY - 0.5 else { return frame }
        return frame.union(notch)
    }
}
