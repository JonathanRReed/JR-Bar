import AppKit
import JRBarCore
import JRBarUI
import QuartzCore

/// The menu-bar item: the `menu_bar_icon_style` look — a dot per live
/// session (the default), a meter per provider, or the glyph alone, in a
/// usage ring, or beside a label. Left click opens the panel; right click
/// (or Option-click) shows a small utility menu. Stage-2 escalation
/// pulses the icon amber.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let headerItem = NSMenuItem()
    private let detailItem = NSMenuItem()
    private let feedItem = NSMenuItem()
    private let coreItem = NSMenuItem()
    private let showBarItem: NSMenuItem
    private let renderer = StatusIconRenderer.shared
    private var currentSpec: StatusIconSpec?
    private var currentLabel: String?
    private var aggregateTint: NSColor?
    private(set) var isPulsing = false
    var onToggleScreenBar: (@MainActor (Bool) -> Void)?
    var onTogglePanel: (@MainActor () -> Void)?
    var onOpenSettings: (@MainActor () -> Void)?
    var onOpenHistory: (@MainActor () -> Void)?
    var onOpenUsageCenter: (@MainActor () -> Void)?
    var onOpenEffects: (@MainActor () -> Void)?
    var onOpenControlCenter: (@MainActor () -> Void)?
    var isScreenBarShown = true { didSet { showBarItem.state = isScreenBarShown ? .on : .off } }
    /// The style and ring the next `update` draws with.
    var iconStyle: StatusIconStyle = .agents {
        didSet {
            guard iconStyle != oldValue else { return }
            syncBreathing()
            applyPulseAnimation()
            redraw()
        }
    }
    var ringFraction: Double? { didSet { if ringFraction != oldValue { redraw() } } }
    var labelText: String? { didSet { if labelText != oldValue { redraw() } } }
    /// One meter per provider shown in the panel, in the panel's order,
    /// already capped by the renderer's `maxMeters` with the rest in `overflow`.
    var meters: [StatusMeter] = [] { didSet { if meters != oldValue { redraw() } } }
    var meterOverflow = 0 { didSet { if meterOverflow != oldValue { redraw() } } }
    /// The state dot; `.working` and `.ask` run the 2 Hz breathing timer,
    /// the other two are still pictures.
    var dotState: StatusDotState = .idle {
        didSet {
            guard dotState != oldValue else { return }
            syncBreathing()
            redraw()
        }
    }
    /// The `agents` style: one dot per live session, in the panel's order.
    /// An ask or a failure in the list runs the same breathing timer the
    /// meters' dot does.
    var sessionDots: [SessionDot] = [] {
        didSet {
            guard sessionDots != oldValue else { return }
            syncBreathing()
            applyPulseAnimation()
            redraw()
        }
    }
    /// One tooltip line per session for the `agents` style
    /// ("docs-sweep · waiting on you 2h 31m · Gemini"), same order.
    var sessionLines: [String] = [] { didSet { if sessionLines != oldValue { redraw() } } }

    private static let pulseKey = "jrbar.escalationPulse"
    /// The breathing clock: two frames a second, only while the dot moves.
    private static let breathingInterval: TimeInterval = 0.5
    private var breathing: Timer?
    private var phase: Double = 0
    /// The width the status item was last given, so a same-width redraw
    /// does not churn the menu bar's layout.
    private var currentWidth: CGFloat = 0

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Where the item sits is the person's to choose (Command-drag);
        // macOS gives no API to ask for a slot. A stable autosave name is
        // the one thing the app can do: it is the key macOS remembers that
        // choice under, so a rebuild does not send the item back to the
        // middle of a busy menu bar.
        statusItem.autosaveName = "com.jonathanreed.jrbar.status-item"
        showBarItem = NSMenuItem(title: "Show Screen Bar", action: #selector(toggleScreenBar(_:)), keyEquivalent: "")
        super.init()

        if let button = statusItem.button {
            button.image = renderer.image(for: StatusIconSpec(style: .agents))
            button.imagePosition = .imageOnly
            button.toolTip = "JR-Bar"
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        headerItem.isEnabled = false
        detailItem.isEnabled = false
        feedItem.isEnabled = false
        coreItem.isEnabled = false
        showBarItem.target = self
        showBarItem.state = .on

        let open = NSMenuItem(title: "Open Panel", action: #selector(openPanel(_:)), keyEquivalent: "")
        open.target = self
        let history = NSMenuItem(title: "History…", action: #selector(openHistory(_:)), keyEquivalent: "y")
        history.target = self
        let usage = NSMenuItem(title: "Usage Center…", action: #selector(openUsageCenter(_:)), keyEquivalent: "u")
        usage.target = self
        let effects = NSMenuItem(title: "Effect Studio…", action: #selector(openEffects(_:)), keyEquivalent: "")
        effects.target = self
        let controlCenter = NSMenuItem(title: "Control Center…", action: #selector(openControlCenter(_:)), keyEquivalent: "k")
        controlCenter.target = self

        menu.addItem(headerItem)
        menu.addItem(detailItem)
        menu.addItem(coreItem)
        menu.addItem(feedItem)
        menu.addItem(.separator())
        menu.addItem(open)
        menu.addItem(history)
        menu.addItem(usage)
        menu.addItem(effects)
        menu.addItem(controlCenter)
        menu.addItem(showBarItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit JR-Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.autoenablesItems = false
        menu.delegate = self
        update(state: .idle, detail: "Starting")
        setFeed(description: "resolving")
        setCore(description: "connecting")
    }

    /// The button's frame in screen coordinates, for anchoring the panel.
    var anchorRect: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func setPanelOpen(_ open: Bool) {
        statusItem.button?.highlight(open)
    }

    func update(state: AgentAggregateState, detail: String) {
        headerItem.attributedTitle = NSAttributedString(string: "JR-Bar  ·  \(state.label)", attributes: [
            .font: NSFont.menuBarFont(ofSize: 0).withWeight(.semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        detailItem.attributedTitle = NSAttributedString(string: detail, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        aggregateTint = state.tint
        stateSummary = "JR-Bar · \(state.label)" + (detail.isEmpty ? "" : " · \(detail)")
        statusItem.button?.toolTip = stateSummary
        redraw()
    }

    /// "JR-Bar · Working · 2 working · 1 needs you", the tooltip's first half.
    private var stateSummary = "JR-Bar"

    /// Redraws only when the spec or the label actually changed; the
    /// renderer hands back the cached image for a repeated spec.
    private func redraw() {
        guard let button = statusItem.button else { return }
        let tint: NSColor? = isPulsing ? .systemOrange : aggregateTint
        let spec = StatusIconSpec(style: iconStyle,
                                  ringFraction: iconStyle == .glyphRing ? ringFraction : nil,
                                  tintHex: tint?.statusHex,
                                  meters: iconStyle.isMeters ? meters : [],
                                  overflow: iconStyle.isMeters ? meterOverflow : 0,
                                  dot: iconStyle.isMeters ? (isPulsing ? .ask : dotState) : .idle,
                                  sessions: iconStyle == .agents ? sessionDots : [],
                                  phase: phase)
        // The meter strip and the session strip size themselves -- agents
        // included while empty, or the last session ending never shrank the
        // item back (size(for:) already answers the square for that spec).
        let strip = iconStyle.isMeters || iconStyle == .agents
        let label = iconStyle == .glyphLabel ? labelText : nil
        if spec != currentSpec {
            currentSpec = spec
            let image = renderer.image(for: spec)
            if button.image !== image { button.image = image }
            // A template image takes the tint from the button; a coloured
            // one carries its own. A strip is never tinted whole:
            // its dots and meters carry the only colour that means anything.
            button.contentTintColor = image.isTemplate && !strip ? tint : nil
            if strip {
                let width = StatusIconRenderer.size(for: spec).width
                if width != currentWidth {
                    currentWidth = width
                    statusItem.length = width
                    logFrame(width: width)
                }
            } else {
                currentWidth = 0
            }
        }
        if iconStyle.isMeters || iconStyle == .agents {
            button.toolTip = StatusIconRenderer.tooltip(spec, headline: stateSummary,
                                                        sessionLines: iconStyle == .agents ? sessionLines : [])
            button.setAccessibilityLabel(StatusIconRenderer.accessibilityLabel(spec))
        }
        if label != currentLabel || (strip && button.imagePosition != .imageOnly) {
            currentLabel = label
            if let label {
                button.attributedTitle = NSAttributedString(string: label, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                ])
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
                statusItem.length = NSStatusItem.variableLength
            } else {
                button.title = ""
                button.imagePosition = .imageOnly
                // A strip sets its own width above; the square styles are
                // square.
                if !strip { statusItem.length = NSStatusItem.squareLength }
            }
        }
    }

    /// Every width change prints where the item is, the way the panel
    /// prints its frame: `screencapture -R` can then crop exactly the
    /// status item, which is the only way to photograph it on a menu bar
    /// that collapses its extras.
    private func logFrame(width: CGFloat) {
        guard let rect = anchorRect, let screen = NSScreen.screens.first else { return }
        let top = screen.frame.maxY - rect.maxY
        print(String(format: "status item: %@ %d meters (+%d) %d sessions dot=%@ x=%.0f y=%.0f w=%.0f h=%.0f top=%.0f (screencapture -R%.0f,%.0f,%.0f,%.0f)",
                     iconStyle.rawValue, meters.count, meterOverflow, sessionDots.count, dotState.rawValue,
                     rect.minX, rect.minY, width, rect.height, top, rect.minX, top, width, rect.height))
    }

    /// The 2 Hz clock behind the breathing dots: it runs only while a dot
    /// actually moves (a working or open-ask dot in the meter styles, an
    /// ask or failure in the session strip), so a quiet menu bar costs
    /// nothing. Reduce Motion holds the dot at its brightest instead of
    /// breathing.
    private func syncBreathing() {
        let moving = (iconStyle.isMeters && dotState.animates)
            || (iconStyle == .agents && sessionDots.contains { $0.state.breathes })
        let wanted = moving && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if wanted, breathing == nil {
            phase = 0.5
            let timer = Timer(timeInterval: Self.breathingInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.phase = (self.phase + 0.25).truncatingRemainder(dividingBy: 1)
                    self.redraw()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            breathing = timer
        } else if !wanted, breathing != nil {
            breathing?.invalidate()
            breathing = nil
            phase = 0.5
        }
    }

    /// Stage-2 escalation: the icon breathes amber until the ask resolves.
    /// With Reduce Motion the icon holds amber without animating.
    func setEscalationPulse(_ on: Bool) {
        guard on != isPulsing else { return }
        isPulsing = on
        applyPulseAnimation()
        redraw()
    }

    /// The whole-item fade is for the glyph styles, which have nowhere else
    /// to put the escalation. In the strips a dot is already pulsing amber,
    /// and fading the strip on top of that only makes it unreadable — so
    /// the layer animation is left off there.
    private func applyPulseAnimation() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        button.layer?.removeAnimation(forKey: Self.pulseKey)
        let dotsPulse = iconStyle == .agents && !sessionDots.isEmpty
        if isPulsing, !iconStyle.isMeters, !dotsPulse,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.3
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            button.layer?.add(pulse, forKey: Self.pulseKey)
        }
        button.layer?.opacity = 1
    }

    func setFeed(description: String) {
        feedItem.attributedTitle = NSAttributedString(string: "Lights: \(description)", attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }

    func setCore(description: String) {
        coreItem.attributedTitle = NSAttributedString(string: "Core: \(description)", attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }

    @objc private func clicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true
        if secondary {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            onTogglePanel?()
        }
    }

    @objc private func openPanel(_ sender: Any?) {
        onTogglePanel?()
    }

    @objc private func openSettings(_ sender: Any?) {
        onOpenSettings?()
    }

    @objc private func openHistory(_ sender: Any?) {
        onOpenHistory?()
    }

    @objc private func openUsageCenter(_ sender: Any?) {
        onOpenUsageCenter?()
    }

    @objc private func openEffects(_ sender: Any?) {
        onOpenEffects?()
    }

    @objc private func openControlCenter(_ sender: Any?) {
        onOpenControlCenter?()
    }

    @objc private func toggleScreenBar(_ sender: NSMenuItem) {
        isScreenBarShown.toggle()
        onToggleScreenBar?(isScreenBarShown)
    }

    /// The plain glyph, for places that draw the app's mark inline.
    static func glyph() -> NSImage {
        StatusIconRenderer.shared.image(for: StatusIconSpec(style: .glyph))
    }

    /// Writes every style at 8× into `directory` (a menu-bar mock-up: dark
    /// bar, the icon, the label beside it where the style has one).
    /// `live` is the item's own meters when the core has answered, so a
    /// design review is of the reader's real providers rather than of a
    /// sample nobody has; empty falls back to the sample.
    static func renderStyles(to directory: String, live: [StatusMeter] = [], liveDots: [SessionDot] = []) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let scale: CGFloat = 8
        let sample = live.isEmpty ? StatusItemController.sampleMeters : live
        let dots = liveDots.isEmpty ? StatusItemController.sampleSessionDots : liveDots
        let manyDots = dots + [
            SessionDot(id: "extra-1", state: .working, accentHex: "#34C759"),
            SessionDot(id: "extra-2", state: .idle),
            SessionDot(id: "extra-3", state: .done),
        ]
        let samples: [(String, StatusIconSpec, String?)] = [
            ("agents", StatusIconSpec(style: .agents, sessions: dots, phase: 0.4), nil),
            ("agents_empty", StatusIconSpec(style: .agents), nil),
            ("agents_overflow", StatusIconSpec(style: .agents, sessions: manyDots, phase: 0.4), nil),
            ("meters_idle", StatusIconSpec(style: .meters, meters: sample, dot: .idle), nil),
            ("meters_working", StatusIconSpec(style: .meters, tintHex: "#00E5FF", meters: sample, dot: .working, phase: 0.5), nil),
            ("meters_ask", StatusIconSpec(style: .meters, meters: sample, dot: .ask, phase: 0.4), nil),
            ("meters_error", StatusIconSpec(style: .meters, meters: sample, dot: .error, phase: 0.2), nil),
            ("meters_done", StatusIconSpec(style: .meters, meters: sample, dot: .done), nil),
            ("meters_overflow", StatusIconSpec(style: .meters, meters: sample, overflow: 2, dot: .working, phase: 0.5), nil),
            ("meters_percent", StatusIconSpec(style: .metersPercent, meters: sample, dot: .working, phase: 0.5), nil),
            ("glyph", StatusIconSpec(style: .glyph), nil),
            ("glyph_working", StatusIconSpec(style: .glyph, tintHex: "#00E5FF"), nil),
            ("glyph_ring_42", StatusIconSpec(style: .glyphRing, ringFraction: 0.42), nil),
            ("glyph_ring_85", StatusIconSpec(style: .glyphRing, ringFraction: 0.85), nil),
            ("glyph_ring_97", StatusIconSpec(style: .glyphRing, ringFraction: 0.97), nil),
            ("glyph_label", StatusIconSpec(style: .glyphLabel), StatusIconRenderer.label(active: 2, needsYou: 1, ready: 0)),
        ]
        for (name, spec, label) in samples {
            let image = StatusIconRenderer.shared.image(for: spec)
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5 * scale, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let textWidth = label.map { ($0 as NSString).size(withAttributes: attributes).width + 6 * scale } ?? 0
            let iconSize = StatusIconRenderer.size(for: spec)
            let size = NSSize(width: (iconSize.width + 8) * scale + textWidth, height: 24 * scale)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(white: 0.12, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            let tinted: NSImage
            if image.isTemplate, let tint = spec.tintHex.flatMap({ NSColor(hex: $0) }) ?? Optional(NSColor.white) {
                tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    tint.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
            } else {
                tinted = image
            }
            tinted.draw(in: NSRect(x: 4 * scale, y: (24 - iconSize.height) / 2 * scale,
                                   width: iconSize.width * scale, height: iconSize.height * scale))
            if let label {
                (label as NSString).draw(at: NSPoint(x: 26 * scale, y: 5.5 * scale), withAttributes: attributes)
            }
            NSGraphicsContext.restoreGraphicsState()
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            }
        }
    }

    /// Four believable providers for the icon previews and the Settings
    /// picker, used whenever the daemon has nothing to meter yet.
    static var sampleMeters: [StatusMeter] {
        [
            StatusMeter(id: "claude", name: "Claude", glyph: .symbol("asterisk"), fraction: 0.16),
            StatusMeter(id: "codex", name: "Codex", glyph: .symbol("chevron.left.forwardslash.chevron.right"), fraction: 0.83),
            StatusMeter(id: "gemini", name: "Gemini", glyph: .symbol("sparkle"), fraction: 0.97),
            StatusMeter(id: "devin", name: "Devin", glyph: .symbol("hammer.fill"), fraction: 0.41, approximate: true),
        ]
    }

    /// Five believable sessions for the `agents` previews, in the panel's
    /// order (asks first, done last), used whenever the daemon has none.
    static var sampleSessionDots: [SessionDot] {
        [
            SessionDot(id: "s-ask", state: .ask),
            SessionDot(id: "s-claude", state: .working, accentHex: "#D97757"),
            SessionDot(id: "s-codex", state: .working, accentHex: "#2B8FFF"),
            SessionDot(id: "s-done", state: .done),
            SessionDot(id: "s-idle", state: .idle),
        ]
    }

    /// A provider's panel style as a menu-bar meter. `fraction` is nil
    /// when the provider reports its primary window without a number; the
    /// strip marks that column as unread. `document` carries the
    /// configured `colors.agent_colors.<id>` accent, when one validates.
    static func meter(for provider: String, fraction: Double?, approximate: Bool,
                      document: SettingsDocument? = nil) -> StatusMeter {
        let style = ProviderStyle.style(for: provider, document: document)
        let glyph: StatusMeter.Glyph
        switch style.glyph {
        case .symbol(let name): glyph = .symbol(name)
        case .text(let text): glyph = .text(text)
        }
        return StatusMeter(id: style.id, name: style.name, glyph: glyph, fraction: fraction,
                           approximate: approximate,
                           accentHex: document?.agentColorHex(provider))
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
