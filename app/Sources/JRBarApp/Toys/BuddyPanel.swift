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
    /// anywhere else it is parked.
    private func drop(_ panel: NSWindow) {
        guard let toy else { return }
        let centre = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        toy.dragEnded()
        if BuddyPlacement.docksOnDrop(center: centre, slot: dockPoint()) {
            toy.dock()
        } else {
            toy.parkFree(at: centre)
        }
    }

    private func showMenu(from view: BuddyMouseHost, at point: NSPoint) {
        guard let toy else { return }
        pressWork?.cancel()
        pressWork = nil
        swallowUp = true
        let menu = toy.actionMenu(panelFrame: view.window?.frame)
        menu.popUp(positioning: nil, at: point, in: view)
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
        contentView = hosting
        isOpaque = false
        backgroundColor = .clear
        // A window shadow would hug the caption text and read as a
        // smudge over whatever is behind the pet.
        hasShadow = false
        ignoresMouseEvents = false   // the draggable one — never click-through
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
    /// change lands here already sized.
    func present(centeredAt point: CGPoint) {
        guard let toy = model.toy, toy.isOn else { dismiss(); return }
        // A carry owns the frame until the drop lands it — a resize
        // mid-carry re-presents on the drop.
        guard buddyDrag?.inProgress != true else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let height = max(26, size.height)
        let width = max(30, size.width)
        let screen = NSScreen.screens.first { $0.frame.contains(point) }
            ?? ScreenBarGeometry.preferredScreen() ?? NSScreen.main
        let visible = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
            .insetBy(dx: 2, dy: 2)
        let centre = BuddyPlacement.clampedCenter(
            point, size: NSSize(width: width, height: height), inside: visible)
        setFrame(NSRect(x: (centre.x - width / 2).rounded(),
                        y: (centre.y - height / 2).rounded(),
                        width: width, height: height), display: true)
        orderFrontRegardless()
        animator().alphaValue = 1
    }

    func dismiss() {
        alphaValue = 0
        orderOut(nil)
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
        // just for a one-line caption, was pure churn.
        if let toy = model.toy, toy.isOn {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let summary = toy.summary(at: context.date)
                let scale = toy.buddyScale
                // The tag grows with the pet but tops out — a caption,
                // not a headline.
                let caption = min(11, 7.2 * scale)
                VStack(spacing: 0) {
                    NotchBuddyView(toy: toy, scale: scale)
                    if toy.showsCaption {
                        Text(summary.focus?.line ?? toy.buddyName)
                            .font(.system(size: caption, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            // No pill behind it — the shadow keeps the
                            // tag readable over whatever it parks on.
                            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: max(150, 60 * scale))
                            .frame(height: caption + 2)
                            .padding(.bottom, 2 * scale)
                    }
                }
                .help(summary.statusLine)
            }
        }
    }
}
