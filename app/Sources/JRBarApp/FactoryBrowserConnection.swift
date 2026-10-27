import JRBarCore
import Observation
import SwiftUI

@MainActor
@Observable
final class FactoryBrowserConnectionModel {
    var profiles: [FactorySessionProfile] = []
    var selected: FactorySessionProfile? {
        didSet { if selected != oldValue { approved = false } }
    }
    var approved = false
    private(set) var busy = false
    private(set) var available: Bool
    private(set) var message: String?
    private var pendingAvailability: Bool?
    private var generation = 0
    private var active = true
    private var loading = false
    private let loadOperation: @MainActor () async throws -> [FactorySessionProfile]
    private let importOperation: @MainActor (FactorySessionProfile) async throws -> String
    private let refreshOperation: (@MainActor () async throws -> String)?
    private let disconnectOperation: @MainActor () async throws -> String
    private let onChanged: @MainActor () -> Void

    init(available: Bool,
         load: @escaping @MainActor () async throws -> [FactorySessionProfile],
         importSession: @escaping @MainActor (FactorySessionProfile) async throws -> String,
         disconnect: @escaping @MainActor () async throws -> String,
         refreshUsage: (@MainActor () async throws -> String)? = nil,
         onChanged: @escaping @MainActor () -> Void = {}) {
        self.available = available
        self.loadOperation = load
        self.importOperation = importSession
        self.refreshOperation = refreshUsage
        self.disconnectOperation = disconnect
        self.onChanged = onChanged
    }

    var canConnect: Bool { active && !busy && approved && selected != nil }

    func beginEditing() {
        guard !busy else { return }
        generation += 1
        active = true
        approved = false
        profiles = []
        selected = nil
        message = nil
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
            selected = profiles.first
            if profiles.isEmpty { message = "No supported browser profiles found. Open your browser, then reload profiles." }
        } catch {
            guard active, generation == request else { return }
            message = Self.failureWords(error)
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
            self.message = message
            pendingAvailability = nil
            available = true
            if let refreshOperation {
                do {
                    let refreshMessage = try await refreshOperation()
                    guard active, generation == request else { return false }
                    self.message = "Factory browser sign-in saved. \(refreshMessage)"
                } catch {
                    guard active, generation == request else { return false }
                    if (error as? CoreReplyError)?.code == "usage_off" {
                        self.message = "Factory browser sign-in saved. Turn on Show Factory usage to check this account."
                    } else {
                        self.message = "Factory browser sign-in saved. Open Usage Center and choose Refresh to check usage."
                    }
                }
            }
            onChanged()
            return true
        } catch {
            guard active, generation == request else { return false }
            message = Self.failureWords(error)
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
            onChanged()
        } catch {
            guard active, generation == request else { return }
            message = Self.failureWords(error)
        }
    }

    private static func failureWords(_ error: Error) -> String {
        if let client = error as? CoreClientError, client == .notConnected {
            return "\(MonitorWords.sentence) Reconnect and try again."
        }
        switch (error as? CoreReplyError)?.code {
        case "browser_session_not_found":
            return "Sign in to Factory in the selected browser profile, then connect again."
        case "unknown_instance": return "This Factory account is unavailable. Reload providers and try again."
        case "credential_unavailable": return "Could not save the browser sign-in in Keychain. Try again."
        case "invalid_args": return "Reload profiles and choose one again."
        case "unauthenticated": return "Restart JR-Bar to reconnect securely, then try again."
        default: return "Could not complete the Factory connection. Try again."
        }
    }
}

@MainActor
struct FactoryBrowserConnectionSheet: View {
    @Bindable var model: FactoryBrowserConnectionModel
    let instance: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Factory").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Use a browser profile where you’re signed in to Factory. An API key is optional.")
                    Link("Sign in to Factory in your browser", destination: URL(string: "https://app.factory.ai")!)
                    Text("After signing in, return here. Choose that browser profile, approve access, then click Connect.")
                        .font(.caption).foregroundStyle(.secondary)
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
                    Text(instance == "default" ? "Default Factory account" : "Factory account: \(instance)")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Keep Factory connected using this browser profile", isOn: $model.approved)
                        .toggleStyle(.checkbox)
                        .disabled(model.busy)
                    Text("Allow JR-Bar to read Factory sign-in from this profile, save it in Keychain, and pick up browser renewals while Factory usage is enabled. Usage requests go to api.factory.ai. The browser keeps ownership of its refresh token. Connecting does not turn on usage.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = model.message {
                        Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.busy ? "Working…" : "Connect") {
                    _ = Task { if await model.connect() { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canConnect)
            }
        }
        .padding(24)
        .frame(minWidth: 340, idealWidth: 480, maxWidth: 540, minHeight: 390, idealHeight: 520, maxHeight: 640)
        .background(NonblockingSheetWindow().frame(width: 0, height: 0).allowsHitTesting(false))
        .task { await model.load() }
        .onDisappear { model.cancel() }
    }
}

@MainActor
struct FactoryBrowserConnectionControls: View {
    let row: ProviderRow
    let core: CoreModel
    @ViewState private var model: FactoryBrowserConnectionModel
    @ViewState private var editing = false

    init(row: ProviderRow, core: CoreModel, onChanged: @escaping @MainActor () -> Void) {
        self.row = row
        self.core = core
        _model = ViewState(initialValue: FactoryBrowserConnectionModel(
            available: row.credentials.contains { $0.account == "web-session" && $0.available },
            load: { try await core.factorySessionProfiles() },
            importSession: { try await core.importFactorySession($0, instance: row.instance) },
            disconnect: { try await core.disconnectFactorySession(instance: row.instance) },
            refreshUsage: { try await core.providerAction("factory", instance: row.instance) },
            onChanged: onChanged
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading, spacing: 6) { buttons }
            }
            .controlSize(.small)
            .disabled(!core.isLive || model.busy)
            if model.available {
                Text("Browser sign-in saved. The usage switch controls requests.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.message, !editing {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: row.credentials) { _, credentials in
            model.updateAvailability(credentials.contains { $0.account == "web-session" && $0.available })
        }
        .sheet(isPresented: WindowPresenter.presentation($editing), onDismiss: { model.cancel() }) {
            FactoryBrowserConnectionSheet(model: model, instance: row.instance, dismiss: { editing = false })
        }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var buttons: some View {
        Button(model.available ? "Reconnect browser session…" : "Connect browser session…") {
            model.beginEditing()
            editing = true
        }
        .fixedSize()
        if model.available {
            Button("Disconnect browser session") {
                model.beginEditing()
                _ = Task { await model.disconnect() }
            }
            .fixedSize()
        }
    }
}
