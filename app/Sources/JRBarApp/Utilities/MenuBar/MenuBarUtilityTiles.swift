import AppKit
import ApplicationServices
import CoreGraphics
import JRBarCore
import Observation
import SwiftUI

/// The Menu Bar utility's tile actions: a press through Accessibility,
/// never the pointer.
extension MenuBarUtility {
    // MARK: Tile actions

    /// A plain click on a tile: `AXPress` the item's element —
    /// Accessibility required. It reaches a covered item without
    /// dropping the shutter and a system-parked item a click could
    /// never hit. Without the grant the tile just raises the owning
    /// app, the posture the permissions row sets — and so does an
    /// element that can no longer be resolved (the app reordered its
    /// extras mid-relaunch).
    func trigger(_ item: MenuBarItem) {
        let granted = probeAccessibility()
        bar.close()
        guard granted else {
            // No Accessibility: nothing can press the item.
            item.owner?.activate()
            return
        }
        Task.detached { [weak self] in
            if MenuBarAX.press(item) { return }
            await MainActor.run { self?.clickFallback(item) }
        }
    }

    /// The no-press fallback: raise the owning app, the answer the
    /// no-Accessibility path gives. A posted click at the item's frame
    /// would move the person's pointer there — synthetic input the
    /// utility never sends on its own.
    private func clickFallback(_ item: MenuBarItem) {
        item.owner?.activate()
    }

    /// A ⌘-click on a tile: pull the item up into the hidden run and
    /// drop the spacer so it shows — the always-hidden section's own
    /// reveal gesture.
    func revealItem(_ item: MenuBarItem) {
        setSection(.hidden, for: item.id)
        hider.reveal([.hidden])
        reveal.rearm()
    }
}
