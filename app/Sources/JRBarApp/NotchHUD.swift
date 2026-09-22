import AppKit
import JRBarCore
import OSLog
import SwiftUI

/// A brief glass pill under the notch: "SidePulse connected". Click-through,
/// never key, gone after two seconds.
@MainActor
final class NotchHUD {
    static let life: TimeInterval = 2.0
    static let log = Logger(subsystem: "devin.jrbar", category: "hud")

    /// The media-key tap feeding the level capsules. It watches the
    /// session's system-defined stream and never swallows a press —
    /// `mediaHUDAllowed` (the notch's setting) is consulted per press.
    let mediaKeys = HUDKeyMonitor()
    /// Focus toggles and Bluetooth connects, announced in the pill.
    let announcements = NotchAnnouncements()
    /// The notch settings' vote on media capsules, wired by the delegate.
    var mediaHUDAllowed: () -> Bool = { true }
    /// The notch settings' votes on announcements and the felt tick.
    var alertsAllowed: () -> Bool = { true }
    var soundEffectsAllowed: () -> Bool = { true }

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
        mediaKeys.isAllowed = { [weak self] in self?.mediaHUDAllowed() ?? true }
        mediaKeys.onLevel = { [weak self] key, value, muted in
            self?.showMeter(for: key, value: value, muted: muted)
        }
        // The tap's license is the capsule's — installed only while the
        // notch wants capsules, so a disabled notch leaves no event tap
        // sitting on the session's system-defined stream.
        syncMediaTap()
        announcements.isAllowed = { [weak self] in self?.alertsAllowed() ?? true }
        announcements.announce = { [weak self] text, symbol in self?.show(text, symbol: symbol) }
        announcements.start()
    }

    /// The tap exists only while the notch can draw capsules —
    /// `mediaHUDAllowed` is the union gate (the consuming tap's
    /// `replaceHUDWanted` implies it). Called at init, once more after
    /// the delegate wires the real gate, and on every notch-settings
    /// reconcile so a flip takes without waiting for the next press.
    func syncMediaTap() {
        if mediaHUDAllowed() { mediaKeys.start() } else { mediaKeys.stop() }
    }

    private func tick() {
        if soundEffectsAllowed() { NotchSounds.tick() }
    }

    func show(_ text: String, symbol: String = "cable.connector") {
        let band = anchorRect() ?? Self.fallbackAnchor()
        panel.present(text: text, symbol: symbol, under: band)
        tick()
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.panel.dismiss() } }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.life, execute: work)
    }

    /// A volume or brightness key press: the level capsule hangs under
    /// the notch — the Alcove HUD. A key we cannot read (an output
    /// with no hardware volume, a desk of externals) draws nothing.
    private func showMeter(for key: MediaKeyPress.Key, value: Float?, muted: Bool?) {
        let symbol: String
        switch key {
        case .volumeUp, .volumeDown, .mute:
            symbol = muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .brightnessUp, .brightnessDown:
            symbol = "sun.max.fill"
        case .illuminationUp, .illuminationDown, .illuminationToggle:
            symbol = "keyboard"
        }
        guard let value else { return }
        let band = anchorRect() ?? Self.fallbackAnchor()
        panel.presentMeter(symbol: symbol, fraction: Double(min(1, max(0, value))),
                           muted: muted == true, under: band)
        tick()
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
        let depth = screen.map { ScreenBarGeometry.islandDepth(of: $0) } ?? 0
        let slot = screen.flatMap { ScreenBarGeometry.islandSlot(on: $0) }
        let width = slot?.width ?? screen.map { ScreenBarGeometry.slotWidth(of: $0) } ?? 180
        let centerX = slot?.centerX ?? frame.midX
        return NSRect(x: centerX - width / 2, y: frame.maxY - depth - 8, width: width, height: 6)
    }

    /// The vertical room the HUD panel claims under the band — docked
    /// buddy or toast — so the peek hangs below it instead of landing
    /// on it. 0 while the panel is away.
    var panelClearance: CGFloat {
        guard panel.isVisible, let bandBottom = panel.bandBottom else { return 0 }
        return bandBottom - panel.frame.minY + 4
    }

    /// The HUD panel's occupied frame under the band — part of the
    /// peek's hover corridor, so crossing the buddy on the way to the
    /// card never counts as leaving.
    var panelFrame: NSRect? {
        panel.isVisible ? panel.frame : nil
    }
}

@MainActor
final class NotchHUDPanel: NSPanel {
    private let hosting: BuddyHostingView<NotchHUDView>
    /// The toast's backing: quiet HUD material. The material rule —
    /// Liquid Glass only on surfaces that visibly float off the notch —
    /// is the drop-down card's (`NotchCardPanel`); the toast keeps its
    /// HUD chrome, and the buddy does not wear it — a pet hangs under
    /// the notch bare, or it reads as a blob crowding the menu bar.
    private let chrome: NSVisualEffectView
    /// The buddy's container: nothing but the hosting view on a clear
    /// window, so the creature floats instead of sitting in a pill.
    private let clear = NSView()
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
        // The hosting view moves between the two containers, so it fills
        // whichever one it is in by autoresizing rather than constraints.
        hosting.autoresizingMask = [.width, .height]
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 15
        effect.layer?.masksToBounds = true
        chrome = effect
        super.init(contentRect: NSRect(x: 0, y: 0, width: 160, height: 30), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hosting.onHoverChange = { [weak self] in self?.model.hovered = $0 }
        clear.frame = NSRect(x: 0, y: 0, width: 160, height: 30)
        clear.addSubview(hosting)
        contentView = clear
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
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

    /// Which container holds the hosting view: the material-backed
    /// chrome for a toast, the clear view for the buddy. The shadow
    /// belongs to the chrome — a bare pet keeps none.
    private func wearChrome(_ on: Bool) {
        let container: NSView = on ? chrome : clear
        if hosting.superview !== container {
            hosting.removeFromSuperview()
            container.addSubview(hosting)
            hosting.frame = container.bounds
        }
        if contentView !== container { contentView = container }
        hasShadow = on
    }

    func present(text: String, symbol: String, under band: NSRect) {
        // A toast takes the panel even out from under a carry — the
        // buddy stays wherever the settings say it lives.
        buddyDrag?.cancel()
        model.text = text
        model.symbol = symbol
        model.meter = nil
        model.toastActive = true
        // A toast is a sign, not a button: clicks fall straight through.
        ignoresMouseEvents = true
        lastBand = band
        wearChrome(true)
        hosting.rootView = NotchHUDView(model: model)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let height = max(30, size.height)
        let width = max(80, size.width)
        chrome.layer?.cornerRadius = height / 2
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

    /// The level capsule — a media key's answer: the symbol and the
    /// segmented bar. Wider than a text toast, so the meter reads.
    func presentMeter(symbol: String, fraction: Double, muted: Bool, under band: NSRect) {
        buddyDrag?.cancel()
        model.meter = NotchHUDModel.Meter(symbol: symbol, fraction: fraction, muted: muted)
        model.toastActive = true
        ignoresMouseEvents = true
        lastBand = band
        wearChrome(true)
        hosting.rootView = NotchHUDView(model: model)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let height = max(30, size.height)
        let width = max(150, size.width)
        chrome.layer?.cornerRadius = height / 2
        let origin = NSPoint(x: (band.midX - width / 2).rounded(), y: (band.minY - 10 - height).rounded())
        let wasVisible = isVisible && alphaValue > 0.01
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        orderFrontRegardless()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !wasVisible, !reduced { setFrameOrigin(NSPoint(x: origin.x, y: origin.y + 6)) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.1 : (wasVisible ? 0.12 : 0.22)
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            animator().alphaValue = 1
            if !wasVisible, !reduced { animator().setFrameOrigin(origin) }
        }
    }

    /// The buddy's own slot: the pet bare under the notch, sized to the
    /// creature. No-op while a toast is up — the toast always wins the
    /// panel. The buddy is a pet: it takes the clicks a toast would let
    /// fall through.
    func presentBuddy(under band: NSRect) {
        guard !model.toastActive else { return }
        // A carry owns the frame until the drop lands it.
        guard buddyDrag?.inProgress != true else { return }
        ignoresMouseEvents = false
        lastBand = band
        wearChrome(false)
        hosting.rootView = NotchHUDView(model: model)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let height = max(26, size.height)
        let width = max(30, size.width)
        let origin = NSPoint(x: (band.midX - width / 2).rounded(), y: (band.minY - 10 - height).rounded())
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        orderFrontRegardless()
        animator().alphaValue = 1
    }

    /// The bottom edge of the band the pill last hung under.
    var bandBottom: CGFloat? { lastBand?.minY }

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
    /// A volume/brightness capsule's payload — a symbol and the level
    /// it landed on.
    struct Meter: Equatable {
        var symbol: String
        /// The level, 0…1.
        var fraction: Double
        /// A muted meter draws the slashed speaker and a dimmed bar.
        var muted: Bool = false
    }

    var text = ""
    var symbol = "cable.connector"
    /// A level capsule is occupying the pill instead of words.
    var meter: Meter?
    /// A toast is occupying the pill; the buddy steps aside until it ends.
    var toastActive = false
    /// The Notch Buddy the panel hosts while no toast is up.
    var buddy: NotchBuddyToy?
    /// The pointer is on the pet — its name tag only shows while it is.
    var hovered = false
}

struct NotchHUDView: View {
    @Bindable var model: NotchHUDModel

    var body: some View {
        if model.toastActive, let meter = model.meter {
            // The level capsule: the key's symbol, then the segmented
            // bar — sixteen steps like the system's own meter.
            HStack(spacing: 10) {
                Image(systemName: meter.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(meter.muted ? .red : .secondary)
                HStack(spacing: 2.5) {
                    let lit = Int((meter.fraction * 16).rounded())
                    ForEach(0..<16, id: \.self) { i in
                        Capsule(style: .continuous)
                            .fill(i < lit
                                  ? (meter.muted ? Color.red.opacity(0.85) : Color.white.opacity(0.92))
                                  : Color.white.opacity(0.22))
                            .frame(width: 5, height: 8)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .fixedSize()
        } else if model.toastActive {
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
        } else if let buddy = model.buddy, buddy.isOn, !buddy.isFree {
            // The docked slot is the status dot — compact beside the
            // notch. Its name tag exists only under the pointer; the
            // space stays reserved so the dot never jumps.
            VStack(spacing: 1) {
                NotchBuddyView(toy: buddy, compact: true)
                Text(model.hovered ? buddy.caption() : " ")
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 130)
                    .frame(height: 9)
                    .opacity(model.hovered ? 1 : 0)
            }
        }
    }
}
