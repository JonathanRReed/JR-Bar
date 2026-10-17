import AppKit
import JRBarCore
import QuartzCore
import SwiftUI

/// The island's shadow, on a panel of its own: borderless, never takes a
/// click (`ignoresMouseEvents`), excluded from screen capture like the
/// island, laid immediately under it. It is drawn once per landed shape and
/// faded in and out; nothing here ticks.
@MainActor
final class NotchShadowPanel: NSPanel {
    private let model = NotchShadowModel()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: NotchShadowView(model: model))
        hosting.sizingOptions = []
        contentView = hosting
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        alphaValue = 0
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        level = .statusBar
        sharingType = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Whether the shadow is meant to be up (it may still be fading).
    private(set) var isCast = false

    /// Cast the shadow of `shape` (the island's landed frame), just under
    /// `island` in the window order. A shadow already up only moves.
    func cast(shape: NSRect, silhouette: NotchSilhouette, under island: NSWindow) {
        model.silhouette = silhouette
        model.size = shape.size
        let frame = NotchShadow.frame(for: shape)
        if self.frame != frame { setFrame(frame, display: true) }
        order(.below, relativeTo: island.windowNumber)
        guard !isCast else { return }
        isCast = true
        NotchSurfaceMotion.fade(self, to: 1, duration: NotchShadow.fadeIn,
                                reducedDuration: NotchMotion.glassReducedIn, curve: NotchSurfaceMotion.panelCurve)
    }

    /// Let the shadow go: as a fold begins, or the island leaves.
    func lift(immediately: Bool = false) {
        guard isCast || isVisible else { return }
        let wasCast = isCast
        isCast = false
        if immediately {
            alphaValue = 0
            orderOut(nil)
            return
        }
        guard wasCast else { return }
        NotchSurfaceMotion.dismiss(self, duration: NotchShadow.fadeOut,
                                   reducedDuration: NotchMotion.glassReducedOut)
    }
}

@MainActor
@Observable
final class NotchShadowModel {
    var silhouette = NotchSilhouette(notchDepth: 0, restingRadius: 0)
    var size = CGSize.zero
}

struct NotchShadowView: View {
    let model: NotchShadowModel

    var body: some View {
        let silhouette = model.silhouette
        let frame = NotchShadow.local(CGRect(origin: .zero, size: model.size))
        ZStack(alignment: .topLeading) {
            silhouette.fill(.black)
                .frame(width: frame.width, height: frame.height)
                .shadow(color: .black.opacity(NotchShadow.ambient.opacity),
                        radius: NotchShadow.ambient.radius, y: NotchShadow.ambient.offset)
                .shadow(color: .black.opacity(NotchShadow.contact.opacity),
                        radius: NotchShadow.contact.radius, y: NotchShadow.contact.offset)
                .offset(x: frame.minX, y: frame.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
