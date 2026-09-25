import AppKit
import JRBarCore
import SwiftUI

/// The burst's overlay: a borderless, transparent, click-through window
/// over one whole screen at `.screenSaver` level — one per free display,
/// each closed by its own timer the moment its burst is done. Shares
/// nothing with screen capture (`sharingType = .none`), like the Fold
/// overlay, so a burst never lands in a recording or a shared screen.
@MainActor
final class ConfettiWindow: NSPanel {
    private let hosting: NSHostingView<ConfettiView>
    private var closer: DispatchWorkItem?
    /// Rest re-reads the windows once a second, so a piece lying on one
    /// that moved or closed fades instead of floating.
    private var ledgeTimer: Timer?
    private let started = Date()
    /// How long this burst runs: the burst's own worked-out life (the
    /// last piece gone), or the Reduce Motion glow's.
    let life: TimeInterval
    let burst: ConfettiBurst

    init(burst: ConfettiBurst, look: ConfettiLook, frame: NSRect, meter: ConfettiDrawMeter?) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let watch = burst.recipe.landing == .rest && !burst.ledges.isEmpty ? ConfettiLedgeWatch() : nil
        let view = ConfettiView(burst: burst, look: look, flash: reduceMotion, ledges: watch, meter: meter,
                                marks: ConfettiMarks())
        self.burst = burst
        life = reduceMotion ? ConfettiView.flashLife : burst.life
        hosting = NSHostingView(rootView: view)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                   defer: false)
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
        if let watch, !reduceMotion { watchLedges(watch, screen: frame) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func burst(then done: @escaping @MainActor () -> Void) {
        orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.stopWatching()
                self?.orderOut(nil)
                self?.closer = nil
                done()
            }
        }
        closer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + life + 0.1, execute: work)
    }

    override func close() {
        closer?.cancel()
        closer = nil
        stopWatching()
        super.close()
    }

    /// Once a second, which of the burst's ledges still stand.
    private func watchLedges(_ watch: ConfettiLedgeWatch, screen: NSRect) {
        let ledges = burst.ledges
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let primaryHeight = NSScreen.screens.first?.frame.maxY ?? screen.maxY
                let now = OnScreenWindows.quartzFrames().map {
                    OnScreenWindows.local($0, on: screen, primaryHeight: primaryHeight)
                }
                watch.note(standing: ConfettiBurst.standing(ledges, now: now),
                           at: Date().timeIntervalSince(self.started))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ledgeTimer = timer
    }

    private func stopWatching() {
        ledgeTimer?.invalidate()
        ledgeTimer = nil
    }
}
