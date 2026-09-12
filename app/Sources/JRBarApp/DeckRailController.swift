import AppKit
import JRBarCore
import QuartzCore
import SwiftUI

/// The Rail: a thin glass strip of fourteen cells (the thirteen keys and a
/// "…" that opens the Control Center) on a screen edge, always on top, on
/// every Space, never key, never auto-hidden. Click sends `deck_press` for
/// the cell's key; hover shows its label in a pill beside the strip. Shown
/// while the daemon's `rail.edge` is not `off` and the core is live; the
/// pad itself is not required.
@MainActor
final class DeckRailController {
    private let store: DeckStore
    private var panel: RailPanel?
    private var label: RailLabelPanel?
    private var geometry: DeckRailGeometry?
    private var observing = false

    init(store: DeckStore) {
        self.store = store
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observe()
    }

    var isShown: Bool { panel?.isVisible ?? false }

    /// The screen the rail lives on: the Control Center window's, else the
    /// one with the key window, else the main one. Resolved every time.
    private var screen: NSScreen? {
        NSApp.windows.first { $0.identifier?.rawValue == "jrbar.control-center" && $0.isVisible }?.screen
            ?? NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        track()
        refresh()
    }

    private func track() {
        withObservationTracking {
            _ = store.railShown
            _ = store.railEdge
            _ = store.railHoveredCell
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                self.track()
            }
        }
    }

    func refresh() {
        let shown = store.railShown
        guard shown, let screen else {
            hide()
            return
        }
        let geometry = DeckRailGeometry(edge: store.railEdge, visibleFrame: screen.visibleFrame)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if self.geometry?.frame != geometry.frame || self.geometry?.edge != geometry.edge {
            self.geometry = geometry
            panel.setFrame(geometry.frame, display: true)
            panel.hosting.rootView = DeckRailView(store: store, edge: geometry.edge, cellRects: geometry.cellRects, size: geometry.frame.size)
        }
        if !panel.isVisible {
            // A 0.18 s alpha ease like the band tooltip's, not a hard
            // snap; Reduce Motion gets the instant version.
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            store.railDidChange(shown: true)
        }
        if panel.alphaValue < 1 {
            let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if reduced {
                panel.alphaValue = 1
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
                    panel.animator().alphaValue = 1
                }
            }
        }
        updateLabel()
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        store.railHoveredCell = nil
        store.railDidChange(shown: false)
        label?.dismiss()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                // A show during the fade put the alpha back up; it wins.
                guard let self, let panel = self.panel, panel.alphaValue < 0.01 else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func makePanel() -> RailPanel {
        RailPanel(store: store)
    }

    /// The label pill follows the hovered cell; it sits toward the screen's
    /// centre so it never leaves the edge.
    private func updateLabel() {
        guard let panel, let geometry, let cell = store.railHoveredCell, let rect = geometry.cellRects[safe: cell] else {
            label?.dismiss()
            return
        }
        let onScreen = NSRect(x: geometry.frame.minX + rect.minX, y: geometry.frame.minY + rect.minY, width: rect.width, height: rect.height)
        let label = self.label ?? RailLabelPanel()
        self.label = label
        let content: RailLabelView
        if DeckRailGeometry.isOverflowCell(cell) {
            content = RailLabelView(title: "Open Control Center", subtitle: store.banks.title, provider: nil, number: "…")
        } else {
            let slot = store.slots[safe: cell] ?? DeckSlot(index: cell)
            content = RailLabelView(title: slot.title, subtitle: slot.subtitle, provider: slot.provider, number: "\(cell + 1)")
        }
        label.present(content, beside: onScreen, edge: geometry.edge, screen: panel.screen ?? screen)
    }
}

// MARK: - The panel

@MainActor
final class RailPanel: NSPanel {
    let hosting: NSHostingView<DeckRailView>

    init(store: DeckStore) {
        hosting = NSHostingView(rootView: DeckRailView(store: store, edge: .left, cellRects: [], size: .zero))
        let frame = NSRect(x: 0, y: 0, width: DeckRailGeometry.depth, height: DeckRailGeometry.maxCell * CGFloat(DeckRailGeometry.cellCount))
        let plain = ProcessInfo.processInfo.environment["JRBAR_PLAIN_MATERIAL"] != nil
        let backdrop: NSView
        if !plain {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = 12
            glass.style = .regular
            glass.contentView = hosting
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(frame: frame)
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 12
            effect.layer?.masksToBounds = true
            hosting.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            backdrop = effect
        }
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = backdrop
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        level = .floating
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The strip may sit inside the menu bar's band on the top edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The glass label beside the hovered cell.
@MainActor
final class RailLabelPanel: NSPanel {
    private let hosting: NSHostingView<RailLabelView>

    init() {
        hosting = NSHostingView(rootView: RailLabelView(title: "", subtitle: "", provider: nil, number: ""))
        hosting.sizingOptions = [.intrinsicContentSize]
        let frame = NSRect(x: 0, y: 0, width: 160, height: 30)
        let plain = ProcessInfo.processInfo.environment["JRBAR_PLAIN_MATERIAL"] != nil
        let backdrop: NSView
        if !plain {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = 9
            glass.style = .regular
            glass.contentView = hosting
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(frame: frame)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 9
            effect.layer?.masksToBounds = true
            hosting.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            backdrop = effect
        }
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = backdrop
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        level = .floating
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(_ content: RailLabelView, beside rect: NSRect, edge: DeckRailEdge, screen: NSScreen?) {
        hosting.rootView = content
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let width = max(80, size.width), height = max(28, size.height)
        let gap: CGFloat = 8
        var origin: NSPoint
        switch edge {
        case .left, .off: origin = NSPoint(x: rect.maxX + gap, y: rect.midY - height / 2)
        case .right: origin = NSPoint(x: rect.minX - gap - width, y: rect.midY - height / 2)
        case .top: origin = NSPoint(x: rect.midX - width / 2, y: rect.minY - gap - height)
        case .bottom: origin = NSPoint(x: rect.midX - width / 2, y: rect.maxY + gap)
        }
        if let visible = screen?.visibleFrame {
            origin.x = min(visible.maxX - width - 4, max(visible.minX + 4, origin.x))
            origin.y = min(visible.maxY - height - 4, max(visible.minY + 4, origin.y))
        }
        setFrame(NSRect(x: origin.x.rounded(), y: origin.y.rounded(), width: width, height: height), display: true)
        let wasVisible = isVisible && alphaValue > 0.01
        if !wasVisible { alphaValue = 0 }
        orderFrontRegardless()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 1
        } else if !wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
                animator().alphaValue = 1
            }
        }
    }

    /// Fades out and orders out. A re-present during the fade puts the
    /// alpha back up and the completion then leaves the panel alone.
    func dismiss() {
        guard isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 0
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.alphaValue < 0.01 else { return }
                self.orderOut(nil)
            }
        })
    }
}

// MARK: - Views

/// Fourteen cells along the strip, laid out by the same geometry the panel
/// frame comes from.
struct DeckRailView: View {
    @Bindable var store: DeckStore
    let edge: DeckRailEdge
    let cellRects: [CGRect]
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(0..<cellRects.count, id: \.self) { cell in
                let rect = cellRects[cell]
                Group {
                    if DeckRailGeometry.isOverflowCell(cell) {
                        RailOverflowCell(store: store, cell: cell)
                    } else {
                        RailSlotCell(store: store, cell: cell, slot: store.slots[safe: cell] ?? DeckSlot(index: cell))
                    }
                }
                .frame(width: rect.width, height: rect.height)
                // Panel coordinates have their origin at the bottom; SwiftUI's at the top.
                .offset(x: rect.minX, y: size.height - rect.maxY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("JR-Bar rail")
    }
}

/// One key on the rail: its number and the Python marks ("!" attention,
/// "·" working) on a tint of the daemon's colour; a flash on input.
struct RailSlotCell: View {
    @Bindable var store: DeckStore
    let cell: Int
    let slot: DeckSlot

    private var color: Color { Color(nsColor: store.color(for: slot)) }
    private var lit: Bool { store.isLit(slot.index) }
    private var glow: Bool { store.glows(slot) }
    private var hovered: Bool { store.railHoveredCell == cell }
    private var dim: Bool { slot.isEmpty || slot.isReserved }
    private var mark: String { slot.state.railMark }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(lit ? Color.white : (glow ? color : Color.primary.opacity(0.12)))
                .opacity(lit ? 0.95 : (glow ? 0.85 : (dim ? 0.5 : 1)))
                .shadow(color: glow && !lit ? color.opacity(0.6) : .clear, radius: 3)
            if hovered {
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
            }
            HStack(spacing: 0) {
                Text("\(slot.index + 1)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                Text(mark)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            }
            .foregroundStyle(lit || glow ? Color.black.opacity(0.8) : (dim ? Color.primary.opacity(0.35) : Color.primary.opacity(0.75)))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            if slot.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 5, weight: .bold))
                    .foregroundStyle(lit || glow ? Color.black.opacity(0.6) : Color.primary.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(2)
            }
        }
        .padding(1.5)
        .contentShape(Rectangle())
        .onHover { store.railHoveredCell = $0 ? cell : (store.railHoveredCell == cell ? nil : store.railHoveredCell) }
        .onTapGesture { if slot.navigable { store.press(index: slot.index) } }
        .animation(store.reduceMotion ? nil : .easeOut(duration: 0.15), value: lit)
        .help("\(slot.title): \(slot.subtitle)")
        .accessibilityLabel("Key \(slot.index + 1), \(slot.title), \(slot.subtitle)")
        .accessibilityAddTraits(slot.navigable ? .isButton : [])
    }
}

/// The "…" cell: opens the Control Center on this bank.
struct RailOverflowCell: View {
    @Bindable var store: DeckStore
    let cell: Int

    private var hovered: Bool { store.railHoveredCell == cell }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(hovered ? 0.2 : 0.1))
            Text("…")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.8))
        }
        .padding(1.5)
        .contentShape(Rectangle())
        .onHover { store.railHoveredCell = $0 ? cell : (store.railHoveredCell == cell ? nil : store.railHoveredCell) }
        .onTapGesture { store.onOpenControlCenter?() }
        .help("Open Control Center, \(store.banks.title.lowercased())")
        .accessibilityLabel("Open Control Center, \(store.banks.title.lowercased())")
        .accessibilityAddTraits(.isButton)
    }
}

struct RailLabelView: View {
    let title: String
    let subtitle: String
    let provider: String?
    let number: String

    var body: some View {
        HStack(spacing: 8) {
            if let provider, !provider.isEmpty {
                ProviderTile(style: ProviderStyle.style(for: provider), size: 18)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Text(number)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .fixedSize()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
