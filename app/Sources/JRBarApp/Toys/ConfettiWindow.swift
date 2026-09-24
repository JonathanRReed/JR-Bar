import AppKit
import JRBarCore
import SwiftUI

/// The burst's overlay: a borderless, transparent, click-through window
/// hung from the top of its screen at `.screenSaver` level — one per
/// attached display, each closed by its own timer. How tall it is and
/// how long it lives are the landing mode's business, both measured off
/// that screen — Rest rains in the top band, Fall spans the screen,
/// Fade needs only the top ~70%. Shares nothing with screen capture
/// (`sharingType = .none`), like the Fold overlay.
@MainActor
final class ConfettiWindow: NSPanel {
    private let hosting: NSHostingView<ConfettiView>
    private var closer: DispatchWorkItem?
    /// How long this burst runs: the slowest piece's travel in the
    /// chosen landing mode on this screen, plus a 0.4 s tail — derived,
    /// never a constant, so a slow streamer can never be vanished
    /// mid-air the way the hardcoded 2.6 s once did.
    private let life: TimeInterval

    /// The Reduce Motion bloom is shorter — it is one fade, not a burst.
    static let flashLife: TimeInterval = 0.9

    /// `screen` is the display this overlay covers — nil only when the
    /// Mac reports no screens at all, in which case the fallback frame
    /// stands in.
    init(color: Color, settings: ConfettiSettings, densityScale: Double = 1, screen: NSScreen?) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = ConfettiView.viewHeight(for: settings.landing, screenHeight: frame.height)
        let bandBottom = (screen.map { ScreenBarGeometry.notchDepth(of: $0) } ?? 0) + 12
        let view = ConfettiView(color: color, flash: reduceMotion, settings: settings,
                                densityScale: densityScale, viewHeight: height, screenHeight: frame.height,
                                bandBottom: bandBottom)
        life = view.life
        hosting = NSHostingView(rootView: view)
        super.init(contentRect: NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        level = .screenSaver
        sharingType = .none
        alphaValue = 1
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func burst(then done: @escaping @MainActor () -> Void) {
        orderFrontRegardless()
        let span = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? Self.flashLife : life
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                self?.closer = nil
                done()
            }
        }
        closer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + span + 0.1, execute: work)
    }

    override func close() {
        closer?.cancel()
        closer = nil
        super.close()
    }
}
