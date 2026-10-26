import SwiftUI

struct ToysPage: View {
    let store: SettingsStore
    var body: some View {
        SettingGroup("Toys") {
            if let toys = store.toys {
                ForEach(toys.toys, id: \.id) { toy in SettingsFeatureRow(store: store, toy: toy) }
            }
        }
    }
}
