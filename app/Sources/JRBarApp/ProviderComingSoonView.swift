import JRBarCore
import SwiftUI

struct ProviderComingSoonState {
    var expanded = false
    var query = ""

    mutating func reveal() {
        query = ""
        expanded = true
    }
}

struct ProviderComingSoonView: View {
    let availableProviderIDs: Set<String>
    var reveal = false
    var revealRequest = 0
    @ViewState private var state = ProviderComingSoonState()

    nonisolated static let title = "Coming soon"
    nonisolated static let note = "Usage integrations planned for future updates."

    private var upcoming: [ProviderRoadmapEntry] {
        ProviderUsageRoadmap.upcoming(availableProviderIDs: availableProviderIDs)
    }

    var body: some View {
        if !upcoming.isEmpty {
            DisclosureGroup(isExpanded: $state.expanded) {
                ProviderComingSoonList(availableProviderIDs: availableProviderIDs, query: $state.query)
                    .padding(.top, 8)
            } label: {
                HStack {
                    Text(Self.title)
                    Text("\(upcoming.count) providers")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)
            }
            .id(SettingsStore.groupAnchor(Self.title))
            .padding(.top, 8)
            .onAppear { if reveal { state.reveal() } }
            .onChange(of: revealRequest) { _, _ in if reveal { state.reveal() } }
        }
    }
}

struct ProviderComingSoonList: View {
    let availableProviderIDs: Set<String>
    @Binding var query: String

    private var matches: [ProviderRoadmapEntry] {
        ProviderUsageRoadmap.upcoming(availableProviderIDs: availableProviderIDs, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ProviderComingSoonView.note)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Find a provider", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .accessibilityLabel("Find a planned provider")
            if matches.isEmpty {
                Text("No matching providers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)],
                          alignment: .leading, spacing: 8) {
                    ForEach(matches) { provider in
                        Text(provider.name)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("\(provider.name), coming soon")
                    }
                }
            }
        }
    }
}
