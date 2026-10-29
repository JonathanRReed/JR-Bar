import JRBarCore
import JRBarUI
import Observation
import SwiftUI

/// Settings › Agents & Usage › Provider usage: one switch per provider for the read
/// that asks that provider (or reads another app's sign-in) for usage.
///
/// Every switch starts off. The words under each are the daemon's own
/// (`list_providers` → `usage_consent`), so the sentence here is the one
/// Setup and the Usage Center card show: who is asked, which host, with
/// whose sign-in. A provider's token counts from files on this Mac stay on
/// whether its switch is on or not.
@MainActor
@Observable
final class ProviderUsageSwitchesModel {
    private(set) var rows: [ProviderRow] = []
    private(set) var loading = false
    /// The provider ids with a write in flight; a second tap cannot stack.
    private(set) var busy: Set<String> = []
    /// The last write's failure, in the daemon's words; cleared by the next success.
    private(set) var failure: String?
    private(set) var loadFailure: String?
    @ObservationIgnored private var active: Bool
    @ObservationIgnored private var readRevision = 0
    @ObservationIgnored private var mutationRevision = 0
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored var readRows: @MainActor (CoreModel) async throws -> [ProviderRow] = {
        try await $0.listProviders()
    }
    @ObservationIgnored var writeConsent: @MainActor (CoreModel, String, Bool) async throws -> ProviderRow = {
        try await $0.setProviderUsageConsent($1, enabled: $2, source: "settings")
    }

    nonisolated init(active: Bool = true) { self.active = active }

    /// Every provider's default account, in the daemon's order, that has a
    /// switch to show.
    var switchRows: [ProviderRow] {
        rows.filter { $0.instance == "default" && $0.usageConsent != nil }
    }

    static func usageTitle(_ row: ProviderRow) -> String {
        "Show \(ProviderStyle.style(for: row.id).name) usage"
    }

    var searchEntries: [SettingsSearchEntry] {
        var entries = switchRows.flatMap { row in
            let name = ProviderStyle.style(for: row.id).name
            var entries = [SettingsSearchEntry(.usage, ProviderUsageSwitchesGroup.title, Self.usageTitle(row),
                subtitle: row.usageConsent?.detail, keywords: [row.id, name, "quota", "subscription"],
                hint: "Provider controls require the monitor to be connected.")]
            if ["factory", "kimi", "kilo"].contains(row.id) {
                entries.append(SettingsSearchEntry(.usage, ProviderUsageSwitchesGroup.title, "\(name) API key",
                    subtitle: "Add, change or remove the saved key. Saving a key does not turn on usage.",
                    keywords: [row.id, name, "credentials", "billing", "subscription"],
                    hint: "In the \(name) row. Usage has its own switch."))
            }
            return entries
        }
        let upcoming = ProviderUsageRoadmap.upcoming(availableProviderIDs: Set(rows.map(\.id)))
        if !upcoming.isEmpty {
            entries.append(SettingsSearchEntry(.usage, ProviderComingSoonView.title,
                ProviderComingSoonView.title, subtitle: ProviderComingSoonView.note,
                keywords: upcoming.flatMap { [$0.id, $0.name] },
                hint: "Planned providers have no connection or usage controls."))
        }
        return entries
    }

    func setActive(_ active: Bool, core: CoreModel) {
        self.active = active
        if active {
            refresh(core: core)
        } else {
            readRevision += 1
            readTask?.cancel()
            readTask = nil
            loading = false
            refreshAgain = false
        }
    }

    @discardableResult
    func refresh(core: CoreModel) -> Task<Void, Never>? {
        guard active, core.isLive else { return nil }
        guard !loading, busy.isEmpty else { refreshAgain = true; return nil }
        readRevision += 1
        let revision = readRevision
        let mutation = mutationRevision
        let read = readRows
        loading = true
        loadFailure = nil
        readTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let fetched = try? await read(core)
            guard let self, self.readRevision == revision else { return }
            self.readTask = nil
            self.loading = false
            if !self.refreshAgain, mutation == self.mutationRevision {
                if let fetched { self.rows = fetched }
                else { self.loadFailure = "Provider controls could not be loaded. Try again." }
            }
            self.resumePendingRefresh(core: core)
        }
        return readTask
    }

    private func resumePendingRefresh(core: CoreModel) {
        guard refreshAgain, !loading, busy.isEmpty, active, core.isLive else { return }
        refreshAgain = false
        refresh(core: core)
    }

    /// Turn one provider's usage on or off. The reply is the row as the
    /// daemon persisted it, so the switch follows what is saved.
    func set(_ row: ProviderRow, on: Bool, core: CoreModel) {
        guard !busy.contains(row.id) else { return }
        busy.insert(row.id)
        mutationRevision += 1
        let write = writeConsent
        Task { [weak self] in
            do {
                let updated = try await write(core, row.id, on)
                guard let self else { return }
                self.busy.remove(row.id)
                self.mutationRevision += 1
                self.failure = nil
                if let index = self.rows.firstIndex(where: { $0.identity == updated.identity }) {
                    self.rows[index] = updated
                }
                if self.loading { self.refreshAgain = true }
                self.resumePendingRefresh(core: core)
            } catch {
                guard let self else { return }
                self.busy.remove(row.id)
                self.mutationRevision += 1
                self.failure = "\(row.label): \(Self.words(for: error))"
                if self.loading { self.refreshAgain = true }
                self.resumePendingRefresh(core: core)
            }
        }
    }

    func setOption(_ row: ProviderRow, key: String, on: Bool, core: CoreModel) {
        guard !busy.contains(row.id) else { return }
        busy.insert(row.id)
        mutationRevision += 1
        Task { [weak self] in
            do {
                let updated = try await core.setProviderOptions(
                    row.id, options: [key: on ? "true" : "false"], instance: row.instance)
                guard let self else { return }
                self.busy.remove(row.id)
                self.failure = nil
                self.accept(updated)
                self.resumePendingRefresh(core: core)
            } catch {
                guard let self else { return }
                self.busy.remove(row.id)
                self.mutationRevision += 1
                self.failure = "\(row.label): \(Self.words(for: error))"
                if self.loading { self.refreshAgain = true }
                self.resumePendingRefresh(core: core)
            }
        }
    }

    func accept(_ row: ProviderRow) {
        mutationRevision += 1
        if let index = rows.firstIndex(where: { $0.identity == row.identity }) {
            rows[index] = row
        }
        if loading { refreshAgain = true }
    }

    nonisolated static func words(for error: Error) -> String {
        MonitorWords.reason(error)
    }
}

/// The group of switches. It reads `list_providers` when the page shows and
/// again when the monitor reconnects.
struct ProviderUsageSwitchesGroup: View {
    @Bindable var store: SettingsStore
    /// Shared with Settings search so both use the same provider rows.
    let model: ProviderUsageSwitchesModel
    nonisolated static let title = "Provider usage"

    static let note = "Off until you turn a provider on. Each switch lets JR-Bar ask that provider for your usage, nothing else. Token counts from files on this Mac stay on either way."

    var body: some View {
        SettingGroup(Self.title, note: Self.note) {
            if model.switchRows.isEmpty {
                if !store.isLive {
                    Text("\(MonitorWords.sentence) Turn on the monitor to choose which providers show usage.")
                        .jrbarType(.callout).foregroundStyle(.secondary)
                } else if model.loading {
                    Text("Reading providers…").jrbarType(.callout).foregroundStyle(.secondary)
                } else if model.loadFailure == nil {
                    Text("No provider usage controls reported.").jrbarType(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(model.switchRows, id: \.id) { row in
                ProviderUsageSwitchRow(row: row, model: model, core: store.core)
            }
            ProviderComingSoonView(availableProviderIDs: Set(model.rows.map(\.id)),
                reveal: store.searchHit?.title == ProviderComingSoonView.title,
                revealRequest: store.revealRequest)
            if let failure = model.failure {
                Text(failure)
                    .jrbarType(.caption)
                    .foregroundStyle(Tone.failure.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = model.loadFailure {
                HStack {
                    Text(failure).jrbarType(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { model.refresh(core: store.core) }
                        .controlSize(.small)
                        .disabled(!store.isLive || model.loading)
                }
            }
        }
    }
}

struct ProviderUsageSwitchRow: View {
    let row: ProviderRow
    var model: ProviderUsageSwitchesModel
    let core: CoreModel

    private var consent: ProviderUsageConsent { row.usageConsent ?? ProviderUsageConsent() }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProviderTile(style: ProviderStyle.style(for: row.id), size: 24)
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { consent.granted },
                    set: { on in model.set(row, on: on, core: core) }
                )) {
                    SettingLabel(title: ProviderUsageSwitchesModel.usageTitle(row), subtitle: consent.detail)
                }
                .disabled(model.busy.contains(row.id) || !core.isLive)
                .accessibilityHint(consent.summary)
                if core.usage.first(where: { $0.identity == row.identity })?.canSetPanelVisibility != false {
                    Toggle("Show in panel", isOn: Binding(
                        get: { row.options["panel_hidden"] != "true" },
                        set: { model.setOption(row, key: "panel_hidden", on: !$0, core: core) }
                    ))
                    .disabled(model.busy.contains(row.id) || !core.isLive)
                }
                if ["factory", "devin", "kimi", "kilo"].contains(row.id) {
                    ProviderCredentialControls(row: row, core: core, onOptionsSaved: { model.accept($0) }) { model.refresh(core: core) }
                        .id(row.identity)
                }
            }
        }
        .settingRowStyle()
    }
}

@MainActor
struct ProviderUsageLifecycle: ViewModifier {
    @Bindable var store: SettingsStore
    private var active: Bool { store.isLive && !store.windowCovered && store.page == .agents }

    func body(content: Content) -> some View {
        content
            .onAppear { store.providerUsage.setActive(active, core: store.core) }
            .onChange(of: active) { _, active in store.providerUsage.setActive(active, core: store.core) }
            .onChange(of: store.value(at: "provider_usage")) { _, _ in
                if active { store.providerUsage.refresh(core: store.core) }
            }
            .onDisappear { store.providerUsage.setActive(false, core: store.core) }
    }
}
