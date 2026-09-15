import AppKit
import JRBarCore
import SwiftUI

/// The Utilities page (docs/UTILITIES.md): the monogram header, then
/// one card per utility in contract order — Menu Bar first; Dock and
/// the Notch card land here as their phases do. The cards reuse
/// `ToyCard`'s shape so the page reads like Toys: same tile, name,
/// blurb, status chip, on/off toggle and disclosure body.
struct UtilitiesPage: View {
    let store: SettingsStore
    private var tint: Color { SettingsStore.Page.utilities.tint }

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 14) {
                JRMonogram(tint: tint)
                Text("Tools that replace other apps. They manage your Mac's own surfaces — the menu bar, the dock, the notch — and keep the agent roster organized.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }

        if let utilities = store.utilities {
            Section {
                MenuBarUtilityCard(utility: utilities.menuBar, tint: tint)
                DockUtilityCard(utility: utilities.dock, tint: tint)
                // The roster's management seat — the compact list and
                // the session verbs; the Overview window stays the canvas.
                AgentUtilityCard(utility: utilities.agents, tint: tint)
                // Notch lives in ToysStore but reads as a utility — it
                // manages the notch itself, not something playful.
                if let notch = store.toys?.notch {
                    ToyCard(toy: notch, tint: tint)
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
