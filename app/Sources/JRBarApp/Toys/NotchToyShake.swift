import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Shake to summon: a shake during any drag opens the card under the
/// notch as a drop target. The monitors and samples live on `NotchToy`.
extension NotchToy {
    /// Shake-summon rides the island's own lifecycle: the monitors
    /// stand while the island is drawn, visible, enabled, and the
    /// setting is on — and die the moment any of those go.
    func syncShakeMonitor() {
        let wanted = runtimeEnabled && settings.enabled
            && settings.shelfShakeToSummon && isDrawingIsland && islandVisible
        if wanted, shakeDragMonitor == nil {
            shakeDragMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: .leftMouseDragged
            ) { [weak self] event in
                let x = NSEvent.mouseLocation.x
                let at = event.timestamp
                Task { @MainActor [weak self] in
                    self?.noteDragSample(x: x, at: at)
                }
            }
            shakeUpMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: .leftMouseUp
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.shakeSamples.removeAll()
                }
            }
        } else if !wanted {
            if let monitor = shakeDragMonitor { NSEvent.removeMonitor(monitor) }
            if let monitor = shakeUpMonitor { NSEvent.removeMonitor(monitor) }
            shakeDragMonitor = nil
            shakeUpMonitor = nil
            shakeSamples.removeAll()
        }
    }

    /// One dragged-pointer sample: keep the buffer bounded, ask the
    /// recognizer, and on a shake pull the card open — with a fold
    /// timer, because a shake is not a promise to drop.
    private func noteDragSample(x: CGFloat, at time: TimeInterval) {
        shakeSamples.append(ShelfShakeDetector.Sample(x: x, at: time))
        if shakeSamples.count > 240 {
            shakeSamples.removeFirst(shakeSamples.count - 240)
        }
        guard ShelfShakeDetector.isShake(shakeSamples) else { return }
        shakeSamples.removeAll()
        shelfSummon()
        armSummonExpiry()
    }

    /// A shake-summoned card nobody drops on folds after five
    /// seconds — the same `shelfDragAbandoned` fold a drag exit takes.
    private func armSummonExpiry() {
        shelfSummonExpiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.shelfSummonExpiry = nil
            self?.shelfDragAbandoned()
        }
        shelfSummonExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// A real drag reaching the island — the summon is now backed by
    /// the hovering drag itself, so the shake expiry stands down and
    /// `draggingExited`/`Ended` own the fold from here.
    func shelfDragAtIsland() {
        shelfSummonExpiry?.cancel()
        shelfSummonExpiry = nil
        shelfDragLeaveWork?.cancel()
        shelfDragLeaveWork = nil
        shelfDragOverIsland = true
        shelfSummon()
    }
}
