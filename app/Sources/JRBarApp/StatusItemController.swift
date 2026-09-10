import AppKit
import JRBarUI
import QuartzCore

/// The menu-bar item: a template glyph of the bar under a notch, tinted by
/// the aggregate agent state, in one of the three `menu_bar_icon_style`
/// looks (glyph, glyph with a usage ring, glyph with a label). Left click
/// opens the panel; right click (or Option-click) shows a small utility
/// menu. Stage-2 escalation pulses the icon amber.
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
    var isScreenBarShown = true { didSet { showBarItem.state = isScreenBarShown ? .on : .off } }
    /// The style and ring the next `update` draws with.
    var iconStyle: StatusIconStyle = .glyph { didSet { if iconStyle != oldValue { redraw() } } }
    var ringFraction: Double? { didSet { if ringFraction != oldValue { redraw() } } }
    var labelText: String? { didSet { if labelText != oldValue { redraw() } } }

    private static let pulseKey = "jrbar.escalationPulse"

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        showBarItem = NSMenuItem(title: "Show Screen Bar", action: #selector(toggleScreenBar(_:)), keyEquivalent: "")
        super.init()

        if let button = statusItem.button {
            button.image = renderer.image(for: StatusIconSpec(style: .glyph))
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

        menu.addItem(headerItem)
        menu.addItem(detailItem)
        menu.addItem(coreItem)
        menu.addItem(feedItem)
        menu.addItem(.separator())
        menu.addItem(open)
        menu.addItem(history)
        menu.addItem(usage)
        menu.addItem(effects)
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
        statusItem.button?.toolTip = "JR-Bar · \(state.label)" + (detail.isEmpty ? "" : " · \(detail)")
        redraw()
    }

    /// Redraws only when the spec or the label actually changed; the
    /// renderer hands back the cached image for a repeated spec.
    private func redraw() {
        guard let button = statusItem.button else { return }
        let tint: NSColor? = isPulsing ? .systemOrange : aggregateTint
        let spec = StatusIconSpec(style: iconStyle, ringFraction: iconStyle == .glyphRing ? ringFraction : nil, tintHex: tint?.statusHex)
        let label = iconStyle == .glyphLabel ? labelText : nil
        if spec != currentSpec {
            currentSpec = spec
            let image = renderer.image(for: spec)
            if button.image !== image { button.image = image }
            // A template image takes the tint from the button; a coloured
            // one carries its own.
            button.contentTintColor = image.isTemplate ? tint : nil
        }
        if label != currentLabel {
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
                statusItem.length = NSStatusItem.squareLength
            }
        }
    }

    /// Stage-2 escalation: the icon breathes amber until the ask resolves.
    /// With Reduce Motion the icon holds amber without animating.
    func setEscalationPulse(_ on: Bool) {
        guard on != isPulsing, let button = statusItem.button else { return }
        isPulsing = on
        button.wantsLayer = true
        button.layer?.removeAnimation(forKey: Self.pulseKey)
        if on, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
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
        redraw()
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
    static func renderStyles(to directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let scale: CGFloat = 8
        let samples: [(String, StatusIconSpec, String?)] = [
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
            let size = NSSize(width: 26 * scale + textWidth, height: 24 * scale)
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
            tinted.draw(in: NSRect(x: 4 * scale, y: 3 * scale, width: 18 * scale, height: 18 * scale))
            if let label {
                (label as NSString).draw(at: NSPoint(x: 26 * scale, y: 5.5 * scale), withAttributes: attributes)
            }
            NSGraphicsContext.restoreGraphicsState()
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            }
        }
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
