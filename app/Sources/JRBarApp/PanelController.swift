import AppKit
import JRBarCore
import QuartzCore
import SwiftUI

/// The floating panel under the status item. Non-activating so the app
/// never steals focus, but key while open so arrows, Return and Esc work;
/// it closes on a click anywhere else, on Esc, and when it resigns key.
///
/// Glass: `NSGlassEffectView` carries the SwiftUI tree; set
/// `JRBAR_PLAIN_MATERIAL=1` to fall back to an `NSVisualEffectView`.
@MainActor
final class PanelController {
    static let cornerRadius: CGFloat = 14
    static let gapBelowStatusItem: CGFloat = 5

    private let store: PanelStore
    private let panel: FloatingPanel
    private let hosting: NSHostingView<PanelView>
    private let backdrop: NSView
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var anchorProvider: (@MainActor () -> NSRect?)?
    private var whyPopover: WhyDetailPanel?
    private var whyHide: DispatchWorkItem?
    private var openedAt = Date.distantPast
    var onOpenStateChange: (@MainActor (Bool) -> Void)?
    private(set) var isOpen = false { didSet { if isOpen != oldValue { onOpenStateChange?(isOpen) } } }

    init(store: PanelStore) {
        self.store = store
        hosting = NSHostingView(rootView: PanelView(store: store))
        // The window is sized from `PanelLayout`, never from the view: the
        // hosting view just fills whatever frame the window has.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let plain = ProcessInfo.processInfo.environment["JRBAR_PLAIN_MATERIAL"] != nil
        if !plain {
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: PanelView.width, height: 200))
            glass.cornerRadius = Self.cornerRadius
            glass.style = .regular
            glass.contentView = hosting
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: PanelView.width, height: 200))
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.cornerRadius
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            effect.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            backdrop = effect
        }

        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: 200))
        panel.contentView = backdrop
        panel.onResignKey = { [weak self] in self?.close() }

        store.onClose = { [weak self] in self?.close() }
        store.onLayoutChange = { [weak self] layout in self?.fit(to: layout) }
        store.onWhyHover = { [weak self] hovering, frame in self?.whyHover(hovering, frame: frame) }
    }

    // MARK: "Why this light" popover

    /// A child window (never key, so the panel keeps the keyboard) hanging
    /// under the row with the programs and the brightness settings.
    private func whyHover(_ hovering: Bool, frame: CGRect) {
        whyHide?.cancel()
        whyHide = nil
        guard hovering, isOpen, let explanation = store.lightExplanation else {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hideWhyPopover() } }
            whyHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            return
        }
        let popover = whyPopover ?? WhyDetailPanel()
        whyPopover = popover
        // SwiftUI's global space is the hosting view's (flipped) space.
        let inWindow = hosting.convert(frame, to: nil)
        let onScreen = panel.convertToScreen(inWindow)
        popover.present(explanation, anchoredTo: onScreen, panelFrame: panel.frame, reduced: store.reduceMotion)
        if popover.parent == nil { panel.addChildWindow(popover, ordered: .above) }
    }

    /// Screenshot aid (`JRBAR_OPEN_PANEL=why`): shows the popover as if the row were hovered.
    func showWhyPopover() {
        whyHover(true, frame: store.whyRowFrame)
    }

    private func hideWhyPopover() {
        guard let whyPopover, whyPopover.isVisible else { return }
        whyPopover.dismiss { [weak self] in
            guard let self, let popover = self.whyPopover, !popover.isVisible || popover.alphaValue < 0.01 else { return }
            self.panel.removeChildWindow(popover)
            popover.orderOut(nil)
        }
    }

    /// Where the status item is, in screen coordinates, for anchoring.
    func setAnchorProvider(_ provider: @escaping @MainActor () -> NSRect?) {
        anchorProvider = provider
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        store.panelDidOpen()
        // Size once, from the content, before anything is on screen.
        let screen = screenForAnchor()
        store.screenHeight = Double(screen?.visibleFrame.height ?? 900)
        let layout = store.layout
        let frame = frameFor(height: CGFloat(layout.totalHeight), screen: screen)
        panel.setFrame(frame, display: false)
        hosting.layoutSubtreeIfNeeded()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        openedAt = Date()
        logFrame("t=0 (target)", frame)

        let reduced = store.reduceMotion
        let rise: CGFloat = reduced ? 0 : 6
        if rise > 0 {
            panel.setFrameOrigin(NSPoint(x: frame.origin.x, y: frame.origin.y + rise))
        }
        let duration = reduced ? PanelMotion.reducedDuration : PanelMotion.unfoldDuration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().alphaValue = 1
            // NSWindow's animator animates `setFrame(_:display:)`, not `setFrameOrigin`.
            if rise > 0 { panel.animator().setFrame(frame, display: true) }
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isOpen else { return }
                // The rise ends exactly on the computed frame, whatever the animator did.
                if self.panel.frame != frame { self.panel.setFrame(frame, display: true) }
                // From here on, data changes may animate.
                self.store.animationsArmed = true
            }
        })
        let opened = openedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOpen, self.openedAt == opened else { return }
                self.logFrame("t=1s", self.panel.frame)
            }
        }
    }

    /// One line per open on stdout ("panel frame t=0 (target): …", then
    /// "t=1s"), so a run can prove the frame never moved after opening.
    private func logFrame(_ label: String, _ frame: NSRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let f = String(format: "x=%.0f y=%.0f w=%.0f h=%.0f top=%.0f", frame.origin.x, frame.origin.y, frame.width, frame.height, primaryHeight - frame.maxY)
        print("panel frame \(label): \(f) rows=\(store.rows.count) usage=\(store.usage.count) window=\(panel.windowNumber)")
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        removeMonitors()
        if let whyPopover, whyPopover.parent != nil {
            panel.removeChildWindow(whyPopover)
            whyPopover.orderOut(nil)
        }
        store.panelDidClose()
        let reduced = store.reduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduced ? 0.08 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    // MARK: Geometry

    private func screenForAnchor() -> NSScreen? {
        let anchor = anchorProvider?()
        return anchor.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func frameFor(height: CGFloat, screen: NSScreen?) -> NSRect {
        let anchor = anchorProvider?()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = PanelView.width
        let height = min(height, visible.height - 12)
        var x = (anchor?.midX ?? visible.midX) - width / 2
        x = min(visible.maxX - width - 6, max(visible.minX + 6, x))
        let top = (anchor?.minY ?? visible.maxY) - Self.gapBelowStatusItem
        let y = max(visible.minY + 6, top - height)
        return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height.rounded())
    }

    /// The content changed shape while open: resize to the new layout,
    /// animated only once the panel has finished arriving.
    private func fit(to layout: PanelLayout) {
        guard isOpen else { return }
        let frame = frameFor(height: CGFloat(layout.totalHeight), screen: screenForAnchor())
        if abs(panel.frame.height - frame.height) < 0.5, abs(panel.frame.origin.x - frame.origin.x) < 0.5 { return }
        guard store.animationsArmed, !store.reduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().setFrame(frame, display: true)
        }
    }

    // MARK: Event monitors

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleLocal(event)
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handleLocal(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A click in one of our other windows (the status item's button,
            // the click-through bar) closes the panel; the status item
            // itself toggles, so let its click through untouched.
            if event.window !== panel {
                if let anchor = anchorProvider?(), let window = event.window {
                    let point = window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
                    if anchor.contains(point) { return event }
                }
                close()
            }
            return event
        case .keyDown:
            guard event.window === panel || panel.isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "q" {
                store.quit()
                return nil
            }
            if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "y" {
                store.openHistory()
                return nil
            }
            if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "u" {
                store.openUsageCenter()
                return nil
            }
            if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "k" {
                store.openControlCenter()
                return nil
            }
            if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "d",
               store.keyboardAsk != nil {
                // ⌘D answers the selected ask card (the first, when none is
                // selected) — registered once here, not once per ask row.
                store.denySelectedAsk()
                return nil
            }
            switch event.keyCode {
            case 53: close(); return nil                            // Esc
            case 125: store.moveSelection(by: 1); return nil       // Down
            case 126: store.moveSelection(by: -1); return nil      // Up
            case 36, 76:                                            // Return / keypad Enter
                if flags.contains(.command) {
                    if store.keyboardAsk != nil { store.approveSelectedAsk(); return nil }
                    return event
                }
                if flags.isEmpty { store.activateSelection(); return nil }
                return event
            case 48:                                                // Tab: keep focus inside
                store.moveSelection(by: flags.contains(.shift) ? -1 : 1); return nil
            default: return event
            }
        default:
            return event
        }
    }
}

/// A borderless, non-activating panel that can still become key.
@MainActor
final class FloatingPanel: NSPanel {
    var onResignKey: (@MainActor () -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        level = .popUpMenu
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        onResignKey?()
    }
}

/// The hover popover for "Why this light": glass, click-through, a child
/// of the panel so it never takes the keyboard away.
@MainActor
final class WhyDetailPanel: NSPanel {
    private let hosting: NSHostingView<WhyDetailView>
    private let backdrop: NSView
    private let model = WhyDetailModel()
    static let width: CGFloat = 300

    init() {
        hosting = NSHostingView(rootView: WhyDetailView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        let plain = ProcessInfo.processInfo.environment["JRBAR_PLAIN_MATERIAL"] != nil
        if !plain {
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 120))
            glass.cornerRadius = 10
            glass.style = .regular
            glass.contentView = hosting
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 120))
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 10
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
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        level = .popUpMenu
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(_ explanation: LightExplanation, anchoredTo row: NSRect, panelFrame: NSRect, reduced: Bool) {
        model.explanation = explanation
        hosting.rootView = WhyDetailView(model: model)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let height = max(40, size.height)
        let width = Self.width
        let screen = NSScreen.screens.first { $0.frame.intersects(row) }?.visibleFrame ?? panelFrame
        var x = row.minX + 8
        x = min(screen.maxX - width - 6, max(screen.minX + 6, x))
        // Below the row when there is room, else above it.
        var y = row.minY - 6 - height
        if y < screen.minY + 6 { y = row.maxY + 6 }
        let origin = NSPoint(x: x.rounded(), y: y.rounded())
        let wasVisible = isVisible && alphaValue > 0.01
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        orderFront(nil)
        if !wasVisible, !reduced { setFrameOrigin(NSPoint(x: origin.x, y: origin.y + 4)) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.08 : 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            animator().alphaValue = 1
            if !wasVisible, !reduced { animator().setFrameOrigin(origin) }
        }
    }

    func dismiss(completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in completion() }
        })
    }
}

@MainActor
@Observable
final class WhyDetailModel {
    var explanation: LightExplanation?
}

struct WhyDetailView: View {
    @Bindable var model: WhyDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let explanation = model.explanation {
                HStack(spacing: 6) {
                    Image(systemName: "light.max").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(explanation.motion).font(.system(size: 12, weight: .semibold))
                    Text("· \(explanation.why.replacingOccurrences(of: "_", with: " "))")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Text(explanation.reason).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !explanation.details.isEmpty {
                    Rectangle().fill(.primary.opacity(0.08)).frame(height: 1).padding(.vertical, 2)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        ForEach(explanation.details) { detail in
                            GridRow {
                                Text(detail.label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                Text(detail.value).font(.system(size: 11)).foregroundStyle(.primary.opacity(0.85)).lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: WhyDetailPanel.width, alignment: .leading)
    }
}
