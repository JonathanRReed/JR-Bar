import AppKit
import JRBarCore
import QuartzCore
import SwiftUI

/// The card's hosting view with the pull gesture: a vertical drag on
/// the pinned card slides it under the finger — past the commit travel
/// or released fast enough, the pull dismisses; short of that the card
/// springs home. It runs the same pure `NotchPullGesture` the island's
/// pull does, so the flick rules are identical on both surfaces. Only a
/// pinned card takes mouse events at all, so the pull exists exactly
/// while the card is interactive.
final class NotchCardHostingView: NSHostingView<NotchCardView> {
    /// The pull's signed slide offset — upward positive, like the finger.
    var onPullSlide: (CGFloat) -> Void = { _ in }
    /// The release verdict — true when the pull committed.
    var onPullEnd: (Bool) -> Void = { _ in }

    private var pullStart: NSPoint?
    private var pull = NotchPullGesture()
    private var pullLive = false
    var isPulling: Bool { pullLive }

    override func mouseDown(with event: NSEvent) {
        beginPull(at: NSEvent.mouseLocation, time: event.timestamp)
        super.mouseDown(with: event)
    }

    func beginPull(at point: NSPoint, time: TimeInterval) {
        pullLive = false
        pullStart = point
        pull = NotchPullGesture()
        pull.move(translation: 0, at: time)
    }

    override func mouseDragged(with event: NSEvent) {
        movePull(to: NSEvent.mouseLocation, time: event.timestamp)
        super.mouseDragged(with: event)
    }

    func movePull(to point: NSPoint, time: TimeInterval) {
        if let start = pullStart {
            pull.move(translation: point.y - start.y, at: time)
            if pull.engaged { pullLive = true }
            if pullLive { onPullSlide(pull.offset(for: .card)) }
        }
    }

    override func mouseUp(with event: NSEvent) {
        endPull(at: event.timestamp)
        super.mouseUp(with: event)
    }

    func endPull(at time: TimeInterval) {
        let committed = pullLive ? pull.release(at: time, surface: .card) == .commit : nil
        pullLive = false
        pullStart = nil
        if let committed { onPullEnd(committed) }
    }

    /// Dismissal or unpinning cancels a pull without a release verdict.
    func abortPull() {
        pullLive = false
        pullStart = nil
        pull = NotchPullGesture()
    }
}

/// The glass card under the notch — the band's peek and pinned card.
/// It is the fallback surface: while the Notch island is drawn the
/// island itself grows into the card instead, and this panel stays
/// dark. Click-through until pinned; keyboard focus requires the Shelf command.
///
/// Material rule: Liquid Glass (`NSGlassEffectView`) is only for
/// surfaces that visibly float off the notch — this one hangs 8 points
/// under its anchor. Anything flush with the notch or growing out of it
/// (the island's faces) stays solid black. `JRBAR_PLAIN_MATERIAL=1`
/// swaps the glass for a plain `NSVisualEffectView`, same as the panel.
@MainActor
final class NotchCardPanel: NSPanel {
    let hosting: NotchCardHostingView
    private let backdrop: NSView
    var presentationEnabled = true
    private var pendingPresentation: (anchor: NSRect, clearance: CGFloat)?

    /// Rounder than the island's shoulder — a surface, not a capsule —
    /// and as round as the system's own glass panels.
    static let cornerRadius: CGFloat = 22
    /// The air between the card and what it hangs from — the gap is
    /// what makes the card a floating surface.
    static let anchorGap: CGFloat = 8

    /// The frame the card last presented at — the pull's slide base and
    /// its retreat target.
    private var restFrame: NSRect?

    init(model: NotchCardModel) {
        self.model = model
        let hosting = NotchCardHostingView(rootView: NotchCardView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        self.hosting = hosting
        let plain = ProcessInfo.processInfo.environment["JRBAR_PLAIN_MATERIAL"] != nil
        if !plain {
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
            glass.cornerRadius = Self.cornerRadius
            glass.style = .regular
            glass.contentView = hosting
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.cornerRadius
            effect.layer?.cornerCurve = .continuous
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
        super.init(contentRect: NSRect(x: 0, y: 0, width: 120, height: 26),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = GlassBackdrop.rounded(backdrop, cornerRadius: Self.cornerRadius)
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
        // Fold's warp captures the desktop — the card must not be in it,
        // the same exclusion the island's own panel claims.
        // JRBAR_CAPTURE_CARD is a dev-only escape so screencapture can see
        // the card in screenshots (it ships unset).
        if ProcessInfo.processInfo.environment["JRBAR_CAPTURE_CARD"] == nil {
            sharingType = .none
        }
        alphaValue = 0
        hosting.onPullSlide = { [weak self] offset in
            guard let self, let restFrame = self.restFrame else { return }
            var pulled = restFrame
            pulled.origin.y += offset
            self.setFrame(pulled, display: true)
        }
        hosting.onPullEnd = { [weak self] committed in
            guard let self, let restFrame = self.restFrame else { return }
            if committed {
                // The pull owns the dismiss — the card is already where
                // the finger left it, `onClose` runs the same let-go as
                // the card's own ✕.
                self.restFrame = nil
                self.pendingPresentation = nil
                self.model.onClose?()
            } else if let pending = self.pendingPresentation {
                self.pendingPresentation = nil
                self.present(under: pending.anchor, clearance: pending.clearance)
            } else {
                // Short or slow — the card springs back onto its anchor.
                let reduced = NotchSurfaceMotion.reduceMotion
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = reduced ? NotchMotion.panelReducedOut : NotchMotion.glassSpringBack
                    context.timingFunction = NotchSurfaceMotion.panelCurve
                    self.animator().setFrameOrigin(restFrame.origin)
                }
            }
        }
    }

    private var keyboardWanted = false
    var onKeyboardKey: (UInt16, Bool) -> Void = { _, _ in }
    var onKeyboardLost: () -> Void = {}
    override var canBecomeKey: Bool { keyboardWanted }
    override var acceptsFirstResponder: Bool { keyboardWanted }
    override var canBecomeMain: Bool { false }

    func takeKeyboard() {
        keyboardWanted = true
        if presentationEnabled {
            makeFirstResponder(self)
            makeKey()
        }
    }

    func returnKeyboard() {
        guard keyboardWanted else { return }
        keyboardWanted = false
        guard presentationEnabled, isKeyWindow else { return }
        super.orderOut(nil)
        super.orderFrontRegardless()
    }

    override func keyDown(with event: NSEvent) {
        guard keyboardWanted, ShelfKeyboardInput.claims(modifiers: event.modifierFlags) else {
            super.keyDown(with: event)
            return
        }
        onKeyboardKey(event.keyCode, event.modifierFlags.contains(.shift))
    }

    override func resignKey() {
        super.resignKey()
        guard keyboardWanted else { return }
        keyboardWanted = false
        onKeyboardLost()
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let changed = super.makeFirstResponder(responder)
        if changed, keyboardWanted, responder !== self {
            keyboardWanted = false
            onKeyboardLost()
        }
        return changed
    }

    /// Pinning enables mouse controls. Keyboard focus requires the
    /// separate Shelf command; the panel remains non-activating.
    private(set) var isPinned = false
    let model: NotchCardModel

    func setPinned(_ pinned: Bool) {
        if !pinned {
            returnKeyboard()
            onKeyboardLost()
            hosting.abortPull()
            pendingPresentation = nil
        }
        isPinned = pinned
        ignoresMouseEvents = !pinned
        model.pinned = pinned
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Hang the card under `anchor` — the island's frame while it is up,
    /// else the band, else the notch itself — dropped `clearance` more
    /// when the buddy's HUD panel claims the room first.
    func present(under anchor: NSRect, clearance: CGFloat = 0) {
        // Live geometry waits for the gesture; only the latest anchor matters.
        if hosting.isPulling {
            pendingPresentation = (anchor, clearance)
            return
        }
        pendingPresentation = nil
        hosting.abortPull()
        hosting.rootView = NotchCardView(model: model)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let height = max(26, size.height)
        let width = max(60, size.width)
        let origin = NSPoint(x: (anchor.midX - width / 2).rounded(),
                             y: (anchor.minY - Self.anchorGap - height - clearance).rounded())
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        restFrame = frame
        // The card settles `glassSettle` pt down into place — it arrives from the
        // notch, it does not pop.
        let enters = !(isVisible && alphaValue > 0.01)
        if enters { setFrame(frame, display: true) }
        guard presentationEnabled else { return }
        NotchSurfaceMotion.present(self, settle: enters ? NotchMotion.glassSettle : 0,
                                   duration: NotchMotion.glassIn, reducedDuration: NotchMotion.glassReducedIn) { target in
            // A live card resizing under new rows eases to the new frame
            // inside the same group — one coalesced setFrame, never a
            // snap per refresh.
            if !enters, frame != self.frame { target.setFrame(frame, display: true) }
        }
    }

    func dismiss() {
        returnKeyboard()
        onKeyboardLost()
        hosting.abortPull()
        pendingPresentation = nil
        restFrame = nil
        NotchSurfaceMotion.dismiss(self, duration: NotchMotion.glassOut,
                                   reducedDuration: NotchMotion.glassReducedOut)
    }
}
