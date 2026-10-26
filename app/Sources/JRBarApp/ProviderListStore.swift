import JRBarCore
import Observation

/// Shared by PanelStore, SettingsStore and the menu bar. Only daemon replies
/// change saved choices. Track never grants usage consent or removes a hook.
@MainActor
@Observable
final class ProviderListStore {
    enum Surface { case menuBar, panel, all }

    let core: CoreModel
    private(set) var rows: [ProviderRow] = []
    private(set) var preferences = MenuBarProviderPreferences()
    private(set) var loading = false
    private(set) var writingPresentation = false
    private(set) var busy: Set<String> = []
    private(set) var failure: String?
    @ObservationIgnored var onPresentationChange: (() -> Void)?
    @ObservationIgnored var onRowsChange: (() -> Void)?
    @ObservationIgnored private var legacy: MenuBarProviderPreferences
    @ObservationIgnored private var migrationScheduled = false
    @ObservationIgnored private var rowsRevision = 0
    @ObservationIgnored private var acceptedGeneration = -1
    @ObservationIgnored private var connectionRevision: UInt64 = 0

    // Small test seams exercise the same reply and race handling as the socket.
    @ObservationIgnored var readRows: () async throws -> [ProviderRow]
    @ObservationIgnored var writePresentation: (MenuBarProviderPreferences) async throws -> CoreReply
    @ObservationIgnored var writeTrack: (ProviderRow, Bool) async throws -> ProviderRow
    @ObservationIgnored var writeConsent: (ProviderRow, Bool) async throws -> ProviderRow
    @ObservationIgnored var writePanel: (ProviderRow, Bool) async throws -> ProviderRow

    init(core: CoreModel, legacy: MenuBarProviderPreferences = .init()) {
        self.core = core
        self.legacy = legacy
        readRows = { try await core.listProviders() }
        writePresentation = { choices in
            try await core.setSetting("provider_display", value: .object([
                "order": .array(choices.order.map(JSONValue.string)),
                "hidden": .array(choices.hidden.map(JSONValue.string)),
            ]))
        }
        writeTrack = { try await core.setProviderEnabled($0.id, enabled: $1, instance: $0.instance) }
        writeConsent = { try await core.setProviderUsageConsent($0.id, enabled: $1, source: "settings", instance: $0.instance) }
        writePanel = { try await core.setProviderOptions($0.id, options: ["panel_hidden": $1 ? "false" : "true"], instance: $0.instance) }
        synchronize()
        observe()
    }

    var providers: [ProviderRow] {
        arranged(rows.filter { $0.instance == "default" && $0.id != "t3code" }, provider: { $0.id }, surface: .all)
    }

    func isTracked(_ provider: String) -> Bool { rows.first { $0.id == provider && $0.instance == "default" }?.enabled ?? true }
    func showsInMenuBar(_ provider: String) -> Bool { isTracked(provider) && !preferences.hidden.contains(provider) }
    func showsInPanel(_ row: ProviderRow) -> Bool { row.enabled && row.options["panel_hidden"] != "true" }

    func arranged<Element>(_ values: [Element], provider: (Element) -> String, surface: Surface) -> [Element] {
        let visible = values.filter { value in
            let id = provider(value)
            guard id != "t3code" else { return false }
            switch surface {
            case .all: return true
            case .menuBar: return showsInMenuBar(id)
            case .panel: return isTracked(id)
            }
        }
        let choices = MenuBarProviderPreferences(order: preferences.order,
                                                 hidden: surface == .menuBar ? preferences.hidden : [])
        return choices.arranged(visible, provider: provider)
    }

    /// Call on page open or after an external provider edit. Retain last good
    /// rows on failure; a late read cannot replace a completed write.
    func refresh() async {
        guard !loading else { return }
        loading = true
        let revision = rowsRevision
        defer { loading = false }
        do {
            let result = try await readRows()
            guard revision == rowsRevision else { return }
            rows = result
            failure = nil
            onRowsChange?()
        } catch { failure = Self.words(error) }
    }

    func setTracked(_ row: ProviderRow, _ on: Bool) async throws {
        try await update(row) { try await self.writeTrack(row, on) }
    }

    /// Show `row.usageConsent.summary` before the person's explicit opt-in.
    func setUsageConsent(_ row: ProviderRow, _ on: Bool) async throws {
        try await update(row) { try await self.writeConsent(row, on) }
    }

    func setPanelVisible(_ row: ProviderRow, _ visible: Bool) async throws {
        try await update(row) { try await self.writePanel(row, visible) }
    }

    func setMenuBarVisible(_ provider: String, _ visible: Bool) async throws {
        var next = preferences
        next.hidden.removeAll { $0 == provider }
        if !visible { next.hidden.append(provider) }
        try await setPreferences(next)
    }

    /// Use the full provider order after a drag. This also orders the icon.
    func setOrder(_ order: [String]) async throws {
        var next = preferences
        next.order = order
        try await setPreferences(next)
    }

    func setPreferences(_ next: MenuBarProviderPreferences) async throws {
        guard !writingPresentation else { throw CoreReplyError(code: "busy", message: "Provider order is being saved") }
        writingPresentation = true
        defer { writingPresentation = false }
        do {
            let reply = try await writePresentation(next)
            guard reply.ok else { throw reply.error ?? CoreReplyError(code: "refused") }
            guard let saved = Self.preferences(reply.result?["value"]) else {
                throw CoreReplyError(code: "invalid_reply", message: "Provider order was not returned")
            }
            acceptedGeneration = reply.result?["generation"]?.intValue ?? acceptedGeneration
            preferences = saved
            legacy = .init()
            failure = nil
            onPresentationChange?()
        } catch {
            failure = Self.words(error)
            throw error
        }
    }

    private func update(_ row: ProviderRow, write: () async throws -> ProviderRow) async throws {
        guard busy.insert(row.identity).inserted else { throw CoreReplyError(code: "busy") }
        rowsRevision += 1
        defer { busy.remove(row.identity); rowsRevision += 1 }
        do {
            let saved = try await write()
            if let index = rows.firstIndex(where: { $0.identity == saved.identity }) { rows[index] = saved }
            else { rows.append(saved) }
            failure = nil
            onRowsChange?()
        } catch {
            failure = Self.words(error)
            throw error
        }
    }

    /// Used by the app's core refresh as well as the observation callback.
    func synchronize() {
        guard let frame = core.settingsFrame,
              frame.connectionRevision == core.settingsConnectionRevision else { return }
        let settings = frame.settings
        if connectionRevision != core.settingsConnectionRevision {
            connectionRevision = core.settingsConnectionRevision
            acceptedGeneration = -1
        }
        guard settings.generation >= acceptedGeneration else { return }
        if let saved = Self.preferences(settings.document["provider_display"]) {
            if saved != preferences {
                preferences = saved
                onPresentationChange?()
            }
        } else if core.connection.isConnected, settings.document["provider_display"] == .null, !writingPresentation, !migrationScheduled {
            // Older daemons omit the key and cannot accept this migration.
            migrationScheduled = true
            Task { [weak self] in
                guard let self else { return }
                defer { self.migrationScheduled = false }
                try? await self.setPreferences(self.legacy)
            }
        }
    }

    private func observe() {
        withObservationTracking {
            _ = core.settingsFrame
            _ = core.settingsConnectionRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.synchronize()
                self?.observe()
            }
        }
    }

    private static func preferences(_ value: JSONValue?) -> MenuBarProviderPreferences? {
        guard let order = value?["order"]?.arrayValue, let hidden = value?["hidden"]?.arrayValue,
              order.allSatisfy({ $0.stringValue != nil }), hidden.allSatisfy({ $0.stringValue != nil }) else { return nil }
        return .init(order: order.compactMap(\.stringValue), hidden: hidden.compactMap(\.stringValue))
    }

    private static func words(_ error: Error) -> String {
        if let reply = error as? CoreReplyError { return reply.message ?? reply.code }
        return String(describing: error)
    }
}
