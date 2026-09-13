import AppKit
import SwiftUI

/// A brief glass pill under the notch: "SidePulse connected". Click-through,
/// never key, gone after two seconds.
@MainActor
final class NotchHUD {
    static let life: TimeInterval = 2.0

    private let panel = NotchHUDPanel()
    /// The buddy's other home: its own pill when a drag parks it on the
    /// screen. Toasts never touch it — they always take `panel` at the
    /// notch, so a toast can never fight the floating buddy for a panel.
    private let buddyPanel = BuddyPanel()
    /// The shared press-and-carry for whichever panel the buddy is in.
    private let buddyDrag = BuddyDragController()
    private var hide: DispatchWorkItem?
    /// Where the band sits, so the pill hangs a little below it; nil
    /// falls back to the top centre of the notched screen.
    var anchorRect: @MainActor () -> NSRect?

    /// The Notch Buddy that lives in the panel between toasts. A showing
    /// toast always wins — the buddy steps aside and comes back when the
    /// toast is done — so `syncBuddy` is only allowed to touch the panel
    /// while no toast is up.
    var buddy: NotchBuddyToy? {
        didSet {
            buddy?.onVisibilityChange = { [weak self] in self?.syncBuddy() }
            buddy?.dockPointProvider = { [weak self] in self?.dockPoint() ?? .zero }
            panel.buddy = buddy
            buddyPanel.host(buddy)
            buddyDrag.toy = buddy
            syncBuddy()
        }
    }

    init(anchorRect: @escaping @MainActor () -> NSRect?) {
        self.anchorRect = anchorRect
        panel.buddyDrag = buddyDrag
        buddyPanel.buddyDrag = buddyDrag
        buddyDrag.dockPoint = { [weak self] in self?.dockPoint() ?? .zero }
    }

    func show(_ text: String, symbol: String = "cable.connector") {
        let band = anchorRect() ?? Self.fallbackAnchor()
        panel.present(text: text, symbol: symbol, under: band)
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.panel.dismiss() } }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.life, execute: work)
    }

    /// Where the docked pill centres, in screen coordinates — the drop
    /// that snaps it home and "Float free"'s starting spot.
    private func dockPoint() -> CGPoint {
        let band = anchorRect() ?? Self.fallbackAnchor()
        return CGPoint(x: band.midX, y: band.minY - 24)
    }

    private func syncBuddy() {
        guard let buddy, buddy.isOn else {
            buddyPanel.dismiss()
            panel.dismissBuddy()
            return
        }
        if let spot = buddy.freeSpot {
            // Parked on screen: the HUD pill belongs to toasts alone.
            panel.dismissBuddy()
            buddyPanel.present(centeredAt: spot.point)
        } else {
            buddyPanel.dismiss()
            panel.presentBuddy(under: anchorRect() ?? Self.fallbackAnchor())
        }
    }

    static func fallbackAnchor() -> NSRect {
        let screen = ScreenBarGeometry.preferredScreen() ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let depth = screen.map { ScreenBarGeometry.notchDepth(of: $0) } ?? 0
        return NSRect(x: frame.midX - 90, y: frame.maxY - depth - 8, width: 180, height: 6)
    }
}

@MainActor
final class NotchHUDPanel: NSPanel {
    private let hosting: BuddyHostingView<NotchHUDView>
    private let backdrop: NSView
    private let model = NotchHUDModel()
    /// The band the pill last hung under, so a toast that is handing back
    /// to the buddy can re-centre without asking again.
    private var lastBand: NSRect?

    /// The buddy the panel hosts between toasts.
    var buddy: NotchBuddyToy? {
        get { model.buddy }
        set { model.buddy = newValue }
    }

    /// The press-and-carry the pill's mouse belongs to while the buddy
    /// holds the panel. A toast cancels it — the toast always wins.
    var buddyDrag: BuddyDragController? {
        get { hosting.buddyDrag }
        set { hosting.buddyDrag = newValue }
    }

    init() {
        hosting = BuddyHostingView(rootView: NotchHUDView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        let plain = ProcessInfo.processInfo.environment["JRBAR_PLAIN_MATERIAL"] != nil
        if !plain {
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
            glass.cornerRadius = 15
            glass.style = .regular
            glass.contentView = hosting
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 15
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
        super.init(contentRect: NSRect(x: 0, y: 0, width: 160, height: 30), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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

    func present(text: String, symbol: String, under band: NSRect) {
        // A toast takes the panel even out from under a carry — the
        // buddy stays wherever the settings say it lives.
        buddyDrag?.cancel()
        model.text = text
        model.symbol = symbol
        model.toastActive = true
        // A toast is a sign, not a button: clicks fall straight through.
        ignoresMouseEvents = true
        lastBand = band
        hosting.rootView = NotchHUDView(model: model)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let height = max(30, size.height)
        let width = max(80, size.width)
        (backdrop as? NSGlassEffectView)?.cornerRadius = height / 2
        backdrop.layer?.cornerRadius = height / 2
        let origin = NSPoint(x: (band.midX - width / 2).rounded(), y: (band.minY - 10 - height).rounded())
        let wasVisible = isVisible && alphaValue > 0.01
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        orderFrontRegardless()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !wasVisible, !reduced { setFrameOrigin(NSPoint(x: origin.x, y: origin.y + 6)) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.1 : 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            animator().alphaValue = 1
            if !wasVisible, !reduced { animator().setFrameOrigin(origin) }
        }
    }

    /// The buddy's own slot: the same pill, sized to the creature. No-op
    /// while a toast is up — the toast always wins the panel. The buddy
    /// is a pet: it takes the clicks a toast would let fall through.
    func presentBuddy(under band: NSRect) {
        guard !model.toastActive else { return }
        // A carry owns the frame until the drop lands it.
        guard buddyDrag?.inProgress != true else { return }
        ignoresMouseEvents = false
        lastBand = band
        hosting.rootView = NotchHUDView(model: model)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let height = max(26, size.height)
        let width = max(30, size.width)
        (backdrop as? NSGlassEffectView)?.cornerRadius = height / 2
        backdrop.layer?.cornerRadius = height / 2
        let origin = NSPoint(x: (band.midX - width / 2).rounded(), y: (band.minY - 10 - height).rounded())
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        orderFrontRegardless()
        animator().alphaValue = 1
    }

    /// The buddy was switched off while it held the panel. A toast in
    /// flight is left alone; it hands back (or out) in `dismiss`.
    func dismissBuddy() {
        guard !model.toastActive else { return }
        alphaValue = 0
        orderOut(nil)
    }

    func dismiss() {
        // A docked buddy that is on keeps the panel: the toast steps
        // away and the pill shrinks back to the creature instead of
        // disappearing. A free buddy lives in its own panel — this one
        // just fades.
        if model.buddy?.isOn == true, model.buddy?.isFree == false, let band = lastBand {
            model.toastActive = false
            presentBuddy(under: band)
            return
        }
        model.toastActive = false
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduced ? 0.08 : 0.2
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
final class NotchHUDModel {
    var text = ""
    var symbol = "cable.connector"
    /// A toast is occupying the pill; the buddy steps aside until it ends.
    var toastActive = false
    /// The Notch Buddy the panel hosts while no toast is up.
    var buddy: NotchBuddyToy?
}

struct NotchHUDView: View {
    @Bindable var model: NotchHUDModel

    var body: some View {
        if model.toastActive {
            HStack(spacing: 7) {
                Image(systemName: model.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(model.text)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .fixedSize()
        } else if let buddy = model.buddy, buddy.isOn {
            NotchBuddyView(toy: buddy)
        }
    }
}
