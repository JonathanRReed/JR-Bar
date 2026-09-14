import AppKit
import JRBarCore
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// What the Screen Bar's tooltip says: the top-priority session, or the
/// aggregate when there is none.
struct ScreenBarFocus: Equatable {
    var style: ProviderStyle?
    var label: String
    var word: String
    /// The session a click opens; nil when nothing should be raised.
    var clickSession: String?
    /// "Why this light", as a second line.
    var explanation: String? = nil
}

/// Hover and click for a click-through band. The panel keeps
/// `ignoresMouseEvents` so it never takes focus or blocks the menu bar --
/// which is also why an `NSTrackingArea` cannot do this job (a tracking area
/// needs the window to take mouse events, and the band shares its strip of
/// screen with Alcove's capsule, so eating clicks there is not an option).
/// Instead an `NSEvent` monitor watches the pointer and hit-tests it against
/// the band's own rounded rect (the way codenotch does), coalesced to at
/// most one main-actor wake per `moveInterval` so a fast pointer does not
/// run the actor at mouse-event rate. Hovering shows a transient glass pill
/// under the band, clicking pins it open. A press dragged down is the
/// Alcove-style swipe — it expands the pinned card — and a press dragged
/// up while pinned collapses it; a click is simply a down+up that never
/// crossed the threshold, so it resolves on release instead of on down.
@MainActor
final class ScreenBarInteraction {
    /// Deliberate-intent delay: long enough that a pointer cutting across
    /// the notch never arms a peek, short enough that aiming at one feels
    /// immediate.
    static let hoverDelay: TimeInterval = 0.18
    /// Pointer moves are needed at ~20 Hz for hover; the raw stream is far
    /// denser than that.
    nonisolated static let moveInterval: TimeInterval = 0.05
    /// The peek is a glance, not a label: it leaves on its own while the
    /// pointer is away…
    static let maxTooltipLife: TimeInterval = 4.0
    /// …but a pointer parked on the card or the band keeps it — the card
    /// is reachable, so leaving must not make it vanish mid-crossing.
    static let lifeExtension: TimeInterval = 2.0
    /// Leaving the hit region gets this long to come back before the peek
    /// really goes — covers the dead pixel or two between the band, the
    /// chips and the card.
    static let closeGrace: TimeInterval = 0.30

    /// The hover zones in screen coordinates: the band plus each drawn
    /// wing chip — the drawn capsules, so hovering them is hovering us.
    var hitRects: @MainActor () -> [NSRect]
    /// The band's rect for anchoring the peek card (nil while hidden).
    var bandRect: @MainActor () -> NSRect?
    var focus: @MainActor () -> ScreenBarFocus?
    /// Extra room under the band another surface already claims — the
    /// docked buddy hangs there, so the peek drops below the pet instead
    /// of landing on it.
    var underBandClearance: @MainActor () -> CGFloat = { 0 }
    var onOpen: @MainActor (String) -> Void

    /// Points of vertical travel before a press-on-the-band becomes a
    /// swipe — small enough that a deliberate pull feels instant, large
    /// enough that a jittery click never fires it.
    nonisolated static let swipeThreshold: CGFloat = 14

    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []
    /// The monitor callback runs off-actor; a lock and one pending flag keep
    /// the coalescing there instead of paying a `Task` hop per event.
    private final class MoveGate: @unchecked Sendable {
        let lock = NSLock()
        var pending = false
    }
    nonisolated private let moveGate = MoveGate()
    private var hovering = false
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var lifeWork: DispatchWorkItem?
    private let tooltip = ScreenBarTooltipPanel()
    /// W12's persisted timers — surfaced so AppDelegate can wire the
    /// expiry notification into `NotificationBridge`.
    var timers: ShelfTimerModel { tooltip.model.timers }
    /// The peek/pinned card's model — surfaced so AppDelegate can wire
    /// the roster affordance into the Overview window.
    var tooltipModel: ScreenBarTooltipModel { tooltip.model }
    private(set) var isTooltipShown = false
    private var lastFocus: ScreenBarFocus?
    /// Escape-to-unpin while a pinned card is up: local covers the
    /// pointer having activated us, global covers every other app.
    private var pinnedKeyMonitors: [Any] = []

    init(hitRects: @escaping @MainActor () -> [NSRect],
         bandRect: @escaping @MainActor () -> NSRect?,
         focus: @escaping @MainActor () -> ScreenBarFocus?,
         onOpen: @escaping @MainActor (String) -> Void) {
        self.hitRects = hitRects
        self.bandRect = bandRect
        self.focus = focus
        self.onOpen = onOpen
        tooltip.model.onOpenSession = { [weak self] in
            guard let self, let session = self.tooltip.model.focus.clickSession else { return }
            self.unpin()
            self.onOpen(session)
        }
        tooltip.model.onClose = { [weak self] in self?.unpin() }
    }

    func start() {
        guard globalMonitors.isEmpty else { return }
        // Global: events bound for other apps (the band is click-through, so
        // that is every pointer event over it while we are not active).
        // Local: the same events when this app happens to be active.
        if let moved = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.schedulePointerMoved()
        } { globalMonitors.append(moved) }
        if let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor [weak self] in self?.pointerDown(at: point) }
        } { globalMonitors.append(down) }
        if let drag = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor [weak self] in self?.pointerDragged(to: point) }
        } { globalMonitors.append(drag) }
        if let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pointerReleased() }
        } { globalMonitors.append(up) }
        if let moved = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.schedulePointerMoved()
            return event
        } { localMonitors.append(moved) }
        if let down = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor [weak self] in self?.pointerDown(at: point) }
            return event
        } { localMonitors.append(down) }
        if let drag = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor [weak self] in self?.pointerDragged(to: point) }
            return event
        } { localMonitors.append(drag) }
        if let up = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            Task { @MainActor [weak self] in self?.pointerReleased() }
            return event
        } { localMonitors.append(up) }
    }

    func stop() {
        for monitor in globalMonitors + localMonitors { NSEvent.removeMonitor(monitor) }
        globalMonitors = []
        localMonitors = []
        hovering = false
        swipeStart = nil
        swipeFired = false
        hideTooltip()
    }

    /// The band moved (screen change): drop any tooltip and re-evaluate.
    func geometryChanged() {
        hideTooltip()
        hovering = false
        pointerMoved()
    }

    // MARK: Pointer

    /// At most one main-actor hop per `moveInterval` however fast the
    /// monitor stream is. `pointerMoved` reads `NSEvent.mouseLocation`
    /// rather than the event, so a dropped intermediate event is a dropped
    /// stale sample, not a dropped state.
    nonisolated private func schedulePointerMoved() {
        moveGate.lock.lock()
        let already = moveGate.pending
        moveGate.pending = true
        moveGate.lock.unlock()
        guard !already else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.moveInterval) { [weak self] in
            guard let self else { return }
            self.moveGate.lock.lock()
            self.moveGate.pending = false
            self.moveGate.lock.unlock()
            MainActor.assumeIsolated { self.pointerMoved() }
        }
    }

    /// Inside = the union of the band, the drawn wing chips, and — once it
    /// is up — the peek card itself. The slack around each chip is a
    /// couple of points so the edge is not a pixel hunt; the card gets a
    /// point too, so brushing its frame does not count as leaving.
    private func pointerInHitRegion() -> Bool {
        let point = NSEvent.mouseLocation
        if hitRects().contains(where: { $0.insetBy(dx: -2, dy: -3).contains(point) }) { return true }
        return isTooltipShown && tooltip.frame.insetBy(dx: -1, dy: -1).contains(point)
    }

    private func pointerMoved() {
        let inside = pointerInHitRegion()
        guard inside != hovering else {
            if inside, isTooltipShown, let current = focus(), current != lastFocus { showTooltip(current) }
            return
        }
        hovering = inside
        showWork?.cancel()
        showWork = nil
        hideWork?.cancel()
        hideWork = nil
        if inside {
            if isTooltipShown {
                // Back inside before the grace fired — the peek never went
                // anywhere; refresh it if the focus moved on.
                if let current = focus(), current != lastFocus { showTooltip(current) }
            } else {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.hovering, let focus = self.focus() else { return }
                        self.showTooltip(focus)
                    }
                }
                showWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
            }
        } else if isTooltipShown && !tooltip.isPinned {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hideTooltip() } }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeGrace, execute: work)
        }
    }

    /// What a click in the hit region does next — factored pure so the
    /// state machine is testable without a pointer (T46/T47):
    /// pinned + outside dismisses; pinned + inside is the card's own
    /// buttons; not pinned + inside pins (deliberate focus entry).
    enum ClickOutcome { case pin, unpin, cardButton, none }

    nonisolated static func clickOutcome(pinned: Bool, inside: Bool) -> ClickOutcome {
        if pinned { return inside ? .cardButton : .unpin }
        return inside ? .pin : .none
    }

    /// What a vertical drag that started on the band becomes — pure so
    /// the gesture's truth table is testable without a pointer: down
    /// expands an unpinned band, up collapses a pinned card, anything
    /// else or below the threshold is still just a click pending.
    /// `deltaY` is in screen coordinates — upward positive.
    enum SwipeOutcome { case expand, collapse, none }

    nonisolated static func swipeOutcome(pinnedAtDown: Bool, deltaY: CGFloat) -> SwipeOutcome {
        if deltaY <= -swipeThreshold { return pinnedAtDown ? .none : .expand }
        if deltaY >= swipeThreshold { return pinnedAtDown ? .collapse : .none }
        return .none
    }

    /// Where the press started, whether the card was pinned then, and
    /// whether the drag already fired its outcome — one pending press
    /// at a time; a down outside the region never arms one.
    private var swipeStart: NSPoint?
    private var swipePinnedAtDown = false
    private var swipeFired = false

    private func pointerDown(at point: NSPoint) {
        if pointerInHitRegion() {
            // Inside: the press might become a swipe — the click resolves
            // on release instead.
            swipeStart = point
            swipePinnedAtDown = tooltip.isPinned
            swipeFired = false
        } else {
            swipeStart = nil
            // Outside: only the dismiss-a-pinned-card case, and it wants
            // the press, not the release.
            if tooltip.isPinned { unpin() }
        }
    }

    private func pointerDragged(to point: NSPoint) {
        guard let start = swipeStart, !swipeFired else { return }
        switch Self.swipeOutcome(pinnedAtDown: swipePinnedAtDown, deltaY: point.y - start.y) {
        case .expand:
            swipeFired = true
            pinCard()
        case .collapse:
            swipeFired = true
            unpin()
        case .none:
            return
        }
    }

    private func pointerReleased() {
        let wasSwipe = swipeFired
        swipeStart = nil
        swipeFired = false
        guard !wasSwipe else { return }
        // A press that never crossed the threshold is the click it always
        // was — pinned cards route inside clicks to their buttons, so
        // only the pin path is left to resolve here.
        if !tooltip.isPinned, pointerInHitRegion() { pinCard() }
    }

    /// Deliberate focus entry: a click or swipe pins the peek open as an
    /// interactive card — Open session lives on the card, so a stray
    /// band click never yanks a terminal forward.
    private func pinCard() {
        guard let focus = focus() ?? lastFocus else { return }
        lastFocus = focus
        showWork?.cancel(); showWork = nil
        hideWork?.cancel(); hideWork = nil
        lifeWork?.cancel(); lifeWork = nil
        if !isTooltipShown { showTooltip(focus) }
        setPinned(true)
    }

    private func setPinned(_ pinned: Bool) {
        tooltip.setPinned(pinned)
        for monitor in pinnedKeyMonitors { NSEvent.removeMonitor(monitor) }
        pinnedKeyMonitors = []
        guard pinned else { return }
        // Escape unpins: the card never becomes key (nonactivating), so
        // watch for it — local when we are active, global when we are not.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in self?.unpin() }
                return nil
            }
            return event
        }) { pinnedKeyMonitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in self?.unpin() }
            }
        }) { pinnedKeyMonitors.append(global) }
    }

    private func unpin() {
        setPinned(false)
        hideTooltip()
    }

    // MARK: Tooltip

    private func showTooltip(_ focus: ScreenBarFocus) {
        guard let rect = bandRect() ?? hitRects().first else { return }
        lastFocus = focus
        tooltip.present(focus, under: rect, clearance: underBandClearance())
        isTooltipShown = true
        lifeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.tooltipLifeExpired() }
        }
        lifeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxTooltipLife, execute: work)
    }

    /// The life timer firing: a pointer still on the card or the band
    /// means someone is reading it — extend rather than yank it away.
    /// A pinned card answers to its buttons, not the clock.
    private func tooltipLifeExpired() {
        lifeWork = nil
        guard isTooltipShown, !tooltip.isPinned else { return }
        if pointerInHitRegion() {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.tooltipLifeExpired() }
            }
            lifeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifeExtension, execute: work)
        } else {
            hideTooltip()
        }
    }

    func hideTooltip() {
        showWork?.cancel()
        hideWork?.cancel()
        lifeWork?.cancel()
        showWork = nil
        hideWork = nil
        lifeWork = nil
        if tooltip.isPinned { setPinned(false) }
        guard isTooltipShown else { return }
        isTooltipShown = false
        tooltip.dismiss()
    }
}

/// The pill under the band. Click-through and never key. Quiet HUD
/// material, not liquid glass — it is a glance, not a surface.
@MainActor
final class ScreenBarTooltipPanel: NSPanel {
    private let hosting: NSHostingView<ScreenBarTooltipView>
    private let backdrop: NSView

    init() {
        model = ScreenBarTooltipModel()
        hosting = NSHostingView(rootView: ScreenBarTooltipView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
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

    /// The W10 pinned state: the card holds open and takes mouse events
    /// so its Open/close buttons work — still `.nonactivatingPanel`,
    /// still never key, so nothing steals focus.
    private(set) var isPinned = false
    private(set) var model: ScreenBarTooltipModel

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        ignoresMouseEvents = !pinned
        model.pinned = pinned
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func present(_ focus: ScreenBarFocus, under band: NSRect, clearance: CGFloat = 0) {
        model.focus = focus
        hosting.rootView = ScreenBarTooltipView(model: model)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let height = max(26, size.height)
        let width = max(60, size.width)
        backdrop.layer?.cornerRadius = height / 2
        let origin = NSPoint(x: (band.midX - width / 2).rounded(),
                             y: (band.minY - 7 - height - clearance).rounded())
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
    /// Pinned: the card holds open and its controls take clicks (W10's
    /// deliberate-focus state — the band itself stays click-through).
    var pinned = false {
        didSet {
            if pinned {
                utility.start()
                tray.revalidate()
            } else {
                utility.stop()
                calendar.stop()
            }
        }
    }
    /// W11's media/device utility facts — monitored only while pinned.
    let utility = ShelfUtilityModel()
    /// W12's file tray — paths persist in defaults; revalidated on pin.
    let tray = ShelfTrayModel()
    /// W12's timers — tick and persist regardless of pin state so a
    /// deadline set now still fires after the card goes away.
    let timers = ShelfTimerModel()
    /// W12's calendar glance — reads only while pinned (privacy: no
    /// background polling of the owner's schedule).
    let calendar = ShelfCalendarModel()
    var onOpenSession: (() -> Void)?
    var onClose: (() -> Void)?
    /// The pinned card's roster affordance — the Overview window.
    var onOpenOverview: (() -> Void)?
}

struct ScreenBarTooltipView: View {
    @Bindable var model: ScreenBarTooltipModel

    var body: some View {
        if model.pinned {
            // The pinned card is a vertical surface: session row on
            // top, W11/W12 utility rows below.
            VStack(alignment: .leading, spacing: 6) {
                sessionRow
                ShelfMediaRow(utility: model.utility)
                ShelfBatteryRow(power: model.utility.power)
                ShelfTrayRow(tray: model.tray)
                ShelfTimersRow(timers: model.timers)
                ShelfCalendarRow(calendar: model.calendar)
                Button { model.onOpenOverview?() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.grid.2x2")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                        Text("Agent Overview")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text("⌘O")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Every session as a roster (⌘O)")
            }
            .padding(.leading, 7)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .fixedSize()
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                ShelfTrayDrop.urls(from: providers) { urls in
                    model.tray.add(urls)
                }
                return true
            }
        } else {
            sessionRow
                .padding(.leading, 7)
                .padding(.trailing, 10)
                .padding(.vertical, 5)
                .fixedSize()
        }
    }

    private var sessionRow: some View {
        HStack(alignment: .center, spacing: 6) {
            if let style = model.focus.style {
                ProviderTile(style: style, size: 16)
            } else {
                Image(nsImage: StatusItemController.glyph())
                    .renderingMode(.template)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.focus.label)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("·").foregroundStyle(.tertiary)
                    Text(model.focus.word)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let explanation = model.focus.explanation {
                    Text(explanation)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if model.pinned {
                // The deliberate-focus controls: Open raises the
                // session's terminal; ✕ lets the card go.
                HStack(spacing: 4) {
                    if model.focus.clickSession != nil {
                        Button("Open") { model.onOpenSession?() }
                            .controlSize(.mini)
                    }
                    Button { model.onClose?() } label: {
                        Image(systemName: "xmark")
                    }
                    .controlSize(.mini)
                    .accessibilityLabel("Close pinned card")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

/// The pinned card's media row (W11/AL04): artwork, source identity,
/// track line, transport. Drawn only while a certified source reports
/// media — `nil` media means no row, not a dead control.
private struct ShelfMediaRow: View {
    let utility: ShelfUtilityModel

    var body: some View {
        if let media = utility.media {
            HStack(spacing: 6) {
                Group {
                    if let artwork = utility.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(media.displayLine)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Text(utility.sourceName ?? "Now playing")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                transportButton("backward.fill") { utility.send(.previousTrack) }
                transportButton(media.playing ? "pause.fill" : "play.fill") {
                    utility.send(.togglePlayPause)
                }
                transportButton("forward.fill") { utility.send(.nextTrack) }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func transportButton(_ symbol: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The pinned card's battery row (W11/AL05): the internal battery's
/// observed state, hidden entirely on machines without one — never an
/// invented charge. Volume/brightness controls are intentionally not
/// here: macOS owns those HUDs.
private struct ShelfBatteryRow: View {
    let power: AlcovePowerState

    var body: some View {
        if power.hasBattery {
            HStack(spacing: 6) {
                Image(systemName: power.charging ? "battery.100.bolt" : "battery.50")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var label: String {
        var parts: [String] = []
        if let percent = power.percent { parts.append("\(percent)%") }
        if power.fullyCharged {
            parts.append("Charged")
        } else if power.charging {
            parts.append("Charging")
        } else {
            parts.append(power.onAC ? "On AC" : "On battery")
        }
        return parts.isEmpty ? "Battery" : parts.joined(separator: " · ")
    }
}

/// The pinned card's tray strip (W12): dropped files as chips. A moved
/// or deleted file renders dimmed and disabled — the strip says
/// missing, it doesn't silently forget (T49). Reveal/share only ever
/// act on a file that re-resolved this pass.
private struct ShelfTrayRow: View {
    let tray: ShelfTrayModel

    var body: some View {
        if !tray.entries.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tray.entries) { entry in
                        trayChip(entry)
                    }
                }
            }
            .frame(maxWidth: 280)
        }
    }

    private func trayChip(_ entry: ShelfTrayModel.Entry) -> some View {
        HStack(spacing: 3) {
            Image(systemName: entry.missing ? "doc.questionmark" : "doc")
                .font(.system(size: 9))
            Text(entry.missing ? "\(entry.name) (moved)" : entry.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(entry.missing
                    ? AnyShapeStyle(Color.primary.opacity(0.05))
                    : AnyShapeStyle(.quaternary),
                    in: Capsule())
        .foregroundStyle(entry.missing ? .tertiary : .secondary)
        .contextMenu {
            if !entry.missing {
                Button("Reveal in Finder") { tray.reveal(entry) }
                shareMenu(for: entry)
            }
            Button("Remove from Tray", role: .destructive) { tray.remove(entry) }
        }
        .onDrag {
            tray.provider(for: entry) ?? NSItemProvider()
        }
        .help(entry.missing
              ? "Missing — the file moved or was deleted."
              : entry.path)
    }

    /// Native share targets for the file; a canceled sheet delivers
    /// nothing and claims nothing (T50).
    private func shareMenu(for entry: ShelfTrayModel.Entry) -> some View {
        Menu("Share…") {
            ForEach(tray.sharingServices(for: entry), id: \.title) { service in
                Button(service.title) {
                    service.perform(withItems: [entry.url])
                }
            }
        }
    }
}

/// The pinned card's timer strip (W12): live countdowns plus a small
/// add menu. Timers persist across sleep/restart on absolute deadlines;
/// an overdue one shows "Done" once — the notification fires through
/// the model's `onFire`, not here.
private struct ShelfTimersRow: View {
    let timers: ShelfTimerModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(timers.entries) { entry in
                timerChip(entry)
            }
            Menu {
                ForEach(Self.presets, id: \.seconds) { preset in
                    Button(preset.name) {
                        timers.add(label: preset.name, duration: preset.seconds)
                    }
                }
            } label: {
                Image(systemName: "timer")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
            .help("Add a timer")
        }
    }

    /// (name, seconds) presets — bounded by `maxDuration` regardless.
    private static let presets: [(name: String, seconds: TimeInterval)] = [
        ("1 minute", 60), ("5 minutes", 300), ("15 minutes", 900),
        ("30 minutes", 1800), ("1 hour", 3600),
    ]

    private func timerChip(_ entry: ShelfTimerModel.Entry) -> some View {
        let overdue = entry.overdue
        return HStack(spacing: 3) {
            Image(systemName: overdue ? "checkmark" : "timer")
                .font(.system(size: 9))
            Text(overdue ? "Done" : remainingText(entry))
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .foregroundStyle(overdue
            ? AnyShapeStyle(.secondary)
            : AnyShapeStyle(Color.primary.opacity(0.75)))
        .contextMenu {
            Button("Remove", role: .destructive) { timers.remove(entry) }
        }
        .help(overdue ? "\(entry.label) — done." : "\(entry.label) — due \(entry.deadline.formatted(date: .omitted, time: .shortened))")
    }

    /// `m:ss` or `h:mm:ss` remaining — the chip counts down from the
    /// absolute deadline, so a clock change shows up here too.
    private func remainingText(_ entry: ShelfTimerModel.Entry) -> String {
        let seconds = Int(entry.remaining.rounded(.up))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

/// The pinned card's calendar glance (W12): the next event, hidden
/// until the owner grants EventKit access — no permission, no row
/// (T52). Join only ever opens an http(s) link.
private struct ShelfCalendarRow: View {
    let calendar: ShelfCalendarModel

    var body: some View {
        switch calendar.state {
        case .hidden:
            EmptyView()
        case .needsPermission:
            Button {
                calendar.authorizeAndLoad()
            } label: {
                Label("Show calendar", systemImage: "calendar")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        case .idle:
            Label("Nothing on the calendar today", systemImage: "calendar")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        case .event(let event):
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(event.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(event.title)
                    .font(.system(size: 10))
                    .lineLimit(1)
                if event.url != nil {
                    Button("Join") { calendar.join(event) }
                        .controlSize(.mini)
                }
            }
            .contextMenu {
                Button("Open in Calendar") { calendar.openInCalendar(event) }
            }
        }
    }
}
