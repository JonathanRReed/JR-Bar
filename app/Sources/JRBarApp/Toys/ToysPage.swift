import AppKit
import JRBarCore
import SwiftUI

/// The Toys page (docs/TOYS.md): one `ToyCard` per toy in contract
/// order, each its own group, under the page header the container
/// draws. The page renders whatever `ToysStore.toys` holds — the cards
/// are generic so a toy that is not built yet is simply absent.
/// External apps are launched per-card via the provider pickers, so
/// this page has no "other apps" section.
struct ToysPage: View {
    let store: SettingsStore
    private var tint: Color { SettingsStore.Page.toys.tint }

    var body: some View {
        if let toys = store.toys {
            ForEach(toys.toys, id: \.id) { toy in
                Section {
                    ToyCard(toy: toy, tint: ToyCard.tint(for: toy.id, page: tint))
                }
            }
        } else {
            Section {
                Text("Toys are not available in this build.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
