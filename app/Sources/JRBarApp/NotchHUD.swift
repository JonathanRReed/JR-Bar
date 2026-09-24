import AppKit
import JRBarCore
import OSLog
import SwiftUI

/// The Mac's own announcements at the top of the screen — a level key's
/// answer, a Focus, a device, Caps Lock, a display, "SidePulse
/// connected". The notch island is the one announcer: each is offered
/// to it first (`islandPresent`), where it morphs out of the notch in
/// black through the same capsule queue as the agents' news. Only when
/// the island cannot take it — not ours, parked, grown into the card, an
/// ask's buttons holding it, a waiting capsule that outranks it — does
/// the brief glass pill hang under the band instead. Click-through,
/// never key, gone after its beat.
@MainActor
final class NotchHUD {
    static let life: TimeInterval = 2.0
    static let log = Logger(subsystem: "devin.jrbar", category: "hud")

    /// The media-key tap feeding the level capsules. It watches the
    /// session's system-defined stream and never swallows a press —
    /// `mediaHUDAllowed` (the notch's setting) is consulted per press.
    let mediaKeys = HUDKeyMonitor()
    /// Focus toggles, Bluetooth connects and disconnects, Caps Lock and
    /// displays.
    let announcements = NotchAnnouncements()
    /// The notch settings' vote on media capsules, wired by the delegate.
    var mediaHUDAllowed: () -> Bool = { true }
    /// The notch settings' votes on announcements and the felt tick.
    var alertsAllowed: () -> Bool = { true }
    var soundEffectsAllowed: () -> Bool = { true }
    /// The island's door (`NotchToy.presentSystemNotice`): true when it
    /// will say the notice, and the pill stays down; false whenever it
    /// would not, so nothing falls between the two. The coordinator
    /// wires it; unwired, everything takes the pill.
    var islandPresent: @MainActor (AlcoveNotice) -> Bool = { _ in false }
    /// How long a level or toast holds — the notch's "HUD duration".
    var hudLife: @MainActor () -> TimeInterval = { NotchHUD.life }
    /// Whether the Screen Bar's ear already announces the audio route —
    /// then a headphone connect is its news, and saying it here too
    /// would be the same thing twice.
    var earAnnouncesAudioRoute: @MainActor () -> Bool = { false }

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
        announcements.isAllowed = { [weak self] in self?.alertsAllowed() ?? true }
        announcements.earAnnouncesAudioRoute = { [weak self] in self?.earAnnouncesAudioRoute() ?? false }
        announcements.announce = { [weak self] notice in self?.announce(notice) }
    }

    /// One announcement: the island first, the pill when it can't.
    func announce(_ notice: AlcoveNotice) {
        if islandPresent(notice) {
            tick()
            return
        }
        pill(notice.subtitle.isEmpty ? notice.title : "\(notice.title) · \(notice.subtitle)",
             symbol: notice.symbol)
    }

    /// The island said yes to `notice`, then gave its waiting slot to
    /// newer news (`NotchToy.onCapsuleEvicted`): the pill says it now,
    /// so an announcement never falls between the two after all. Only
    /// the Mac's own announcements are the HUD's to say. Silently: the
    /// tick went with the island's yes.
    func islandDropped(_ notice: AlcoveNotice) {
        guard notice.kind.isMacAnnouncement else { return }
        pill(notice.subtitle.isEmpty ? notice.title : "\(notice.title) · \(notice.subtitle)",
             symbol: notice.symbol, ticks: false)
    }

    /// Everything that reaches outside the process — the media-key tap,
    /// the Focus, Bluetooth, Caps Lock and display watchers — starts
    /// here, never in init: the delegate calls it once the real notch
    /// gates are wired, and a HUD built anywhere else touches nothing.
    /// IOBluetooth's connect registration is a TCC ask that kills a
    /// process with no Bluetooth usage string — `swift test`'s helper
    /// is one, and a coordinator built in a test took the suite down.
    func startSystemWatchers() {
        syncMediaTap()
        announcements.start()
    }

    /// The tap exists only while the notch can draw capsules —
    /// `mediaHUDAllowed` is the union gate (the consuming tap's
    /// `replaceHUDWanted` implies it), so a disabled notch leaves no
    /// event tap sitting on the session's system-defined stream.
    /// Called from `startSystemWatchers`, then on every notch-settings
    /// reconcile so a flip takes without waiting for the next press.
    func syncMediaTap() {
        if mediaHUDAllowed() { mediaKeys.start() } else { mediaKeys.stop() }
    }

    private func tick() {
        if soundEffectsAllowed() { NotchSounds.tick() }
    }

    /// A one-line toast — "SidePulse connected", "Agent hooks
    /// installed". It is an announcement like any other: the island
    /// speaks it when it can.
    func show(_ text: String, symbol: String = "cable.connector") {
        announce(AlcoveNotice(id: UUID().uuidString, kind: .device, title: text, subtitle: "",
                              key: "toast:\(text)", glyph: symbol))
    }

    /// The glass pill under the band — the fallback voice.
    private func pill(_ text: String, symbol: String, ticks: Bool = true) {
        let band = anchorRect() ?? Self.fallbackAnchor()
        panel.present(text: text, symbol: symbol, under: band)
        if ticks { tick() }
        armHide()
    }

    private func armHide() {
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.panel.dismiss() } }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hudLife(), execute: work)
    }

    /// A volume, brightness or backlight key press: the level grows out
    /// of the notch as one continuous fill — the Alcove HUD in the
    /// island's own black. The glyph is the device the sound is going
    /// to. Where the island can't take it the pill carries the same
    /// continuous fill. A key we cannot read (an output with no hardware
    /// volume, a desk of externals) draws nothing.
    private func showMeter(for key: MediaKeyPress.Key, value: Float?, muted: Bool?) {
        guard let value else { return }
        let level = min(1, max(0, value))
        let isMuted = muted == true
        let symbol: String
        var deviceName: String?
        let target: NotchLevelScrub.Target
        switch key {
        case .volumeUp, .volumeDown, .mute:
            let route = SystemLevelReader.outputRoute()
            deviceName = route?.name
            symbol = NotchLevelGlyph.volume(level: level, muted: isMuted,
                                            transport: route?.transport, name: route?.name)
            target = .volume
        case .brightnessUp, .brightnessDown:
            symbol = NotchLevelGlyph.brightness(level: level)
            target = .brightness
        case .illuminationUp, .illuminationDown, .illuminationToggle:
            symbol = NotchLevelGlyph.keyboard
            target = .keyboard
        }
        // The key names which level this is, so a scroll over the
        // capsule knows what it is setting.
        let notice = AlcoveNotice(id: UUID().uuidString, kind: .level,
                                  title: NotchLevelGlyph.title(for: key, deviceName: deviceName),
                                  subtitle: "", key: NotchLevelScrub.key(for: target), glyph: symbol,
                                  fraction: Double(level), muted: isMuted)
        if islandPresent(notice) {
            tick()
            return
        }
        let band = anchorRect() ?? Self.fallbackAnchor()
        panel.presentMeter(symbol: symbol, fraction: Double(level), muted: isMuted, under: band)
        tick()
        armHide()
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
        NotchSurfaceMotion.present(self, settle: wasVisible ? 0 : 6, duration: 0.22, reducedDuration: 0.1)
    }

    /// The fallback level capsule — a media key's answer where the
    /// island can't take it: the symbol and one continuous fill. Wider
    /// than a text toast, so the meter reads.
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
        NotchSurfaceMotion.present(self, settle: wasVisible ? 0 : 6,
                                   duration: wasVisible ? 0.12 : 0.22, reducedDuration: 0.1)
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
        NotchSurfaceMotion.dismiss(self, duration: 0.2, reducedDuration: 0.08)
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
            // The level capsule: the key's symbol, then one continuous
            // fill — the unbroken language the Screen Bar speaks, never
            // a row of segments.
            // The HUD material follows the appearance, so the fill is the
            // label colour rather than the island's white.
            HStack(spacing: 10) {
                Image(systemName: meter.symbol, variableValue: meter.muted ? nil : meter.fraction)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(meter.muted ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                    .frame(width: 20)
                NotchLevelBar(fraction: meter.fraction,
                              tint: meter.muted ? .red : .primary,
                              track: .primary.opacity(0.14), dimmed: meter.muted, glows: false)
                    .frame(width: 112)
                    .animation(.smooth(duration: 0.16), value: meter.fraction)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .fixedSize()
        } else if model.toastActive {
            HStack(spacing: 8) {
                Image(systemName: model.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
                Text(model.text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .fixedSize()
        } else if let buddy = model.buddy, buddy.isShowing, !buddy.isFree {
            // The docked slot is the pet itself: the character with its
            // poses, tricks, treats and badges at the notch's fixed
            // 18pt — stepping back to the bare dot only while a
            // screen_bar program is playing (the slot is the strip's
            // extra seam LED) or Mini is picked. Its name tag exists
            // only under the pointer; the space stays reserved so the
            // figure never jumps.
            VStack(spacing: 1) {
                NotchBuddyView(toy: buddy, docked: true)
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
