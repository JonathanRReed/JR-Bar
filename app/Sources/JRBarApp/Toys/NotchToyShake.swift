import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Shake to summon: a shake during any drag opens the card under the
/// notch as a drop target. The monitors and samples live on `NotchToy`.
extension NotchToy {
    /// Whether the shake's monitors should stand: the island drawn and
    /// up, the utility, the shelf and the gesture on — and no shelf app
    /// that owns the same shake running while the card says to step
    /// aside for it (`shelfYieldToRivals`). Pure, so the yield is pinned
    /// without a real Dropover.
    static func wantsShakeMonitor(runtimeEnabled: Bool, settings: NotchSettings,
                                  drawingIsland: Bool, islandVisible: Bool,
                                  rivalsRunning: Bool) -> Bool {
        guard runtimeEnabled, settings.enabled, settings.shelfEnabled,
              settings.shelfShakeToSummon, drawingIsland, islandVisible else { return false }
        return !(settings.shelfYieldToRivals && rivalsRunning)
    }

    /// Whether a shake may summon over the app in front: never over one
    /// the person excluded (a drawing app, where a quick back-and-forth
    /// drag is the work itself).
    static func shakeAllowed(frontmost: String?, excluded: [String]) -> Bool {
        guard let frontmost else { return true }
        return !excluded.contains(frontmost)
    }

    /// The shelf apps whose own shake is summoning right now, when the
    /// yield is on — the card's note names them.
    var shakeYieldingTo: [UtilityRivals.Rival] {
        _ = workspaceVersion
        guard settings.shelfYieldToRivals else { return [] }
        return shelfRivalsNow()
    }

    /// The running shelf rivals, asked once per app launch or quit. The
    /// question lists every running app through LaunchServices — 13 ms
    /// on the main thread, up to 96 — and `reconcile` used to ask it on
    /// every daemon doc. Nothing but a launch or a quit can change the
    /// answer, and both bump `workspaceVersion`.
    func shelfRivalsNow() -> [UtilityRivals.Rival] {
        if let memo = shelfRivalsMemo, memo.version == workspaceVersion { return memo.rivals }
        let rivals = shelfRivalsRunning()
        shelfRivalsMemo = (workspaceVersion, rivals)
        return rivals
    }

    /// Shake-summon rides the island's own lifecycle: the monitors
    /// stand while the island is drawn, visible, enabled, and the
    /// setting is on — and die the moment any of those go, or a shelf
    /// app that owns the shake launches. A launch or a quit re-runs
    /// this (`NotchToy`'s workspace watch).
    func syncShakeMonitor() {
        let settings = settings
        let wanted = Self.wantsShakeMonitor(
            runtimeEnabled: runtimeEnabled, settings: settings,
            drawingIsland: isDrawingIsland, islandVisible: islandVisible,
            rivalsRunning: settings.shelfYieldToRivals && !shelfRivalsNow().isEmpty)
        if wanted, shakeDragMonitor == nil {
            shakeDragMonitor = installShakeMonitor(.leftMouseDragged) { [weak self] event in
                let x = NSEvent.mouseLocation.x
                let at = event.timestamp
                Task { @MainActor [weak self] in
                    self?.noteDragSample(x: x, at: at)
                }
            }
            shakeUpMonitor = installShakeMonitor(.leftMouseUp) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.shakeSamples.removeAll()
                }
            }
        } else if !wanted {
            if let monitor = shakeDragMonitor { removeShakeMonitor(monitor) }
            if let monitor = shakeUpMonitor { removeShakeMonitor(monitor) }
            shakeDragMonitor = nil
            shakeUpMonitor = nil
            shakeSamples.removeAll()
        }
    }

    /// One dragged-pointer sample: keep the buffer bounded, ask the
    /// recognizer at the person's sensitivity, and on a shake pull the
    /// card open — with a fold timer, because a shake is not a promise
    /// to drop. An excluded app in front keeps the shelf down.
    func noteDragSample(x: CGFloat, at time: TimeInterval) {
        shakeSamples.append(ShelfShakeDetector.Sample(x: x, at: time))
        if shakeSamples.count > 240 {
            shakeSamples.removeFirst(shakeSamples.count - 240)
        }
        guard ShelfShakeDetector.isShake(shakeSamples, sensitivity: settings.shelfShakeSensitivity)
        else { return }
        shakeSamples.removeAll()
        guard Self.shakeAllowed(frontmost: shakeFrontmostApp(),
                                excluded: settings.shelfShakeExcludedBundleIDs) else { return }
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
