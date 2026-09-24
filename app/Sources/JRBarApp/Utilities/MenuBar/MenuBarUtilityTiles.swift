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
            item.owner?.activate()
            return
        }
        if concealer != nil, let id = item.bundleID,
           MenuBarConcealPlan.concealed(apps: liveSettings().concealedApps, revealed: hider.revealed).contains(id) {
            // Concealed: only this app stands. The assertion's target
            // narrows by exactly this bundle — every other hidden app
            // stays concealed, so the bar never lifts — then the item
            // gets a beat to draw, the press lands on its fresh frame,
            // and the full target goes back up after the rehide window.
            let rehide = settings().rehideSeconds
            // Held past the press and the rehide window; `releaseLift`
            // ends it once the app's menu is closed.
            lift(id, until: Date().addingTimeInterval(3 + rehide))
            Task { [weak self] in
                guard let self else { return }
                var fresh = item
                // Poll up to ~600 ms for the item's real frame — the
                // agent needs a beat to draw a just-unconcealed item,
                // and its ghost's frozen frame is not where it lands.
                for _ in 0..<6 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    _ = await MenuBarItemLister.refreshAXItems()
                    if let found = MenuBarItemLister.axItems.first(where: { $0.id == item.id }) {
                        fresh = found
                        if MenuBarItemLister.onAnyMenuBarRow(found.bounds) { break }
                    }
                }
                // The press waits on the owner's reply — up to the
                // messaging timeout twice over — so it runs off the main
                // actor, as the uncovered path's does; the lift stays here.
                let target = fresh
                let pressed = await Task.detached(priority: .userInitiated) {
                    MenuBarAX.press(target)
                }.value
                if !pressed { self.clickFallback(target) }
                try? await Task.sleep(nanoseconds: UInt64(rehide * 1e9))
                await self.releaseLift(id, item: fresh)
            }
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
