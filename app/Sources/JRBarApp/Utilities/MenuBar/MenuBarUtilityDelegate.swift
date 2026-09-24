import AppKit
import ApplicationServices
import CoreGraphics
import JRBarCore
import Observation
import SwiftUI

// MARK: - MenuBarActionsDelegate

/// The actions facade's seam: every command-bar row, hotkey and
/// trigger lands on the same machinery the card rows use.
extension MenuBarUtility: MenuBarActionsDelegate {
    func menuBarItems(for _: MenuBarActions) -> [MenuBarItem] { listedItems }

    func menuBarSections(for _: MenuBarActions) -> [String: MenuBarItemSection] {
        // The palette's truth is the effective section: under the
        // concealer a concealed item reads hidden, so its row offers
        // "Show" and "Open" — never "Hide".
        var map: [String: MenuBarItemSection] = [:]
        for item in listedItems { map[item.id] = effectiveSection(for: item) }
        return map
    }

    func menuBarActions(_: MenuBarActions, setSection section: MenuBarItemSection,
                        for itemID: String) {
        setSection(section, for: itemID)
    }

    func menuBarActions(_: MenuBarActions, openItem itemID: String) {
        guard let item = listedItems.first(where: { $0.id == itemID }) else { return }
        trigger(item)
    }

    func menuBarActionsRevealHidden(_: MenuBarActions) {
        hider.reveal([.hidden])
        reveal.rearm()
    }

    /// The `toggleReveal` hotkey is the chevron's click: whatever the
    /// transition is — reveal when the run is parked, re-hide when a
    /// reveal is out — it happens.
    func menuBarActionsToggleReveal(_: MenuBarActions) {
        // The hotkey's bar is the keyboard's: it takes key, and the
        // arrows, a typed filter and Return reach every hidden item
        // without the pointer.
        toggleHiddenSection(fromKeyboard: true)
    }

    func menuBarActionsFoldItemBar(_: MenuBarActions) {
        bar.close()
    }

    /// The dedicated always-hidden gesture: drop that run's covers on
    /// the rehide clock. Under the concealer the reveal set narrows
    /// the assertion the same way — the deeper apps stand back on the
    /// row for the window.
    func menuBarActionsRevealAlwaysHidden(_: MenuBarActions) {
        hider.reveal([.alwaysHidden])
        reveal.rearm()
    }

    func menuBarActions(_: MenuBarActions, revealFor seconds: Double) {
        hider.reveal([.hidden])
        reveal.rearm(for: seconds)
    }

    func menuBarActionsHideAll(_: MenuBarActions) {
        hideAllListed()
    }

    func menuBarActionsShowAll(_: MenuBarActions) {
        showAllListed()
    }

    func menuBarActions(_: MenuBarActions, applyProfile name: String) {
        if name == MenuBarProfiles.noneName {
            applyProfile(id: MenuBarProfiles.noneID)
        } else if let profile = settings().profiles.first(where: { $0.name == name }) {
            applyProfile(id: profile.id)
        }
        // An unknown name is a no-op, not a clear — never fall through
        // to `apply(nil)` on a mistyped trigger.
    }

    /// The hotkeys' step through the profiles — from the active one,
    /// persisted, so the cycle picks up where the card or a rule left it.
    /// The built-in "None" sits first.
    func menuBarActions(_: MenuBarActions, cycleProfile direction: Int) {
        let profiles = settings().profiles
        guard !profiles.isEmpty else { return }
        applyProfile(id: MenuBarProfiles.cycled(from: settings().curation.activeProfileID,
                                                profiles: profiles, direction: direction))
    }
}
