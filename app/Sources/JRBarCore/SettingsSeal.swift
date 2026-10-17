import Foundation
import Observation
import Security

// The app's side of "Protected settings" (docs/CORE-PROTOCOL.md): the key the
// daemon seals the settings that grant a capability with, how it reaches the
// daemon, what the daemon says about the seal, and what the app does about it.
//
// The key is 32 random bytes in a Keychain item the app makes with an access
// list that trusts the app's own code signature alone, so another process
// running as the same person gets a prompt or a refusal rather than the key.
// The app hands it to the daemon it starts over the stdin pipe that already
// carries the per-launch secret; it is in no argument, environment variable
// or file.

// MARK: - The key

/// The seal key and whether anything has been sealed under it yet.
public struct SettingsSealKey: Equatable, Sendable {
    public static let byteCount = 32
    public var bytes: Data
    /// True once the daemon has sealed the settings under this key. A key
    /// that has not is `isNew`: the daemon trusts the file until the app
    /// asks it to seal (`adopt_seal`).
    public var sealedBefore: Bool

    public init(bytes: Data, sealedBefore: Bool) {
        self.bytes = bytes
        self.sealedBefore = sealedBefore
    }
}

/// Why the app has no seal key, in words it can show.
public enum SettingsSealKeyProblem: Equatable, Sendable {
    /// The Keychain would have had to ask (it is locked, or this build is not
    /// the one the item trusts), and the app does not ask on its own.
    case needsApproval
    /// The Keychain said no, or the person did.
    case denied
    /// Any other Keychain status.
    case failed(Int32)

    public var sentence: String {
        switch self {
        case .needsApproval:
            return "The Keychain needs your approval, and JR-Bar does not ask on its own."
        case .denied:
            return "The Keychain did not give JR-Bar its key."
        case .failed(let status):
            return "The Keychain failed (status \(status))."
        }
    }

    /// The problem a Keychain status stands for; pure, so it is a test.
    public static func of(status: Int32) -> SettingsSealKeyProblem {
        switch status {
        case errSecInteractionNotAllowed:
            return .needsApproval
        case errSecAuthFailed, errSecUserCanceled, errSecNoAccessForItem:
            return .denied
        default:
            return .failed(status)
        }
    }
}

public enum SettingsSealKeyResult: Equatable, Sendable {
    case key(SettingsSealKey)
    case unavailable(SettingsSealKeyProblem)
}

/// Where the key lives. The real one is the Keychain; tests use
/// `InMemorySettingsSealKeyStore` and never touch it.
public protocol SettingsSealKeyStoring: Sendable {
    /// Reads the key, making it the first time. With `allowPrompt` false the
    /// system never shows a dialog: it answers `.needsApproval` instead.
    func loadOrCreate(allowPrompt: Bool) -> SettingsSealKeyResult
    /// Records that the daemon sealed the settings under the key. True if it
    /// was recorded.
    func markSealed() -> Bool
}

/// The item's data: 32 key bytes, then one byte saying the settings were
/// sealed under it. Pure, so the format is a test.
public enum SettingsSealKeyItem {
    public static let sealedMarker: UInt8 = 1

    public static func encode(_ key: SettingsSealKey) -> Data {
        var data = key.bytes
        if key.sealedBefore { data.append(sealedMarker) }
        return data
    }

    public static func decode(_ data: Data) -> SettingsSealKey? {
        switch data.count {
        case SettingsSealKey.byteCount:
            return SettingsSealKey(bytes: data, sealedBefore: false)
        case SettingsSealKey.byteCount + 1 where data.last == sealedMarker:
            return SettingsSealKey(bytes: data.prefix(SettingsSealKey.byteCount), sealedBefore: true)
        default:
            return nil
        }
    }
}

/// An in-memory key store for tests and previews; it is the whole protocol.
public final class InMemorySettingsSealKeyStore: SettingsSealKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SettingsSealKey?
    private var problem: SettingsSealKeyProblem?
    private var promptedProblem: SettingsSealKeyProblem?
    public private(set) var loads = 0
    public private(set) var prompts = 0
    public private(set) var marks = 0

    public init(key: SettingsSealKey? = nil, problem: SettingsSealKeyProblem? = nil,
                problemClearsOnPrompt: Bool = false) {
        self.key = key
        self.problem = problem
        self.promptedProblem = problemClearsOnPrompt ? nil : problem
    }

    public func loadOrCreate(allowPrompt: Bool) -> SettingsSealKeyResult {
        lock.lock(); defer { lock.unlock() }
        loads += 1
        if allowPrompt { prompts += 1 }
        if let problem = allowPrompt ? promptedProblem : problem { return .unavailable(problem) }
        if let key { return .key(key) }
        let made = SettingsSealKey(bytes: Data((0..<SettingsSealKey.byteCount).map { UInt8($0 &+ 7) }),
                                   sealedBefore: false)
        key = made
        return .key(made)
    }

    public func markSealed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        marks += 1
        guard var current = key else { return false }
        current.sealedBefore = true
        key = current
        return true
    }

    public var stored: SettingsSealKey? { lock.lock(); defer { lock.unlock() }; return key }
}

/// The real store: a generic-password item in the login Keychain whose access
/// list trusts this app's code signature alone.
///
/// It uses the file-based Keychain on purpose: that is the one that can bind
/// an item to a specific app without a provisioning profile (JR-Bar ships
/// with two entitlements and no profile). Apple deprecated those calls with
/// the rest of the file-based Keychain, so the build warns about them.
public struct KeychainSettingsSealKeyStore: SettingsSealKeyStoring {
    public static let service = "com.jonathanreed.jrbar.settings-seal"
    public static let account = "settings-seal-key"
    public static let label = "JR-Bar settings seal"

    private let service: String
    private let account: String

    public init(service: String = Self.service, account: String = Self.account) {
        self.service = service
        self.account = account
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func loadOrCreate(allowPrompt: Bool) -> SettingsSealKeyResult {
        switch read(allowPrompt: allowPrompt) {
        case .success(let data):
            if let key = SettingsSealKeyItem.decode(data) { return .key(key) }
            // An item of another shape is not ours to overwrite blindly.
            return .unavailable(.failed(errSecDecode))
        case .failure(let status) where status.rawValue == errSecItemNotFound:
            return create()
        case .failure(let status):
            return .unavailable(.of(status: status.rawValue))
        }
    }

    public func markSealed() -> Bool {
        var key: SettingsSealKey
        switch read(allowPrompt: false) {
        case .success(let data):
            guard let decoded = SettingsSealKeyItem.decode(data) else { return false }
            key = decoded
        case .failure:
            return false
        }
        key.sealedBefore = true
        let update = [kSecValueData as String: SettingsSealKeyItem.encode(key)]
        return SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary) == errSecSuccess
    }

    // `kSecUseAuthenticationUIFail` is the one way to refuse a prompt on the
    // file-based Keychain; Apple deprecated it with the rest of that API.
    private func read(allowPrompt: Bool) -> Result<Data, SealKeychainStatus> {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowPrompt { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        guard status == errSecSuccess, let data = found as? Data else { return .failure(SealKeychainStatus(status)) }
        return .success(data)
    }

    // SecAccess is how an item is bound to one app on the file-based Keychain.
    private func create() -> SettingsSealKeyResult {
        var bytes = [UInt8](repeating: 0, count: SettingsSealKey.byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return .unavailable(.failed(errSecAllocate))
        }
        let key = SettingsSealKey(bytes: Data(bytes), sealedBefore: false)
        // nil path: this running application.
        var me: SecTrustedApplication?
        var access: SecAccess?
        guard SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me,
              SecAccessCreate(Self.label as CFString, [me] as CFArray, &access) == errSecSuccess, let access else {
            return .unavailable(.failed(errSecParam))
        }
        var add = baseQuery()
        add[kSecValueData as String] = SettingsSealKeyItem.encode(key)
        add[kSecAttrAccess as String] = access
        add[kSecAttrLabel as String] = Self.label
        add[kSecAttrComment as String] = "Seals the JR-Bar settings that switch on answering, webhooks and other sensitive features. Only JR-Bar reads it."
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem { return loadOrCreate(allowPrompt: false) }
        guard status == errSecSuccess else { return .unavailable(.of(status: status)) }
        return .key(key)
    }
}

/// A Keychain status as an `Error`, so a failed read can ride a `Result`.
struct SealKeychainStatus: Error, Equatable {
    var rawValue: Int32
    init(_ rawValue: Int32) { self.rawValue = rawValue }
}

/// What the supervisor puts on the daemon's stdin pipe after the secret.
public struct SettingsSealHandoff: Equatable, Sendable {
    public var key: Data
    /// Nothing is sealed under this key yet: the daemon is told so
    /// (`JRBAR_AUTH_STDIN=3`) and trusts the file until it is asked to seal.
    public var isNew: Bool

    public init(key: Data, isNew: Bool) {
        self.key = key
        self.isNew = isNew
    }
}

/// The app's one copy of the key for this launch. The Keychain is read once,
/// the first time the supervisor needs the key and never with a prompt; every
/// later start of the daemon reuses the copy in memory, so a restart never
/// asks the Keychain again.
public final class SettingsSealKeyHolder: @unchecked Sendable {
    private let store: any SettingsSealKeyStoring
    private let lock = NSLock()
    private var loaded = false
    private var key: SettingsSealKey?
    private var problem: SettingsSealKeyProblem?

    public init(store: any SettingsSealKeyStoring) {
        self.store = store
    }

    /// The key for the daemon about to start, or nil when there is none (the
    /// daemon then runs unsealed and the app says so).
    public func handoff() -> SettingsSealHandoff? {
        resolveIfNeeded()
        lock.lock(); defer { lock.unlock() }
        guard let key else { return nil }
        return SettingsSealHandoff(key: key.bytes, isNew: !key.sealedBefore)
    }

    /// Reads the key on `queue` (never with a prompt) and calls `completion`
    /// there once it is held. The Keychain read is a synchronous call that can
    /// take a moment, so the app does it here before the daemon is started
    /// rather than on the main thread inside the spawn; `handoff()` then finds
    /// the copy in memory.
    public func warm(on queue: DispatchQueue = .global(qos: .userInitiated),
                     completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            resolveIfNeeded()
            completion()
        }
    }

    public var currentProblem: SettingsSealKeyProblem? {
        lock.lock(); defer { lock.unlock() }
        return problem
    }

    public var hasKey: Bool {
        lock.lock(); defer { lock.unlock() }
        return key != nil
    }

    public var sealedBefore: Bool {
        lock.lock(); defer { lock.unlock() }
        return key?.sealedBefore ?? false
    }

    /// Reads again, this time allowed to ask: the person pressed Try again.
    /// True if there is a key now that there was not before.
    @discardableResult
    public func retry(allowPrompt: Bool) -> Bool {
        lock.lock()
        let had = key != nil
        lock.unlock()
        apply(store.loadOrCreate(allowPrompt: allowPrompt))
        lock.lock(); defer { lock.unlock() }
        return !had && key != nil
    }

    /// The daemon sealed the settings under the key: remember it for the next launch.
    public func markSealed() {
        lock.lock()
        guard var current = key, !current.sealedBefore else { lock.unlock(); return }
        lock.unlock()
        if store.markSealed() {
            current.sealedBefore = true
            lock.lock(); key = current; lock.unlock()
        }
    }

    private func resolveIfNeeded() {
        lock.lock()
        let already = loaded
        lock.unlock()
        if !already { apply(store.loadOrCreate(allowPrompt: false)) }
    }

    private func apply(_ result: SettingsSealKeyResult) {
        lock.lock(); defer { lock.unlock() }
        loaded = true
        switch result {
        case .key(let found):
            key = found
            problem = nil
        case .unavailable(let why):
            problem = why
        }
    }
}

// MARK: - What the daemon says

/// `settings.settings_seal` in the daemon's settings document.
public struct SettingsSealStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        case sealed
        case notSealed = "not_sealed"
        case unavailable
    }

    public var state: State
    /// The protected settings a foreign edit tried to change, ignored.
    public var changedKeys: [String]
    public var changedAt: Date?
    /// The ignored values are still held, so "Keep the change" can apply them.
    public var canKeep: Bool

    public init(state: State, changedKeys: [String] = [], changedAt: Date? = nil, canKeep: Bool = false) {
        self.state = state
        self.changedKeys = changedKeys
        self.changedAt = changedAt
        self.canKeep = canKeep
    }

    public var hasIgnoredChange: Bool { !changedKeys.isEmpty }

    /// Nil when the document has no `settings_seal` (an older daemon, or a stand-in).
    public init?(document: JSONValue) {
        guard let seal = document["settings_seal"], let word = seal["state"]?.stringValue,
              let state = State(rawValue: word) else { return nil }
        self.state = state
        let changed = seal["changed"]
        changedKeys = (changed?["keys"]?.arrayValue ?? []).compactMap(\.stringValue)
        changedAt = changed?["at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
        canKeep = changed?["can_keep"]?.boolValue ?? false
    }

    /// The names a person knows these settings by.
    public static func displayName(of key: String) -> String {
        switch key {
        case "serve_enabled": return "Status server"
        case "serve_answer_enabled": return "Answering from the status server"
        case "escalation_webhook_url": return "Webhook address"
        case "webhook_events": return "Webhook events"
        case "cloud_ingest_enabled": return "Cloud ingest"
        case "remote_peers": return "Remote peers"
        case "usage_hooks", "usage_event_hook_path": return "Usage hook"
        case "claude_plan_limits_enabled", "claude_plan_limits_consent_version": return "Claude plan limits"
        case "claude_statusline_source": return "Claude status line source"
        case "provider_status_feeds_enabled": return "Provider status pages"
        case "provider_update_checks_enabled": return "Agent update checks"
        case "cliproxy_hub": return "Proxy hub"
        case "provider_extra_homes": return "Extra agent homes"
        case "closed_lid_awake_policy", "closed_lid_grace_minutes": return "Closed-lid awake"
        case "global_action_shortcuts": return "Global shortcuts"
        case "provider_usage_consent": return "Provider usage consent"
        case "browser_consent": return "Browser consent"
        case "integrations": return "Integrations"
        default: return key
        }
    }

    /// The changed settings in a sentence's worth of words, without repeats.
    public var changedNames: [String] {
        var seen = Set<String>()
        return changedKeys.map(Self.displayName(of:)).filter { seen.insert($0).inserted }
    }
}

/// What Settings should say about the seal, if anything.
public enum SettingsSealNotice: Equatable, Sendable {
    /// A protected setting was changed outside JR-Bar and ignored.
    case ignoredChange(names: [String], canKeep: Bool)
    /// The Keychain did not give JR-Bar its key, so nothing is sealed.
    case keychainUnavailable(SettingsSealKeyProblem)
    /// There is a key but the daemon has not sealed under it.
    case notSealed(reason: String?)

    public var title: String {
        switch self {
        case .ignoredChange:
            return "A protected setting was changed outside JR-Bar and was ignored."
        case .keychainUnavailable:
            return "Protected settings are not sealed (Keychain unavailable)"
        case .notSealed:
            return "Protected settings are not sealed"
        }
    }

    public var detail: String {
        switch self {
        case .ignoredChange(let names, _):
            let which = names.isEmpty ? "" : " (\(names.joined(separator: ", ")))"
            return "Review it in Settings\(which). Keep it only if you made the change yourself."
        case .keychainUnavailable(let problem):
            return "\(problem.sentence) Until it does, a program running as you can change them by editing the settings file."
        case .notSealed(let reason):
            return reason ?? "JR-Bar has a key but the monitor has not sealed the settings under it yet."
        }
    }

    public var canKeep: Bool {
        if case .ignoredChange(_, let canKeep) = self { return canKeep }
        return false
    }

    /// The notice for these facts; ignoring a change outranks the rest.
    public static func notice(status: SettingsSealStatus?, keyProblem: SettingsSealKeyProblem?,
                              adoptFailure: String?) -> SettingsSealNotice? {
        if let status, status.hasIgnoredChange {
            return .ignoredChange(names: status.changedNames, canKeep: status.canKeep)
        }
        if let keyProblem { return .keychainUnavailable(keyProblem) }
        guard let status else { return nil }
        switch status.state {
        case .sealed:
            return nil
        case .notSealed:
            // The first launch of a build with protection: the app is about to ask.
            return adoptFailure.map { .notSealed(reason: $0) }
        case .unavailable:
            return .notSealed(reason: "The monitor did not take JR-Bar's key, so a program running as you can change them by editing the settings file.")
        }
    }
}

// MARK: - The coordinator

/// Keeps the seal in order: asks the daemon to seal on a new key, remembers
/// that it did, and carries out the three things a person can do about it.
@MainActor
@Observable
public final class SettingsSealCoordinator {
    public typealias Send = @MainActor (_ command: String) async throws -> CoreReply

    public private(set) var status: SettingsSealStatus?
    public private(set) var keyProblem: SettingsSealKeyProblem?
    public private(set) var adoptFailure: String?
    public private(set) var working = false
    /// Advanced › Reset protection asked "are you sure?" and is waiting.
    public var confirmingReset = false
    /// The last thing a button did, for the banner to say.
    public private(set) var resultLine: String?
    @ObservationIgnored public var onNeedsDaemonRestart: (@MainActor () -> Void)?
    /// The sealing the app asked for on a new key, so a test can wait for it.
    @ObservationIgnored public private(set) var pendingAdoption: Task<Void, Never>?

    @ObservationIgnored private let holder: SettingsSealKeyHolder
    @ObservationIgnored private let send: Send
    @ObservationIgnored private var authenticated = false
    @ObservationIgnored private var adoptTried = false

    public init(holder: SettingsSealKeyHolder, send: @escaping Send) {
        self.holder = holder
        self.send = send
        keyProblem = holder.currentProblem
    }

    public var notice: SettingsSealNotice? {
        SettingsSealNotice.notice(status: status, keyProblem: keyProblem, adoptFailure: adoptFailure)
    }

    public var stateWord: String {
        if keyProblem != nil { return "Not sealed · Keychain unavailable" }
        switch status?.state {
        case .sealed: return "Sealed"
        case .notSealed: return "Not sealed yet"
        case .unavailable: return "Not sealed"
        case nil: return "Waiting for the monitor"
        }
    }

    /// The daemon sent a `settings` frame; `authenticated` is whether this
    /// connection has proved itself to the daemon.
    public func settingsArrived(_ settings: CoreSettings, authenticated isAuthenticated: Bool) {
        authenticated = isAuthenticated
        if !isAuthenticated { adoptTried = false }
        status = SettingsSealStatus(document: settings.document)
        keyProblem = holder.currentProblem
        if status?.state == .sealed, holder.hasKey, !holder.sealedBefore { holder.markSealed() }
        adoptIfNeeded()
    }

    /// The connection proved itself to the daemon.
    public func authenticationSucceeded() {
        authenticated = true
        adoptIfNeeded()
    }

    private func adoptIfNeeded() {
        guard authenticated, !adoptTried, status?.state == .notSealed, holder.hasKey else { return }
        adoptTried = true
        pendingAdoption = Task { [weak self] in await self?.adopt() }
    }

    private func adopt() async {
        do {
            let reply = try await send("adopt_seal")
            if reply.ok {
                adoptFailure = nil
                holder.markSealed()
            } else {
                adoptFailure = reply.error?.message ?? "The monitor would not seal the settings."
            }
        } catch {
            adoptFailure = "The monitor did not answer when JR-Bar asked it to seal the settings."
        }
    }

    // MARK: What a person can do

    /// "Keep the change": the ignored values become the settings, sealed.
    public func keepChange() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            let reply = try await send("keep_protected_change")
            resultLine = reply.ok ? "The change was kept and sealed." : (reply.error?.message ?? "The change could not be kept.")
        } catch {
            resultLine = "The monitor did not answer."
        }
    }

    /// "Reset protection" (and "Discard the change"): seal what the monitor
    /// holds now, dropping any ignored edit.
    public func resetProtection() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            let reply = try await send("adopt_seal")
            if reply.ok {
                adoptFailure = nil
                holder.markSealed()
                resultLine = "Protection was reset: the settings as they are now are sealed."
            } else {
                resultLine = reply.error?.message ?? "Protection could not be reset."
            }
        } catch {
            resultLine = "The monitor did not answer."
        }
    }

    /// "Try again": ask the Keychain once more, and this time it may show its
    /// own dialog. A key that arrives goes to the daemon at its next start,
    /// so the daemon is restarted for it.
    public func tryKeychainAgain() async {
        guard !working else { return }
        working = true
        defer { working = false }
        let gotKey = holder.retry(allowPrompt: true)
        keyProblem = holder.currentProblem
        if gotKey {
            adoptTried = false
            resultLine = "JR-Bar has its key. Restarting the monitor to seal the settings."
            onNeedsDaemonRestart?()
        } else if keyProblem == nil {
            resultLine = "JR-Bar already has its key."
        } else {
            resultLine = "The Keychain still did not give JR-Bar its key."
        }
    }

    public func clearResultLine() { resultLine = nil }
}
