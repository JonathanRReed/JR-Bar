import AppKit
import JRBarCore
import QuartzCore
import SwiftUI

/// The island's panel: a borderless, non-activating panel pinned to the
/// screen's top edge over the notch, at `statusBar` level — high enough
/// to own the notch, short of pop-ups and the Fold overlay's
/// screen-saver tier, and under the Screen Bar's `statusBar+2`, so the
/// bar's tray and ears draw over the island's notch-deep top and its
/// strip seats at the island's bottom edge. The tray ends at the bezel,
/// so content may start right under the notch; the strip's black
/// housing climbs up behind the island's bottom corners, so content
/// keeps above that climb (the notice's `noticeClimb`, the card's
/// `islandBottomContentInset`). The bar's window is click-through, so
/// hover and swipes still land. `sharingType = .none` keeps it out of
/// Fold's desktop capture so a warped screen never shows the island twice;
/// `JRBAR_CAPTURE_CARD` is a dev-only escape that lifts the exclusion
/// so screenshots can see it (it ships unset).
///
/// Unlike `FoldOverlayWindow` it takes mouse events — hover is what
/// grows the card — so at rest its frame is exactly the drawn shape:
/// the island never parks invisible glass over the menu bar. While it
/// moves, the window is a stage held at one frame for the whole move
/// and the shape travels inside it (`NotchStage`); the instant the
/// spring lands it is the shape again. Idle, notice and the expanded
/// card only ever move the bottom edge; the top stays pinned.
/// A two-finger swipe on the island, in finger-travel direction —
/// `.left` is a swipe toward the left. Read off trackpad scroll events.
enum NotchIslandSwipe { case left, right, down, up }

/// The island's hosting view with a click gate, a pull tracker and a
/// swipe reader: while Fold's overlay is up the island is invisible
/// under it, so clicks must fall through to the (itself click-through)
/// fold rather than die on unseen glass. `scrollWheel` turns precise
/// trackpad deltas into one swipe per gesture — Alcove's signature
/// move: a horizontal flick for the transport, a downward flick for
/// dismiss — and a flick lifted short of the threshold still commits
/// on release, so a fast pull never needs the full travel. A mouse
/// wheel has no phase and no precise deltas, so it never reads as a
/// swipe; and a swipe only ever fires once per gesture, so it can
/// never fight the hover that is also live.
///
/// The press-and-pull (a mouse or track drag on the island) runs the
/// pure `NotchPullGesture`: the resting island stretches open under
/// the finger, the grown card slides off the notch, and the release
/// verdict — commit, retreat or click — belongs to the toy.
final class NotchIslandHostingView: NSHostingView<NotchIslandView> {
    var acceptsClicks: () -> Bool = { true }
    var wingOwnsGesture: (NSPoint) -> Bool = { _ in false }
    var canRestoreIslandWings: @MainActor (NSPoint) -> Bool = { _ in false }
    private var restoresWingsOnHorizontalScroll = false
    private var wingOwnsPress = false
    private var mouseRestorationStart: NSPoint?
    private var mouseRestorationConsumed = false
    private var wingOwnsScroll = false
    /// The pull/swipe master switch — `NotchSettings.pullGestures`.
    var pullsEnabled: () -> Bool = { true }
    /// Which face a pull acts on — `.rest` until the island is grown,
    /// then `.card`. Read live: the face can morph mid-press.
    var pullSurface: () -> NotchPullGesture.Surface = { .rest }
    var onSwipe: (NotchIslandSwipe) -> Void = { _ in }
    /// The pull engaged — the window captures its base frame and stops
    /// any in-flight morph so the finger owns it.
    var onPullBegan: () -> Void = {}
    /// The pull's presentation offset, in the surface's convention —
    /// positive stretch for `.rest`, signed slide for `.card`.
    var onPullChanged: (CGFloat) -> Void = { _ in }
    var onPullEnded: (NotchPullGesture.Verdict) -> Void = { _ in }
    /// A file or link dragged onto the island — NotchNook's shelf
    /// summon: the card grows under the pointer so the tray strip is
    /// there to take the drop.
    var onShelfDragEntered: () -> Void = {}
    /// The drag left this view — out of the island, or onto one of the
    /// card's own drop targets (a session row, the tray catch-all),
    /// which AppKit hands the drag to as destinations of their own. The
    /// toy tells the two apart before it lets a summoned card go.
    var onShelfDragExited: () -> Void = {}
    /// The drop itself — pasteboard URLs, files and web links alike.
    /// Only a drop on the island proper lands here; one on a session
    /// row or the grown card is that target's own (SwiftUI's `onDrop`
    /// views, never routed through this view's methods).
    var onShelfDrop: ([URL]) -> Void = { _ in }
    /// The drag ended (drop performed) — the summon flag clears.
    var onShelfDragEnded: () -> Void = {}

    /// Travel this many points before the gesture commits — small
    /// scrolls and scroll-jitter stay scrolls.
    private static let horizontalThreshold: CGFloat = 48
    private static let verticalThreshold: CGFloat = 40

    private var gestureX: CGFloat = 0
    private var gestureY: CGFloat = 0
    private var gestureLive = false
    private var gestureFired = false

    private var pullStart: NSPoint?
    private var pull = NotchPullGesture()
    private var pullLive = false

    /// The pinch — spread to grow, squeeze to fold — one verdict per
    /// gesture (`NotchPinch`).
    var onPinch: (NotchPinch.Verdict) -> Void = { _ in }
    private var pinch = NotchPinch()
    /// A scroll over the island, in finger travel (positive is up),
    /// offered first to a level capsule that can take it: true when it
    /// set the level, and the scroll is not a swipe.
    var onLevelScroll: (_ fingerDelta: CGFloat, _ precise: Bool) -> Bool = { _, _ in false }
    /// ⌘-drag sideways sets a timer (`NotchTimerDrag`): the pull and the
    /// tap stand aside for it. Travel is screen points, rightward
    /// positive; the end hands the toy the last travel to commit.
    var timerDragAllowed: () -> Bool = { false }
    var onTimerDrag: (_ travel: CGFloat) -> Void = { _ in }
    var onTimerDragEnd: (_ travel: CGFloat) -> Void = { _ in }
    private var timerDragStart: NSPoint?

    override func magnify(with event: NSEvent) {
        guard pullsEnabled() else { return }
        if event.phase.contains(.began) { pinch = NotchPinch() }
        if let verdict = pinch.add(event.magnification) { onPinch(verdict) }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { pinch = NotchPinch() }
    }

    /// Where the shape stands on its stage, in the stage's own
    /// coordinates (top-left origin), or nil when the window is the
    /// shape. Outside it a stage is transparent glass for the instant
    /// it exists: nothing there is the island's to take.
    var stageShape: () -> CGRect? = { nil }
    var stageExtraContains: (CGPoint) -> Bool = { _ in false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsClicks() else { return nil }
        if let shape = stageShape() {
            // `point` is in the superview's space; the shape is top-left
            // origin, y down, whichever way this view's own axis runs.
            let local = convert(point, from: superview)
            let top = isFlipped ? local.y : bounds.height - local.y
            let position = CGPoint(x: local.x, y: top)
            if !shape.contains(position), !stageExtraContains(position) { return nil }
        }
        return super.hitTest(point)
    }

    // MARK: Pull

    override func mouseDown(with event: NSEvent) {
        if handleMouseDown(at: NSEvent.mouseLocation, time: event.timestamp,
                           command: event.modifierFlags.contains(.command)) {
            super.mouseDown(with: event)
        }
    }

    /// Returns whether the hosting view should forward this raw mouse input.
    func handleMouseDown(at point: NSPoint, time: TimeInterval, command: Bool = false) -> Bool {
        mouseRestorationStart = nil
        mouseRestorationConsumed = false
        wingOwnsPress = wingOwnsGesture(point)
        if wingOwnsPress { return false }
        if command, timerDragAllowed() {
            timerDragStart = point
            onTimerDrag(0)
            return false
        }
        if !command, canRestoreIslandWings(point) { mouseRestorationStart = point }
        if pullsEnabled() {
            pullStart = point
            pull = NotchPullGesture()
            pull.move(translation: 0, at: time)
        }
        return true
    }

    override func mouseDragged(with event: NSEvent) {
        if handleMouseDragged(to: NSEvent.mouseLocation, time: event.timestamp) {
            super.mouseDragged(with: event)
        }
    }

    func handleMouseDragged(to point: NSPoint, time: TimeInterval) -> Bool {
        if wingOwnsPress || mouseRestorationConsumed { return false }
        if let start = timerDragStart {
            onTimerDrag(point.x - start.x)
            return false
        }
        if let start = mouseRestorationStart {
            let dx = point.x - start.x
            let dy = point.y - start.y
            var vertical = NotchPullGesture()
            vertical.move(translation: dy, at: time)
            if abs(dx) > abs(dy) {
                if abs(dx) >= ScreenBarInteraction.swipeThreshold {
                    mouseRestorationConsumed = true
                    pullStart = nil
                    pullLive = false
                }
                return false
            }
            if vertical.engaged { mouseRestorationStart = nil }
        }
        if let start = pullStart {
            pull.move(translation: point.y - start.y, at: time)
            if !pullLive, pull.engaged {
                pullLive = true
                onPullBegan()
            }
            if pullLive { onPullChanged(pull.offset(for: pullSurface())) }
        }
        return true
    }

    override func mouseUp(with event: NSEvent) {
        if handleMouseUp(at: NSEvent.mouseLocation, time: event.timestamp) {
            super.mouseUp(with: event)
        }
    }

    func handleMouseUp(at point: NSPoint, time: TimeInterval) -> Bool {
        mouseRestorationStart = nil
        if mouseRestorationConsumed {
            mouseRestorationConsumed = false
            return false
        }
        if wingOwnsPress {
            wingOwnsPress = false
            return false
        }
        if let start = timerDragStart {
            timerDragStart = nil
            onTimerDragEnd(point.x - start.x)
            return false
        }
        if pullLive {
            onPullEnded(pull.release(at: time, surface: pullSurface()))
        }
        pullLive = false
        pullStart = nil
        return true
    }

    /// A morph landing mid-pull owns the frame — the pull lets go
    /// silently: no verdict, no callbacks.
    func abortPull() {
        pullLive = false
        pullStart = nil
        pull = NotchPullGesture()
    }

    // MARK: Swipe

    override func scrollWheel(with event: NSEvent) {
        handleScroll(precise: event.hasPreciseScrollingDeltas, phase: event.phase,
                     deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                     inverted: event.isDirectionInvertedFromDevice, at: NSEvent.mouseLocation)
    }

    func handleScroll(precise: Bool, phase: NSEvent.Phase, deltaX: CGFloat,
                      deltaY: CGFloat, inverted: Bool, at point: NSPoint) {
        if !precise { wingOwnsScroll = false }
        if phase.contains(.began) {
            wingOwnsScroll = wingOwnsGesture(point)
            restoresWingsOnHorizontalScroll = canRestoreIslandWings(point)
            if wingOwnsScroll { ScreenBarInteraction.diag("native scroll owner=wing") }
        }
        if wingOwnsScroll {
            // Keep the momentum tail with its starting owner. The next
            // began event or a discrete wheel event establishes new ownership.
            return
        }
        // A level capsule up is a slider: any scroll over it — trackpad
        // or wheel, momentum included — moves the level instead.
        let finger = NotchScrollFinger.travel(dx: deltaX, dy: deltaY,
                                              inverted: inverted)
        if finger.dy != 0, onLevelScroll(finger.dy, precise) {
            gestureLive = false
            return
        }
        // Only a trackpad gesture carries phases; momentum events arrive
        // with `phase` empty and are ignored with everything else.
        guard pullsEnabled(), precise, phase != [] else { return }
        if phase.contains(.began) {
            gestureLive = true
            gestureFired = false
            gestureX = 0
            gestureY = 0
        }
        if phase.contains(.ended) {
            if gestureLive, !gestureFired {
                gestureX += finger.dx
                gestureY += finger.dy
            }
            // A flick is a gesture that lifts short of the threshold —
            // a fast pull past roughly half commits on release instead
            // of evaporating. `.cancelled` is the OS retracting the
            // gesture (a palm), so only `.ended` commits.
            if gestureLive, !gestureFired {
                let commitY = Self.verticalThreshold * 0.55
                let commitX = Self.horizontalThreshold * 0.55
                if abs(gestureX) > abs(gestureY), abs(gestureX) >= commitX {
                    if !restoresWingsOnHorizontalScroll { onSwipe(gestureX < 0 ? .left : .right) }
                } else if gestureY <= -commitY {
                    onSwipe(.down)
                } else if gestureY >= commitY {
                    onSwipe(.up)
                }
            }
            gestureLive = false
            gestureX = 0
            gestureY = 0
            return
        }
        if phase.contains(.cancelled) {
            gestureLive = false
            gestureX = 0
            gestureY = 0
            return
        }
        guard gestureLive, !gestureFired else { return }
        // Normalise to finger travel, right and up positive. Natural
        // scrolling's deltas follow the content, which follows the
        // fingers in a y-down frame — so the vertical flips — and a
        // legacy wheel reports the opposite on both axes
        // (`NotchScrollFinger`, the Screen Bar's reading too). The
        // vertical used to keep AppKit's y-down sign, which turned a
        // pull down into a fold and a push up into an open.
        gestureX += finger.dx
        gestureY += finger.dy
        if abs(gestureX) >= Self.horizontalThreshold, abs(gestureX) > abs(gestureY) {
            gestureFired = true
            // Fingers left = next track, fingers right = previous.
            if !restoresWingsOnHorizontalScroll { onSwipe(gestureX < 0 ? .left : .right) }
        } else if gestureY <= -Self.verticalThreshold, abs(gestureY) > abs(gestureX) {
            gestureFired = true
            onSwipe(.down)
        } else if gestureY >= Self.verticalThreshold, abs(gestureY) > abs(gestureX) {
            gestureFired = true
            // Fingers up = tuck the card back into the notch —
            // Alcove's dismiss gesture.
            onSwipe(.up)
        }
    }

    // MARK: Shelf drop target

    /// The island is a registered drop destination — a file or link
    /// held to the notch grows the card so the tray strip can take it.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onShelfDragEntered()
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onShelfDragExited()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        var urls = (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: false]) as? [URL]) ?? []
        if urls.isEmpty,
           let text = sender.draggingPasteboard.string(forType: .string),
           let loc = ShelfTrayDrop.textLoc(for: text) {
            // A text clipping — no URL on the pasteboard, so the
            // string materializes as a .txt and joins as a file.
            urls = [loc]
        }
        guard !urls.isEmpty else { return false }
        onShelfDrop(urls)
        return true
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onShelfDragEnded()
    }
}

@MainActor
final class NotchIslandWindow: NSPanel {
    private let hosting: NotchIslandHostingView
    private weak var toy: NotchToy?

    init(toy: NotchToy) {
        self.toy = toy
        hosting = NotchIslandHostingView(rootView: NotchIslandView(toy: toy))
        // The toy owns the frame; the hosting view must never push back
        // with the content's own size. Left at the default sizing
        // options, a 320-point card inside a 200-point window mid-grow
        // was laid out at the window's left edge and marched with it —
        // the card "came in from the side" and snapped centred at the
        // last tick.
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 140, height: 30)
        hosting.autoresizingMask = [.width, .height]
        super.init(contentRect: NSRect(x: 0, y: 0, width: 140, height: 30),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = hosting
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // `ignoresMouseEvents` is left at its default on purpose: a
        // window that never assigns it lets a click on fully transparent
        // pixels fall through to what is beneath, which is what a stage
        // (briefly larger than the shape) relies on; assigning `false`
        // explicitly is reported to switch that off for good.
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        level = .statusBar
        if ProcessInfo.processInfo.environment["JRBAR_CAPTURE_CARD"] == nil {
            sharingType = .none
        }
        hosting.acceptsClicks = { [weak toy] in !(toy?.foldEngaged ?? false) }
        hosting.onSwipe = { [weak toy] swipe in toy?.islandSwipe(swipe) }
        hosting.onPinch = { [weak toy] verdict in toy?.islandPinch(verdict) }
        hosting.onLevelScroll = { [weak toy] delta, precise in
            toy?.scrubLevel(fingerDelta: delta, precise: precise) ?? false
        }
        hosting.pullsEnabled = { [weak toy] in toy?.settings.pullGestures ?? true }
        hosting.timerDragAllowed = { [weak toy] in toy?.timerDragAllowed ?? false }
        hosting.onTimerDrag = { [weak toy] travel in toy?.timerDragChanged(travel: travel) }
        hosting.onTimerDragEnd = { [weak toy] travel in toy?.timerDragEnded(travel: travel) }
        hosting.pullSurface = { [weak toy] in toy?.islandExpanded == true ? .card : .rest }
        hosting.onPullBegan = { [weak self] in self?.beginPullFrame() }
        hosting.onPullChanged = { [weak self] offset in self?.movePullFrame(offset) }
        hosting.onPullEnded = { [weak self] verdict in self?.endPullFrame(verdict) }
        // The shelf summon: file URLs and web links — NotchNook's
        // drag-to-the-notch gesture.
        // .plainText too — a text clipping dragged to the notch
        // materializes as a .txt the way a web link becomes a .webloc.
        hosting.registerForDraggedTypes([.fileURL, .URL, .string])
        hosting.onShelfDragEntered = { [weak toy] in toy?.shelfDragAtIsland() }
        hosting.onShelfDragExited = { [weak toy] in toy?.shelfDragLeftIsland() }
        hosting.onShelfDragEnded = { [weak toy] in toy?.shelfDragLanded() }
        hosting.onShelfDrop = { [weak toy] urls in toy?.shelfDrop(urls) }
        hosting.stageShape = { [weak toy] in toy?.stage.shape }
        hosting.stageExtraContains = { [weak toy] in toy?.shoulderInputPath?.contains($0) ?? false }
        hosting.wingOwnsGesture = { [weak toy] in toy?.wingOwnsGesture($0) ?? false }
        hosting.canRestoreIslandWings = { [weak toy] in toy?.canRestoreIslandWings($0) ?? false }
        // The grown card's content follows its shape: each spring tick
        // reports how far the shape has travelled between the resting
        // island and the card (`NotchReveal` reads it), and the end of
        // the move says the card is simply there or simply gone.
        onOpenness = { [weak toy] openness, dt in toy?.noteOpenness(openness, dt: dt) }
        onMorphEnded = { [weak toy] in toy?.noteMorphEnded() }
        onTick = { [weak toy] dt in toy?.noteTick(dt) }
    }

    /// A morph landing mid-pull owns the frame: the pull's
    /// finger-following stretch is over, with no verdict — the toy's
    /// face change IS the answer to whatever the finger meant.
    func cancelPull() {
        pullBase = nil
        hosting.abortPull()
    }

    /// The pull's stretch/slide rides on the window's frame: this is
    /// the frame — and the face — at engage time, so a morph that
    /// starts under the finger can't tug the floor away mid-drag.
    func beginPullFrame() {
        cancelSpring()
        pullBase = (presentedFrame, hosting.pullSurface())
        toy?.islandPullBegan()
        syncShadow()
    }

    func movePullFrame(_ offset: CGFloat) {
        guard let base = pullBase else { return }
        var pulled = base.frame
        switch base.surface {
        case .rest:
            pulled.origin.y -= offset
            pulled.size.height += offset
        case .card:
            pulled.origin.y += offset
        }
        land(on: pulled)
    }

    func endPullFrame(_ verdict: NotchPullGesture.Verdict) {
        pullBase = nil
        toy?.islandPullEnded(verdict)
        syncShadow()
    }

    private var pullBase: (frame: NSRect, surface: NotchPullGesture.Surface)?

    /// The frame spring preserves velocity when a move changes direction.
    private var spring: NotchFrameSpring?
    private var springLink: CADisplayLink?
    private var springTickAt: CFTimeInterval = 0
    /// Where a face change runs between: the resting island's height and
    /// the grown card's. Kept until the spring lands, so every tick of it
    /// (and of a reversal of it) reads the same two heights.
    private var morph: NotchMorph?
    /// Each spring tick's openness — how far the shape has travelled
    /// between the resting island and the card (0...1). The card's
    /// content reads it; nothing else keeps time.
    var onOpenness: ((CGFloat, TimeInterval) -> Void)?
    /// Every tick of any move, however long: the notice's content clock
    /// keeps time by it.
    var onTick: ((TimeInterval) -> Void)?
    /// The move is over, however it ended.
    var onMorphEnded: (() -> Void)?
    /// A test drives the spring tick by tick instead of on the display
    /// link.
    var drivesSpringByHand = false

    /// Whether anything about the window is in motion: a spring carrying a
    /// move, or the display link that drives it. False at rest, so a
    /// closed island asks the display for nothing.
    var isAnimating: Bool { spring != nil || springLink != nil }

    /// The stage. While a move runs the window does not follow the
    /// shape (a resize per display tick is the dearest thing a window
    /// can be asked to do): it is held at a frame big enough for the
    /// whole move, once, and the shape moves inside it. `stagedShape` is
    /// the shape's place in screen coordinates while that is so, nil when
    /// the window is the shape. `jrbar.notchStagedMotion` = false in
    /// the defaults puts the old per-tick resize back.
    private var stagedShape: NSRect?
    static var stagedMotion: Bool {
        UserDefaults.standard.object(forKey: "jrbar.notchStagedMotion") as? Bool ?? true
    }

    private var shoulderScreenPath: CGPath?

    /// Reserve the same native input window for every painted shoulder.
    func setShoulderInput(_ path: CGPath?) {
        let path = isPresented ? path : nil
        shoulderScreenPath = path
        let shape = presentedFrame
        if let bounds = path?.boundingBoxOfPath, !frame.contains(bounds) {
            seat(shape, on: frame.union(bounds))
        } else if path == nil, !isAnimating, stagedShape != nil {
            land(on: shape)
        }
        publishShoulderInput()
    }

    private func publishShoulderInput() {
        guard let toy, let path = shoulderScreenPath else {
            toy?.shoulderInputPath = nil
            return
        }
        let shape = presentedFrame
        let silhouette = NotchSilhouette(notchDepth: toy.notchDepth,
            restingRadius: toy.notchCornerRadius, notchWidth: toy.notchSlotWidth)
        var bodyTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
            tx: shape.minX, ty: shape.maxY)
        guard let body = silhouette.path(in: CGRect(origin: .zero, size: shape.size)).cgPath.copy(using: &bodyTransform) else { return }
        let extra = path.subtracting(body)
        var localTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
            tx: -frame.minX, ty: frame.maxY)
        toy.shoulderInputPath = extra.copy(using: &localTransform)
    }

    /// The shape the island draws right now, in screen coordinates: the
    /// spring's frame while a stage carries a move, else the window's
    /// own. The Screen Bar couples to this, never to the stage.
    var presentedFrame: NSRect { stagedShape ?? frame }

    /// Motion tests supply visibility without ordering the native window.
    var visibility: (@MainActor () -> Bool)?
    var isPresented: Bool { visibility?() ?? isVisible }

    /// Only the explicit ask or Shelf keyboard command can take typing
    /// from the app in front. Hover remains non-key.
    private var keyboardWanted = false
    override var canBecomeKey: Bool { keyboardWanted }
    override var acceptsFirstResponder: Bool { keyboardWanted }
    override var canBecomeMain: Bool { false }

    /// Take the keyboard, without activating JR-Bar (the panel is
    /// non-activating, so the terminal stays the frontmost app).
    func takeKeyboard() {
        keyboardWanted = true
        if toy?.runtimeEnabled != false {
            makeFirstResponder(self)
            WindowPresenter.automatic.perform { makeKey() }
        }
    }

    /// Give it back. A window that is key is made to lose it by being
    /// ordered out and straight back in within one turn of the run loop
    /// (the window server composes once, so nothing blinks), which hands
    /// key status to the window that had it. No ordering notification is
    /// posted: nothing about the island's place changed.
    func returnKeyboard() {
        guard keyboardWanted else { return }
        keyboardWanted = false
        guard isKeyWindow else { return }
        super.orderOut(nil)
        WindowPresenter.automatic.perform { super.orderFrontRegardless() }
    }

    override func keyDown(with event: NSEvent) {
        guard keyboardWanted, ShelfKeyboardInput.claims(modifiers: event.modifierFlags) else {
            super.keyDown(with: event)
            return
        }
        toy?.islandKey(code: event.keyCode, shift: event.modifierFlags.contains(.shift))
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let changed = super.makeFirstResponder(responder)
        if changed, keyboardWanted, responder !== self {
            keyboardWanted = false
            toy?.releaseAskKeyboard()
            toy?.releaseShelfKeyboard()
        }
        return changed
    }

    /// A click elsewhere, another window taking key: the keyboard goes.
    override func resignKey() {
        super.resignKey()
        guard keyboardWanted else { return }
        keyboardWanted = false
        toy?.releaseAskKeyboard()
        toy?.releaseShelfKeyboard()
    }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    // MARK: Shadow

    /// `jrbar.notchShadow` = false in the defaults takes the shadow away.
    static var shadowEnabled: Bool {
        UserDefaults.standard.object(forKey: "jrbar.notchShadow") as? Bool ?? true
    }

    /// The shadow's own panel, made the first time a grown shape lands.
    private(set) var shadowPanel: NotchShadowPanel?

    /// Whether the island's landed shape casts one right now: it is on
    /// screen, nothing moves it (no stage, no pull) and it hangs below the
    /// notch.
    private var shadowWanted: Bool {
        guard Self.shadowEnabled, isPresented, !isAnimating, pullBase == nil,
              let toy else { return false }
        return NotchShadow.casts(height: presentedFrame.height, notchDepth: toy.notchDepth)
    }

    /// Put the shadow where the landed shape is, or take it away.
    private func syncShadow() {
        guard let toy else { return }
        guard shadowWanted else {
            shadowPanel?.lift()
            return
        }
        let panel = shadowPanel ?? NotchShadowPanel()
        shadowPanel = panel
        let silhouette = NotchSilhouette(notchDepth: toy.notchDepth, restingRadius: toy.notchCornerRadius,
                                         notchWidth: toy.notchSlotWidth)
        panel.cast(shape: presentedFrame, silhouette: silhouette, under: self)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        // A stage or a pull is not a shape that landed; `land(on:)` and the
        // pull's end come back through here once it has.
        syncShadow()
    }

    /// Posted after the island is ordered in or out. AppKit announces
    /// nothing reliable for an `orderOut` or an `orderFrontRegardless`
    /// that moves no point, and the Screen Bar couples to the island
    /// only while it is on screen — without this, parking the island
    /// waited on the bar's safety poll to drop the housing.
    static let didChangeOrderingNotification = Notification.Name("JRBarNotchIslandDidChangeOrdering")

    override func orderFrontRegardless() {
        WindowPresenter.automatic.perform { super.orderFrontRegardless() }
        syncShadow()
        NotificationCenter.default.post(name: Self.didChangeOrderingNotification, object: self)
    }

    override func orderOut(_ sender: Any?) {
        visibility = nil
        shadowPanel?.lift(immediately: true)
        super.orderOut(sender)
        NotificationCenter.default.post(name: Self.didChangeOrderingNotification, object: self)
    }

    /// The grown card's content height at `width`, measured off a probe
    /// hosting view — the window's frame is sized by the toy before the
    /// card is on screen, so the layout answers off-screen.
    func expandedCardHeight(width: CGFloat) -> CGFloat {
        measureCard(width: width, pinnedLayout: false)
    }

    /// Lays the probe out as the grown card before the card is pinned —
    /// the hover's pause, or once after launch — so the grow's own frame
    /// measures a card the probe already built rather than building it.
    /// The window's own face is untouched.
    func prewarmExpandedCard(width: CGFloat) {
        _ = measureCard(width: width, pinnedLayout: true)
    }

    private func measureCard(width: CGFloat, pinnedLayout: Bool) -> CGFloat {
        guard let toy else { return 0 }
        let view = NotchCardView(model: toy.cardModel, style: .island, width: width,
                                 pinnedLayout: pinnedLayout)
        // One probe for the window's life — `reconcile` re-measures on
        // every sessions doc, and a fresh hosting view per pass is a
        // whole SwiftUI tree built to be thrown away.
        let probe: NSHostingView<NotchCardView>
        if let existing = heightProbe {
            existing.rootView = view
            probe = existing
        } else {
            probe = NSHostingView(rootView: view)
            heightProbe = probe
        }
        probe.layoutSubtreeIfNeeded()
        return max(1, probe.fittingSize.height)
    }
    private var heightProbe: NSHostingView<NotchCardView>?

    /// A resize that keeps the top edge pinned: the caller hands a frame
    /// that already hangs from the screen's top, so the ease is only the
    /// bottom edge travelling. Animated moves run on the frame spring —
    /// a new target mid-flight retargets it, so an expansion cancelled
    /// halfway folds home from where it visibly was. Snaps under Reduce
    /// Motion and while the island is hidden. `flip` names the two heights
    /// of a change between the card and any other face; the move's
    /// openness reads them.
    func applyFrame(_ frame: NSRect, animated: Bool, flip: NotchMorph? = nil) {
        guard animated, isPresented, pullBase == nil else {
            // A live pull owns the frame — a morph arriving under the
            // finger would read as the floor moving.
            cancelSpring(landingOn: frame)
            return
        }
        if let flip { morph = flip }
        var spring = spring ?? NotchFrameSpring(at: presentedFrame)
        spring.retarget(frame, motion: NotchFrameSpring.motion(from: spring.frame, to: frame))
        self.spring = spring
        // The notch is read once per morph, not once per display tick.
        springNotch = surroundingsOverride.map(\.floor) ?? toy?.notchFloor
        springScale = screen?.backingScaleFactor ?? 2
        holdStage(for: spring)
        // A fold or a shrink to the bezel lets the shadow go as it begins;
        // a body that stays grown keeps its shadow until the shape lands.
        if let toy, !NotchShadow.casts(height: presentedFrame.height, notchDepth: toy.notchDepth) {
            shadowPanel?.lift()
        }
        startSpring()
    }

    /// The hardware's rectangle and the pixel scale the in-flight morph
    /// settles every frame onto: whole pixels, never a gap against the
    /// notch's edge — the overshoot-free landing of a fold included.
    private var springNotch: CGRect?
    private var springScale: CGFloat = 2

    private func startSpring() {
        guard springLink == nil, !drivesSpringByHand else { return }
        let link = displayLink(target: self, selector: #selector(springTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        springTickAt = CACurrentMediaTime()
        springLink = link
    }

    /// What a move is held inside: the screen the stage may not leave
    /// and the hardware rectangle the shape never dips under. A test
    /// names its own, so a window parked far from any display is not
    /// measured against this Mac's.
    struct Surroundings {
        var bounds: NSRect
        var floor: CGRect?
    }
    var surroundingsOverride: Surroundings?
    private var stageBounds: NSRect {
        surroundingsOverride?.bounds ?? (screen ?? ScreenBarGeometry.preferredScreen())?.frame ?? frame
    }

    /// Make the window carry the move: a stage around the shape and
    /// where it is going, set before the first tick draws. The shape
    /// goes onto the stage in the same turn, so the view never fills a
    /// window larger than the shape for even a frame.
    private func holdStage(for spring: NotchFrameSpring) {
        guard Self.stagedMotion else { return }
        let want = NotchStage.frame(presented: spring.frame, target: spring.target,
                                    motion: spring.motion, within: stageBounds, scale: springScale)
        if let shape = stagedShape {
            guard !NotchStage.holds(frame, want) else { return }
            seat(shape, on: frame.union(want))
        } else {
            seat(frame, on: want.union(frame))
        }
    }

    /// Put `shape` on a stage of `stage`'s frame: the model first, then
    /// the window, so the one layout that sees the new window size has
    /// already been told where the shape stands in it.
    private func seat(_ shape: NSRect, on stage: NSRect) {
        stagedShape = shape
        toy?.stage.shape = NotchStage.local(shape, in: stage)
        if frame != stage { setFrame(stage, display: true) }
        publishShoulderInput()
        hosting.layoutSubtreeIfNeeded()
    }

    /// The shape is the window again: the model first, then the frame.
    private func land(on shape: NSRect) {
        if let bounds = shoulderScreenPath?.boundingBoxOfPath, !shape.contains(bounds) {
            seat(shape, on: shape.union(bounds))
            return
        }
        stagedShape = nil
        toy?.stage.shape = nil
        setFrame(shape, display: true)
        publishShoulderInput()
        hosting.layoutSubtreeIfNeeded()
    }

    /// Kill an in-flight morph — a parked island runs no display link.
    /// A stage is struck where the shape stands, so the window is the
    /// shape again whatever stopped the move.
    func cancelSpring(landingOn target: NSRect? = nil) {
        springLink?.invalidate()
        springLink = nil
        let wasMoving = spring != nil
        spring = nil
        morph = nil
        if let target {
            land(on: target)
        } else if let shape = stagedShape {
            land(on: shape)
        }
        if wasMoving { onMorphEnded?() }
    }

    @objc private func springTick(_ link: CADisplayLink) {
        let dt = max(0, link.timestamp - springTickAt)
        springTickAt = link.timestamp
        advanceSpring(by: dt)
    }

    /// One display tick. Tests advance the same curve directly.
    func advanceSpring(by dt: TimeInterval) {
        guard var spring else {
            springLink?.invalidate()
            springLink = nil
            return
        }
        if spring.integrate(dt: dt) {
            self.spring = spring
            // A shape drawn on a stage moves between device pixels, which
            // the view anti-aliases; only a window that is the shape sits
            // on the pixel grid.
            let shape = stagedShape != nil
                ? NotchIslandLayout.floored(spring.frame, over: springNotch)
                : NotchIslandLayout.settled(spring.frame, scale: springScale, over: springNotch)
            if stagedShape != nil {
                if !NotchStage.holds(frame, shape) {
                    // A retarget past the stage: widen it without a
                    // visible step.
                    seat(shape, on: frame.union(shape))
                }
                stagedShape = shape
                toy?.stage.shape = NotchStage.local(shape, in: frame)
            } else {
                setFrame(shape, display: true)
            }
            if let morph { onOpenness?(morph.openness(size: shape.size), dt) }
            onTick?(dt)
            if stagedShape != nil {
                hosting.layoutSubtreeIfNeeded()
                // Publish after the island receives this tick's shape and
                // content state, so the band cannot lead those updates.
                NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: self)
            }
        } else {
            // Land exactly: never rest a fraction of a point off the
            // frame the face actually asked for.
            let target = spring.target
            springLink?.invalidate()
            springLink = nil
            self.spring = nil
            morph = nil
            land(on: target)
            onMorphEnded?()
        }
    }
}
