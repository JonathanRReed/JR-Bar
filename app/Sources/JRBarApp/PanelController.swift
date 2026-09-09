import AppKit
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
    var onOpenStateChange: (@MainActor (Bool) -> Void)?
    private(set) var isOpen = false { didSet { if isOpen != oldValue { onOpenStateChange?(isOpen) } } }

    init(store: PanelStore) {
        self.store = store
        hosting = NSHostingView(rootView: PanelView(store: store))
        hosting.sizingOptions = [.intrinsicContentSize]
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
        store.onContentSizeChange = { [weak self] size in self?.fit(to: size) }
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
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize.width > 0 ? hosting.fittingSize : NSSize(width: PanelView.width, height: 320)
        let frame = frameFor(size: size)
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        installMonitors()

        let reduced = store.reduceMotion
        let rise: CGFloat = reduced ? 0 : 6
        if rise > 0 {
            panel.setFrameOrigin(NSPoint(x: frame.origin.x, y: frame.origin.y + rise))
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? PanelMotion.reducedDuration : PanelMotion.unfoldDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
            if rise > 0 { panel.animator().setFrameOrigin(frame.origin) }
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        removeMonitors()
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

    private func frameFor(size: NSSize) -> NSRect {
        let anchor = anchorProvider?()
        let screen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = PanelView.width
        let height = min(size.height, visible.height - 12)
        var x = (anchor?.midX ?? visible.midX) - width / 2
        x = min(visible.maxX - width - 6, max(visible.minX + 6, x))
        let top = (anchor?.minY ?? visible.maxY) - Self.gapBelowStatusItem
        let y = max(visible.minY + 6, top - height)
        return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height.rounded())
    }

    private func fit(to size: CGSize) {
        guard isOpen, size.height > 0 else { return }
        let frame = frameFor(size: size)
        if abs(panel.frame.height - frame.height) < 0.5, abs(panel.frame.origin.x - frame.origin.x) < 0.5 { return }
        let reduced = store.reduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.0 : 0.18
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
            switch event.keyCode {
            case 53: close(); return nil                            // Esc
            case 125: store.moveSelection(by: 1); return nil       // Down
            case 126: store.moveSelection(by: -1); return nil      // Up
            case 36, 76:                                            // Return / keypad Enter
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
