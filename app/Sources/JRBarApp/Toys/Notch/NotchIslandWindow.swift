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
/// so the island's own content starts right under the notch with no
/// clearance; the bar's window is click-through, so hover and swipes
/// still land. `sharingType = .none` keeps it out of Fold's desktop capture
/// so a warped screen never shows the island twice;
/// `JRBAR_CAPTURE_CARD` is a dev-only escape that lifts the exclusion
/// so screenshots can see it (it ships unset).
///
/// Unlike `FoldOverlayWindow` it takes mouse events — hover is what
/// grows the card — so its frame is always exactly the drawn shape:
/// the island never parks invisible glass over the menu bar. Idle,
/// notice and the expanded card only ever move the bottom edge; the
/// top stays pinned.
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
private final class NotchIslandHostingView: NSHostingView<NotchIslandView> {
    var acceptsClicks: () -> Bool = { true }
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
    /// The drag left without dropping — the summoned card lets go
    /// again instead of sitting pinned forever.
    var onShelfDragExited: () -> Void = {}
    /// The drop itself — pasteboard URLs, files and web links alike.
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsClicks() ? super.hitTest(point) : nil
    }

    // MARK: Pull

    override func mouseDown(with event: NSEvent) {
        if pullsEnabled() {
            pullStart = NSEvent.mouseLocation
            pull = NotchPullGesture()
            pull.move(translation: 0, at: event.timestamp)
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = pullStart {
            pull.move(translation: NSEvent.mouseLocation.y - start.y, at: event.timestamp)
            if !pullLive, pull.engaged {
                pullLive = true
                onPullBegan()
            }
            if pullLive { onPullChanged(pull.offset(for: pullSurface())) }
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if pullLive {
            onPullEnded(pull.release(at: event.timestamp, surface: pullSurface()))
        }
        pullLive = false
        pullStart = nil
        super.mouseUp(with: event)
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
        // Only a trackpad gesture carries phases; momentum events arrive
        // with `phase` empty and are ignored with everything else.
        guard pullsEnabled(), event.hasPreciseScrollingDeltas, event.phase != [] else { return }
        if event.phase.contains(.began) {
            gestureLive = true
            gestureFired = false
            gestureX = 0
            gestureY = 0
        }
        if event.phase.contains(.ended) {
            // A flick is a gesture that lifts short of the threshold —
            // a fast pull past roughly half commits on release instead
            // of evaporating. `.cancelled` is the OS retracting the
            // gesture (a palm), so only `.ended` commits.
            if gestureLive, !gestureFired {
                let commitY = Self.verticalThreshold * 0.55
                let commitX = Self.horizontalThreshold * 0.55
                if abs(gestureX) > abs(gestureY), abs(gestureX) >= commitX {
                    onSwipe(gestureX < 0 ? .left : .right)
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
        if event.phase.contains(.cancelled) {
            gestureLive = false
            gestureX = 0
            gestureY = 0
            return
        }
        guard gestureLive, !gestureFired else { return }
        // Normalise to finger direction: with "natural" scrolling the
        // delta already follows the fingers (`isDirectionInvertedFrom-
        // Device`), with legacy scrolling it is the wheel's opposite.
        let inverted = event.isDirectionInvertedFromDevice
        gestureX += inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
        gestureY += inverted ? event.scrollingDeltaY : -event.scrollingDeltaY
        if abs(gestureX) >= Self.horizontalThreshold, abs(gestureX) > abs(gestureY) {
            gestureFired = true
            // Fingers left = next track, fingers right = previous.
            onSwipe(gestureX < 0 ? .left : .right)
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
        ignoresMouseEvents = false
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
        hosting.pullsEnabled = { [weak toy] in toy?.settings.pullGestures ?? true }
        hosting.pullSurface = { [weak toy] in toy?.islandExpanded == true ? .card : .rest }
        hosting.onPullBegan = { [weak self, weak toy] in
            guard let self else { return }
            cancelSpring()
            pullBase = (frame, hosting.pullSurface())
            toy?.islandPullBegan()
        }
        hosting.onPullChanged = { [weak self] offset in
            guard let self, let base = pullBase else { return }
            var pulled = base.frame
            switch base.surface {
            case .rest:
                // The resting island stretches down from its pinned
                // top edge — the notch itself does not move.
                pulled.origin.y -= offset
                pulled.size.height += offset
            case .card:
                // The grown card slides under the finger — down peels
                // it off the notch, up tucks it back in.
                pulled.origin.y += offset
            }
            setFrame(pulled, display: true)
        }
        hosting.onPullEnded = { [weak self, weak toy] verdict in
            self?.pullBase = nil
            toy?.islandPullEnded(verdict)
        }
        // The shelf summon: file URLs and web links — NotchNook's
        // drag-to-the-notch gesture.
        // .plainText too — a text clipping dragged to the notch
        // materializes as a .txt the way a web link becomes a .webloc.
        hosting.registerForDraggedTypes([.fileURL, .URL, .string])
        hosting.onShelfDragEntered = { [weak toy] in toy?.shelfDragAtIsland() }
        hosting.onShelfDragExited = { [weak toy] in toy?.shelfDragAbandoned() }
        hosting.onShelfDragEnded = { [weak toy] in toy?.shelfDragLanded() }
        hosting.onShelfDrop = { [weak toy] urls in toy?.shelfDrop(urls) }
        // The grown card's content follows its frame: each spring tick
        // reports how far the height has carried toward the target,
        // and the toy opens the rows once most of the way there.
        onSpringProgress = { [weak toy] progress in
            toy?.noteFrameProgress(progress)
        }
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
    private var pullBase: (frame: NSRect, surface: NotchPullGesture.Surface)?

    /// The island's frame motion: a display-link-integrated spring —
    /// retargeting mid-flight continues from wherever the frame
    /// actually is with the velocity it actually has, so an
    /// interrupted morph never snaps (the `animator().setFrame` this
    /// replaces restarted instead).
    private var spring: NotchFrameSpring?
    private var springLink: CADisplayLink?
    private var springTickAt: CFTimeInterval = 0
    /// Each spring tick's height progress toward the target — the
    /// expanded card's content-follow gate reads it (≈0 leaving,
    /// 1.0 landed).
    var onSpringProgress: ((CGFloat) -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Posted after the island is ordered in or out. AppKit announces
    /// nothing reliable for an `orderOut` or an `orderFrontRegardless`
    /// that moves no point, and the Screen Bar couples to the island
    /// only while it is on screen — without this, parking the island
    /// waited on the bar's safety poll to drop the housing.
    static let didChangeOrderingNotification = Notification.Name("JRBarNotchIslandDidChangeOrdering")

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        NotificationCenter.default.post(name: Self.didChangeOrderingNotification, object: self)
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        NotificationCenter.default.post(name: Self.didChangeOrderingNotification, object: self)
    }

    /// The grown card's content height at `width`, measured off a probe
    /// hosting view — the window's frame is sized by the toy before the
    /// card is on screen, so the layout answers off-screen.
    func expandedCardHeight(width: CGFloat) -> CGFloat {
        guard let toy else { return 0 }
        let view = NotchCardView(model: toy.cardModel, style: .island, width: width)
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
    /// Motion and while the island is hidden.
    func applyFrame(_ frame: NSRect, animated: Bool) {
        guard animated, isVisible, pullBase == nil else {
            // A live pull owns the frame — a morph arriving under the
            // finger would read as the floor moving.
            cancelSpring()
            setFrame(frame, display: true)
            return
        }
        var spring = spring ?? NotchFrameSpring(at: self.frame)
        spring.retarget(frame, motion: NotchFrameSpring.motion(from: spring.frame, to: frame))
        self.spring = spring
        startSpring()
    }

    private func startSpring() {
        guard springLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(springTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        springTickAt = CACurrentMediaTime()
        springLink = link
    }

    /// Kill an in-flight morph — a parked island runs no display link.
    func cancelSpring() {
        springLink?.invalidate()
        springLink = nil
        spring = nil
    }

    @objc private func springTick(_ link: CADisplayLink) {
        guard var spring else {
            link.invalidate()
            springLink = nil
            return
        }
        let dt = max(0, link.timestamp - springTickAt)
        springTickAt = link.timestamp
        if spring.integrate(dt: dt) {
            self.spring = spring
            setFrame(spring.frame, display: true)
            onSpringProgress?(spring.frame.height / max(1, spring.target.height))
        } else {
            // Land exactly: never rest a fraction of a point off the
            // frame the face actually asked for.
            let target = spring.target
            cancelSpring()
            setFrame(target, display: true)
            onSpringProgress?(1)
        }
    }
}
