import AppKit
import QuartzCore

/// What JR-Bar's status item wears, as the mirror reproduces it. The
/// host builds it from its own model — never from the button, which
/// wears nothing while the mirror carries the face — and pushes it on
/// every change (redraw, tooltip, the panel's highlight, the
/// escalation pulse, the bar's appearance), so the mirror is never a
/// sampled copy of a moving picture.
struct MenuBarIconFace {
    /// The icon's own image — the style that is live, meters and all.
    var image: NSImage?
    /// The template tint the button applies: state, escalation amber.
    var tint: NSColor?
    /// The label style's text; nil for every other style.
    var title: NSAttributedString?
    /// The width the real item claims as the icon: a strip's own width,
    /// the square's thickness. 0 lets a label measure itself.
    var length: CGFloat = 0
    /// The panel is open — the button's highlight.
    var highlighted = false
    /// The glyph styles' stage-2 escalation fade.
    var pulsing = false
    var toolTip: String?
    var accessibilityLabel: String?
    /// The menu bar's appearance, read off the real button: a template
    /// glyph must resolve to the bar's label colour, not the app's.
    var appearance: NSAppearance?
    /// The hidden run, for the ‹ beside the face.
    var hiddenCount = 0
    var hiddenRevealed = false

    static let pulseKey = "jrbar.escalationPulse"

    /// The escalation fade — one definition for the button and the
    /// mirror, so the two can never breathe out of step.
    static func pulseAnimation() -> CABasicAnimation {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return pulse
    }
}

/// The visible face of our status item while the concealer runs.
///
/// Under our own assertion macOS does not draw JR-Bar's item — measured
/// 2026-09-22 with the notarized build: the item stood uncovered at
/// x≈975–1005 and a capture that excluded only our overlay windows
/// showed nothing there. The agent exempts by signing identity, and the
/// helper that holds the assertion shares ours. So while the engine
/// conceals, this panel IS the icon: the host's face as pushed to it,
/// seated flush left of the first item that stays drawn — the right end
/// of the blank run the concealed apps leave behind, where Bartender
/// keeps its icon — with a ‹ beside it while anything is hidden.
///
/// It answers clicks the way the real button does: the face opens the
/// panel, right/Option/Control-click pops the item's full menu, and
/// the ‹ toggles the hidden run.
final class MenuBarIconMirror: NSPanel {
    /// The face's ordinary click — the panel toggle.
    var onPrimaryClick: (() -> Void)?
    /// Right/Option/Control-click — the item's own menu, popped under
    /// the view handed over.
    var onSecondaryClick: ((NSView) -> Void)?
    /// The ‹ — the hidden run's toggle.
    var onChevronClick: (() -> Void)?
    /// The face's frame in AppKit screen coordinates after every move;
    /// nil once the mirror is down. The host anchors the panel on it.
    var onPlace: ((NSRect?) -> Void)?

    private let content = MirrorContentView()
    private(set) var face = MenuBarIconFace()
    /// The face frame last handed to `onPlace`.
    private var publishedFaceFrame: NSRect?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 30, height: Self.itemHeight),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        // A panel in an app that is almost never active: the tooltip
        // must not wait for an activation that never comes.
        allowsToolTipsWhenApplicationIsInactive = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        title = "JR-Bar Icon"
        content.onClick = { [weak self] click, view in self?.route(click, from: view) }
        contentView = content
        // `acceptsMouseMovedEvents` stays off — this window exists to be
        // seen and clicked, never to hover over the run it stands beside.
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Wear `face`. Only what changed is touched — the breathing dot
    /// pushes a new image twice a second.
    func update(face: MenuBarIconFace) {
        self.face = face
        if appearance !== face.appearance { appearance = face.appearance }
        content.apply(face)
    }

    /// The panel's width for the current face: the face at its natural
    /// width plus the ‹ zone while anything is hidden.
    var panelWidth: CGFloat {
        Self.panelWidth(faceWidth: content.faceWidth(for: face), hiddenCount: face.hiddenCount)
    }

    /// Stand at `seat(width)` on the menu-bar `row` (Quartz), converted
    /// against the Quartz origin display's `primaryMaxY`. Idempotent: the
    /// window moves only when its frame changes and orders front only
    /// when it is not already up.
    func show(row: CGRect, primaryMaxY: CGFloat, seat: (CGFloat) -> CGFloat) {
        let width = panelWidth
        let frame = Self.frame(seatMinX: seat(width), width: width, row: row, primaryMaxY: primaryMaxY)
        if self.frame != frame {
            setFrame(frame, display: true)
            // A move that keeps the size never reaches `resizeSubviews`.
            content.layoutZones()
        }
        if !isVisible { orderFrontRegardless() }
        let chevron = face.hiddenCount > 0 ? Self.chevronZone : 0
        publish(Self.faceFrame(in: frame, chevronWidth: chevron))
    }

    func hide() {
        if isVisible { orderOut(nil) }
        publish(nil)
    }

    private func publish(_ faceFrame: NSRect?) {
        guard faceFrame != publishedFaceFrame else { return }
        publishedFaceFrame = faceFrame
        onPlace?(faceFrame)
    }

    /// What a click means. Internal so a test can drive the routing
    /// without an event.
    func route(_ click: Click, from view: NSView) {
        switch click {
        case .face: onPrimaryClick?()
        case .menu: onSecondaryClick?(view)
        case .chevron: onChevronClick?()
        }
    }

    // MARK: Pure geometry

    enum Click: Equatable { case face, menu, chevron }

    /// A click's meaning: any secondary click (right button, Option,
    /// Control — the real item's rule) is the menu; otherwise the ‹
    /// zone is the hidden run's toggle and the rest is the face.
    nonisolated static func click(atX x: CGFloat, chevronWidth: CGFloat, secondary: Bool) -> Click {
        if secondary { return .menu }
        return x < chevronWidth ? .chevron : .face
    }

    /// The gap macOS keeps between neighbouring status items' frames —
    /// measured 2026-09-22 across the right-hand run.
    nonisolated static let itemGap: CGFloat = 7
    /// A status item's height: the extras' AX frames are 24 pt, centred
    /// on the row whatever the notch makes its depth.
    nonisolated static let itemHeight: CGFloat = 24
    /// The ‹'s click zone left of the face.
    nonisolated static let chevronZone: CGFloat = 14
    /// A label's breathing room each side, as a variable-length item
    /// pads its title.
    nonisolated static let labelInset: CGFloat = 4

    /// The seat: the x the mirror's left edge takes so it stands flush
    /// left of the first drawn item, scanning from the right, whose gap
    /// to the left fits it — `trailingGap` to that item, `leadingGap` to
    /// whatever bounds the gap on the left (another item, or `clearOf`:
    /// the notch's and our band's edge). Only items reaching right of
    /// `clearOf` bound a gap, and overlapping frames (a ghost stacked on
    /// its neighbour) count as one. nil when no gap fits.
    nonisolated static func seatMinX(drawn: [CGRect], clearOf: CGFloat, width: CGFloat,
                                     trailingGap: CGFloat = itemGap,
                                     leadingGap: CGFloat = itemGap) -> CGFloat? {
        var runs: [(minX: CGFloat, maxX: CGFloat)] = []
        for rect in drawn.filter({ $0.maxX > clearOf && $0.width > 0 })
            .sorted(by: { $0.minX < $1.minX }) {
            if let last = runs.last, rect.minX <= last.maxX {
                runs[runs.count - 1].maxX = max(last.maxX, rect.maxX)
            } else {
                runs.append((rect.minX, rect.maxX))
            }
        }
        var gaps: [(left: CGFloat, right: CGFloat)] = []
        var left = clearOf
        for run in runs {
            if run.minX > left { gaps.append((left, run.minX)) }
            left = max(left, run.maxX)
        }
        let needed = width + trailingGap + leadingGap
        for gap in gaps.reversed() where gap.right - gap.left >= needed {
            return gap.right - trailingGap - width
        }
        return nil
    }

    /// The panel's width: the face plus the ‹ zone while anything is
    /// hidden.
    nonisolated static func panelWidth(faceWidth: CGFloat, hiddenCount: Int) -> CGFloat {
        faceWidth + (hiddenCount > 0 ? chevronZone : 0)
    }

    /// The panel's frame for a seat, in AppKit screen coordinates: one
    /// item high, centred on the Quartz `row` like the other items' AX
    /// frames, flipped against the Quartz origin display's top.
    nonisolated static func frame(seatMinX: CGFloat, width: CGFloat, height: CGFloat = itemHeight,
                                  row: CGRect, primaryMaxY: CGFloat) -> NSRect {
        let quartzY = row.midY - height / 2
        return NSRect(x: seatMinX, y: primaryMaxY - quartzY - height, width: width, height: height)
    }

    /// The face's slice of the panel — everything right of the ‹ zone.
    nonisolated static func faceFrame(in panel: NSRect, chevronWidth: CGFloat) -> NSRect {
        NSRect(x: panel.minX + chevronWidth, y: panel.minY,
               width: max(0, panel.width - chevronWidth), height: panel.height)
    }
}

/// The mirror's content: the ‹ and the face, one view taking every
/// click so the panel answers like the item it stands in for. The face
/// is a borderless `NSButton` — the same renderer the status item's own
/// button is — so template tinting, the label and the image position
/// come out as the real one draws them.
private final class MirrorContentView: NSView {
    let chevron = NSImageView()
    let faceButton = NSButton()
    var onClick: ((MenuBarIconMirror.Click, NSView) -> Void)?

    private var showsChevron = false
    private var chevronRevealed: Bool?
    private var highlighted = false
    private var pulsing = false
    private var axLabel = "JR-Bar"

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: MenuBarIconMirror.itemHeight))
        wantsLayer = true
        faceButton.isBordered = false
        faceButton.title = ""
        faceButton.imagePosition = .imageOnly
        faceButton.imageScaling = .scaleProportionallyDown
        faceButton.focusRingType = .none
        faceButton.wantsLayer = true
        faceButton.setAccessibilityElement(false)
        chevron.imageScaling = .scaleNone
        chevron.imageAlignment = .alignCenter
        chevron.contentTintColor = .secondaryLabelColor
        chevron.isHidden = true
        chevron.setAccessibilityElement(false)
        addSubview(chevron)
        addSubview(faceButton)
        // The zones get their frames here, not only on a resize: the
        // panel's content rect is this same 30 pt, so a first face that
        // is 30 pt wide with nothing hidden never resizes the view, and
        // the button would stand 0×0 — an icon with nothing drawn.
        layoutZones()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(_ face: MenuBarIconFace) {
        if faceButton.image !== face.image { faceButton.image = face.image }
        if faceButton.contentTintColor != face.tint { faceButton.contentTintColor = face.tint }
        if let title = face.title {
            if !faceButton.attributedTitle.isEqual(to: title) { faceButton.attributedTitle = title }
            faceButton.imagePosition = .imageLeading
            faceButton.imageHugsTitle = true
        } else if !faceButton.title.isEmpty || faceButton.imagePosition != .imageOnly {
            faceButton.title = ""
            faceButton.imagePosition = .imageOnly
        }
        if toolTip != face.toolTip { toolTip = face.toolTip }
        axLabel = face.accessibilityLabel ?? "JR-Bar"
        if highlighted != face.highlighted {
            highlighted = face.highlighted
            needsDisplay = true
        }
        if pulsing != face.pulsing {
            pulsing = face.pulsing
            faceButton.layer?.removeAnimation(forKey: MenuBarIconFace.pulseKey)
            if pulsing {
                faceButton.layer?.add(MenuBarIconFace.pulseAnimation(), forKey: MenuBarIconFace.pulseKey)
            }
            faceButton.layer?.opacity = 1
        }
        let shows = face.hiddenCount > 0
        if shows != showsChevron {
            showsChevron = shows
            chevron.isHidden = !shows
            layoutZones()
        }
        if chevronRevealed != face.hiddenRevealed {
            chevronRevealed = face.hiddenRevealed
            chevron.image = NSImage(systemSymbolName: face.hiddenRevealed ? "chevron.right" : "chevron.left",
                                    accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        }
    }

    /// The face's natural width: a label measures itself like a
    /// variable-length item; everything else is the host's length, or
    /// the image when that is wider.
    func faceWidth(for face: MenuBarIconFace) -> CGFloat {
        if face.title != nil {
            return ceil(faceButton.cell?.cellSize.width ?? 0) + 2 * MenuBarIconMirror.labelInset
        }
        return max(face.length, ceil(face.image?.size.width ?? 0))
    }

    func layoutZones() {
        let chevronWidth = showsChevron ? MenuBarIconMirror.chevronZone : 0
        chevron.frame = NSRect(x: 0, y: 0, width: chevronWidth, height: bounds.height)
        faceButton.frame = NSRect(x: chevronWidth, y: 0,
                                  width: max(0, bounds.width - chevronWidth), height: bounds.height)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutZones()
    }

    /// The panel's highlight while it is open: the rounded wash a status
    /// item draws behind itself when its menu or panel is up.
    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: faceButton.frame.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    // MARK: Clicks — every one lands here, not on the button

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    /// Acts on the press, as the status item's menu does: the panel's
    /// and the Item Bar's outside-click monitors see this same event, and
    /// answering on the release would reopen whatever they just closed.
    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags
        onClick?(click(for: event, secondary: flags.contains(.option) || flags.contains(.control)),
                 faceButton)
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?(click(for: event, secondary: true), faceButton)
    }

    private func click(for event: NSEvent, secondary: Bool) -> MenuBarIconMirror.Click {
        let x = convert(event.locationInWindow, from: nil).x
        return MenuBarIconMirror.click(atX: x,
                                       chevronWidth: showsChevron ? MenuBarIconMirror.chevronZone : 0,
                                       secondary: secondary)
    }

    // MARK: Accessibility — one button, the item's own label

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { axLabel }

    override func accessibilityPerformPress() -> Bool {
        onClick?(.face, faceButton)
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        onClick?(.menu, faceButton)
        return true
    }
}
