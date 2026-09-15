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
private final class NotchCardHostingView: NSHostingView<NotchCardView> {
    /// The pull's signed slide offset — upward positive, like the finger.
    var onPullSlide: (CGFloat) -> Void = { _ in }
    /// The release verdict — true when the pull committed.
    var onPullEnd: (Bool) -> Void = { _ in }

    private var pullStart: NSPoint?
    private var pull = NotchPullGesture()
    private var pullLive = false

    override func mouseDown(with event: NSEvent) {
        pullStart = NSEvent.mouseLocation
        pull = NotchPullGesture()
        pull.move(translation: 0, at: event.timestamp)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = pullStart {
            pull.move(translation: NSEvent.mouseLocation.y - start.y, at: event.timestamp)
            if pull.engaged { pullLive = true }
            if pullLive { onPullSlide(pull.offset(for: .card)) }
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if pullLive {
            onPullEnd(pull.release(at: event.timestamp, surface: .card) == .commit)
        }
        pullLive = false
        pullStart = nil
        super.mouseUp(with: event)
    }

    /// A re-present or a dismiss mid-pull owns the frame — the pull
    /// lets go silently, no verdict.
    func abortPull() {
        pullLive = false
        pullStart = nil
        pull = NotchPullGesture()
    }
}

/// The glass card under the notch — the band's peek and pinned card.
/// It is the fallback surface: while the Notch island is drawn the
/// island itself grows into the card instead, and this panel stays
/// dark. Click-through until pinned, never key.
///
/// Material rule: Liquid Glass (`NSGlassEffectView`) is only for
/// surfaces that visibly float off the notch — this one hangs 8 points
/// under its anchor. Anything flush with the notch or growing out of it
/// (the island's faces) stays solid black. `JRBAR_PLAIN_MATERIAL=1`
/// swaps the glass for a plain `NSVisualEffectView`, same as the panel.
@MainActor
final class NotchCardPanel: NSPanel {
    private let hosting: NotchCardHostingView
    private let backdrop: NSView

    /// Rounder than the island's shoulder — a surface, not a capsule.
    static let cornerRadius: CGFloat = 18
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
                self.model.onClose?()
            } else {
                // Short or slow — the card springs back onto its anchor.
                let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = reduced ? 0.08 : 0.24
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
                    self.animator().setFrameOrigin(restFrame.origin)
                }
            }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The pinned state: the card holds open and takes mouse events so
    /// its Open/close buttons work — still `.nonactivatingPanel`, still
    /// never key, so nothing steals focus.
    private(set) var isPinned = false
    let model: NotchCardModel

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        ignoresMouseEvents = !pinned
        model.pinned = pinned
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Hang the card under `anchor` — the island's frame while it is up,
    /// else the band, else the notch itself — dropped `clearance` more
    /// when the buddy's HUD panel claims the room first.
    func present(under anchor: NSRect, clearance: CGFloat = 0) {
        // A re-present owns the frame — a pull in flight lets go first.
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
        let wasVisible = isVisible && alphaValue > 0.01
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // The card settles 4 pt down into place — it arrives from the
        // notch, it does not pop. The raised frame goes on before the
        // order so the rest position never flashes first.
        let enters = !wasVisible && !reduced
        if enters {
            setFrame(NSRect(origin: NSPoint(x: origin.x, y: origin.y + 4),
                            size: frame.size),
                     display: true)
        }
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.1 : 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            animator().alphaValue = 1
            if enters {
                animator().setFrameOrigin(origin)
            } else if frame != self.frame {
                // A live card resizing under new rows eases to the new
                // frame inside the same group — one coalesced setFrame,
                // never a snap per refresh.
                animator().setFrame(frame, display: true)
            }
        }
    }

    func dismiss() {
        hosting.abortPull()
        restFrame = nil
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
