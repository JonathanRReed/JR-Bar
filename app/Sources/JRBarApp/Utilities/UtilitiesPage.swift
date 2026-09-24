import AppKit
import JRBarCore
import SwiftUI

/// The Utilities page (docs/UTILITIES.md): one card per utility in
/// contract order — Menu Bar, Dock, Agent Overview, Data Hoarder,
/// Notch — each its own group under the page header the container
/// draws. The cards reuse `ToyCard`'s shape so the page reads like
/// Toys: same tile, name, pill, blurb, switch and disclosure body.
struct UtilitiesPage: View {
    let store: SettingsStore
    private var tint: Color { SettingsStore.Page.utilities.tint }

    private func tint(_ id: String) -> Color { ToyCard.tint(for: id, page: tint) }

    var body: some View {
        if let utilities = store.utilities {
            Section {
                MenuBarUtilityCard(utility: utilities.menuBar, tint: tint(utilities.menuBar.id))
            }
            Section {
                DockUtilityCard(utility: utilities.dock, tint: tint(utilities.dock.id))
            }
            Section {
                // The roster's management seat — the compact list and
                // the session verbs; the Overview window stays the canvas.
                AgentUtilityCard(utility: utilities.agents, tint: tint(utilities.agents.id))
            }
            Section {
                ToyCard(toy: utilities.dataHoarder, tint: tint(utilities.dataHoarder.id))
            }
            // Notch lives in ToysStore but reads as a utility — it
            // manages the notch itself, not something playful.
            if let notch = store.toys?.notch {
                Section {
                    ToyCard(toy: notch, tint: tint(notch.id))
                }
            }
        } else {
            Section {
                Text("Utilities are not available in this build.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
