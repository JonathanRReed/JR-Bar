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
    /// What the ‹ says under the pointer — the utility names the
    /// keyboard's way in when the hotkey is on.
    var chevronToolTip: String?
    /// The extras that ride the face as segments of its one compound
    /// face — the agent dot, the combined system readout. Under our own
    /// assertion macOS draws none of JR-Bar's status items, so an extra
    /// item of ours is invisible there; drawn here it shows, and JR-Bar
    /// keeps its one status item. The utility adds them; the host never
    /// sets them.
    var accessories: [MenuBarFaceAccessory] = []

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

/// One segment of the compound face, right of the icon: an image, an
/// optional label, and what a click on it means (the id routes it).
struct MenuBarFaceAccessory {
    var id: String
    var image: NSImage?
    var title: String?
    var toolTip: String?
    var accessibilityLabel: String
    /// Changes whenever what the segment shows does — the mirror
    /// rebuilds a segment only then.
    var signature: String

    /// A segment's breathing room each side, as a variable-length item
    /// pads its content.
    static let inset: CGFloat = 4
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
    /// A segment's click, with the view to anchor anything it opens on.
    var onAccessoryClick: ((String, NSView) -> Void)?
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
        Self.panelWidth(faceWidth: content.faceWidth(for: face), hiddenCount: face.hiddenCount,
                        accessoryWidths: content.accessoryWidths)
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
        publish(Self.faceFrame(in: frame, chevronWidth: chevron,
                               accessoryWidth: content.accessoryWidths.reduce(0, +)))
    }

    /// A segment's view, in the panel — what a popover anchors on.
    func accessoryView(id: String) -> NSView? {
        content.accessoryView(id: id)
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
        case .accessory(let id): onAccessoryClick?(id, content.accessoryView(id: id) ?? view)
        }
    }

    // MARK: Pure geometry

    enum Click: Equatable { case face, menu, chevron, accessory(String) }

    /// A click's meaning on a compound face: past the face's slice, the
    /// segment under the pointer; otherwise as `click(atX:chevronWidth:
    /// secondary:)` says.
    nonisolated static func click(atX x: CGFloat, chevronWidth: CGFloat, faceWidth: CGFloat,
                                  accessories: [(id: String, width: CGFloat)],
                                  secondary: Bool) -> Click {
        if secondary { return .menu }
        var edge = chevronWidth + faceWidth
        guard x >= edge else { return click(atX: x, chevronWidth: chevronWidth, secondary: false) }
        for accessory in accessories {
            edge += accessory.width
            if x < edge { return .accessory(accessory.id) }
        }
        return accessories.last.map { .accessory($0.id) } ?? .face
    }

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
    /// the notch's, our band's or the front app's menus' edge; `gaps`
    /// says which items bound one). nil when no gap fits.
    nonisolated static func seatMinX(drawn: [CGRect], clearOf: CGFloat, width: CGFloat,
                                     trailingGap: CGFloat = itemGap,
                                     leadingGap: CGFloat = itemGap) -> CGFloat? {
        let needed = width + trailingGap + leadingGap
        for gap in gaps(drawn: drawn, clearOf: clearOf).reversed() where gap.right - gap.left >= needed {
            return gap.right - trailingGap - width
        }
        return nil
    }

    /// Where the mirror stands, always. First the seat with macOS's
    /// item gap each side; failing that, a gap the face fits flush
    /// against both neighbours — touching them beats standing on one,
    /// and a hole the agent leaves open after concealing a small app is
    /// often just that wide; failing that, the seat that covers the
    /// least of anything drawn. On a crowded bar every gap is narrower
    /// than the face, so the face takes the widest gap's left edge and
    /// overlaps the next item by only the width that gap lacks — the
    /// leftmost of equal gaps, so the system's own items at the right
    /// end are the last covered. The old last resort, one gap right of
    /// `clearOf`, was sure to land on the first drawn item: a
    /// status-bar-level panel there hides that app's icon and takes its
    /// clicks. With no gap to weigh — nothing drawn right of `clearOf`:
    /// an empty row, or no Accessibility and so no frames — the mirror
    /// stands one item gap clear of it. `rowMaxX` keeps the panel on
    /// the bar.
    nonisolated static func seat(drawn: [CGRect], clearOf: CGFloat, width: CGFloat,
                                 rowMaxX: CGFloat) -> CGFloat {
        if let seat = seatMinX(drawn: drawn, clearOf: clearOf, width: width) { return seat }
        if let seat = seatMinX(drawn: drawn, clearOf: clearOf, width: width,
                               trailingGap: 0, leadingGap: 0) { return seat }
        var widest: (left: CGFloat, right: CGFloat)?
        for gap in gaps(drawn: drawn, clearOf: clearOf)
        where widest.map({ gap.right - gap.left > $0.right - $0.left }) ?? true {
            widest = gap
        }
        guard let widest else { return min(clearOf + itemGap, rowMaxX - width) }
        return min(max(widest.left, widest.right - width), rowMaxX - width)
    }

    /// The open stretches of the row right of `clearOf`, left to right:
    /// from `clearOf` or a run's right edge to the next run of drawn
    /// items. Only items reaching right of `clearOf` bound a gap, and
    /// overlapping frames (a ghost stacked on its neighbour) count as
    /// one run. The stretch right of the last run is not a gap: the
    /// clock ends it, and the icon never stands there.
    nonisolated static func gaps(drawn: [CGRect], clearOf: CGFloat) -> [(left: CGFloat, right: CGFloat)] {
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
        return gaps
    }

    /// The panel's width: the face plus the ‹ zone while anything is
    /// hidden.
    nonisolated static func panelWidth(faceWidth: CGFloat, hiddenCount: Int,
                                       accessoryWidths: [CGFloat] = []) -> CGFloat {
        faceWidth + (hiddenCount > 0 ? chevronZone : 0) + accessoryWidths.reduce(0, +)
    }

    /// The panel's frame for a seat, in AppKit screen coordinates: one
    /// item high, centred on the Quartz `row` like the other items' AX
    /// frames, flipped against the Quartz origin display's top.
    nonisolated static func frame(seatMinX: CGFloat, width: CGFloat, height: CGFloat = itemHeight,
                                  row: CGRect, primaryMaxY: CGFloat) -> NSRect {
        let quartzY = row.midY - height / 2
        return NSRect(x: seatMinX, y: primaryMaxY - quartzY - height, width: width, height: height)
    }

    /// The face's slice of the panel — right of the ‹ zone, left of the
    /// compound face's segments.
    nonisolated static func faceFrame(in panel: NSRect, chevronWidth: CGFloat,
                                      accessoryWidth: CGFloat = 0) -> NSRect {
        NSRect(x: panel.minX + chevronWidth, y: panel.minY,
               width: max(0, panel.width - chevronWidth - accessoryWidth), height: panel.height)
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
    /// The compound face's segments, in order, and what each last showed.
    private var accessoryButtons: [(id: String, signature: String, button: NSButton)] = []

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
        if chevron.toolTip != face.chevronToolTip { chevron.toolTip = face.chevronToolTip }
        let shows = face.hiddenCount > 0
        if shows != showsChevron {
            showsChevron = shows
            chevron.isHidden = !shows
            layoutZones()
        }
        applyAccessories(face.accessories)
        if !face.accessories.isEmpty {
            axLabel += ", " + face.accessories.map(\.accessibilityLabel).joined(separator: ", ")
        }
        layoutZones()
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

    /// Each segment's width: its content at natural size plus its inset.
    var accessoryWidths: [CGFloat] {
        accessoryButtons.map { ceil($0.button.cell?.cellSize.width ?? 0) + 2 * MenuBarFaceAccessory.inset }
    }

    func accessoryView(id: String) -> NSView? {
        accessoryButtons.first { $0.id == id }?.button
    }

    /// Rebuild the segments whose content changed; drop the gone ones.
    private func applyAccessories(_ accessories: [MenuBarFaceAccessory]) {
        let wanted = accessories.map(\.id)
        if accessoryButtons.map(\.id) != wanted {
            for entry in accessoryButtons { entry.button.removeFromSuperview() }
            accessoryButtons = accessories.map { accessory in
                let button = NSButton()
                button.isBordered = false
                button.focusRingType = .none
                button.setAccessibilityElement(false)
                addSubview(button)
                return (accessory.id, "", button)
            }
        }
        for (index, accessory) in accessories.enumerated()
        where accessoryButtons[index].signature != accessory.signature {
            let button = accessoryButtons[index].button
            button.image = accessory.image
            button.imageScaling = .scaleProportionallyDown
            if let title = accessory.title {
                button.attributedTitle = StatusItemController.labelTitle(title)
                button.imagePosition = accessory.image == nil ? .noImage : .imageLeading
                button.imageHugsTitle = true
            } else {
                button.title = ""
                button.imagePosition = .imageOnly
            }
            button.toolTip = accessory.toolTip
            accessoryButtons[index].signature = accessory.signature
        }
    }

    func layoutZones() {
        let chevronWidth = showsChevron ? MenuBarIconMirror.chevronZone : 0
        chevron.frame = NSRect(x: 0, y: 0, width: chevronWidth, height: bounds.height)
        let segments = accessoryWidths
        let faceWidth = max(0, bounds.width - chevronWidth - segments.reduce(0, +))
        faceButton.frame = NSRect(x: chevronWidth, y: 0, width: faceWidth, height: bounds.height)
        var x = chevronWidth + faceWidth
        for (entry, width) in zip(accessoryButtons, segments) {
            entry.button.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
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
        let chevronWidth = showsChevron ? MenuBarIconMirror.chevronZone : 0
        guard !accessoryButtons.isEmpty else {
            return MenuBarIconMirror.click(atX: x, chevronWidth: chevronWidth, secondary: secondary)
        }
        return MenuBarIconMirror.click(
            atX: x, chevronWidth: chevronWidth, faceWidth: faceButton.frame.width,
            accessories: Array(zip(accessoryButtons.map(\.id), accessoryWidths)).map { ($0.0, $0.1) },
            secondary: secondary)
    }

    // MARK: Accessibility — one button, the item's own label

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { axLabel }
    /// A leaf: an `NSButton` answers AX through its cell, so hiding the
    /// face button alone still listed a second, identical button.
    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityPerformPress() -> Bool {
        onClick?(.face, faceButton)
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        onClick?(.menu, faceButton)
        return true
    }
}
