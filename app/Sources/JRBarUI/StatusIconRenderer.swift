import AppKit

/// `menu_bar_icon_style`: the glyph alone, the glyph inside a thin usage
/// ring, or the glyph beside a short text label.
public enum StatusIconStyle: String, CaseIterable, Sendable {
    case glyph
    case glyphRing = "glyph_ring"
    case glyphLabel = "glyph_label"

    /// Accepts the settings value in either spelling (`ring` / `glyph_ring`).
    public init(setting: String?) {
        switch setting?.lowercased() {
        case "glyph_ring", "ring", "usage_ring": self = .glyphRing
        case "glyph_label", "label", "text": self = .glyphLabel
        default: self = .glyph
        }
    }
}

/// Everything that changes the picture. Equatable so the status item only
/// redraws when something moved.
public struct StatusIconSpec: Hashable, Sendable {
    public var style: StatusIconStyle
    /// 0...1 of the primary provider's 5 h window; nil draws no ring.
    public var ringFraction: Double?
    /// The aggregate tint (working cyan, ask orange, ...); nil keeps the
    /// menu bar's own colour through a template image.
    public var tintHex: String?

    public init(style: StatusIconStyle, ringFraction: Double? = nil, tintHex: String? = nil) {
        self.style = style
        self.ringFraction = ringFraction.map { max(0, min(1, $0)) }
        self.tintHex = tintHex
    }

    /// Fractions are bucketed to 2 % so a slowly moving window does not
    /// rebuild the image every state message.
    var cacheKey: StatusIconSpec {
        var key = self
        key.ringFraction = ringFraction.map { ($0 * 50).rounded() / 50 }
        return key
    }

    public var ringWarning: RingWarning {
        guard style == .glyphRing, let ringFraction else { return .none }
        if ringFraction >= 0.95 { return .red }
        if ringFraction >= 0.80 { return .amber }
        return .none
    }

    public enum RingWarning: Sendable { case none, amber, red }
}

/// Draws and caches the 18×18 pt status item images.
public final class StatusIconRenderer: @unchecked Sendable {
    public static let shared = StatusIconRenderer()
    public static let size = NSSize(width: 18, height: 18)

    private var cache: [StatusIconSpec: NSImage] = [:]
    private let lock = NSLock()

    public init() {}

    public var cachedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cache.count
    }

    /// The same `NSImage` instance for the same spec (the status item can
    /// compare identity to skip a redraw).
    public func image(for spec: StatusIconSpec) -> NSImage {
        let key = spec.cacheKey
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let image = Self.draw(key)
        lock.lock()
        cache[key] = image
        if cache.count > 64 { cache.removeAll() ; cache[key] = image }
        lock.unlock()
        return image
    }

    /// "2 working · 1 ask" for the label style; nil when everything is quiet.
    public static func label(active: Int, needsYou: Int, ready: Int, failed: Int = 0) -> String? {
        var parts: [String] = []
        if needsYou > 0 { parts.append(needsYou == 1 ? "1 ask" : "\(needsYou) asks") }
        if failed > 0 { parts.append("\(failed) failed") }
        if active > 0 { parts.append("\(active) working") }
        if ready > 0 { parts.append("\(ready) done") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Drawing

    /// Template when nothing needs its own colour; otherwise a full-colour
    /// image whose glyph follows `labelColor` for the current appearance
    /// (the drawing handler runs at draw time, so it re-resolves).
    static func draw(_ spec: StatusIconSpec) -> NSImage {
        let warning = spec.ringWarning
        let tint = spec.tintHex.flatMap(NSColor.init(statusHex:))
        let template = warning == .none && tint == nil
        let image = NSImage(size: size, flipped: false) { _ in
            let glyphColor: NSColor = template ? .black : (tint ?? .labelColor)
            let capColor = glyphColor.withAlphaComponent(0.38)
            if spec.style == .glyphRing, let fraction = spec.ringFraction {
                let ringColor: NSColor
                switch warning {
                case .red: ringColor = .systemRed
                case .amber: ringColor = .systemOrange
                case .none: ringColor = glyphColor
                }
                drawRing(fraction: fraction, color: ringColor, track: glyphColor.withAlphaComponent(0.18))
                drawGlyph(cap: capColor, bar: glyphColor, scale: 0.68)
            } else {
                drawGlyph(cap: capColor, bar: glyphColor, scale: 1.0)
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "JR-Bar"
        return image
    }

    /// A rounded bar tucked under a small notch cap, as in the original glyph.
    static func drawGlyph(cap capColor: NSColor, bar barColor: NSColor, scale: CGFloat) {
        let transform = NSAffineTransform()
        transform.translateX(by: 9, yBy: 9)
        transform.scale(by: scale)
        transform.translateX(by: -9, yBy: -9)
        transform.concat()
        defer { transform.invert(); transform.concat() }
        capColor.setFill()
        let cap = NSBezierPath()
        cap.move(to: NSPoint(x: 4.5, y: 15.5))
        cap.line(to: NSPoint(x: 13.5, y: 15.5))
        cap.line(to: NSPoint(x: 13.5, y: 12.2))
        cap.curve(to: NSPoint(x: 11.7, y: 10.4), controlPoint1: NSPoint(x: 13.5, y: 11.2), controlPoint2: NSPoint(x: 12.7, y: 10.4))
        cap.line(to: NSPoint(x: 6.3, y: 10.4))
        cap.curve(to: NSPoint(x: 4.5, y: 12.2), controlPoint1: NSPoint(x: 5.3, y: 10.4), controlPoint2: NSPoint(x: 4.5, y: 11.2))
        cap.close()
        cap.fill()
        barColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 2.5, y: 5.6, width: 13, height: 3.6), xRadius: 1.8, yRadius: 1.8).fill()
    }

    /// A 1.2 pt ring at radius 8, filling clockwise from 12 o'clock.
    static func drawRing(fraction: Double, color: NSColor, track: NSColor) {
        let center = NSPoint(x: 9, y: 9)
        let radius: CGFloat = 8.0
        let trackPath = NSBezierPath()
        trackPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        trackPath.lineWidth = 1.2
        track.setStroke()
        trackPath.stroke()
        guard fraction > 0.001 else { return }
        let sweep = CGFloat(min(1, fraction)) * 360
        let path = NSBezierPath()
        // AppKit angles run counter-clockwise from 3 o'clock; start at 12 and go clockwise.
        path.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        path.lineWidth = 1.2
        path.lineCapStyle = fraction >= 0.999 ? .butt : .round
        color.setStroke()
        path.stroke()
    }
}

extension NSColor {
    convenience init?(statusHex hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0, green: CGFloat((value >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(value & 0xFF) / 255.0, alpha: 1)
    }

    public var statusHex: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}
