import JRBarCore
import JRBarUI
import SwiftUI

struct SettingsProvidersPage: View {
    let store: SettingsStore

    private var list: ProviderListStore { store.providerList }

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
            HStack {
                Text("Providers").frame(maxWidth: .infinity, alignment: .leading)
                column("Track")
                column("Menu bar")
                column("Panel")
                Color.clear.frame(width: 20)
            }
            .jrbarType(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, JRBarTokens.Space.md)
            SettingsGroup {
                ForEach(list.providers, id: \.identity) { row in
                    providerRow(row)
                        .draggable(row.id)
                        .dropDestination(for: String.self) { values, _ in
                            guard store.isLive, !list.writingPresentation,
                                  let source = values.first, source != row.id,
                                  list.providers.contains(where: { $0.id == source }),
                                  !list.busy.contains(source), !list.busy.contains(row.identity) else { return false }
                            let order = Self.moving(source, before: row.id, in: list.providers.map(\.id))
                            _ = Task { try? await list.setOrder(order) }
                            return true
                        }
                }
            }
            ProviderComingSoonView(availableProviderIDs: Set(list.providers.map(\.id)),
                reveal: store.searchHit?.title == "Coming soon", revealRequest: store.revealRequest)
            if list.loading && list.providers.isEmpty { ProgressView().controlSize(.small) }
            if store.isLive && !list.loading && list.providers.isEmpty && list.failure == nil {
                StatusBanner("No providers reported")
            }
            if store.isLive, list.failure != nil { SettingsProviderFailureBanner(list: list) }
            SectionNote("Track off stops JR-Bar's reads and jobs. The hook stays installed until you remove the integration.")
        }
        .id(SettingsStore.groupAnchor("Providers"))
        .task(id: store.isLive) { if store.isLive { await list.refresh() } }
    }

    private func column(_ title: String) -> some View { Text(title).frame(width: 62) }

    private func providerRow(_ row: ProviderRow) -> some View {
        HStack(spacing: JRBarTokens.Space.sm) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                .help("Drag to reorder")
            ProviderLogoTile(provider: row.id, accent: store.providerStyle(row.id).accent, dim: !row.enabled)
            Button { store.selectedProvider = row.id } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(ProviderPalette.displayName(for: row.id)).jrbarType(.body)
                    HStack(spacing: JRBarTokens.Space.xs) {
                        StateDot(state(row))
                        Text(row.enabled ? status(row) : "Not tracked")
                            .jrbarType(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            providerSwitch("Track", row: row, on: row.enabled) { try await list.setTracked(row, $0) }
            providerSwitch("Menu bar", row: row, on: list.showsInMenuBar(row.id)) { try await list.setMenuBarVisible(row.id, $0) }
                .disabled(!row.enabled)
            providerSwitch("Panel", row: row, on: list.showsInPanel(row)) { try await list.setPanelVisible(row, $0) }
                .disabled(!row.enabled)
            Button { store.selectedProvider = row.id } label: {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain).frame(width: 20)
            .accessibilityLabel("Open \(ProviderPalette.displayName(for: row.id)) settings")
        }
        .padding(.horizontal, JRBarTokens.Space.md)
        .padding(.vertical, JRBarTokens.Space.sm)
        .disabled(!store.isLive || list.busy.contains(row.identity) || list.writingPresentation)
        .contextMenu {
            Button("Move Up") { move(row, by: -1) }
            Button("Move Down") { move(row, by: 1) }
        }
    }

    private func state(_ row: ProviderRow) -> StateDot.State {
        guard row.enabled, store.isLive else { return .stale }
        switch row.state {
        case "ready", "live": return .live
        case "error", "failed": return .failed
        case "collecting", "scanning": return .working
        default: return .stale
        }
    }

    private func status(_ row: ProviderRow) -> String {
        guard store.isLive else { return "Last saved settings" }
        if store.hookDetected(row.id) == false { return "Not found on this Mac" }
        if let reason = row.reason { return reason.replacingOccurrences(of: "_", with: " ") }
        return row.supportsQuota ? "Tracking" : "Sessions only"
    }

    private func providerSwitch(_ title: String, row: ProviderRow, on: Bool,
                                write: @escaping @MainActor (Bool) async throws -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { value in _ = Task { try? await write(value) } }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .frame(width: 62)
            .accessibilityLabel("\(ProviderPalette.displayName(for: row.id)) \(title)")
    }

    private func move(_ row: ProviderRow, by offset: Int) {
        guard store.isLive, !list.writingPresentation, !list.busy.contains(row.identity) else { return }
        var ids = list.providers.map(\.id)
        guard let index = ids.firstIndex(of: row.id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        Task { try? await list.setOrder(ids) }
    }

    static func moving(_ source: String, before target: String, in ids: [String]) -> [String] {
        guard source != target, ids.contains(source), ids.contains(target) else { return ids }
        var result = ids.filter { $0 != source }
        result.insert(source, at: result.firstIndex(of: target)!)
        return result
    }
}

struct SettingsProviderDetail: View {
    let store: SettingsStore
    let provider: String
    @ViewState private var asksForConsent = false
    @ViewState private var doctor = HooksDoctorModel()

    private var row: ProviderRow? { store.providerList.providers.first { $0.id == provider } }

    var body: some View {
        SettingsBackRow(store: store)
            .task {
                doctor.refresh(core: store.core)
                store.core.checkProviderUpdates()
            }
            .onChange(of: store.hookBusy) { before, after in
                if after.count < before.count { doctor.refresh(core: store.core) }
            }
            .onChange(of: store.core.providerUpdates) { before, after in
                if before.values.contains(where: { $0.isRunning }), !after.values.contains(where: { $0.isRunning }) {
                    doctor.refresh(core: store.core)
                }
            }
            .onChange(of: store.isLive) { _, live in
                if live { doctor.refresh(core: store.core) }
            }
        if let row {
            SettingGroup(ProviderPalette.displayName(for: provider)) {
                SettingsRow("Read usage", subtitle: row.usageConsent?.detail) {
                    Toggle("Read usage", isOn: Binding(
                        get: { row.usageConsent?.granted ?? false },
                        set: { on in
                            if on { asksForConsent = true }
                            else { _ = Task { try? await store.providerList.setUsageConsent(row, false) } }
                        }
                    ))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(!row.enabled || row.usageConsent == nil || store.providerList.busy.contains(row.identity))
                }
                Provided(store, "session_open_preferences") {
                    SettingsRow("Clicks Open") {
                        Picker("Clicks Open", selection: store.optionalString("session_open_preferences.\(provider)")) {
                            ForEach(AgentsPage.openChoices, id: \.value) { Text($0.label).tag($0.value) }
                        }.labelsHidden()
                    }
                }
                if provider == "claude" { ClaudePlanLimitsRow(store: store) }
                if ["factory", "kimi", "kilo"].contains(provider) {
                    ProviderCredentialControls(row: row, core: store.core,
                        onOptionsSaved: { _ in _ = Task { await store.providerList.refresh() } }) {
                        Task { await store.providerList.refresh() }
                    }
                    .padding(JRBarTokens.Space.md)
                }
                AgentRow(store: store, provider: provider, doctor: doctor.entry(for: provider, live: store.isLive))
                    .padding(JRBarTokens.Space.md)
                SettingsRow("Remove integration", subtitle: "Removes JR-Bar's hook from this provider's configuration.") {
                    Button("Remove integration", role: .destructive) { store.requestIntegrationRemoval(provider) }
                        .disabled(store.hookBusy.contains(provider) || store.hookStatus(provider) == "missing")
                }
            }
            .disabled(!store.isLive)
            .confirmationDialog("Read \(ProviderPalette.displayName(for: provider)) usage?", isPresented: WindowPresenter.presentation($asksForConsent),
                                titleVisibility: .visible) {
                Button("Allow") { _ = Task { try? await store.providerList.setUsageConsent(row, true) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text(row.usageConsent?.summary ?? "") }
        }
        SettingsProviderFailureBanner(list: store.providerList)
    }
}

struct SettingsProviderFailureBanner: View {
    let list: ProviderListStore

    func retry() async { await list.refresh() }

    var body: some View {
        if let failure = list.failure {
            StatusBanner(failure, kind: .failure) {
                Button("Retry") { _ = Task { await retry() } }
            }
        }
    }
}
