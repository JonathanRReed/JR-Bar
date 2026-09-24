import AppKit
import JRBarCore
import Observation
import SwiftUI

/// What the drag controller needs from the view under the press: its
/// window (the thing being carried) and a way to let an event through
/// to SwiftUI when the press turned out to be a plain tap.
@MainActor
protocol BuddyMouseHost: NSView {
    func passDown(_ event: NSEvent)
    func passDragged(_ event: NSEvent)
    func passUp(_ event: NSEvent)
}

/// The hosting view both buddy panels ride on — the HUD pill's and the
/// free panel's. The mouse goes to the shared `BuddyDragController`
/// first: it decides whether the press is a tap (forwarded to SwiftUI),
/// a carry (moves the window), or a menu (right-click, control-click,
/// or a press held half a second).
final class BuddyHostingView<Content: View>: NSHostingView<Content>, BuddyMouseHost {
    weak var buddyDrag: BuddyDragController?
    /// The pointer entering or leaving the pet — the name tag and the
    /// docked status line hang off this, so they only exist on hover.
    var onHoverChange: ((Bool) -> Void)?
    /// Ours only — the hosting view keeps whatever tracking areas it
    /// installs for SwiftUI's own hover machinery. It re-registers only
    /// when the bounds actually change: the buddy's breathing relayouts
    /// run per animation tick, and re-adding the area each time refires
    /// enter/exit and flickers the name tag.
    private var hoverArea: NSTrackingArea?
    private var hoverAreaBounds: NSRect?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if hoverArea != nil, hoverAreaBounds == bounds { return }
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        hoverAreaBounds = bounds
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func mouseDown(with event: NSEvent) {
        if let buddyDrag { buddyDrag.mouseDown(event, in: self) } else { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if let buddyDrag { buddyDrag.mouseDragged(event, in: self) } else { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if let buddyDrag { buddyDrag.mouseUp(event, in: self) } else { super.mouseUp(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let buddyDrag { buddyDrag.rightMouseDown(event, in: self) } else { super.rightMouseDown(with: event) }
    }

    func passDown(_ event: NSEvent) { super.mouseDown(with: event) }
    func passDragged(_ event: NSEvent) { super.mouseDragged(with: event) }
    func passUp(_ event: NSEvent) { super.mouseUp(with: event) }
}

/// One carry, whichever panel the press landed in. The press is read in
/// screen coordinates so the pill travels with the cursor no matter
/// which window owns it: past `BuddyPlacement.dragThreshold` the source
/// panel is carried along, a drop inside the dock's reach snaps the
/// buddy home, and anywhere else parks it (`freePosition` writes
/// through the toy, so the HUD re-lays the panels out itself).
@MainActor
final class BuddyDragController {
    weak var toy: NotchBuddyToy?
    /// The docked pill's centre — a drop there snaps home. The HUD
    /// supplies it because the band can move.
    var dockPoint: @MainActor () -> CGPoint = { .zero }

    private weak var source: NSWindow?
    /// The window whose menu is open right now — popUp tracks until it
    /// closes, and the walk stands still for it.
    private weak var menuWindow: NSWindow?
    private var down: NSPoint?
    private var origin: NSPoint = .zero
    private var last: NSPoint?
    private var moved = false
    /// Set once the press was spent on the menu — the release must not
    /// land as a tap.
    private var swallowUp = false
    private var pressWork: DispatchWorkItem?

    /// A carry is in flight — the panels consult it so nothing reframes
    /// the window out from under the mouse.
    var inProgress: Bool { moved }

    /// A press is down on `window`, or its menu is open: a walking buddy
    /// stands still under the pointer instead of strolling out from
    /// under it.
    func holds(_ window: NSWindow) -> Bool {
        (down != nil && source === window) || menuWindow === window
    }

    /// Whatever owned the press is gone (a toast took the panel): the
    /// carry is cut short and the buddy goes back where the settings put
    /// it. The release still arrives — `swallowUp` keeps it from landing
    /// as a tap on a press that was never a click.
    func cancel() {
        pressWork?.cancel()
        pressWork = nil
        if moved, let source {
            source.setFrameOrigin(origin)
        }
        down = nil
        source = nil
        last = nil
        moved = false
        swallowUp = true
        toy?.dragCancelled()
    }

    func mouseDown(_ event: NSEvent, in view: BuddyMouseHost) {
        // Every press starts clean: a menu's release never reaches
        // `mouseUp`, so without this reset the tap after a right-click
        // would die on the stale `swallowUp`.
        swallowUp = false
        pressWork?.cancel()
        pressWork = nil
        // A control-click is a right-click.
        guard !event.modifierFlags.contains(.control) else {
            showMenu(from: view, at: view.convert(event.locationInWindow, from: nil))
            return
        }
        down = NSEvent.mouseLocation
        last = down
        origin = view.window?.frame.origin ?? .zero
        source = view.window
        moved = false
        view.passDown(event)
        // A press held in place is the menu. The event is dispatched
        // once — only the point survives into the timer.
        let menuPoint = view.convert(event.locationInWindow, from: nil)
        let work = DispatchWorkItem { [weak self, weak view] in
            MainActor.assumeIsolated {
                guard let self, let view, self.down != nil, !self.moved else { return }
                self.swallowUp = true
                self.showMenu(from: view, at: menuPoint)
            }
        }
        pressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    func mouseDragged(_ event: NSEvent, in view: BuddyMouseHost) {
        guard let down, let source else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - down.x
        let dy = mouse.y - down.y
        if !moved {
            guard BuddyPlacement.isDrag(dx: dx, dy: dy) else { return }
            moved = true
            pressWork?.cancel()
            toy?.dragStarted()
        }
        source.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
        toy?.dragMoved(dx: mouse.x - (last?.x ?? mouse.x))
        last = mouse
    }

    func mouseUp(_ event: NSEvent, in view: BuddyMouseHost) {
        pressWork?.cancel()
        pressWork = nil
        let wasSwallowed = swallowUp
        let source = self.source
        let didMove = moved
        down = nil
        self.source = nil
        last = nil
        moved = false
        swallowUp = false
        if wasSwallowed { return }
        if didMove, let source {
            drop(source)
            return  // the carry ate the click — no trick on a drop
        }
        view.passUp(event)
    }

    func rightMouseDown(_ event: NSEvent, in view: BuddyMouseHost) {
        showMenu(from: view, at: view.convert(event.locationInWindow, from: nil))
    }

    /// Where the press let go: inside the dock's reach it snaps home,
    /// anywhere else it is parked. Carried out of the notch, the drop
    /// says where the docked figure stood, so the free panel can take
    /// over from exactly there.
    private func drop(_ panel: NSWindow) {
        guard let toy else { return }
        let centre = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        toy.dragEnded()
        if BuddyPlacement.docksOnDrop(center: centre, slot: dockPoint()) {
            toy.dock()
        } else {
            let figure = panel is BuddyPanel ? nil : BuddyPanel.dockedFigureCentre(in: panel.frame)
            toy.parkFree(at: centre, figureCentre: figure)
        }
    }

    private func showMenu(from view: BuddyMouseHost, at point: NSPoint) {
        guard let toy else { return }
        pressWork?.cancel()
        pressWork = nil
        swallowUp = true
        let menu = toy.actionMenu(panelFrame: view.window?.frame)
        menuWindow = view.window
        menu.popUp(positioning: nil, at: point, in: view)
        menuWindow = nil
        // The press is spent on the menu either way; `swallowUp` stays
        // set so a stray release can't complete the pending tap.
        down = nil
        source = nil
        last = nil
        moved = false
    }
}

@MainActor
@Observable
final class BuddyPanelModel {
    /// Who lives in the free panel; nil until the HUD hands it over.
    var toy: NotchBuddyToy?
    /// The pointer is on the pet — the name tag only shows while it is.
    var hovered = false
    /// The panel is showing the buddy or still fading it out. It outlasts
    /// the toy's own state on purpose: docked or switched off, the figure
    /// stays drawn until the fade has played, so a dock crossfades with
    /// the notch pill fading in instead of blinking out.
    var drawsBuddy = false
}

/// The buddy's free-floating home: the pet bare on a transparent
/// window — no pill chrome — on the same just-over-the-menu-bar level.
/// It takes the mouse — the pet is how it gets dragged, tapped and
/// menued. It hosts no toasts, so a toast can never fight it for the
/// panel.
@MainActor
final class BuddyPanel: NSPanel {
    private let hosting: BuddyHostingView<BuddyPanelView>
    private let model = BuddyPanelModel()

    var buddyDrag: BuddyDragController? {
        get { hosting.buddyDrag }
        set { hosting.buddyDrag = newValue }
    }

    init() {
        hosting = BuddyHostingView(rootView: BuddyPanelView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.autoresizingMask = [.width, .height]
        super.init(contentRect: NSRect(x: 0, y: 0, width: 60, height: 30),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hosting.onHoverChange = { [weak self] in self?.model.hovered = $0 }
        contentView = hosting
        isOpaque = false
        backgroundColor = .clear
        // A window shadow would hug the caption text and read as a
        // smudge over whatever is behind the pet.
        hasShadow = false
        ignoresMouseEvents = false   // the draggable one — click-through only while it fades out
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false            // the carry moves it by hand
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Who lives here — set once, by the HUD's buddy handoff.
    func host(_ toy: NotchBuddyToy?) {
        model.toy = toy
    }

    /// Parked centred on `point` in screen coordinates, clamped so the
    /// whole pill stays on the visible screen — a spot saved on a
    /// monitor that is no longer there lands somewhere sane instead.
    /// The frame is measured fresh off the hosting view, so a scale
    /// change lands here already sized. Fresh out of the notch (a
    /// hand-off) it shows at once and the figure grows in from where the
    /// docked one stood; anywhere else it fades in.
    func present(centeredAt point: CGPoint) {
        guard let toy = model.toy, toy.isOn else { dismiss(); return }
        // A carry owns the frame until the drop lands it — a resize
        // mid-carry re-presents on the drop.
        guard buddyDrag?.inProgress != true else { return }
        // Drawn before it is measured, so a panel coming back from a
        // fade-out sizes to the pet, not to nothing.
        model.drawsBuddy = true
        ignoresMouseEvents = false
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let height = max(26, size.height)
        let width = max(30, size.width)
        let panelSize = NSSize(width: width, height: height)
        let screen = NSScreen.screens.first { $0.frame.contains(point) }
            ?? ScreenBarGeometry.preferredScreen() ?? NSScreen.main
        let visible = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
            .insetBy(dx: 2, dy: 2)
        let centre = BuddyPlacement.clampedCenter(point, size: panelSize, inside: visible)
        showing = true
        if walk != nil {
            // Out on a walk from this very spot: the walk keeps the frame.
            if home == centre, frame.size == panelSize { return }
            // Re-parked or resized mid-walk: it heads for the new home
            // from where it is drawn, at its new size, rather than
            // jumping there.
            let here = CGPoint(x: frame.midX, y: frame.midY)
            home = centre
            homeVisible = visible
            walk?.headHome(from: here, home: centre, at: ProcessInfo.processInfo.systemUptime)
            model.toy?.setStrollHeading(nil)
            let origin = BuddyWalk.origin(for: here, size: panelSize)
            setFrame(NSRect(origin: origin, size: panelSize), display: true)
            return
        }
        home = centre
        homeVisible = visible
        setFrame(NSRect(origin: BuddyWalk.origin(for: centre, size: panelSize), size: panelSize),
                 display: true)
        if let handoff = toy.takeHandoff() {
            // The docked pill vanished this same turn: be there already,
            // and let the figure grow in from the docked size.
            let drift = handoff.figureCentre.map {
                let own = Self.figureCentre(in: frame, scale: toy.buddyScale)
                return CGSize(width: $0.x - own.x, height: own.y - $0.y)
            } ?? .zero
            toy.arrive(fromScale: 1 / max(1, toy.buddyScale), drift: drift)
            // At once, and over any fade-out still running from a dock a
            // moment ago: a zero-length group replaces that animation.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                self.animator().alphaValue = 1
            }
            alphaValue = 1
            orderFrontRegardless()
        } else {
            orderFrontRegardless()
            animator().alphaValue = 1
        }
        armWalkabout()
    }

    /// Fades out with the figure still drawn in it, rather than vanishing;
    /// a present that lands mid-fade keeps the panel. Fading, it lets the
    /// mouse through: a click meant for the pill fading in under it at
    /// the notch reaches that one.
    func dismiss() {
        endStroll(reframe: false)
        beat?.invalidate()
        beat = nil
        home = nil
        showing = false
        ignoresMouseEvents = true
        guard isVisible else {
            alphaValue = 0
            model.drawsBuddy = false
            return
        }
        NotchSurfaceMotion.dismiss(self, duration: 0.2, reducedDuration: 0.1,
                                   stillGone: { [weak self] in self?.showing == false },
                                   then: { [weak self] in self?.model.drawsBuddy = false })
    }

    /// Meant to be on screen; a fade-out only orders the panel out while
    /// this stays false.
    private var showing = false

    /// Where the docked slot draws its figure inside a docked pill's
    /// frame: the 18 pt creature and its padding make a 30 pt block at
    /// the top of the pill, the hover caption's row under it
    /// (`NotchHUDView`). A drop out of the notch hands this spot over.
    static func dockedFigureCentre(in frame: NSRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.maxY - 15)
    }

    /// The same for this panel: the figure's block is 30 pt at the
    /// buddy's scale, at the top, the caption row under it.
    static func figureCentre(in frame: NSRect, scale: Double) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.maxY - 15 * max(1, scale))
    }

    // MARK: Walkabout

    /// The parked centre, and the screen area it was clamped into.
    private var home: CGPoint?
    private var homeVisible: CGRect = .zero
    /// The walk in progress (`BuddyWalk`: the plan, its clock, a press's
    /// hold).
    private var walk: BuddyWalk?
    private var strollTimer: Timer?
    /// The once-a-minute decision beat, alive while the panel shows.
    private var beat: Timer?
    private var lastStrollAt = ProcessInfo.processInfo.systemUptime
    private var lastLedgeLook: TimeInterval = 0

    private func armWalkabout() {
        guard beat == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.considerStroll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        beat = timer
    }

    private func considerStroll() {
        guard walk == nil, isVisible, let home, let toy = model.toy, toy.isOn, toy.isFree,
              toy.takesWalks, !toy.isTucked else { return }
        let digest = toy.sessionDigest()
        let now = ProcessInfo.processInfo.systemUptime
        guard BuddyStroll.shouldStroll(
            working: digest.working, waiting: digest.waiting, failed: digest.failed,
            dragging: toy.isDragged || buddyDrag?.inProgress == true,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            sinceLast: now - lastStrollAt, roll: Double.random(in: 0..<1),
            every: toy.walkEvery),
              let plan = BuddyStroll.plan(home: home, size: frame.size, visible: homeVisible,
                                          windows: BuddyStroll.windowFrames(),
                                          rightward: Bool.random())
        else { return }
        begin(plan)
    }

    private func begin(_ plan: BuddyStroll) {
        strollTimer?.invalidate()
        let now = ProcessInfo.processInfo.systemUptime
        walk = BuddyWalk(plan: plan, began: now)
        lastLedgeLook = now
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepStroll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        strollTimer = timer
    }

    /// One frame of the walk: the panel moves, the figure turns toward
    /// the way it goes. A press holds it still, a carry takes it over,
    /// and an ask or a vanished edge sends it home from where it stands.
    private func stepStroll() {
        guard var walk, let home, let toy = model.toy else { endStroll(); return }
        if toy.isDragged || buddyDrag?.inProgress == true {
            // The carry owns the frame now; the drop parks it.
            endStroll(reframe: false)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if buddyDrag?.holds(self) == true {
            walk.hold(at: now)
        } else {
            walk.release(at: now)
        }
        // Once a second: Reduce Motion still off (turned on mid-walk, the
        // buddy is simply home — a plain reposition), walks still allowed
        // ("Take walks" turned off mid-walk heads home), nothing asking,
        // and the edge still there.
        if now - lastLedgeLook >= 1, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            endStroll()
            return
        }
        if now - lastLedgeLook >= 1, walk.plan.legs.count > 1 {
            lastLedgeLook = now
            let digest = toy.sessionDigest()
            let ledge = walk.plan.ledge
            let carriesOn = BuddyStroll.carriesOn(
                working: digest.working, waiting: digest.waiting, failed: digest.failed,
                showing: toy.isOn, free: toy.isFree, takesWalks: toy.takesWalks,
                ledgeStands: BuddyStroll.ledgeStands(ledge, in: BuddyStroll.windowFrames()))
            if !carriesOn {
                walk.headHome(from: CGPoint(x: frame.midX, y: frame.midY), home: home, at: now)
            }
        }
        self.walk = walk
        guard let point = walk.centre(at: now) else {
            endStroll()
            return
        }
        toy.setStrollHeading(walk.heading(at: now))
        setFrameOrigin(BuddyWalk.origin(for: point, size: frame.size))
    }

    /// Home, and the walk forgotten. `reframe` false leaves the frame to
    /// whoever took it (a carry, a fade-out).
    private func endStroll(reframe: Bool = true) {
        strollTimer?.invalidate()
        strollTimer = nil
        guard walk != nil else { return }
        walk = nil
        lastStrollAt = ProcessInfo.processInfo.systemUptime
        model.toy?.setStrollHeading(nil)
        if reframe, let home {
            setFrameOrigin(BuddyWalk.origin(for: home, size: frame.size))
        }
    }
}

/// What the free panel shows: the same buddy the docked pill carries —
/// moods, tricks, badges, hover line and all — drawn at the settings'
/// `scale` (the docked slot is fixed at 18pt; this one is a desk pet),
/// plus the quiet caption underneath naming the session it is watching,
/// or just its name tag while nothing is on the clock. The caption row
/// keeps its height even when the text is short, so the pill's size
/// never breathes — only the slider does that.
struct BuddyPanelView: View {
    let model: BuddyPanelModel

    var body: some View {
        // The buddy view owns its own animation timeline; this layer
        // re-reads the summary only often enough to keep the caption's
        // relative time honest — a display-rate reduce of every session,
        // just for a one-line caption, was pure churn. It draws for as
        // long as the panel shows or fades (`drawsBuddy`), except a buddy
        // that has finished ducking out for a nap: that one is gone already.
        if let toy = model.toy, model.drawsBuddy, toy.isShowing || !toy.isTucked {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let summary = toy.summary(at: context.date)
                let scale = toy.buddyScale
                // The tag grows with the pet but tops out — a caption,
                // not a headline.
                let caption = min(11, 7.2 * scale)
                // The name tag shows only under the pointer, and only
                // while "Caption on hover" is on. Its row is always laid
                // out, the way the docked slot keeps its space, so neither
                // a hover nor the toggle moves the pet.
                let showsTag = model.hovered && toy.showsCaption
                VStack(spacing: 0) {
                    NotchBuddyView(toy: toy, scale: scale)
                    Text(summary.focus?.line ?? toy.buddyName)
                        .font(.system(size: caption, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        // No pill behind it — the shadow keeps the tag
                        // readable over whatever it parks on.
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: max(150, 60 * scale))
                        .frame(height: caption + 2)
                        .padding(.bottom, 2 * scale)
                        .opacity(showsTag ? 1 : 0)
                        .accessibilityHidden(!toy.showsCaption)
                }
                .help(summary.statusLine)
            }
        }
    }
}
