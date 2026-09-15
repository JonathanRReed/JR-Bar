import AppKit
import JRBarCore
import SwiftUI

/// The Toys page (docs/TOYS.md): the monogram header then one `ToyCard`
/// per toy in contract order. The page renders whatever `ToysStore.toys`
/// holds — the cards are generic so a toy that is not built yet is
/// simply absent. External apps are launched per-card via the provider
/// pickers, so this page has no "other apps" section.
struct ToysPage: View {
    let store: SettingsStore
    private var tint: Color { SettingsStore.Page.toys.tint }

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 14) {
                JRMonogram(tint: tint)
                Text("Stuff that's just fun. None of it touches your agents or your usage, & every bit of it can be turned off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }

        if let toys = store.toys {
            Section {
                ForEach(toys.toys, id: \.id) { toy in
                    ToyCard(toy: toy, tint: tint)
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
