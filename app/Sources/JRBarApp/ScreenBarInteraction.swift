import AppKit
import QuartzCore
import SwiftUI

/// What the Screen Bar's tooltip says: the top-priority session, or the
/// aggregate when there is none.
struct ScreenBarFocus: Equatable {
    var style: ProviderStyle?
    var label: String
    var word: String
    /// The session a click opens; nil when nothing should be raised.
    var clickSession: String?
}

/// Hover and click for a click-through band. The panel keeps
/// `ignoresMouseEvents` so it never takes focus or blocks the menu bar;
/// instead an `NSEvent` monitor watches the pointer and hit-tests it against
/// the band's own rounded rect (the way codenotch does). Hovering shows a
/// transient glass pill under the band, clicking opens the session.
@MainActor
final class ScreenBarInteraction {
    static let hoverDelay: TimeInterval = 0.32
    /// The tooltip is a glance, not a label: it leaves on its own even if
    /// the pointer parks on the band.
    static let maxTooltipLife: TimeInterval = 4.0

    var bandRect: @MainActor () -> NSRect?
    var focus: @MainActor () -> ScreenBarFocus?
    var onOpen: @MainActor (String) -> Void

    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []
    private var hovering = false
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private let tooltip = ScreenBarTooltipPanel()
    private(set) var isTooltipShown = false
    private var lastFocus: ScreenBarFocus?

    init(bandRect: @escaping @MainActor () -> NSRect?, focus: @escaping @MainActor () -> ScreenBarFocus?, onOpen: @escaping @MainActor (String) -> Void) {
        self.bandRect = bandRect
        self.focus = focus
        self.onOpen = onOpen
    }

    func start() {
        guard globalMonitors.isEmpty else { return }
        // Global: events bound for other apps (the band is click-through, so
        // that is every pointer event over it while we are not active).
        // Local: the same events when this app happens to be active.
        if let moved = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pointerMoved() }
        } { globalMonitors.append(moved) }
        if let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pointerClicked() }
        } { globalMonitors.append(down) }
        if let moved = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            Task { @MainActor [weak self] in self?.pointerMoved() }
            return event
        } { localMonitors.append(moved) }
        if let down = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in self?.pointerClicked() }
            return event
        } { localMonitors.append(down) }
    }

    func stop() {
        for monitor in globalMonitors + localMonitors { NSEvent.removeMonitor(monitor) }
        globalMonitors = []
        localMonitors = []
        hovering = false
        hideTooltip()
    }

    /// The band moved (screen change): drop any tooltip and re-evaluate.
    func geometryChanged() {
        hideTooltip()
        hovering = false
        pointerMoved()
    }

    // MARK: Pointer

    private func pointerInsideBand() -> Bool {
        guard let rect = bandRect() else { return false }
        // The band is 6 pt tall; give the pointer a little slack below it so
        // it is reachable without pixel hunting, but never above the notch.
        let target = NSRect(x: rect.minX, y: rect.minY - 3, width: rect.width, height: rect.height + 3)
        return target.contains(NSEvent.mouseLocation)
    }

    private func pointerMoved() {
        let inside = pointerInsideBand()
        guard inside != hovering else {
            if inside, isTooltipShown, let current = focus(), current != lastFocus { showTooltip(current) }
            return
        }
        hovering = inside
        showWork?.cancel()
        if inside {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.hovering, let focus = self.focus() else { return }
                    self.showTooltip(focus)
                }
            }
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
        } else {
            hideTooltip()
        }
    }

    private func pointerClicked() {
        guard pointerInsideBand() else { return }
        hideTooltip()
        if let session = focus()?.clickSession {
            onOpen(session)
        }
    }

    // MARK: Tooltip

    private func showTooltip(_ focus: ScreenBarFocus) {
        guard let rect = bandRect() else { return }
        lastFocus = focus
        tooltip.present(focus, under: rect)
        isTooltipShown = true
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hideTooltip() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxTooltipLife, execute: work)
    }

    func hideTooltip() {
        showWork?.cancel()
        hideWork?.cancel()
        showWork = nil
        hideWork = nil
        guard isTooltipShown else { return }
        isTooltipShown = false
        tooltip.dismiss()
    }
}

/// The glass pill under the band. Click-through and never key.
@MainActor
final class ScreenBarTooltipPanel: NSPanel {
    private let hosting: NSHostingView<ScreenBarTooltipView>
    private let backdrop: NSView
    private var model = ScreenBarTooltipModel()

    init() {
        hosting = NSHostingView(rootView: ScreenBarTooltipView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        let plain = ProcessInfo.processInfo.environment["JRBAR_PLAIN_MATERIAL"] != nil
        if !plain {
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
            glass.cornerRadius = 13
            glass.style = .regular
            glass.contentView = hosting
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 13
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
        super.init(contentRect: NSRect(x: 0, y: 0, width: 120, height: 26), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func present(_ focus: ScreenBarFocus, under band: NSRect) {
        model.focus = focus
        hosting.rootView = ScreenBarTooltipView(model: model)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let height = max(26, size.height)
        let width = max(60, size.width)
        (backdrop as? NSGlassEffectView)?.cornerRadius = height / 2
        backdrop.layer?.cornerRadius = height / 2
        let origin = NSPoint(x: (band.midX - width / 2).rounded(), y: (band.minY - 7 - height).rounded())
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        let wasVisible = isVisible && alphaValue > 0.01
        setFrame(frame, display: true)
        orderFrontRegardless()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !wasVisible, !reduced {
            setFrameOrigin(NSPoint(x: origin.x, y: origin.y + 4))
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.1 : 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            animator().alphaValue = 1
            if !wasVisible, !reduced { animator().setFrameOrigin(origin) }
        }
    }

    func dismiss() {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduced ? 0.06 : 0.12
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

@MainActor
@Observable
final class ScreenBarTooltipModel {
    var focus = ScreenBarFocus(style: nil, label: "JR-Bar", word: "Idle", clickSession: nil)
}

struct ScreenBarTooltipView: View {
    @Bindable var model: ScreenBarTooltipModel

    var body: some View {
        HStack(spacing: 6) {
            if let style = model.focus.style {
                ProviderTile(style: style, size: 16)
            } else {
                Image(nsImage: StatusItemController.glyph())
                    .renderingMode(.template)
                    .foregroundStyle(.secondary)
            }
            Text(model.focus.label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Text("·").foregroundStyle(.tertiary)
            Text(model.focus.word)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, 7)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .fixedSize()
    }
}
