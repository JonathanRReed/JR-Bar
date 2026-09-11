import AppKit

/// `menu_bar_icon_style`: a column per provider (the default, and the
/// thing that is worth a glance), the same with the leading provider's
/// percent spelled out, or one of the three older looks — the glyph
/// alone, the glyph inside a thin usage ring, the glyph beside a label.
public enum StatusIconStyle: String, CaseIterable, Sendable {
    case meters
    case metersPercent = "meters_percent"
    case glyph
    case glyphRing = "glyph_ring"
    case glyphLabel = "glyph_label"

    /// Accepts the settings value in either spelling (`ring` / `glyph_ring`);
    /// anything unknown, and an absent value, is the default `meters`.
    public init(setting: String?) {
        switch setting?.lowercased() {
        case "glyph", "icon", "plain", "mark": self = .glyph
        case "glyph_ring", "ring", "usage_ring": self = .glyphRing
        case "glyph_label", "label", "text", "counts": self = .glyphLabel
        case "meters_percent", "meters+percent", "percent", "meters_pct": self = .metersPercent
        default: self = .meters
        }
    }

    /// True for the two styles that draw one meter per provider.
    public var isMeters: Bool { self == .meters || self == .metersPercent }

    /// The Settings picker's words.
    public var title: String {
        switch self {
        case .meters: return "Usage meters"
        case .metersPercent: return "Usage meters with percent"
        case .glyph: return "Glyph only"
        case .glyphRing: return "Glyph with usage ring"
        case .glyphLabel: return "Glyph with label"
        }
    }

    public var subtitle: String {
        switch self {
        case .meters: return "A column per provider you show in the panel, plus a state dot."
        case .metersPercent: return "The same columns, with the first provider's number."
        case .glyph: return "The JR-Bar mark, tinted by what the agents are doing."
        case .glyphRing: return "The mark inside a ring of your primary window."
        case .glyphLabel: return "The mark beside “1 ask · 2 working”."
        }
    }
}

/// One provider's column in the menu bar: how full its primary usage
/// window is, plus the name and glyph the tooltip and the percent style
/// need.
public struct StatusMeter: Hashable, Sendable {
    /// SF Symbol, or one or two characters for a logo no symbol matches.
    public enum Glyph: Hashable, Sendable {
        case symbol(String)
        case text(String)
    }

    public var id: String
    public var name: String
    public var glyph: Glyph
    /// 0…1 of the provider's primary window — nil when the provider reports
    /// the window without a number. A column drawn at zero for that would
    /// say "plenty left" about something nobody measured, so an unmeasured
    /// column gets its own mark instead.
    public var fraction: Double?
    /// The figure is derived rather than official: the percent style says `~`.
    public var approximate: Bool
    /// The provider's configured accent (`#RRGGBB`), when the settings
    /// document carries a usable `colors.agent_colors.<id>`. A coloured
    /// column cannot be a template image, so one accent renders the whole
    /// strip in colours.
    public var accentHex: String?

    public init(id: String, name: String, glyph: Glyph, fraction: Double?, approximate: Bool = false,
                accentHex: String? = nil) {
        self.id = id
        self.name = name
        self.glyph = glyph
        self.fraction = fraction.map { max(0, min(1, $0)) }
        self.approximate = approximate
        self.accentHex = accentHex
    }

    /// The window exists and nobody said how full it is.
    public var isUnknown: Bool { fraction == nil }

    public var warning: StatusIconSpec.RingWarning {
        guard let fraction else { return .none }
        if fraction >= 0.95 { return .red }
        if fraction >= 0.80 { return .amber }
        return .none
    }

    /// "Claude 82 %" for the tooltip, "Claude no reading" for a window the
    /// provider reports without a number.
    public var readout: String {
        guard let fraction else { return "\(name) no reading" }
        return "\(name) \(approximate ? "~" : "")\(Int((fraction * 100).rounded())) %"
    }
}

/// The dot at the left of the meters: what the agents are doing right now,
/// independent of how full anybody's quota is.
public enum StatusDotState: String, Hashable, Sendable, CaseIterable {
    /// Nothing running: a quiet hollow dot.
    case idle
    /// Something is working: the dot breathes at 2 Hz.
    case working
    /// An ask is open: the dot pulses amber.
    case ask
    /// Something failed: the dot blinks red. Its own state since
    /// 2026-09-10 -- a failed session used to show as whatever else was
    /// running, or as nothing at all.
    case error
    /// A run finished in the last few seconds: the dot holds green.
    case done

    /// Only these three move, so only these three run the redraw timer.
    public var animates: Bool { self == .working || self == .ask || self == .error }

    /// What the dot at the left is saying, in one line, so its meaning is
    /// somewhere other than this file. The tooltip's second line.
    public var meaning: String {
        switch self {
        case .idle: return "Hollow dot: nothing is running."
        case .working: return "Breathing dot: something is running."
        case .ask: return "Amber dot: something needs you."
        case .error: return "Red dot: something failed."
        case .done: return "Green dot: a run just finished."
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
    /// The meter styles: one column per provider shown in the panel, in
    /// the panel's order, capped by `StatusIconRenderer.maxMeters`.
    public var meters: [StatusMeter]
    /// Providers past the cap: drawn as "+2".
    public var overflow: Int
    public var dot: StatusDotState
    /// 0…1 breathing phase for the moving dots; steady dots ignore it.
    public var phase: Double

    public init(style: StatusIconStyle, ringFraction: Double? = nil, tintHex: String? = nil,
                meters: [StatusMeter] = [], overflow: Int = 0, dot: StatusDotState = .idle, phase: Double = 0) {
        self.style = style
        self.ringFraction = ringFraction.map { max(0, min(1, $0)) }
        self.tintHex = tintHex
        self.meters = meters
        self.overflow = max(0, overflow)
        self.dot = dot
        self.phase = max(0, min(1, phase))
    }

    /// Fractions are bucketed to 2 % so a slowly moving window does not
    /// rebuild the image every state message; the breathing phase to a
    /// quarter, so 2 Hz costs three cached images rather than a stream.
    var cacheKey: StatusIconSpec {
        var key = self
        key.ringFraction = ringFraction.map { ($0 * 50).rounded() / 50 }
        key.meters = meters.map { meter in
            var bucketed = meter
            bucketed.fraction = meter.fraction.map { ($0 * 50).rounded() / 50 }
            return bucketed
        }
        key.phase = style.isMeters && dot.animates ? (phase * 4).rounded() / 4 : 0
        return key
    }

    public var ringWarning: RingWarning {
        guard style == .glyphRing, let ringFraction else { return .none }
        if ringFraction >= 0.95 { return .red }
        if ringFraction >= 0.80 { return .amber }
        return .none
    }

    /// The worst warning any meter is in; `.none` when every window is calm.
    public var meterWarning: RingWarning {
        if meters.contains(where: { $0.warning == .red }) { return .red }
        if meters.contains(where: { $0.warning == .amber }) { return .amber }
        return .none
    }

    public enum RingWarning: Sendable { case none, amber, red }
}

/// Draws and caches the status item images: 18×18 pt for the glyph
/// styles, a 22 pt-tall strip as wide as it needs for the meters.
public final class StatusIconRenderer: @unchecked Sendable {
    public static let shared = StatusIconRenderer()
    public static let size = NSSize(width: 18, height: 18)

    // The meter strip, in points. The menu bar is 22 pt tall on every Mac
    // this app runs on, so the strip is drawn at that height and centred.
    //
    // Width is the scarce thing, not height: on a notched MacBook with a
    // busy menu bar, an item much past 80 pt is given no slot at all and
    // macOS hides it behind the "«" — measured on the owner's Mac, where a
    // glyph-and-bar cell per provider (115 pt for three) never appeared.
    // So a provider costs one 3.5 pt column: five of them, the dot and the
    // insets come to about 43 pt, narrower than the clock.
    public static let barHeight: CGFloat = 22
    /// Providers past this many become "+n".
    public static let maxMeters = 5
    static let edgeInset: CGFloat = 2
    static let dotDiameter: CGFloat = 5
    static let dotGap: CGFloat = 6
    static let glyphBox: CGFloat = 11
    /// One provider's column: a track with the used fraction filled from
    /// the bottom.
    static let meterBarWidth: CGFloat = 3.5
    static let meterBarHeight: CGFloat = 12
    static let meterBarGap: CGFloat = 2.5
    static let glyphGap: CGFloat = 2
    static let cellGap: CGFloat = 4
    static let percentGap: CGFloat = 3

    static var percentFont: NSFont { .monospacedDigitSystemFont(ofSize: 9, weight: .medium) }
    static var overflowFont: NSFont { .systemFont(ofSize: 9.5, weight: .semibold) }

    private var cache: [StatusIconSpec: NSImage] = [:]
    private let lock = NSLock()

    public init() {}

    public var cachedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cache.count
    }

    /// How wide the image for this spec is. The glyph styles are square;
    /// a meter strip grows with the providers it shows, so the status item
    /// has to ask before it sets its own length.
    public static func size(for spec: StatusIconSpec) -> NSSize {
        guard spec.style.isMeters else { return size }
        var width = edgeInset + dotDiameter + dotGap
        if spec.meters.isEmpty {
            width += glyphBox                                  // the bare mark, so the item is never a gap
        } else {
            width += CGFloat(spec.meters.count) * meterBarWidth + CGFloat(spec.meters.count - 1) * meterBarGap
        }
        // The percent style spells out the leading provider — the one at
        // the top of Settings › Usage. Every figure is in the tooltip;
        // printing them all is what made the strip too wide to survive.
        if spec.style == .metersPercent, let leading = spec.meters.first {
            width += percentGap + glyphBox + glyphGap + percentWidth(leading)
        }
        if spec.overflow > 0 { width += cellGap + overflowWidth(spec.overflow) }
        return NSSize(width: (width + edgeInset).rounded(.up), height: barHeight)
    }

    static func percentWidth(_ meter: StatusMeter) -> CGFloat {
        (percentText(meter) as NSString).size(withAttributes: [.font: percentFont]).width.rounded(.up)
    }

    static func percentText(_ meter: StatusMeter) -> String {
        guard let fraction = meter.fraction else { return unknownPercentText }
        return (meter.approximate ? "~" : "") + "\(Int((fraction * 100).rounded()))"
    }

    /// What the percent style prints for a window with no reading. Two
    /// dashes, never "0".
    static let unknownPercentText = "--"

    static func overflowWidth(_ overflow: Int) -> CGFloat {
        ("+\(overflow)" as NSString).size(withAttributes: [.font: overflowFont]).width.rounded(.up)
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
        // Width is the scarce thing on a notched MacBook: an item much
        // past 80 pt is given no slot at all. "1 ask · 1 working · 5 done"
        // is three counts too many for the bar, so the two that matter
        // most go on it and the tooltip carries the rest.
        return parts.isEmpty ? nil : parts.prefix(2).joined(separator: " · ")
    }

    // MARK: Drawing

    /// Template when nothing needs its own colour; otherwise a full-colour
    /// image whose glyph follows `labelColor` for the current appearance
    /// (the drawing handler runs at draw time, so it re-resolves).
    static func draw(_ spec: StatusIconSpec) -> NSImage {
        if spec.style.isMeters { return drawMeters(spec) }
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

    // MARK: Meters

    /// The at-a-glance strip: a state dot, then one column per provider —
    /// its primary window filled from the bottom, amber from 80 % and red
    /// from 95 % — then, in the percent style, the leading provider's
    /// glyph and number, and "+n" for the providers past the cap.
    ///
    /// The strip is a template image while every window is calm and the
    /// dot is quiet, so it takes the menu bar's own colour; a warning or a
    /// live state dot needs its own colours, and then the neutral parts
    /// are drawn in `labelColor`, which the drawing handler re-resolves
    /// for the current appearance.
    static func drawMeters(_ spec: StatusIconSpec) -> NSImage {
        let warning = spec.meterWarning
        let dotColor = dotColor(spec)
        // A configured provider colour is the reason the column exists, so
        // it shows even while everything is calm -- which costs the strip
        // its template colouring, the same trade a warning makes.
        let coloured = spec.meters.contains { $0.accentHex != nil }
        let template = warning == .none && dotColor == nil && !coloured
        let imageSize = Self.size(for: spec)
        let image = NSImage(size: imageSize, flipped: false) { _ in
            let ink: NSColor = template ? .black : .labelColor
            let midY = imageSize.height / 2
            var x = edgeInset
            // The state dot.
            let dot = NSRect(x: x, y: midY - dotDiameter / 2, width: dotDiameter, height: dotDiameter)
            drawDot(spec, rect: dot, color: dotColor, ink: ink)
            x += dotDiameter + dotGap
            if spec.meters.isEmpty {
                // Nothing to meter yet: keep the mark so the item is never blank.
                drawGlyph(.symbol("chart.bar.fill"), in: NSRect(x: x, y: midY - glyphBox / 2, width: glyphBox, height: glyphBox),
                          color: ink.withAlphaComponent(0.45))
                x += glyphBox
            }
            for (index, meter) in spec.meters.enumerated() {
                if index > 0 { x += meterBarGap }
                let bar = NSRect(x: x, y: midY - meterBarHeight / 2, width: meterBarWidth, height: meterBarHeight)
                drawMeter(meter, in: bar, ink: ink, template: template)
                x += meterBarWidth
            }
            if spec.style == .metersPercent, let leading = spec.meters.first {
                x += percentGap
                // Whose number it is, so the figure is attributable.
                drawGlyph(leading.glyph, in: NSRect(x: x, y: midY - glyphBox / 2, width: glyphBox, height: glyphBox),
                          color: ink.withAlphaComponent(0.7))
                x += glyphBox + glyphGap
                let text = percentText(leading) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: percentFont, .foregroundColor: meterColor(leading, ink: ink, template: template),
                ]
                let height = text.size(withAttributes: attributes).height
                text.draw(at: NSPoint(x: x, y: midY - height / 2), withAttributes: attributes)
                x += percentWidth(leading)
            }
            if spec.overflow > 0 {
                x += cellGap
                let text = "+\(spec.overflow)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: overflowFont, .foregroundColor: ink.withAlphaComponent(0.55)]
                let height = text.size(withAttributes: attributes).height
                text.draw(at: NSPoint(x: x, y: midY - height / 2), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = accessibilityLabel(spec)
        return image
    }

    /// The dot's own colour, or nil while it is quiet (then the strip can
    /// stay a template image and follow the menu bar).
    static func dotColor(_ spec: StatusIconSpec) -> NSColor? {
        switch spec.dot {
        case .idle: return nil
        case .working: return spec.tintHex.flatMap(NSColor.init(statusHex:)) ?? .systemTeal
        case .ask: return .systemOrange
        case .error: return .systemRed
        case .done: return .systemGreen
        }
    }

    /// Working breathes between a third and full opacity; an ask pulses the
    /// same way with a halo; done and idle hold still.
    static func drawDot(_ spec: StatusIconSpec, rect: NSRect, color: NSColor?, ink: NSColor) {
        let breath = 0.5 - 0.5 * cos(spec.phase * 2 * .pi)      // 0 → 1 → 0
        switch spec.dot {
        case .idle:
            ink.withAlphaComponent(0.28).setFill()
            NSBezierPath(ovalIn: rect).fill()
        case .working:
            let alpha = 0.35 + 0.65 * breath
            (color ?? ink).withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: rect).fill()
        case .ask:
            let halo = rect.insetBy(dx: -1.6 * breath, dy: -1.6 * breath)
            (color ?? ink).withAlphaComponent(0.30 * (1 - breath)).setFill()
            NSBezierPath(ovalIn: halo).fill()
            (color ?? ink).setFill()
            NSBezierPath(ovalIn: rect).fill()
        case .error:
            // A hard square, like the strip's: on for half the cycle, off
            // for half, no easing. The ask's halo swells; this one snaps,
            // so the two are told apart by rhythm as well as by colour.
            (color ?? ink).withAlphaComponent(spec.phase < 0.5 ? 1.0 : 0.30).setFill()
            NSBezierPath(ovalIn: rect).fill()
        case .done:
            (color ?? ink).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    static func meterColor(_ meter: StatusMeter, ink: NSColor, template: Bool) -> NSColor {
        switch meter.warning {
        case .red: return template ? ink : .systemRed
        case .amber: return template ? ink : .systemOrange
        case .none:
            // The configured accent wins over the neutral fill; a warning
            // wins over the accent, because a near-full window outranks a
            // brand colour.
            if !template, let accent = meter.accentHex.flatMap({ NSColor(statusHex: $0) }) {
                return accent
            }
            return ink.withAlphaComponent(template ? 1 : 0.85)
        }
    }

    /// One provider's column: a faint full-height track with the used
    /// fraction filled from the bottom. A provider that has barely started
    /// still shows a sliver, so an empty column always means "nothing
    /// reported" rather than "nothing used".
    static func drawMeter(_ meter: StatusMeter, in rect: NSRect, ink: NSColor, template: Bool) {
        let radius = rect.width / 2
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        ink.withAlphaComponent(0.22).setFill()
        track.fill()
        guard let fraction = meter.fraction else {
            // No reading: a bar across the middle of the track. An empty
            // column would read as a window that is barely touched, which
            // is exactly the thing nobody knows.
            let bar = NSRect(x: rect.minX, y: rect.midY - unknownMarkHeight / 2,
                             width: rect.width, height: unknownMarkHeight)
            ink.withAlphaComponent(0.75).setFill()
            NSBezierPath(rect: bar).fill()
            return
        }
        guard fraction > 0.001 else { return }
        // The fill is the track's own shape cut off at the level, not a
        // capsule of its own. A capsule cannot be shorter than it is wide,
        // so every figure under 29 % used to draw the same 3.5 pt blob and
        // 1 % was indistinguishable from 36 % on the real menu bar.
        let height = max(minimumFill, rect.height * CGFloat(fraction))
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        meterColor(meter, ink: ink, template: template).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The thinnest visible foot: a provider that has barely started still
    /// shows something, so an empty column always means "nothing reported"
    /// rather than "nothing used".
    static let minimumFill: CGFloat = 1.5

    /// The height of the dash that marks a column with no reading.
    static let unknownMarkHeight: CGFloat = 1.5

    /// An SF Symbol scaled into the box, or one or two characters centred
    /// in it; both in `color`.
    static func drawGlyph(_ glyph: StatusMeter.Glyph, in box: NSRect, color: NSColor) {
        switch glyph {
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: box.height * 0.82, weight: .semibold)
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
                drawGlyph(.text(String(name.prefix(1)).uppercased()), in: box, color: color)
                return
            }
            let scale = min(box.width / max(symbol.size.width, 1), box.height / max(symbol.size.height, 1), 1)
            let drawn = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            let rect = NSRect(x: box.midX - drawn.width / 2, y: box.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
            symbol.isTemplate = true
            symbol.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
        case .text(let text):
            let font = NSFont.systemFont(ofSize: box.height * 0.82, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: attributes)
        }
    }

    /// "Working · Claude 82 %, Codex 41 % · 2 more" — what VoiceOver reads
    /// and what the button's tooltip says.
    public static func accessibilityLabel(_ spec: StatusIconSpec) -> String {
        guard spec.style.isMeters else { return "JR-Bar" }
        var parts: [String] = ["JR-Bar"]
        switch spec.dot {
        case .idle: break
        case .working: parts.append("working")
        case .ask: parts.append("needs you")
        case .error: parts.append("failed")
        case .done: parts.append("finished")
        }
        if !spec.meters.isEmpty { parts.append(spec.meters.map(\.readout).joined(separator: ", ")) }
        if spec.overflow > 0 { parts.append("\(spec.overflow) more") }
        return parts.joined(separator: " · ")
    }

    /// The status item's tooltip: what state the app is in and what the
    /// counts are, then what the dot means, then every provider's figure.
    /// `headline` is the caller's "JR-Bar · Needs input · 1 working · 1
    /// needs you"; the meters and the dot's line come from the spec.
    public static func tooltip(_ spec: StatusIconSpec, headline: String) -> String {
        guard spec.style.isMeters else { return headline }
        var lines = [headline, spec.dot.meaning]
        if !spec.meters.isEmpty {
            var readout = spec.meters.map(\.readout).joined(separator: " · ")
            if spec.overflow > 0 { readout += " · \(spec.overflow) more" }
            lines.append(readout)
        } else if spec.overflow > 0 {
            lines.append("\(spec.overflow) more")
        }
        return lines.joined(separator: "\n")
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
