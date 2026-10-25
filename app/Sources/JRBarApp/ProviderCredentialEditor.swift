import JRBarCore
import Observation
import SwiftUI

@MainActor
@Observable
final class ProviderCredentialEditorModel {
    let provider: String
    let instance: String
    let account: String
    var providerName: String { ProviderStyle.style(for: provider).name }
    var credentialName: String { account == "web-session" ? "web token" : "API key" }
    var credentialTitle: String { account == "web-session" ? "Web token" : "API key" }
    var secret = ""
    private(set) var busy = false
    private(set) var message: String?
    private(set) var available: Bool
    private var pendingAvailability: Bool?
    private var generation = 0
    private var active = true
    private let saveOperation: @MainActor (String) async throws -> Void
    private let removeOperation: @MainActor () async throws -> Void
    private let onChanged: @MainActor () -> Void

    init(provider: String, instance: String, account: String, available: Bool,
         save: @escaping @MainActor (String) async throws -> Void,
         remove: @escaping @MainActor () async throws -> Void,
         onChanged: @escaping @MainActor () -> Void = {}) {
        self.provider = provider
        self.instance = instance
        self.account = account
        self.available = available
        self.saveOperation = save
        self.removeOperation = remove
        self.onChanged = onChanged
    }

    func updateAvailability(_ value: Bool) {
        if busy {
            pendingAvailability = value
        } else {
            available = value
        }
    }

    func beginEditing() {
        guard !busy else { return }
        generation += 1
        active = true
        secret = ""
        message = nil
    }

    func cancel() {
        generation += 1
        active = false
        secret = ""
        message = nil
    }

    @discardableResult
    func save() async -> Bool {
        guard active, !busy else { return false }
        let value: String
        do { value = try CoreModel.normalizedProviderSecret(secret) }
        catch {
            secret = ""
            message = "Enter a valid single-line \(credentialName)."
            return false
        }
        let request = generation
        busy = true
        secret = ""
        defer {
            busy = false
            if let pendingAvailability {
                available = pendingAvailability
                self.pendingAvailability = nil
            }
        }
        do {
            try await saveOperation(value)
            guard active, generation == request else { return false }
            pendingAvailability = nil
            available = true
            message = "\(credentialTitle) saved. The usage switch controls requests."
            onChanged()
            return true
        } catch {
            guard active, generation == request else { return false }
            message = Self.failureWords(error, removing: false, credential: credentialName)
            return false
        }
    }

    func remove() async {
        guard active, !busy else { return }
        let request = generation
        busy = true
        secret = ""
        defer {
            busy = false
            if let pendingAvailability {
                available = pendingAvailability
                self.pendingAvailability = nil
            }
        }
        do {
            try await removeOperation()
            guard active, generation == request else { return }
            pendingAvailability = nil
            available = false
            message = "Saved \(credentialName) removed."
            onChanged()
        } catch {
            guard active, generation == request else { return }
            message = Self.failureWords(error, removing: true, credential: credentialName)
        }
    }

    private static func failureWords(_ error: Error, removing: Bool, credential: String) -> String {
        if let client = error as? CoreClientError, client == .notConnected {
            return "Monitor offline. Reconnect and try again."
        }
        switch (error as? CoreReplyError)?.code {
        case "unauthenticated": return "Restart JR-Bar to reconnect securely, then try again."
        case "unknown_instance", "unknown_provider": return "This account is unavailable. Reload providers and try again."
        case "bad_reply": return "The monitor did not confirm this account. Reload providers and try again."
        default:
            return removing ? "Could not remove the \(credential). Try again." : "Could not save the \(credential). Enter it again and retry."
        }
    }
}

@MainActor
struct ProviderCredentialEditor: View {
    @Bindable var model: ProviderCredentialEditorModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(model.providerName) \(model.credentialName)").font(.headline)
            Text(model.instance == "default" ? "Default account" : "Account: \(model.instance)")
                .font(.caption).foregroundStyle(.secondary)
            SecureField(model.credentialTitle, text: $model.secret)
                .textFieldStyle(.roundedBorder)
                .privacySensitive()
                .accessibilityLabel("\(model.providerName) \(model.credentialName)")
                .disabled(model.busy)
            Text("Stored in JR-Bar's Keychain. Saving a credential does not turn on usage. The usage switch controls requests to \(model.providerName).")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.provider == "factory", model.account == "api-key" {
                Link("Create a Factory API key", destination: URL(string: "https://app.factory.ai/settings/api-keys")!)
            }
            if let message = model.message {
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(message)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.busy ? "Saving…" : "Save \(model.credentialName)") {
                    _ = Task { if await model.save() { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || model.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onDisappear { model.cancel() }
    }
}

@MainActor
struct ProviderCredentialControls: View {
    let row: ProviderRow
    let core: CoreModel
    let onChanged: @MainActor () -> Void
    let onOptionsSaved: @MainActor (ProviderRow) -> Void

    init(row: ProviderRow, core: CoreModel,
         onOptionsSaved: @escaping @MainActor (ProviderRow) -> Void = { _ in },
         onChanged: @escaping @MainActor () -> Void) {
        self.row = row
        self.core = core
        self.onChanged = onChanged
        self.onOptionsSaved = onOptionsSaved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if ["kimi", "kilo"].contains(row.id) {
                ProviderSourceOptionsControls(row: row, core: core) { updated in
                    onOptionsSaved(updated)
                    onChanged()
                }
                .id("source-\(row.identity)")
            }
            if row.id == "factory" {
                FactoryBrowserConnectionControls(row: row, core: core, onChanged: onChanged)
                DisclosureGroup("API key, optional") {
                    ProviderSavedCredentialControls(row: row, core: core, account: "api-key", onChanged: onChanged)
                        .padding(.top, 6)
                }
                .font(.callout)
            } else {
                ProviderSavedCredentialControls(row: row, core: core, account: "api-key", onChanged: onChanged)
                if row.id == "kimi" {
                    DisclosureGroup("Manual web session") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("A saved Kimi web access token for the selected region. Renew it in Kimi when it expires.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ProviderSavedCredentialControls(row: row, core: core, account: "web-session", onChanged: onChanged)
                        }
                        .padding(.top, 6)
                    }
                    .font(.callout)
                    if row.instance == "default" {
                        Text("A fresh Kimi CLI sign-in can also provide usage for the default China account. Run kimi to renew it.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if row.id == "kilo", row.instance == "default" {
                    Text("An existing Kilo CLI sign-in can also provide usage for the default account.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

@MainActor
struct ProviderSavedCredentialControls: View {
    let row: ProviderRow
    let core: CoreModel
    let onChanged: @MainActor () -> Void
    @ViewState private var model: ProviderCredentialEditorModel
    @ViewState private var editing = false

    init(row: ProviderRow, core: CoreModel, account: String, onChanged: @escaping @MainActor () -> Void) {
        self.row = row
        self.core = core
        self.onChanged = onChanged
        let saved = row.credentials.contains { $0.account == account && $0.available }
        _model = ViewState(initialValue: ProviderCredentialEditorModel(
            provider: row.id, instance: row.instance, account: account, available: saved,
            save: { secret in
                _ = try await core.setProviderCredential(row.id, account: account, secret: secret, instance: row.instance)
            },
            remove: {
                _ = try await core.deleteProviderCredential(row.id, account: account, instance: row.instance)
            },
            onChanged: onChanged
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(model.available ? "Replace \(model.credentialName)…" : "Add \(model.credentialName)…") {
                    model.beginEditing()
                    editing = true
                }
                .accessibilityLabel(model.available ? "Replace \(model.providerName) \(model.credentialName)" : "Add \(model.providerName) \(model.credentialName)")
                if model.available {
                    Button("Remove saved \(model.credentialName)", role: .destructive) {
                        model.beginEditing()
                        _ = Task { await model.remove() }
                    }
                    .accessibilityLabel("Remove saved \(model.providerName) \(model.credentialName)")
                }
            }
            .controlSize(.small)
            .disabled(model.busy || !core.isLive)
            if let message = model.message, !editing {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !core.isLive {
                Text("Monitor offline. Reconnect to manage this credential.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: row.credentials) { _, credentials in
            model.updateAvailability(credentials.contains { $0.account == model.account && $0.available })
        }
        .sheet(isPresented: WindowPresenter.presentation($editing), onDismiss: { model.cancel() }) {
            ProviderCredentialEditor(model: model, dismiss: { editing = false })
        }
        .onDisappear { model.cancel() }
    }
}

@MainActor
@Observable
final class ProviderSourceOptionsModel {
    let provider: String
    let instance: String
    var region: String
    var source: String
    var organizationID: String
    private(set) var busy = false
    private(set) var message: String?
    private var generation = 0
    private var active = true
    private let write: @MainActor ([String: String]) async throws -> ProviderRow
    private let onSaved: @MainActor (ProviderRow) -> Void

    init(row: ProviderRow, write: @escaping @MainActor ([String: String]) async throws -> ProviderRow,
         onSaved: @escaping @MainActor (ProviderRow) -> Void = { _ in }) {
        provider = row.id
        instance = row.instance
        region = row.options["region"] ?? "china"
        source = row.options["source"] ?? "auto"
        organizationID = row.options["organization_id"] ?? ""
        self.write = write
        self.onSaved = onSaved
    }

    var cliAvailable: Bool { instance == "default" && region == "china" }

    func begin() { active = true }

    func cancel() {
        generation += 1
        active = false
        message = nil
    }

    func update(_ options: [String: String]) {
        guard !busy else { return }
        region = options["region"] ?? "china"
        source = options["source"] ?? "auto"
        organizationID = options["organization_id"] ?? ""
    }

    @discardableResult
    func save() async -> Bool {
        guard active, !busy else { return false }
        guard provider != "kimi" || source != "cli" || cliAvailable else {
            message = "Kimi CLI sign-in is available only for the default China account."
            return false
        }
        let options = provider == "kimi" ? ["region": region, "source": source]
            : ["organization_id": organizationID.trimmingCharacters(in: .whitespacesAndNewlines)]
        let revision = generation
        busy = true
        message = nil
        defer { busy = false }
        do {
            let row = try await write(options)
            guard active, generation == revision else { return false }
            guard row.id == provider, row.instance == instance else {
                message = "The monitor returned another account. Reload providers and try again."
                return false
            }
            region = row.options["region"] ?? "china"
            source = row.options["source"] ?? "auto"
            organizationID = row.options["organization_id"] ?? ""
            message = "Source choices saved. The usage switch controls requests."
            onSaved(row)
            return true
        } catch {
            guard active, generation == revision else { return false }
            if error as? CoreClientError == .notConnected {
                message = "Monitor offline. Reconnect and try again."
            } else if (error as? CoreReplyError)?.code == "settings_changed" {
                message = "These choices changed elsewhere. Reload providers and try again."
            } else {
                message = "Could not save source choices. Check the values and retry."
            }
            return false
        }
    }
}

@MainActor
struct ProviderSourceOptionsControls: View {
    let row: ProviderRow
    let core: CoreModel
    @ViewState private var model: ProviderSourceOptionsModel

    init(row: ProviderRow, core: CoreModel, onSaved: @escaping @MainActor (ProviderRow) -> Void) {
        self.row = row
        self.core = core
        _model = ViewState(initialValue: ProviderSourceOptionsModel(row: row,
            write: { try await core.setProviderOptions(row.id, options: $0, instance: row.instance) },
            onSaved: onSaved))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if row.id == "kimi" {
                Picker("Region", selection: Binding(get: { model.region }, set: { region in
                    model.region = region
                    if !model.cliAvailable, model.source == "cli" { model.source = "auto" }
                })) {
                    Text("China").tag("china")
                    Text("International").tag("international")
                }
                Picker("Usage source", selection: Binding(get: { model.source }, set: { model.source = $0 })) {
                    Text("Automatic").tag("auto")
                    Text("API key").tag("api")
                    Text("Web session").tag("web")
                    if model.cliAvailable { Text("Kimi CLI").tag("cli") }
                }
                Text("Use credentials issued for the selected region. CLI sign-in is limited to the default China account.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("Organization ID, optional", text: Binding(get: { model.organizationID }, set: { model.organizationID = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Kilo organization ID")
                Text("Leave empty for personal usage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(model.busy ? "Saving…" : "Save source choices") { _ = Task { await model.save() } }
                .controlSize(.small)
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(model.busy || !core.isLive)
        .onAppear { model.begin() }
        .onChange(of: row.options) { _, options in model.update(options) }
        .onDisappear { model.cancel() }
    }
}
