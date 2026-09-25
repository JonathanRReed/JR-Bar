import AppKit

/// `menu_bar_icon_style`: a dot per live session (the default — this is an
/// agent monitor, so agent state outranks quota at a glance), a column per
/// provider, the same with the leading provider's percent spelled out, or
/// one of the three older looks — the glyph alone, the glyph inside a thin
/// usage ring, the glyph beside a label.
public enum StatusIconStyle: String, CaseIterable, Sendable {
    case agents
    case meters
    case metersPercent = "meters_percent"
    /// The tightest window's remaining percent beside its provider's
    /// mark — the CodexBar glanceable readout.
    case compactPercent = "compact_percent"
    case glyph
    case glyphRing = "glyph_ring"
    case glyphLabel = "glyph_label"
    /// The mark in a usage ring, working sessions as dots below.
    case orbit
    /// Ice's no-icon mode: the item draws nothing — a thin invisible
    /// slot that still clicks, still carries the tooltip and the ‹
    /// boundary while a run is hidden.
    case hidden

    /// Accepts the settings value in either spelling (`ring` / `glyph_ring`);
    /// anything unknown, and an absent value, is the default `agents`.
    public init(setting: String?) {
        switch setting?.lowercased() {
        case "glyph", "icon", "plain", "mark": self = .glyph
        case "glyph_ring", "ring", "usage_ring": self = .glyphRing
        case "glyph_label", "label", "text", "counts": self = .glyphLabel
        case "meters", "meter", "bars", "columns": self = .meters
        case "meters_percent", "meters+percent", "percent", "meters_pct": self = .metersPercent
        case "compact_percent", "compact", "percent_left", "remaining": self = .compactPercent
        case "orbit", "orbital", "fold", "unified", "device": self = .orbit
        case "hidden", "none", "invisible", "off": self = .hidden
        default: self = .agents
        }
    }

    /// True for the two styles that draw one meter per provider.
    public var isMeters: Bool { self == .meters || self == .metersPercent }

    /// The Settings picker's words.
    public var title: String {
        switch self {
        case .agents: return "Session dots"
        case .meters: return "Usage meters"
        case .metersPercent: return "Usage meters with % left"
        case .compactPercent: return "Compact % left"
        case .glyph: return "Glyph only"
        case .glyphRing: return "Glyph with usage ring"
        case .glyphLabel: return "Glyph with label"
        case .orbit: return "Orbit"
        case .hidden: return "No icon"
        }
    }

    public var subtitle: String {
        switch self {
        case .agents: return "One dot per live session, coloured by what it is doing; the mark alone when nothing runs."
        case .meters: return "A column per provider checked under Settings › Usage, plus a state dot."
        case .metersPercent: return "The same columns, with the first provider's remaining percent — or its reset countdown when that is the more urgent number."
        case .compactPercent: return "The tightest window's remaining percent beside its provider's mark, tinted by pace; shows the reset countdown when it is nearly spent or nearly due."
        case .glyph: return "The JR-Bar mark, tinted by what the agents are doing."
        case .glyphRing: return "The mark inside a ring of your primary window."
        case .glyphLabel: return "The mark beside “1 ask · 2 working”."
        case .orbit: return "The mark in a usage ring, working sessions as dots below."
        case .hidden: return "No icon at all — a thin invisible slot. A click, the hotkey, or the ‹ mark while items are hidden still opens the panel."
        }
    }
}

/// One provider's column in the menu bar: how full its primary usage
/// window is, plus the name and glyph the tooltip and the percent style
/// need.
public struct StatusMeter: Hashable, Sendable {
    /// The provider's real mark (a `ProviderLogo` id), an SF Symbol, or
    /// one or two characters.
    public enum Glyph: Hashable, Sendable {
        case symbol(String)
        case text(String)
        case logo(String)
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
    /// Epoch seconds the window resets. The percent-bearing styles swap
    /// the figure for a countdown when the reset is imminent — and they
    /// cannot show one without this stamp.
    public var resetsAt: Double?
    /// What the window is heading for, collapsed for the tint decision:
    /// `comfortable` (reset comes first), `runsOut` (pace hits 100 %
    /// first), `exhausted` (nothing left), `guarded` (the daemon refused
    /// a pace), `unknown` (no verdict worth a colour).
    public enum PaceVerdict: String, Hashable, Sendable {
        case comfortable, runsOut, exhausted, guarded, unknown
    }
    public var paceVerdict: PaceVerdict
    /// The figure is old: the provider's last refresh did not land, so
    /// this is how full the window was then, not how full it is now. The
    /// column draws it faint and never warns with it.
    public var stale: Bool

    public init(id: String, name: String, glyph: Glyph, fraction: Double?, approximate: Bool = false,
                accentHex: String? = nil, resetsAt: Double? = nil, paceVerdict: PaceVerdict = .unknown,
                stale: Bool = false) {
        self.id = id
        self.name = name
        self.glyph = glyph
        self.fraction = fraction.map { max(0, min(1, $0)) }
        self.approximate = approximate
        self.accentHex = accentHex
        self.resetsAt = resetsAt
        self.paceVerdict = paceVerdict
        self.stale = stale
    }

    /// The window exists and nobody said how full it is.
    public var isUnknown: Bool { fraction == nil }

    public var warning: StatusIconSpec.RingWarning {
        guard let fraction, !stale else { return .none }
        if fraction >= 0.95 { return .red }
        if fraction >= 0.80 { return .amber }
        return .none
    }

    /// "Claude 82%" for the tooltip, "Claude no reading" for a window the
    /// provider reports without a number, and "(stale)" after either when
    /// the reading is old.
    public var readout: String {
        let staleNote = stale ? " (stale)" : ""
        guard let fraction else { return "\(name) no reading\(staleNote)" }
        let percent = Int((fraction * 100).rounded())
        return "\(name) \(approximate ? "~" : "")\(percent)%\(staleNote)"
    }
}

/// One session's dot in the `agents` style, in the panel's order (asks,
/// waiting, failed, working, done). Kept small — the spec is `Hashable`
/// and compared on every redraw.
public struct SessionDot: Hashable, Sendable {
    public var id: String
    public var state: StatusDotState
    /// The provider's configured accent (`#RRGGBB`), for a working dot;
    /// the other states carry their own colour.
    public var accentHex: String?
    /// A snoozed session's ask draws dim and holds still: the family
    /// mailbox is muted, so the strip must not pulse amber about it.
    public var dimmed: Bool

    public init(id: String, state: StatusDotState, accentHex: String? = nil, dimmed: Bool = false) {
        self.id = id
        self.state = state
        self.accentHex = accentHex
        self.dimmed = dimmed
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

    /// In the `agents` strip only asks and failures move: a working dot
    /// holds still so a busy menu bar stays calm.
    public var breathes: Bool { self == .ask || self == .error }

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
    /// The `agents` style: one dot per live session, in the panel's order,
    /// capped by `StatusIconRenderer.maxSessionDots`. `orbit` counts the
    /// working ones for the dots under its ring.
    public var sessions: [SessionDot]
    /// 0…1 breathing phase for the moving dots; steady dots ignore it.
    public var phase: Double

    public init(style: StatusIconStyle, ringFraction: Double? = nil, tintHex: String? = nil,
                meters: [StatusMeter] = [], overflow: Int = 0, dot: StatusDotState = .idle,
                sessions: [SessionDot] = [], phase: Double = 0) {
        self.style = style
        self.ringFraction = ringFraction.map { max(0, min(1, $0)) }
        self.tintHex = tintHex
        self.meters = meters
        self.overflow = max(0, overflow)
        self.dot = dot
        self.sessions = sessions
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
        let animating = (style.isMeters && dot.animates)
            || (style == .agents && sessions.contains { $0.state.breathes && !$0.dimmed })
        key.phase = animating ? (phase * 4).rounded() / 4 : 0
        return key
    }

    public var ringWarning: RingWarning {
        guard style == .glyphRing || style == .orbit, let ringFraction else { return .none }
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
/// styles, a 22 pt-tall strip as wide as it needs for the meters and the
/// session dots.
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
    /// Sessions past this many become five dots and "+n".
    public static let maxSessionDots = 6
    static let edgeInset: CGFloat = 2
    static let dotDiameter: CGFloat = 5
    static let dotGap: CGFloat = 6
    static let glyphBox: CGFloat = 11
    /// The `agents` strip: the mark in a 14 pt box, then 6 pt session dots
    /// 3 pt apart.
    static let agentsMark: CGFloat = 14
    static let agentsGap: CGFloat = 4
    static let sessionDot: CGFloat = 6
    static let sessionDotGap: CGFloat = 3
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

    /// The orbit roundel's footprint: a little wider than square so the
    /// ring, its number and the dots all sit inside.
    public static let orbitSize = NSSize(width: 26, height: 22)

    /// The hidden style's whole footprint: wide enough to click, thin
    /// enough that "no icon" means what it says. Zero would unregister
    /// the slot entirely and take the boundary's seat with it.
    public static let hiddenSlotWidth: CGFloat = 8

    /// How wide the image for this spec is. The glyph styles are square;
    /// a meter or session strip grows with what it shows, so the status
    /// item has to ask before it sets its own length.
    public static func size(for spec: StatusIconSpec) -> NSSize {
        if spec.style == .hidden { return NSSize(width: hiddenSlotWidth, height: barHeight) }
        if spec.style == .orbit { return orbitSize }
        if spec.style == .agents {
            // No sessions: the mark alone, square like the glyph styles.
            guard !spec.sessions.isEmpty else { return size }
            let over = spec.sessions.count > maxSessionDots
            let shown = over ? maxSessionDots - 1 : spec.sessions.count
            var width = edgeInset + agentsMark + agentsGap
                + CGFloat(shown) * sessionDot + CGFloat(max(0, shown - 1)) * sessionDotGap
            if over { width += agentsGap + overflowWidth(spec.sessions.count - shown) }
            return NSSize(width: (width + edgeInset).rounded(.up), height: barHeight)
        }
        if spec.style == .compactPercent {
            let width = edgeInset + glyphBox + glyphGap + compactWidth(spec)
            return NSSize(width: (width + edgeInset).rounded(.up), height: barHeight)
        }
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

    static func percentWidth(_ meter: StatusMeter, now: Date = Date()) -> CGFloat {
        (percentText(meter, now: now) as NSString).size(withAttributes: [.font: percentFont]).width.rounded(.up)
    }

    /// What the percent styles print: the window's *remaining* percent —
    /// the CodexBar semantics a menu-bar figure should glance at — or the
    /// reset countdown when the countdown rule fires.
    static func percentText(_ meter: StatusMeter, now: Date = Date()) -> String {
        if let countdown = countdownText(meter, now: now) { return countdown }
        guard let fraction = meter.fraction else { return unknownPercentText }
        return (meter.approximate ? "~" : "") + "\(Int(((1 - fraction) * 100).rounded()))"
    }

    /// "12m" / "3h" / "2d" to the window's reset when the reset deserves
    /// the slot: under a tenth of the window left, or the reset inside
    /// fifteen minutes. Nil while neither holds, when the reset already
    /// passed (a stale stamp — the next reading refreshes it), or when no
    /// reset time was reported.
    static func countdownText(_ meter: StatusMeter, now: Date = Date()) -> String? {
        guard let resetsAt = meter.resetsAt else { return nil }
        let delta = resetsAt - now.timeIntervalSince1970
        guard delta >= 0 else { return nil }
        let nearlySpent = meter.fraction.map { $0 > 0.90 } ?? false
        guard nearlySpent || delta < 900 else { return nil }
        if delta < 3600 { return "\(Int(delta / 60))m" }
        if delta < 86400 { return "\(Int(delta / 3600))h" }
        return "\(Int(delta / 86400))d"
    }

    /// What the percent style prints for a window with no reading. Two
    /// dashes, never "0".
    static let unknownPercentText = "--"

    /// The meter whose window is nearest to spent — the compact strip's
    /// subject. Unmeasured windows sort last, so a provider that never
    /// reported a number cannot win the readout over one that did, and a
    /// stale figure sorts below every fresh one.
    static func tightestMeter(_ spec: StatusIconSpec) -> StatusMeter? {
        spec.meters.max(by: { tightness($0) < tightness($1) })
    }

    /// Fresh readings 0…1, stale ones below them, unread ones last.
    static func tightness(_ meter: StatusMeter) -> Double {
        guard let fraction = meter.fraction else { return -3 }
        return meter.stale ? fraction - 2 : fraction
    }

    /// The compact strip's figure: the reset countdown when the rule
    /// fires, else the remaining percent with its `%`, else two dashes.
    static func compactText(_ meter: StatusMeter?, now: Date = Date()) -> String {
        guard let meter else { return unknownPercentText }
        if let countdown = countdownText(meter, now: now) { return countdown }
        guard let fraction = meter.fraction else { return unknownPercentText }
        return (meter.approximate ? "~" : "") + "\(Int(((1 - fraction) * 100).rounded()))%"
    }

    static func compactWidth(_ spec: StatusIconSpec, now: Date = Date()) -> CGFloat {
        (compactText(tightestMeter(spec), now: now) as NSString)
            .size(withAttributes: [.font: percentFont]).width.rounded(.up)
    }

    /// The compact strip's tint: the pace verdict's colour when the
    /// window is heading somewhere bad — exhausted red, running out
    /// amber — then the meter's own warning, then the provider accent;
    /// nil leaves a template image to follow the menu bar's colour.
    static func compactColor(_ meter: StatusMeter?) -> NSColor? {
        // A stale figure says nothing about where the window is heading
        // now, so it takes no colour at all.
        guard let meter, !meter.stale else { return nil }
        switch meter.paceVerdict {
        case .exhausted: return .systemRed
        case .runsOut: return .systemOrange
        case .comfortable, .guarded, .unknown: break
        }
        switch meter.warning {
        case .red: return .systemRed
        case .amber: return .systemOrange
        case .none: return meter.accentHex.flatMap(NSColor.init(hex:))
        }
    }

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
        if spec.style == .hidden {
            // A genuinely empty image — the slot stays clickable and
            // labelled, nothing is drawn into it.
            let image = NSImage(size: NSSize(width: hiddenSlotWidth, height: barHeight),
                                flipped: false) { _ in true }
            image.isTemplate = true
            image.accessibilityDescription = accessibilityLabel(spec)
            return image
        }
        if spec.style.isMeters { return drawMeters(spec) }
        if spec.style == .compactPercent { return drawCompact(spec) }
        if spec.style == .agents { return drawAgents(spec) }
        if spec.style == .orbit { return drawOrbit(spec) }
        let warning = spec.ringWarning
        let tint = spec.tintHex.flatMap(NSColor.init(hex:))
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
        let coloured = spec.meters.contains { $0.accentHex != nil && !$0.stale }
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
        case .working: return spec.tintHex.flatMap(NSColor.init(hex:)) ?? .systemTeal
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

    // MARK: Session dots

    /// The `agents` strip: the JR-Bar mark at the left, then one dot per
    /// live session in the panel's order — ask amber, error red, done
    /// green, working in the provider's accent, idle hollow — and "+n"
    /// past the cap. With no sessions it is the mark alone, tinted the way
    /// the glyph styles tint it.
    ///
    /// The image stays a template while every session is quiet (or there
    /// are none) so it follows the menu bar's own colour; any coloured dot
    /// — or a tint — makes it full colour, and the neutral parts are drawn
    /// in `labelColor`, which the drawing handler re-resolves for the
    /// current appearance.
    static func drawAgents(_ spec: StatusIconSpec) -> NSImage {
        let tint = spec.tintHex.flatMap(NSColor.init(hex:))
        let coloured = spec.sessions.contains { $0.state != .idle }
        let template = !coloured && tint == nil
        let imageSize = Self.size(for: spec)
        let image = NSImage(size: imageSize, flipped: false) { _ in
            let ink: NSColor = template ? .black : .labelColor
            let midY = imageSize.height / 2
            var x = edgeInset
            let markColor = tint ?? ink
            drawMark(cap: markColor.withAlphaComponent(0.38), bar: markColor,
                     center: NSPoint(x: x + agentsMark / 2, y: midY), scale: agentsMark / 18)
            x += agentsMark
            if !spec.sessions.isEmpty {
                x += agentsGap
                let over = spec.sessions.count > maxSessionDots
                let shown = over ? maxSessionDots - 1 : spec.sessions.count
                for session in spec.sessions.prefix(shown) {
                    let rect = NSRect(x: x, y: midY - sessionDot / 2, width: sessionDot, height: sessionDot)
                    drawSessionDot(session, phase: spec.phase, rect: rect, ink: ink)
                    x += sessionDot + sessionDotGap
                }
                if over {
                    x += agentsGap - sessionDotGap
                    let text = "+\(spec.sessions.count - shown)" as NSString
                    let attributes: [NSAttributedString.Key: Any] = [.font: overflowFont, .foregroundColor: ink.withAlphaComponent(0.55)]
                    let height = text.size(withAttributes: attributes).height
                    text.draw(at: NSPoint(x: x, y: midY - height / 2), withAttributes: attributes)
                }
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = accessibilityLabel(spec)
        return image
    }

    /// One session's dot, drawn by the same routine as the meters' state
    /// dot: asks and failures breathe with the strip's phase, everything
    /// else holds still (a working dot is steady — the accent, not the
    /// motion, is what says it is running).
    static func drawSessionDot(_ session: SessionDot, phase: Double, rect: NSRect, ink: NSColor) {
        let color: NSColor?
        switch session.state {
        case .idle: color = nil
        case .working: color = session.accentHex.flatMap(NSColor.init(hex:)) ?? .systemTeal
        case .ask: color = .systemOrange
        case .error: color = .systemRed
        case .done: color = .systemGreen
        }
        if session.dimmed {
            // Snoozed: the state colour at a murmur, no halo, no clock.
            (color ?? ink).withAlphaComponent(0.38).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return
        }
        let phase = session.state.breathes ? phase : 0.5
        drawDot(StatusIconSpec(style: .agents, dot: session.state, phase: phase), rect: rect, color: color, ink: ink)
    }

    static func meterColor(_ meter: StatusMeter, ink: NSColor, template: Bool) -> NSColor {
        // A stale figure is drawn faint in the strip's own ink: not the
        // accent, and not a warning colour, since it is not what the
        // window holds now.
        if meter.stale { return ink.withAlphaComponent(staleAlpha) }
        switch meter.warning {
        case .red: return template ? ink : .systemRed
        case .amber: return template ? ink : .systemOrange
        case .none:
            // The configured accent wins over the neutral fill; a warning
            // wins over the accent, because a near-full window outranks a
            // brand colour.
            if !template, let accent = meter.accentHex.flatMap({ NSColor(hex: $0) }) {
                return accent
            }
            return ink.withAlphaComponent(template ? 1 : 0.85)
        }
    }

    /// One provider's column: a faint full-height track with the used
    /// fraction filled from the bottom. A provider that has barely started
    /// still shows a sliver, so an empty column always means "nothing
    /// reported" rather than "nothing used". A stale figure fills the
    /// same continuous column, only faint.
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

    // MARK: Compact percent

    /// The CodexBar glanceable: the tightest measured window's provider
    /// glyph beside its remaining percent — or its reset countdown when
    /// the window is nearly spent or nearly due — tinted by the pace
    /// verdict. No state dot and no columns: this style is the readout
    /// and nothing else, which is what keeps it compact.
    static func drawCompact(_ spec: StatusIconSpec) -> NSImage {
        let meter = tightestMeter(spec)
        let tint = spec.tintHex.flatMap(NSColor.init(hex:))
        let colour = compactColor(meter) ?? tint
        let template = colour == nil
        let imageSize = Self.size(for: spec)
        let image = NSImage(size: imageSize, flipped: false) { _ in
            let ink: NSColor = template ? .black : .labelColor
            let midY = imageSize.height / 2
            var x = edgeInset
            if let meter {
                drawGlyph(meter.glyph, in: NSRect(x: x, y: midY - glyphBox / 2, width: glyphBox, height: glyphBox),
                          color: colour ?? ink.withAlphaComponent(0.8))
            } else {
                // Nothing to meter yet: keep a mark so the item is never a gap.
                drawGlyph(.symbol("chart.bar.fill"), in: NSRect(x: x, y: midY - glyphBox / 2, width: glyphBox, height: glyphBox),
                          color: ink.withAlphaComponent(0.45))
            }
            x += glyphBox + glyphGap
            let text = compactText(meter) as NSString
            // A stale figure keeps the readout's hue, the agents' tint
            // included, and loses its strength. The glyph keeps its
            // colour, as the percent strip's does: it says whose figure
            // it is, which is still true.
            let base = colour ?? ink
            let textColor = meter?.stale == true ? base.withAlphaComponent(staleAlpha) : base
            let attributes: [NSAttributedString.Key: Any] = [
                .font: percentFont, .foregroundColor: textColor,
            ]
            let height = text.size(withAttributes: attributes).height
            text.draw(at: NSPoint(x: x, y: midY - height / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = accessibilityLabel(spec)
        return image
    }

    /// The thinnest visible foot: a provider that has barely started still
    /// shows something, so an empty column always means "nothing reported"
    /// rather than "nothing used".
    static let minimumFill: CGFloat = 1.5

    /// The height of the dash that marks a column with no reading.
    static let unknownMarkHeight: CGFloat = 1.5

    /// How strongly a stale figure is drawn: plainly above the 0.22
    /// track, plainly below a fresh fill.
    static let staleAlpha: CGFloat = 0.45

    /// The provider's mark, an SF Symbol scaled into the box, or one or
    /// two characters centred in it; all in `color`. A mark is its cached
    /// path filled straight into the context: no symbol lookup, no image,
    /// no second pass to tint it.
    static func drawGlyph(_ glyph: StatusMeter.Glyph, in box: NSRect, color: NSColor) {
        switch glyph {
        case .logo(let id):
            guard let logo = ProviderLogo.named(id), let context = NSGraphicsContext.current?.cgContext else {
                drawGlyph(.text(String(id.prefix(1)).uppercased()), in: box, color: color)
                return
            }
            // The same share of the box the symbol's point size took.
            let side = box.height * 0.82
            let rect = NSRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
            color.setFill()
            color.setStroke()
            logo.fill(in: rect, context: context, weight: ProviderLogo.hairline(for: id, side: side))
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

    /// "Working · Claude 82%, Codex 41% · 2 more" — what VoiceOver reads
    /// and what the button's tooltip says.
    public static func accessibilityLabel(_ spec: StatusIconSpec) -> String {
        if spec.style == .agents {
            var parts: [String] = ["JR-Bar"]
            let words: [(StatusDotState, String, String)] = [
                (.ask, "needs you", "need you"),
                (.error, "failed", "failed"),
                (.working, "working", "working"),
                (.done, "finished", "finished"),
                (.idle, "idle", "idle"),
            ]
            for (state, one, many) in words {
                let count = spec.sessions.filter { $0.state == state && !$0.dimmed }.count
                guard count > 0 else { continue }
                parts.append(count == 1 ? "1 \(one)" : "\(count) \(many)")
            }
            // A dimmed dot is a snoozed session: still listed, but not
            // read as "needs you" while its mailbox is muted.
            let snoozed = spec.sessions.filter(\.dimmed).count
            if snoozed > 0 { parts.append(snoozed == 1 ? "1 snoozed" : "\(snoozed) snoozed") }
            return parts.joined(separator: " · ")
        }
        if spec.style == .orbit {
            return (["JR-Bar"] + orbitWords(spec)).joined(separator: " · ")
        }
        if spec.style == .compactPercent {
            guard let meter = tightestMeter(spec) else { return "JR-Bar" }
            if let countdown = countdownText(meter) {
                return "JR-Bar · \(meter.name) resets in \(countdown)"
            }
            let staleNote = meter.stale ? " (stale)" : ""
            guard let fraction = meter.fraction else { return "JR-Bar · \(meter.name) no reading\(staleNote)" }
            let left = Int(((1 - fraction) * 100).rounded())
            return "JR-Bar · \(meter.name) \(left)% left\(staleNote)"
        }
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
    /// needs you"; the meters and the dot's line come from the spec. For
    /// the `agents` style the caller passes `sessionLines` — one per live
    /// session ("docs-sweep · waiting on you 2h 31m · Gemini"), capped at
    /// the strip's own six.
    public static func tooltip(_ spec: StatusIconSpec, headline: String, sessionLines: [String] = []) -> String {
        if spec.style == .agents {
            return ([headline] + sessionLines.prefix(maxSessionDots)).joined(separator: "\n")
        }
        if spec.style == .orbit {
            return ([headline] + orbitWords(spec)).joined(separator: "\n")
        }
        if spec.style == .compactPercent {
            var lines = [headline]
            if !spec.meters.isEmpty {
                var readout = spec.meters.map(\.readout).joined(separator: " · ")
                if spec.overflow > 0 { readout += " · \(spec.overflow) more" }
                lines.append(readout)
            }
            return lines.joined(separator: "\n")
        }
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

    /// The words `orbit`'s picture carries: the window's fill and the
    /// working count its four dots stand for — "42% used · 2 working".
    static func orbitWords(_ spec: StatusIconSpec) -> [String] {
        var words: [String] = []
        if let fraction = spec.ringFraction {
            words.append("\(Int((fraction * 100).rounded()))% used")
        }
        let working = spec.sessions.filter { $0.state == .working }.count
        if working > 0 {
            words.append(working == 1 ? "1 working" : "\(working) working")
        }
        return words
    }

    /// A rounded bar tucked under a small notch cap, as in the original glyph.
    static func drawGlyph(cap capColor: NSColor, bar barColor: NSColor, scale: CGFloat) {
        drawMark(cap: capColor, bar: barColor, center: NSPoint(x: 9, y: 9), scale: scale)
    }

    /// The same mark centred on `center` at `scale` — the `agents` strip
    /// draws it in a 14 pt box beside the session dots.
    static func drawMark(cap capColor: NSColor, bar barColor: NSColor, center: NSPoint, scale: CGFloat) {
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
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

    /// The orbit roundel — the mark inside the primary usage window's
    /// ring, the working sessions as dots in the ring's bottom gap. The
    /// mark and the ring take the glyph styles' colours — the aggregate
    /// tint, amber from 80 % and red from 95 % — so a calm one is a
    /// template image like the glyph alone.
    static func drawOrbit(_ spec: StatusIconSpec) -> NSImage {
        let warning = spec.ringWarning
        let tint = spec.tintHex.flatMap(NSColor.init(hex:))
        let template = warning == .none && tint == nil
        let image = NSImage(size: orbitSize, flipped: false) { _ in
            let center = NSPoint(x: orbitSize.width / 2, y: orbitSize.height / 2)
            let radius: CGFloat = 9.3
            // The ring's gap at 6 o'clock is where the working dots sit.
            let gapHalf: CGFloat = 34
            let arcStart: CGFloat = 270 + gapHalf   // bottom-left edge of the gap
            let arcSweep: CGFloat = 360 - 2 * gapHalf

            let ink: NSColor = template ? .black : .labelColor
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius,
                            startAngle: arcStart, endAngle: arcStart + arcSweep, clockwise: false)
            track.lineWidth = 1.6
            track.lineCapStyle = .round
            ink.withAlphaComponent(0.18).setStroke()
            track.stroke()
            if let fraction = spec.ringFraction, fraction > 0 {
                let ringColor: NSColor
                switch warning {
                case .red: ringColor = .systemRed
                case .amber: ringColor = .systemOrange
                case .none: ringColor = ink
                }
                let fillPath = NSBezierPath()
                fillPath.appendArc(withCenter: center, radius: radius,
                                   startAngle: arcStart,
                                   endAngle: arcStart + arcSweep * fraction, clockwise: false)
                fillPath.lineWidth = 1.6
                fillPath.lineCapStyle = .round
                ringColor.setStroke()
                fillPath.stroke()
            }

            // The mark centred in the ring, tinted exactly as the glyph
            // styles draw it. Its design box centres at (9, 9) but the
            // mark's visual middle sits a touch above that, so the point
            // it is drawn around is dropped to match.
            let markColor = tint ?? ink
            drawMark(cap: markColor.withAlphaComponent(0.38), bar: markColor,
                     center: NSPoint(x: center.x, y: center.y - 1.0), scale: 0.62)

            // The working sessions, four dots in the ring's bottom gap.
            let working = min(4, spec.sessions.filter { $0.state == .working }.count)
            let dotD: CGFloat = 1.7
            let dotGap: CGFloat = 2.1
            let dotsWidth = 4 * dotD + 3 * dotGap
            for i in 0..<4 {
                let rect = NSRect(x: center.x - dotsWidth / 2 + CGFloat(i) * (dotD + dotGap),
                                  y: center.y - radius + 1.4,
                                  width: dotD, height: dotD)
                (i < working ? ink : ink.withAlphaComponent(0.22)).setFill()
                NSBezierPath(ovalIn: rect).fill()
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = accessibilityLabel(spec)
        return image
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
    /// `#RRGGBB` (the `#` optional, surrounding whitespace ignored) as an
    /// sRGB colour; nil for anything else. The one parser the app, the
    /// settings pages and the status icon share.
    public convenience init?(hex: String) {
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
