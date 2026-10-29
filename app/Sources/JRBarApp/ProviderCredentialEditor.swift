import JRBarUI
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
    var isFactoryKey: Bool { provider == "factory" && account == "api-key" }
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
    private let openFactoryKeyPage: @MainActor () -> Bool

    init(provider: String, instance: String, account: String, available: Bool,
         save: @escaping @MainActor (String) async throws -> Void,
         remove: @escaping @MainActor () async throws -> Void,
         openFactoryKeyPage: @escaping @MainActor () -> Bool = {
             DesktopServices.automatic.open(URL(string: "https://app.factory.ai/settings/api-keys")!)
         },
         onChanged: @escaping @MainActor () -> Void = {}) {
        self.provider = provider
        self.instance = instance
        self.account = account
        self.available = available
        self.saveOperation = save
        self.removeOperation = remove
        self.onChanged = onChanged
        self.openFactoryKeyPage = openFactoryKeyPage
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

    func beginConnection() {
        guard !busy else { return }
        beginEditing()
        if isFactoryKey, !available, !openFactoryKeyPage() {
            message = "Could not open Factory. Use Create a Factory API key below."
        }
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
            message = isFactoryKey
                ? "Factory key validated and saved. The usage switch controls ongoing requests."
                : "\(credentialTitle) saved. The usage switch controls requests."
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
            return "\(MonitorWords.sentence) Reconnect and try again."
        }
        switch (error as? CoreReplyError)?.code {
        case "unauthenticated": return "Restart JR-Bar to reconnect securely, then try again."
        case "unknown_instance", "unknown_provider": return "This account is unavailable. Reload providers and try again."
        case "bad_reply": return "The monitor did not confirm this account. Reload providers and try again."
        case "authentication_required": return "Factory rejected this key. Create a new key and try again."
        case "usage_access_denied": return "This key cannot read Factory usage. Check its account and permissions."
        case "rate_limited": return "Factory is limiting requests. Wait a moment and try Save again."
        case "network_unavailable": return "Could not reach Factory. Check your connection and try Save again."
        case "invalid_response": return "Factory returned unreadable usage. The key was not saved. Try again later."
        default:
            return removing ? "Could not remove the \(credential). Try again." : "Could not save the \(credential). Enter it again and retry."
        }
    }
}

@MainActor
struct ProviderCredentialEditor: View {
    @Bindable var model: ProviderCredentialEditorModel
    let dismiss: () -> Void
    @FocusState private var keyFocused: Bool
    @ViewState private var replacing = false

    private var showsKeyField: Bool { !model.isFactoryKey || !model.available || replacing }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.isFactoryKey ? "Connect Factory" : "\(model.providerName) \(model.credentialName)")
                .jrbarType(.headline)
            Text(model.instance == "default" ? "Default account" : "Account: \(model.instance)")
                .jrbarType(.caption).foregroundStyle(.secondary)
            if model.isFactoryKey {
                Text("Connect JR-Bar with a Factory API key. Browser sign-in is unavailable.")
                    .jrbarType(.callout).fixedSize(horizontal: false, vertical: true)
                if model.available {
                    Text("Factory API key saved.").jrbarType(.callout)
                    HStack {
                        Button("Replace") { replacing = true; keyFocused = true }
                            .disabled(model.busy)
                        Button("Remove", role: .destructive) {
                            _ = Task { await model.remove() }
                        }
                        .disabled(model.busy)
                    }
                }
            }
            if showsKeyField {
                SecureField(model.credentialTitle, text: $model.secret)
                    .focused($keyFocused)
                    .textFieldStyle(.roundedBorder)
                    .privacySensitive()
                    .accessibilityLabel("\(model.providerName) \(model.credentialName)")
                    .disabled(model.busy)
            }
            Text(model.isFactoryKey
                 ? "Save checks this key with api.factory.ai, then stores it in JR-Bar's Keychain. It does not turn on ongoing usage requests."
                 : "Stored in JR-Bar's Keychain. Saving a credential does not turn on usage. The usage switch controls requests to \(model.providerName).")
                .jrbarType(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.isFactoryKey {
                Link("Create a Factory API key", destination: URL(string: "https://app.factory.ai/settings/api-keys")!)
            }
            if let message = model.message {
                Text(message).jrbarType(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(message)
            }
            HStack {
                Spacer()
                Button(showsKeyField ? "Cancel" : "Done") { model.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                if showsKeyField {
                    Button(model.busy ? (model.isFactoryKey ? "Checking…" : "Saving…") : "Save \(model.credentialName)") {
                        _ = Task {
                            if await model.save() {
                                if model.isFactoryKey { replacing = false } else { dismiss() }
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: model.isFactoryKey)
        .background {
            if model.isFactoryKey {
                NonblockingSheetWindow().frame(width: 0, height: 0).allowsHitTesting(false)
            }
        }
        .onAppear { keyFocused = showsKeyField }
        .onChange(of: model.available) { _, available in
            if !available { keyFocused = true }
        }
        .onDisappear { model.cancel() }
    }
}

@MainActor
struct ProviderCredentialControls: View {
    let row: ProviderRow
    let core: CoreModel
    let onChanged: @MainActor () -> Void
    let onOptionsSaved: @MainActor (ProviderRow) -> Void
    let connectRequest: Int
    let onConnectPresented: @MainActor () -> Void
    let keyConnectRequest: Int
    let onKeyConnectPresented: @MainActor () -> Void
    @ViewState private var localKeyRequest = 0
    @ViewState private var keyExpanded = false

    init(row: ProviderRow, core: CoreModel, connectRequest: Int = 0,
         onConnectPresented: @escaping @MainActor () -> Void = {},
         keyConnectRequest: Int = 0, onKeyConnectPresented: @escaping @MainActor () -> Void = {},
         onOptionsSaved: @escaping @MainActor (ProviderRow) -> Void = { _ in },
         onChanged: @escaping @MainActor () -> Void) {
        self.row = row
        self.core = core
        self.onChanged = onChanged
        self.onOptionsSaved = onOptionsSaved
        self.connectRequest = connectRequest
        self.keyConnectRequest = keyConnectRequest
        self.onKeyConnectPresented = onKeyConnectPresented
        self.onConnectPresented = onConnectPresented
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
                keyControls
            } else if row.id == "devin" {
                DevinBrowserConnectionControls(row: row, core: core, connectRequest: connectRequest,
                    onConnectPresented: onConnectPresented, onAddAPIKey: {
                        keyExpanded = true
                        localKeyRequest += 1
                    }, onChanged: onChanged)
                DisclosureGroup("API key", isExpanded: $keyExpanded) {
                    keyControls.padding(.top, 6)
                }
                .jrbarType(.callout)
            } else {
                ProviderSavedCredentialControls(row: row, core: core, account: "api-key", onChanged: onChanged)
                if row.id == "kimi" {
                    DisclosureGroup("Manual web session") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("A saved Kimi web access token for the selected region. Renew it in Kimi when it expires.")
                                .jrbarType(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ProviderSavedCredentialControls(row: row, core: core, account: "web-session", onChanged: onChanged)
                        }
                        .padding(.top, 6)
                    }
                    .jrbarType(.callout)
                    if row.instance == "default" {
                        Text("A fresh Kimi CLI sign-in can also provide usage for the default China account. Run kimi to renew it.")
                            .jrbarType(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if row.id == "kilo", row.instance == "default" {
                    Text("An existing Kilo CLI sign-in can also provide usage for the default account.")
                        .jrbarType(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: connectRequest, initial: true) { _, request in
            guard row.id == "factory", request > 0 else { return }
            localKeyRequest += 1
            onConnectPresented()
        }
        .onChange(of: keyConnectRequest, initial: true) { _, request in
            guard request > 0 else { return }
            keyExpanded = true
            localKeyRequest += 1
            onKeyConnectPresented()
        }
    }

    private var keyControls: some View {
        ProviderSavedCredentialControls(row: row, core: core,
            account: row.id == "devin" ? "token" : "api-key", connectRequest: localKeyRequest,
            onChanged: onChanged)
    }
}

@MainActor
struct ProviderSavedCredentialControls: View {
    let row: ProviderRow
    let core: CoreModel
    let onChanged: @MainActor () -> Void
    let connectRequest: Int
    @ViewState private var model: ProviderCredentialEditorModel
    @ViewState private var editing = false

    init(row: ProviderRow, core: CoreModel, account: String, connectRequest: Int = 0, onChanged: @escaping @MainActor () -> Void) {
        self.row = row
        self.core = core
        self.onChanged = onChanged
        self.connectRequest = connectRequest
        let saved = row.credentials.contains { $0.account == account && $0.available }
        _model = ViewState(initialValue: ProviderCredentialEditorModel(
            provider: row.id, instance: row.instance, account: account, available: saved,
            save: { secret in
                if row.id == "factory", account == "api-key" {
                    _ = try await core.connectFactoryAPIKey(secret, instance: row.instance)
                } else {
                    _ = try await core.setProviderCredential(row.id, account: account, secret: secret, instance: row.instance)
                }
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
                Button(credentialActionTitle) {
                    model.beginConnection()
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
                Text(message).jrbarType(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !core.isLive {
                Text("\(MonitorWords.sentence) Reconnect to manage this credential.")
                    .jrbarType(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: connectRequest, initial: true) { _, request in
            guard request > 0 else { return }
            model.beginConnection()
            editing = true
        }
        .onChange(of: row.credentials) { _, credentials in
            model.updateAvailability(credentials.contains { $0.account == model.account && $0.available })
        }
        .sheet(isPresented: WindowPresenter.presentation($editing), onDismiss: { model.cancel() }) {
            ProviderCredentialEditor(model: model, dismiss: { editing = false })
        }
        .onDisappear { model.cancel() }
    }

    private var credentialActionTitle: String {
        let credential = model.isFactoryKey ? "Factory API key" : model.credentialName
        return model.available ? "Replace \(credential)…" : "Add \(credential)…"
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
                message = "\(MonitorWords.sentence) Reconnect and try again."
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
                    .jrbarType(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("Organization ID, optional", text: Binding(get: { model.organizationID }, set: { model.organizationID = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Kilo organization ID")
                Text("Leave empty for personal usage.")
                    .jrbarType(.caption).foregroundStyle(.secondary)
            }
            Button(model.busy ? "Saving…" : "Save source choices") { _ = Task { await model.save() } }
                .controlSize(.small)
            if let message = model.message {
                Text(message).jrbarType(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(model.busy || !core.isLive)
        .onAppear { model.begin() }
        .onChange(of: row.options) { _, options in model.update(options) }
        .onDisappear { model.cancel() }
    }
}
