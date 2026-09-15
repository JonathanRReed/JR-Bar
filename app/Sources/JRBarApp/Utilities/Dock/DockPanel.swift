import AppKit
import JRBarCore
import QuartzCore
import SwiftUI

/// The bar's frame math, pure so a test can pin it: row length from
/// the magnified scales, thickness from the rest size, and the
/// anchored frame on a screen edge.
enum DockBarMetrics {
    /// The row's length along the dock axis: scaled icons, spacing,
    /// the separators the view draws between groups (each separator is
    /// a row child — its width plus a share of the spacing gaps), and
    /// the bar's padding.
    static func rowLength(iconSize: Double, spacing: Double,
                          padding: Double, scales: [Double],
                          separators: Int = 0, separatorWidth: Double = 0) -> Double {
        let icons = scales.reduce(0) { $0 + iconSize * $1 }
        let gaps = Double(max(0, scales.count + separators - 1))
        return icons + spacing * gaps + separatorWidth * Double(separators) + padding * 2
    }

    /// The bar's cross-axis thickness: room for a fully magnified icon,
    /// the running indicator, and padding.
    static func thickness(iconSize: Double, maxScale: Double,
                          indicatorRoom: Double, padding: Double) -> Double {
        iconSize * max(1, maxScale) + indicatorRoom + padding * 2
    }

    /// The anchored frame for a bar of `size` on `screen`'s edge —
    /// centred along the axis for `.floating`, edge to edge for
    /// `.fullWidth`. A `.floating` bar longer than the screen clamps
    /// inside it (margin both ends) rather than hanging off the
    /// display.
    static func frame(edge: DockEdge, style: DockBarStyle, size: NSSize,
                      on screenFrame: NSRect, margin: CGFloat) -> NSRect {
        switch edge {
        case .bottom:
            let width = style == .fullWidth
                ? screenFrame.width
                : min(size.width, max(1, screenFrame.width - margin * 2))
            return NSRect(x: style == .fullWidth ? screenFrame.minX : screenFrame.midX - width / 2,
                          y: screenFrame.minY + margin,
                          width: width, height: size.height)
        case .left:
            let height = style == .fullWidth
                ? screenFrame.height
                : min(size.height, max(1, screenFrame.height - margin * 2))
            return NSRect(x: screenFrame.minX + margin,
                          y: style == .fullWidth ? screenFrame.minY : screenFrame.midY - height / 2,
                          width: size.width, height: height)
        case .right:
            let height = style == .fullWidth
                ? screenFrame.height
                : min(size.height, max(1, screenFrame.height - margin * 2))
            return NSRect(x: screenFrame.maxX - margin - size.width,
                          y: style == .fullWidth ? screenFrame.minY : screenFrame.midY - height / 2,
                          width: size.width, height: height)
        }
    }

    /// The hidden frame: slid off the edge until only `sliver` points
    /// remain on screen — the strip a pointer at the edge touches to
    /// reveal the bar again.
    static func hiddenFrame(_ shown: NSRect, edge: DockEdge,
                            on screenFrame: NSRect, sliver: CGFloat) -> NSRect {
        var frame = shown
        switch edge {
        case .bottom: frame.origin.y = screenFrame.minY - shown.height + sliver
        case .left: frame.origin.x = screenFrame.minX - shown.width + sliver
        case .right: frame.origin.x = screenFrame.maxX - sliver
        }
        return frame
    }
}

/// The Replace-mode bar's window: a borderless, nonactivating panel
/// anchored to the configured edge of its display (docs/TOY-PARITY.md
/// P1 rows). Its level sits one step above the Dock's own window
/// level, so even if Apple's Dock is summoned (Mission Control, a
/// stray reveal) it can never cover our bar; all-spaces collection
/// behaviour and Liquid Glass / frosted / solid / clear backing per
/// `DockSettings.material` — the bar floats, so the material rule
/// allows glass.
///
/// Auto-hide slides the panel off its edge until a `hiddenSliver`
/// strip remains on screen. A `pointerPollInterval` timer reads
/// `NSEvent.mouseLocation` and hit-tests it against the panel's frame
/// — the same pattern `ScreenBarInteraction` uses — because a
/// tracking area on a mostly-offscreen sliver can't be relied on to
/// deliver the enter that reveals the bar. Inside cancels a pending
/// hide (and reveals); outside arms the hide after `autoHide.delay`.
@MainActor
final class DockPanel: NSPanel {
    static let cornerRadius: CGFloat = 22
    /// Air between the bar and the screen edge.
    static let edgeMargin: CGFloat = 6
    /// How much of the bar stays on screen while hidden — the reveal strip.
    static let hiddenSliver: CGFloat = 3
    /// Breathing room inside the material, around the icon row.
    static let padding: CGFloat = 8
    /// Cross-axis room the running indicator takes beside the icon.
    static let indicatorRoom: CGFloat = 8
    /// The auto-hide poll's cadence — ~20 Hz, same as the enhance
    /// watcher's poll and `ScreenBarInteraction.moveInterval`.
    static let pointerPollInterval: TimeInterval = 0.05

    let model: DockModel
    let magnifier: DockMagnifier
    /// The view's panel-side callbacks — the folder tile's tap lands
    /// here so the popover can anchor to the tile.
    let actions: DockViewActions
    /// The bar's own window previews — the swipe-up gesture's panel.
    let previewer = DockItemPreviewer()
    private(set) var edge: DockEdge
    /// The display this bar belongs to — stored because a not-yet-
    /// ordered window's `screen` is nil and would anchor to main.
    private(set) var dockScreen: NSScreen
    private let hosting: DockHostingView
    private var backdrop: NSView
    private var applied: DockSettings
    private var pointerTimer: Timer?
    private var hideWork: DispatchWorkItem?
    private(set) var dockHidden = false
    private var anchoring = false
    /// The scroll/swipe state machine — accumulates a trackpad
    /// gesture's travel across events.
    private var scrollInterpreter = DockScrollInterpreter()
    /// The folder popover — one per bar, retargeted per tap.
    private var folderPanel: DockFolderPanel?

    init(model: DockModel, magnifier: DockMagnifier,
         edge: DockEdge, screen: NSScreen, settings: DockSettings) {
        self.model = model
        self.magnifier = magnifier
        self.edge = edge
        self.dockScreen = screen
        self.applied = settings
        let viewActions = DockViewActions()
        self.actions = viewActions
        let hosting = DockHostingView(rootView: DockView(
            model: model, magnifier: magnifier, edge: edge,
            settings: settings, actions: viewActions))
        self.hosting = hosting
        self.backdrop = NSView()
        super.init(contentRect: NSRect(x: 0, y: 0, width: 160, height: 72),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backdrop = Self.makeBackdrop(material: settings.material, tint: settings.tintHex,
                                     content: hosting)
        contentView = backdrop
        isOpaque = false
        backgroundColor = .clear
        hasShadow = settings.material != .clear
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        title = "JR-Bar Dock"
        // One step above the Dock's own window level — even a revealed
        // Apple Dock draws beneath our bar, never over it.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        magnifier.magnification = { [weak self] in self?.applied.magnification ?? DockMagnification() }
        magnifier.onScalesChanged = { [weak self] in self?.reanchor() }
        hosting.onScrollWheel = { [weak self] event in self?.handleScroll(event) }
        hosting.onSwipe = { [weak self] event in self?.handleSwipe(event) }
        actions.onFolderTap = { [weak self] item in self?.toggleFolderPopover(item) }
        previewer.thumbnailsEnabled = { [weak self] in
            self?.applied.enhance.showThumbnails ?? true
        }
        setFrame(targetFrame(for: dockScreen), display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The bar lives over screen edges the window server would
    /// otherwise keep windows off of.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // MARK: Settings

    /// A new `DockSettings` from the store: material changes rebuild
    /// the backdrop, geometry changes re-anchor, and the view takes the
    /// new settings so toggles re-render.
    func apply(settings: DockSettings) {
        let materialChanged = settings.material != applied.material || settings.tintHex != applied.tintHex
        applied = settings
        edge = settings.edge
        if materialChanged {
            backdrop = Self.makeBackdrop(material: settings.material, tint: settings.tintHex,
                                         content: hosting)
            contentView = backdrop
            hasShadow = settings.material != .clear
        }
        hosting.rootView = DockView(model: model, magnifier: magnifier,
                                    edge: settings.edge, settings: settings,
                                    actions: actions)
        if !applied.autoHide.enabled {
            hideWork?.cancel()
            hideWork = nil
            if dockHidden {
                dockHidden = false
            }
        }
        reanchor()
    }

    // MARK: Present / dismiss

    func present() {
        magnifier.attach(to: dockScreen)
        reanchor()
        startPointerPoll()
        alphaValue = 0
        orderFrontRegardless()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.05 : 0.16
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        magnifier.detach()
        pointerTimer?.invalidate()
        pointerTimer = nil
        hideWork?.cancel()
        hideWork = nil
        folderPanel?.dismiss()
        previewer.hide()
        alphaValue = 0
        orderOut(nil)
    }

    // MARK: Anchoring

    /// The bar's on-screen size: thickness follows the wave's current
    /// peak — flat at rest, growing as icons lift so a magnified tile
    /// never overflows the pill — and length follows the rendered row
    /// so the pill always hugs its icons.
    private func barSize() -> NSSize {
        let mag = applied.magnification
        let lift = magnifier.scaleList.max() ?? 1
        let thickness = DockBarMetrics.thickness(
            iconSize: applied.iconSize,
            maxScale: mag.enabled ? max(1, lift) : 1,
            indicatorRoom: Self.indicatorRoom, padding: Self.padding)
        let length = DockBarMetrics.rowLength(
            iconSize: applied.iconSize, spacing: DockView.spacing,
            padding: Self.padding, scales: magnifier.scaleList,
            separators: DockView.separatorIndices(for: model.items).count,
            separatorWidth: DockView.separatorWidth)
        return edge.isHorizontal
            ? NSSize(width: length, height: thickness)
            : NSSize(width: thickness, height: length)
    }

    private func targetFrame(for screen: NSScreen?) -> NSRect {
        let screenFrame = (screen ?? NSScreen.main)?.frame ?? .zero
        let shown = DockBarMetrics.frame(edge: edge, style: applied.style,
                                         size: barSize(), on: screenFrame,
                                         margin: Self.edgeMargin)
        guard dockHidden else { return shown }
        return DockBarMetrics.hiddenFrame(shown, edge: edge, on: screenFrame,
                                          sliver: Self.hiddenSliver)
    }

    /// Re-fit and re-anchor on the screen's edge. Called when items or
    /// magnification scales change; guarded against re-entry from
    /// `setFrame`.
    func reanchor() {
        guard !anchoring, isVisible || alphaValue > 0 else { return }
        anchoring = true
        defer { anchoring = false }
        let target = targetFrame(for: dockScreen)
        if target != frame { setFrame(target, display: true) }
    }

    // MARK: Gestures — scroll to switch, swipe up for previews (P4)

    /// A scroll event over the bar: find the tile under the pointer,
    /// run the event through the interpreter, act on the result.
    private func handleScroll(_ event: NSEvent) {
        guard let item = itemUnderPointer(event) else {
            scrollInterpreter.reset()
            return
        }
        let action: DockGestureAction?
        if event.hasPreciseScrollingDeltas {
            // A trackpad gesture carries phases; momentum events (phase
            // empty) are dropped — a flick's tail must not keep
            // stepping windows.
            guard event.phase != [] else { return }
            let inverted = event.isDirectionInvertedFromDevice
            action = scrollInterpreter.notePan(
                dx: inverted ? event.scrollingDeltaX : -event.scrollingDeltaX,
                dy: inverted ? event.scrollingDeltaY : -event.scrollingDeltaY,
                began: event.phase.contains(.began),
                ended: event.phase.contains(.ended) || event.phase.contains(.cancelled))
        } else {
            action = scrollInterpreter.noteWheel(deltaY: event.scrollingDeltaY)
        }
        perform(action, on: item)
    }

    /// A trackpad `.swipe` — a vertical swipe over a tile opens its
    /// window previews. (`deltaY`'s sign convention for swipe events
    /// is unreliable across systems; either vertical direction opens.)
    private func handleSwipe(_ event: NSEvent) {
        guard event.deltaY != 0, abs(event.deltaY) > abs(event.deltaX),
              let item = itemUnderPointer(event) else { return }
        showPreviews(for: item)
    }

    private func perform(_ action: DockGestureAction?, on item: DockItem) {
        switch action {
        case .cycleWindows(let forward):
            model.cycleWindows(item, forward: forward)
        case .showPreviews:
            showPreviews(for: item)
        case nil:
            break
        }
    }

    /// The tile under an event's pointer, mapped through the
    /// magnifier's centre map so a magnified row still hit-tests true.
    private func itemUnderPointer(_ event: NSEvent) -> DockItem? {
        let location = hosting.convert(event.locationInWindow, from: nil)
        let axisPosition: Double
        if edge.isHorizontal {
            axisPosition = location.x - Self.padding
        } else {
            // The row runs top-down in the hosting view; the view's
            // flippedness decides which way y counts.
            let topDown = hosting.isFlipped
                ? location.y : hosting.bounds.height - location.y
            axisPosition = topDown - Self.padding
        }
        guard let index = DockGestureMath.itemIndex(
            at: axisPosition, centers: magnifier.currentCenters(),
            hitRadius: applied.iconSize * 0.75 + DockView.spacing),
              model.items.indices.contains(index) else { return nil }
        return model.items[index]
    }

    /// A tile's frame in screen coordinates — the folder popover and
    /// the preview panel anchor to it.
    func tileAnchor(for itemID: String) -> CGRect? {
        guard let index = model.items.firstIndex(where: { $0.id == itemID }) else {
            return nil
        }
        let centers = magnifier.currentCenters()
        guard index < centers.count else { return nil }
        let center = centers[index]
        let half = applied.iconSize * (magnifier.scales[itemID] ?? 1) / 2
        switch edge {
        case .bottom:
            return CGRect(x: frame.minX + Self.padding + center - half,
                          y: frame.minY, width: half * 2, height: frame.height)
        case .left, .right:
            // The row axis runs top-down; screens run bottom-up.
            return CGRect(x: frame.minX,
                          y: frame.maxY - Self.padding - center - half,
                          width: frame.width, height: half * 2)
        }
    }

    // MARK: Folder popover & previews

    /// The folder tile's click: retarget the popover, or close it if
    /// it's already showing this folder — Apple's stacks toggle the
    /// same way.
    private func toggleFolderPopover(_ item: DockItem) {
        guard item.isFolder, let path = item.bundleURL?.path else { return }
        if let folderPanel, folderPanel.isVisible,
           folderPanel.content.folderPath == path {
            folderPanel.dismiss()
            return
        }
        guard let anchor = tileAnchor(for: item.id) else { return }
        let panel = folderPanel ?? DockFolderPanel()
        folderPanel = panel
        panel.show(folder: item, anchor: anchor, edge: edge,
                   screen: dockScreen, gap: 8)
    }

    /// Swipe-up on an app tile floats its window previews — the same
    /// panel enhance mode shows over Apple's Dock.
    private func showPreviews(for item: DockItem) {
        guard item.section == .apps,
              let anchor = tileAnchor(for: item.id) else { return }
        folderPanel?.dismiss()
        previewer.show(item: item, anchor: anchor, edge: edge,
                       screen: dockScreen, gap: 8)
    }

    /// Whether the pointer rests on the popover or preview panel —
    /// the auto-hide poll counts it as "still on the bar" so the dock
    /// can't slide away from under its own popover.
    private func pointerOverAux(_ location: NSPoint) -> Bool {
        if let folderPanel, folderPanel.isVisible,
           folderPanel.frame.insetBy(dx: -4, dy: -4).contains(location) {
            return true
        }
        return previewer.pointerInside(location)
    }

    // MARK: Auto-hide

    /// Slide off the edge (leaving `hiddenSliver`) or back on. A no-op
    /// when auto-hide is off.
    func setDockHidden(_ hidden: Bool, animated: Bool = true) {
        guard applied.autoHide.enabled || !hidden else { return }
        guard hidden != dockHidden else { return }
        dockHidden = hidden
        if hidden {
            folderPanel?.dismiss()
            previewer.hide()
        }
        let target = targetFrame(for: dockScreen)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = (!animated || reduced) ? 0.08 : 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            animator().setFrame(target, display: true)
        }
    }

    /// ~20 Hz pointer watch — the reveal path for the hidden sliver
    /// and the hide path for the shown bar. A tracking area can't do
    /// this: the sliver is three points at the screen's edge on a
    /// mostly-offscreen window, where enter/exit delivery is flaky,
    /// and a click-through-ish edge needs no events anyway — just the
    /// pointer's position.
    private func startPointerPoll() {
        guard pointerTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pointerPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func pollPointer() {
        guard isVisible else { return }
        let location = NSEvent.mouseLocation
        if frame.contains(location) || pointerOverAux(location) {
            // Inside the bar (or its hidden sliver): hold it open.
            hideWork?.cancel()
            hideWork = nil
            if dockHidden { setDockHidden(false) }
        } else {
            guard applied.autoHide.enabled, !dockHidden, hideWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.hideWork = nil
                    self?.setDockHidden(true)
                }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, applied.autoHide.delay),
                                         execute: work)
        }
    }

    isolated deinit {
        pointerTimer?.invalidate()
    }

    // MARK: Materials

    /// The backing for `DockSettings.material`. All four keep the
    /// hosting view edge to edge and carry the same hairline stroke;
    /// `clear` draws only that edge so hit-testing still has a surface
    /// without drawing a slab.
    private static func makeBackdrop(material: DockMaterial, tint: String?,
                                     content: NSHostingView<DockView>) -> NSView {
        let tintColor = tint.flatMap { NSColor(hex: $0) }
        switch material {
        case .glass:
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            if let tintColor { glass.tintColor = tintColor }
            // The glass view manages its own layer, so the hairline
            // goes on a pass-through overlay inside the content.
            let container = NSView()
            pin(content, into: container)
            pin(stroke(), into: container)
            glass.contentView = container
            return glass
        case .frosted:
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            effect.layer?.borderWidth = 0.5
            effect.layer?.borderColor = Self.strokeColor
            pin(content, into: effect)
            if let tintColor {
                let tintView = NSView()
                tintView.wantsLayer = true
                tintView.layer?.backgroundColor = tintColor.withAlphaComponent(0.35).cgColor
                pin(tintView, into: effect, below: content)
            }
            return effect
        case .solid, .clear:
            let fill = NSView()
            fill.wantsLayer = true
            let base = tintColor ?? NSColor.windowBackgroundColor
            fill.layer?.backgroundColor =
                (material == .solid ? base : base.withAlphaComponent(0.12)).cgColor
            fill.layer?.cornerRadius = cornerRadius
            fill.layer?.cornerCurve = .continuous
            fill.layer?.borderWidth = 0.5
            fill.layer?.borderColor = Self.strokeColor
            pin(content, into: fill)
            return fill
        }
    }

    /// The bar's edge hairline — barely-there white, the same stroke
    /// Apple's own floating chrome carries.
    private static var strokeColor: CGColor {
        NSColor.white.withAlphaComponent(0.10).cgColor
    }

    /// A border-only overlay for backings whose own layer is spoken
    /// for (the glass view). `hitTest` returns nil so it never eats a
    /// click meant for an icon.
    private static func stroke() -> NSView {
        let view = DockStrokeView()
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = strokeColor
        return view
    }

    private static func pin(_ child: NSView, into parent: NSView, below: NSView? = nil) {
        child.translatesAutoresizingMaskIntoConstraints = false
        if let below {
            parent.addSubview(child, positioned: .below, relativeTo: below)
        } else {
            parent.addSubview(child)
        }
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}

/// The hairline overlay `makeBackdrop` drops into the glass
/// container — draws its layer's border, never intercepts the mouse.
private final class DockStrokeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
