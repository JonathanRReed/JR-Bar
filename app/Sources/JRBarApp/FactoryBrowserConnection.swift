import JRBarUI
import JRBarCore
import Observation
import SwiftUI

@MainActor
@Observable
final class FactoryBrowserConnectionModel {
    let provider: String
    var name: String { ProviderStyle.style(for: provider).name }
    var profiles: [FactorySessionProfile] = []
    var selected: FactorySessionProfile? {
        didSet {
            if selected != oldValue {
                approved = false
                needsAPIKey = false
                message = nil
            }
        }
    }
    var approved = false
    private(set) var busy = false
    private(set) var available: Bool
    private(set) var message: String?
    private(set) var needsAPIKey = false
    private(set) var latestReading: CoreProviderUsage?
    var usageEnabled = true
    private var waitingForRead = false
    private var readBaseline: Double?
    private var operationError: String?
    var signInProfiles: [FactorySessionProfile] { profiles.filter { $0.hasSignIn != false } }
    var savedProfiles: [FactorySessionProfile] { profiles.filter { $0.consented == true || $0.connected == true } }

    var factoryStatus: String {
        if let operationError { return operationError }
        if !available { return "Not connected" }
        if waitingForRead && !usageEnabled {
            return "Saved. Turn on Show Factory usage."
        }
        if waitingForRead { return "Saved. Waiting for the first usage read." }
        if let latestReading {
            if latestReading.state == "ready" { return "Connected and reading Factory usage." }
            return latestReading.statusText ?? "Factory usage needs attention. Choose Connect Factory."
        }
        return "Saved. Waiting for the first usage read."
    }

    func updateReading(_ reading: CoreProviderUsage?) {
        guard let reading else { return }
        if waitingForRead, let baseline = readBaseline, (reading.observedAt ?? 0) <= baseline { return }
        latestReading = reading
        waitingForRead = false
        operationError = nil
        message = nil
    }
    private var pendingAvailability: Bool?
    private var generation = 0
    private var active = true
    private var loading = false
    private let loadOperation: @MainActor () async throws -> [FactorySessionProfile]
    private let importOperation: @MainActor (FactorySessionProfile) async throws -> String
    private let refreshOperation: (@MainActor () async throws -> String)?
    private let disconnectOperation: @MainActor () async throws -> String
    private let forgetOperation: (@MainActor (FactorySessionProfile) async throws -> Void)?
    private let onChanged: @MainActor () -> Void

    init(provider: String = "factory", available: Bool,
         load: @escaping @MainActor () async throws -> [FactorySessionProfile],
         importSession: @escaping @MainActor (FactorySessionProfile) async throws -> String,
         disconnect: @escaping @MainActor () async throws -> String,
         refreshUsage: (@MainActor () async throws -> String)? = nil,
         forgetProfile: (@MainActor (FactorySessionProfile) async throws -> Void)? = nil,
         onChanged: @escaping @MainActor () -> Void = {}) {
        self.provider = provider
        self.available = available
        self.loadOperation = load
        self.importOperation = importSession
        self.refreshOperation = refreshUsage
        self.disconnectOperation = disconnect
        self.forgetOperation = forgetProfile
        self.onChanged = onChanged
    }

    var isActive: Bool { active }

    func resumeSavedProfiles() async {
        guard !busy else { return }
        generation += 1
        active = true
        approved = false
        await load()
    }

    var canConnect: Bool { active && !busy && approved && selected?.hasSignIn != false && selected != nil }

    func beginEditing() {
        guard !busy else { return }
        generation += 1
        active = true
        approved = false
        needsAPIKey = false
        profiles = []
        selected = nil
        message = nil
        operationError = nil
    }

    func updateAvailability(_ available: Bool) {
        if busy && !loading {
            pendingAvailability = available
        } else {
            self.available = available
        }
    }

    func cancel() {
        generation += 1
        active = false
        approved = false
        if loading {
            loading = false
            busy = false
        }
    }

    func load() async {
        guard active, !busy else { return }
        needsAPIKey = false
        operationError = nil
        let request = generation
        busy = true
        loading = true
        message = nil
        defer {
            if generation == request {
                loading = false
                busy = false
            }
        }
        do {
            let profiles = try await loadOperation()
            guard active, generation == request else { return }
            self.profiles = profiles
            selected = signInProfiles.first(where: { $0.connected == true }) ?? signInProfiles.first
            if profiles.isEmpty && provider != "factory" { message = "No supported browser profiles found. Open your browser, then reload profiles." }
        } catch {
            guard active, generation == request else { return }
            message = failureWords(error)
            operationError = message
        }
    }

    @discardableResult
    func connect() async -> Bool {
        guard canConnect, let selected, profiles.contains(selected) else { return false }
        let request = generation
        busy = true
        defer {
            busy = false
            if let pendingAvailability {
                available = pendingAvailability
                self.pendingAvailability = nil
            }
        }
        do {
            let message = try await importOperation(selected)
            guard active, generation == request else { return false }
            operationError = nil
            pendingAvailability = nil
            available = true
            profiles = profiles.map { profile in
                var updated = profile
                updated.connected = profile.id == selected.id
                if updated.connected == true { updated.consented = true }
                return updated
            }
            self.selected = profiles.first { $0.id == selected.id }
            self.message = message
            readBaseline = latestReading?.observedAt
            latestReading = nil
            waitingForRead = true
            if provider == "factory", !usageEnabled {
                self.message = "Factory browser sign-in saved. Turn on Show Factory usage to check this account."
            } else if let refreshOperation {
                do {
                    let refreshMessage = try await refreshOperation()
                    guard active, generation == request else { return false }
                    self.message = "\(name) browser sign-in saved. \(refreshMessage)"
                } catch {
                    guard active, generation == request else { return false }
                    if (error as? CoreReplyError)?.code == "usage_off" {
                        usageEnabled = false
                        self.message = "\(name) browser sign-in saved. Turn on Show \(name) usage to check this account."
                    } else {
                        self.message = "\(name) browser sign-in saved. Choose Connect \(name) to retry the usage read."
                        operationError = self.message
                    }
                }
            }
            if provider == "factory", latestReading != nil { self.message = nil }
            onChanged()
            return true
        } catch {
            guard active, generation == request else { return false }
            needsAPIKey = (error as? CoreReplyError)?.code == "browser_token_unavailable"
            message = failureWords(error)
            operationError = message
            return false
        }
    }

    func disconnect() async {
        guard active, !busy, available else { return }
        let request = generation
        busy = true
        defer {
            busy = false
            if let pendingAvailability {
                available = pendingAvailability
                self.pendingAvailability = nil
            }
        }
        do {
            let message = try await disconnectOperation()
            guard active, generation == request else { return }
            self.message = message
            pendingAvailability = nil
            available = false
            waitingForRead = false
            latestReading = nil
            self.message = "Not connected"
            operationError = nil
            profiles = profiles.map { profile in
                var updated = profile
                updated.connected = false
                updated.consented = false
                return updated
            }.filter { $0.hasSignIn != false }
            selected = signInProfiles.first
            approved = false
            onChanged()
        } catch {
            guard active, generation == request else { return }
            message = failureWords(error)
            operationError = message
        }
    }

    func forget(_ profile: FactorySessionProfile) async {
        guard active, !busy, let forgetOperation else { return }
        let request = generation
        busy = true
        defer { busy = false }
        do {
            try await forgetOperation(profile)
            guard active, generation == request else { return }
            if profile.connected == true {
                available = false
                latestReading = nil
                waitingForRead = false
                message = "Not connected"
            }
            operationError = nil
            profiles = profiles.map { current in
                var updated = current
                if current.id == profile.id { updated.connected = false; updated.consented = false }
                return updated
            }.filter { $0.hasSignIn != false }
            selected = signInProfiles.first(where: { $0.connected == true }) ?? signInProfiles.first
            approved = false
            onChanged()
        } catch {
            guard active, generation == request else { return }
            message = failureWords(error)
            operationError = message
        }
    }

    private func failureWords(_ error: Error) -> String {
        if let client = error as? CoreClientError, client == .notConnected {
            return "\(MonitorWords.sentence) Reconnect and try again."
        }
        switch (error as? CoreReplyError)?.code {
        case "browser_token_unavailable":
            return provider == "factory"
                ? "Connect Factory with refresh permission, or add a Factory API key."
                : "Devin sign-in data was found, but its access token is unavailable. Add a Devin API key to read usage."
        case "browser_import_failed":
            return (error as? CoreReplyError)?.message ?? "Browser import failed. Choose the profile again and retry."
        case "browser_session_not_found":
            return "Sign in at app.\(provider).ai in the selected browser profile, then Import again."
        case "unknown_instance": return "This \(name) account is unavailable. Reload providers and try again."
        case "credential_unavailable": return "Could not save the browser sign-in in Keychain. Try again."
        case "invalid_args": return "Reload profiles and choose one again."
        case "unauthenticated": return "Restart JR-Bar to reconnect securely, then try again."
        default: return "Could not complete the \(name) connection. Try again."
        }
    }
}

@MainActor
struct DevinBrowserConnectionSheet: View {
    @Bindable var model: FactoryBrowserConnectionModel
    let instance: String
    let dismiss: () -> Void
    var onAddAPIKey: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect \(model.name)").jrbarType(.heading).fontWeight(.semibold)
            if model.needsAPIKey {
                Text(model.message ?? "This browser sign-in has no usable access token.")
                    .jrbarType(.callout).fixedSize(horizontal: false, vertical: true)
                Link("Create a \(model.name) API key", destination:
                    URL(string: "https://app.\(model.provider).ai/settings/api-keys")!)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Choose the browser profile where you signed in to \(model.name).")
                    Link("Sign in to \(model.name) in your browser", destination: URL(string: "https://app.\(model.provider).ai")!)
                    Text("After signing in, return here. Choose that browser profile, approve access, then click Import.")
                        .jrbarType(.caption).foregroundStyle(.secondary)
                    if model.profiles.isEmpty {
                        Text(model.busy ? "Loading browser profiles…" : "No browser profile selected.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Browser profile", selection: $model.selected) {
                            ForEach(model.profiles) { profile in
                                Text(profile.label).tag(Optional(profile))
                            }
                        }
                        .disabled(model.busy)
                    }
                    Button("Reload profiles") { _ = Task { await model.load() } }
                        .disabled(model.busy)
                    Text(instance == "default" ? "Default \(model.name) account" : "\(model.name) account: \(instance)")
                        .jrbarType(.caption).foregroundStyle(.secondary)
                    Toggle("Allow \(model.name) access to this browser profile", isOn: $model.approved)
                        .toggleStyle(.checkbox)
                        .disabled(model.busy)
                    Text("Read app.devin.ai sign-in and organization from this profile, save the sign-in in Keychain, and allow this profile to repair it while Devin usage is enabled. Usage requests go to app.devin.ai. Importing does not turn on usage.")
                        .jrbarType(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = model.message, !model.needsAPIKey {
                        Text(message).jrbarType(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                if model.needsAPIKey, let onAddAPIKey {
                    Button("Add \(model.name) API key", action: onAddAPIKey)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(model.busy ? "Working…" : "Import") {
                        _ = Task { if await model.connect() { dismiss() } }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConnect)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 340, idealWidth: 480, maxWidth: 540, minHeight: 390, idealHeight: 520, maxHeight: 640)
        .background(NonblockingSheetWindow().frame(width: 0, height: 0).allowsHitTesting(false))
        .task { if model.profiles.isEmpty { await model.load() } }
        .onDisappear { model.cancel() }
    }
}

@MainActor
struct ProviderBrowserConnectionControls: View {
    let row: ProviderRow
    let core: CoreModel
    let connectRequest: Int
    let onConnectPresented: @MainActor () -> Void
    let onAddAPIKey: @MainActor () -> Void
    @ViewState private var keyAfterDismiss = false
    @ViewState private var model: FactoryBrowserConnectionModel
    @ViewState private var editing = false

    init(row: ProviderRow, core: CoreModel, connectRequest: Int = 0,
         onConnectPresented: @escaping @MainActor () -> Void = {},
         onAddAPIKey: @escaping @MainActor () -> Void = {}, onChanged: @escaping @MainActor () -> Void) {
        self.row = row
        self.core = core
        self.connectRequest = connectRequest
        self.onConnectPresented = onConnectPresented
        self.onAddAPIKey = onAddAPIKey
        let account = row.id == "devin" ? "token" : "web-session"
        let available = row.credentials.contains { $0.account == account && $0.available }
        let forgetOperation: (@MainActor (FactorySessionProfile) async throws -> Void)?
        if row.id == "factory" {
            forgetOperation = { profile in try await core.forgetFactoryProfile(profile, instance: row.instance) }
        } else {
            forgetOperation = nil
        }
        let connection = FactoryBrowserConnectionModel(
            provider: row.id,
            available: available,
            load: {
                if row.id == "factory" { return try await core.factorySessionProfiles(instance: row.instance) }
                return try await core.devinSessionProfiles()
            },
            importSession: { profile in
                if row.id == "factory" { return try await core.importFactorySession(profile, instance: row.instance) }
                return try await core.importDevinSession(profile, instance: row.instance)
            },
            disconnect: { try await core.disconnectFactorySession(instance: row.instance) },
            refreshUsage: {
                if row.id == "factory" {
                    try await core.refreshFactoryUsage(instance: row.instance)
                    return "Waiting for the first usage read."
                }
                let reply = try await core.refreshUsage(providers: [row.id])
                guard reply.ok else { throw reply.error ?? CoreReplyError(code: "unavailable") }
                return "Usage refresh requested."
            },
            forgetProfile: forgetOperation,
            onChanged: onChanged
        )
        connection.usageEnabled = row.enabled && row.usageConsent?.granted == true
        _model = ViewState(initialValue: connection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading, spacing: 6) { buttons }
            }
            .controlSize(.small)
            .disabled(!core.isLive || model.busy)
            if model.available && row.id != "factory" {
                Text("Browser sign-in saved. The usage switch controls requests.")
                    .jrbarType(.caption).foregroundStyle(.secondary)
            }
            if row.id == "factory" {
                FactorySavedProfiles(model: model)
            }
            if let message = model.message, !editing, row.id != "factory" {
                Text(message).jrbarType(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { if row.id == "factory" { await model.load() } }
        .onChange(of: row.enabled && row.usageConsent?.granted == true, initial: true) { _, enabled in
            model.usageEnabled = enabled
        }
        .onChange(of: core.usage, initial: true) { _, readings in
            if row.id == "factory" { model.updateReading(readings.first { $0.identity == row.identity }) }
        }
        .onChange(of: connectRequest, initial: true) { _, request in
            guard request > 0 else { return }
            model.beginEditing()
            editing = true
            onConnectPresented()
        }
        .onChange(of: row.credentials) { _, credentials in
            model.updateAvailability(credentials.contains { $0.account == (row.id == "devin" ? "token" : "web-session") && $0.available })
            if row.id == "factory", !editing { _ = Task { await model.resumeSavedProfiles() } }
        }
        .onChange(of: row.consents) { _, _ in
            if row.id == "factory", !editing { _ = Task { await model.resumeSavedProfiles() } }
        }
        .onChange(of: model.busy) { _, busy in
            if row.id == "factory", !busy, !editing, !model.isActive {
                _ = Task { await model.resumeSavedProfiles() }
            }
        }
        .sheet(isPresented: WindowPresenter.presentation($editing), onDismiss: {
            model.cancel()
            if row.id == "factory" { _ = Task { await model.resumeSavedProfiles() } }
            if keyAfterDismiss {
                keyAfterDismiss = false
                onAddAPIKey()
            }
        }) {
            if row.id == "factory" {
                FactoryConnectionSheet(model: model, instance: row.instance, dismiss: { editing = false },
                    onAddAPIKey: { keyAfterDismiss = true; editing = false })
            } else {
                DevinBrowserConnectionSheet(model: model, instance: row.instance, dismiss: { editing = false },
                    onAddAPIKey: { keyAfterDismiss = true; editing = false })
            }
        }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var buttons: some View {
        Button(row.id == "factory" ? "Connect Factory" : (model.available ? "Reconnect browser session…" : "Connect browser session…")) {
            model.beginEditing()
            editing = true
        }
        .fixedSize()
    }
}


@MainActor
struct FactoryConnectionSheet: View {
    @Bindable var model: FactoryBrowserConnectionModel
    var instance: String = "default"
    let dismiss: () -> Void
    let onAddAPIKey: () -> Void

    private var browserName: String { model.selected?.browser.capitalized ?? "your browser" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(instance == "default" ? "Connect Factory" : "Connect Factory · \(instance)")
                .jrbarType(.heading).fontWeight(.semibold)
            Link("Sign in to Factory", destination: URL(string: "https://app.factory.ai")!)
            if model.signInProfiles.isEmpty {
                Text(model.busy ? "Loading profiles…" : "No Zen profile is signed in to Factory. Sign in at app.factory.ai first.")
            } else {
                Picker("Browser profile", selection: $model.selected) {
                    ForEach(model.signInProfiles) { profile in
                        Text(profile.pickerLabel).tag(Optional(profile))
                    }
                }
                .disabled(model.busy)
            }
            Button("Reload profiles") { _ = Task { await model.load() } }
                .disabled(model.busy)
            Toggle("Use this browser's Factory sign-in", isOn: $model.approved)
                .toggleStyle(.checkbox)
                .disabled(model.busy)
            Text("Factory may ask you to sign in again in \(browserName).")
                .fixedSize(horizontal: false, vertical: true)
            Text("JR-Bar reads this profile's Factory sign-in and saves it in Keychain. When usage is on, JR-Bar renews it through api.workos.com and reads usage from api.factory.ai. Browser files stay unchanged. Connecting does not turn on usage. A saved API key is used first.")
                .jrbarType(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.factoryStatus).jrbarType(.callout).fixedSize(horizontal: false, vertical: true)
            FactorySavedProfiles(model: model)
            if model.available {
                Button("Disconnect browser sign-in", role: .destructive) { _ = Task { await model.disconnect() } }
                    .disabled(model.busy)
            }
            HStack {
                Button("Use API key…", action: onAddAPIKey).disabled(model.busy)
                Spacer()
                Button("Done") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.busy ? "Connecting…" : "Connect") { _ = Task { await model.connect() } }
                    .keyboardShortcut(.defaultAction).disabled(!model.canConnect)
            }
        }
        .padding(24)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(NonblockingSheetWindow().frame(width: 0, height: 0).allowsHitTesting(false))
        .task { if model.signInProfiles.isEmpty { await model.load() } }
        .onDisappear { model.cancel() }
    }
}


@MainActor
struct FactorySavedProfiles: View {
    @Bindable var model: FactoryBrowserConnectionModel

    var body: some View {
        ForEach(model.savedProfiles) { profile in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(profile.pickerLabel).jrbarType(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Forget this profile", role: .destructive) { _ = Task { await model.forget(profile) } }
                    .disabled(model.busy)
            }
        }
    }
}
