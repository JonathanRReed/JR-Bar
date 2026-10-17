import Darwin
import Foundation
import Testing
@testable import JRBarCore

/// The app's side of "Protected settings" (docs/CORE-PROTOCOL.md): the seal
/// key behind a store protocol (a fake here, never the Keychain), its hand-off
/// to the daemon, the daemon's word on the seal, and what the coordinator does
/// about it. Synthetic data only.
@Suite("Settings seal", .serialized)
struct SettingsSealTests {
    static let keyBytes = Data((0..<32).map { UInt8($0 &+ 90) })

    // MARK: The item

    @Test("the item is 32 key bytes, plus one marker byte once the settings were sealed")
    func itemFormat() {
        let fresh = SettingsSealKey(bytes: Self.keyBytes, sealedBefore: false)
        let sealed = SettingsSealKey(bytes: Self.keyBytes, sealedBefore: true)
        #expect(SettingsSealKeyItem.encode(fresh).count == 32)
        #expect(SettingsSealKeyItem.encode(sealed).count == 33)
        #expect(SettingsSealKeyItem.decode(SettingsSealKeyItem.encode(fresh)) == fresh)
        #expect(SettingsSealKeyItem.decode(SettingsSealKeyItem.encode(sealed)) == sealed)
    }

    @Test("an item of any other shape is not a key")
    func itemRefusesOtherShapes() {
        #expect(SettingsSealKeyItem.decode(Data()) == nil)
        #expect(SettingsSealKeyItem.decode(Data(count: 31)) == nil)
        #expect(SettingsSealKeyItem.decode(Data(count: 34)) == nil)
        #expect(SettingsSealKeyItem.decode(Self.keyBytes + Data([2])) == nil, "a marker that is not ours")
    }

    @Test("Keychain statuses become the problems the banner words")
    func statusesBecomeProblems() {
        #expect(SettingsSealKeyProblem.of(status: errSecInteractionNotAllowed) == .needsApproval)
        #expect(SettingsSealKeyProblem.of(status: errSecAuthFailed) == .denied)
        #expect(SettingsSealKeyProblem.of(status: errSecUserCanceled) == .denied)
        #expect(SettingsSealKeyProblem.of(status: errSecNoAccessForItem) == .denied)
        #expect(SettingsSealKeyProblem.of(status: -1) == .failed(-1))
        for problem in [SettingsSealKeyProblem.needsApproval, .denied, .failed(7)] {
            #expect(!problem.sentence.isEmpty)
        }
    }

    // MARK: The holder

    @Test("the Keychain is read once per launch, never with a prompt, however often the daemon starts")
    func holderReadsOnce() throws {
        let store = InMemorySettingsSealKeyStore(key: SettingsSealKey(bytes: Self.keyBytes, sealedBefore: true))
        let holder = SettingsSealKeyHolder(store: store)

        for _ in 0..<4 { #expect(holder.handoff() == SettingsSealHandoff(key: Self.keyBytes, isNew: false)) }

        #expect(store.loads == 1 && store.prompts == 0)
        #expect(holder.hasKey && holder.currentProblem == nil && holder.sealedBefore)
    }

    @Test("a key nothing is sealed under is handed over as new, until the daemon sealed under it")
    func holderNewKey() throws {
        let store = InMemorySettingsSealKeyStore()
        let holder = SettingsSealKeyHolder(store: store)

        let first = try #require(holder.handoff())
        #expect(first.isNew && first.key.count == 32)
        holder.markSealed()

        #expect(holder.handoff()?.isNew == false)
        #expect(store.stored?.sealedBefore == true, "remembered in the store for the next launch")
        #expect(store.marks == 1)
        holder.markSealed()
        #expect(store.marks == 1, "recorded once")
    }

    @Test("with no key the daemon is handed none and the problem is kept, with no repeated asking")
    func holderWithoutKey() {
        let store = InMemorySettingsSealKeyStore(problem: .needsApproval)
        let holder = SettingsSealKeyHolder(store: store)

        #expect(holder.handoff() == nil)
        #expect(holder.handoff() == nil)

        #expect(holder.currentProblem == .needsApproval && !holder.hasKey)
        #expect(store.loads == 1 && store.prompts == 0, "one quiet read per launch")
    }

    @Test("Try again may prompt, and a key that arrives is reported once")
    func holderRetry() {
        let store = InMemorySettingsSealKeyStore(problem: .needsApproval, problemClearsOnPrompt: true)
        let holder = SettingsSealKeyHolder(store: store)
        #expect(holder.handoff() == nil)

        #expect(holder.retry(allowPrompt: false) == false)
        #expect(holder.retry(allowPrompt: true) == true)
        #expect(holder.retry(allowPrompt: true) == false, "already there")

        #expect(holder.hasKey && holder.currentProblem == nil)
        #expect(store.prompts == 2)
    }

    // MARK: What the daemon says

    private func document(_ seal: JSONValue?) -> JSONValue {
        var members: [String: JSONValue] = ["alert_burst": 3]
        if let seal { members["settings_seal"] = seal }
        return .object(members)
    }

    @Test("the status reads the settings_seal member, and an older daemon has none")
    func statusParses() throws {
        let sealed = try #require(SettingsSealStatus(document: document(["state": "sealed", "changed": nil])))
        #expect(sealed.state == .sealed && !sealed.hasIgnoredChange)

        let changed = try #require(SettingsSealStatus(document: document([
            "state": "sealed",
            "changed": ["keys": ["serve_answer_enabled", "serve_enabled"], "at": 1_700_000_000, "can_keep": true],
        ])))
        #expect(changed.changedKeys == ["serve_answer_enabled", "serve_enabled"])
        #expect(changed.canKeep)
        #expect(changed.changedAt == Date(timeIntervalSince1970: 1_700_000_000))

        #expect(SettingsSealStatus(document: document(["state": "not_sealed"]))?.state == .notSealed)
        #expect(SettingsSealStatus(document: document(["state": "unavailable"]))?.state == .unavailable)
        #expect(SettingsSealStatus(document: document(nil)) == nil)
        #expect(SettingsSealStatus(document: document(["state": "something new"])) == nil)
    }

    @Test("the banner names settings the way a person does, once each")
    func namesAreForPeople() {
        let status = SettingsSealStatus(state: .sealed,
                                        changedKeys: ["usage_hooks", "usage_event_hook_path", "escalation_webhook_url", "odd_key"],
                                        canKeep: true)
        #expect(status.changedNames == ["Usage hook", "Webhook address", "odd_key"])
    }

    @Test("the consent files beside settings.json are named too")
    func consentFilesAreNamed() {
        let status = SettingsSealStatus(
            state: .sealed,
            changedKeys: ["provider_usage_consent", "browser_consent", "integrations"], canKeep: true)
        #expect(status.changedNames == ["Provider usage consent", "Browser consent", "Integrations"])
    }

    @Test("an ignored change outranks the Keychain, which outranks the rest")
    func noticePrecedence() {
        let changed = SettingsSealStatus(state: .sealed, changedKeys: ["serve_answer_enabled"], canKeep: true)
        let notice = SettingsSealNotice.notice(status: changed, keyProblem: .denied, adoptFailure: nil)
        #expect(notice == .ignoredChange(names: ["Answering from the status server"], canKeep: true))
        #expect(notice?.title == "A protected setting was changed outside JR-Bar and was ignored.")
        #expect(notice?.canKeep == true)

        let quiet = SettingsSealStatus(state: .unavailable)
        #expect(SettingsSealNotice.notice(status: quiet, keyProblem: .denied, adoptFailure: nil)
                == .keychainUnavailable(.denied))
        #expect(SettingsSealNotice.notice(status: nil, keyProblem: .denied, adoptFailure: nil)?.title
                == "Protected settings are not sealed (Keychain unavailable)")
    }

    @Test("a healthy seal, a first launch about to seal, and a daemon without the member say nothing")
    func quietStates() {
        #expect(SettingsSealNotice.notice(status: SettingsSealStatus(state: .sealed), keyProblem: nil, adoptFailure: nil) == nil)
        #expect(SettingsSealNotice.notice(status: SettingsSealStatus(state: .notSealed), keyProblem: nil, adoptFailure: nil) == nil)
        #expect(SettingsSealNotice.notice(status: nil, keyProblem: nil, adoptFailure: nil) == nil)
    }

    @Test("a daemon that did not take the key, or would not seal, is said so")
    func loudStates() {
        let unavailable = SettingsSealNotice.notice(status: SettingsSealStatus(state: .unavailable),
                                                    keyProblem: nil, adoptFailure: nil)
        #expect(unavailable?.title == "Protected settings are not sealed")
        let refused = SettingsSealNotice.notice(status: SettingsSealStatus(state: .notSealed),
                                                keyProblem: nil, adoptFailure: "could not write")
        #expect(refused == .notSealed(reason: "could not write"))
    }

    // MARK: The coordinator

    @MainActor
    final class Daemon {
        var sent: [String] = []
        var reply = CoreReply(id: "x", ok: true)
        var throwing = false
        func send(_ command: String) async throws -> CoreReply {
            sent.append(command)
            if throwing { throw CoreClientError.notConnected }
            return reply
        }
    }

    @MainActor
    private func coordinator(store: InMemorySettingsSealKeyStore, daemon: Daemon) -> SettingsSealCoordinator {
        let holder = SettingsSealKeyHolder(store: store)
        _ = holder.handoff()
        return SettingsSealCoordinator(holder: holder, send: { try await daemon.send($0) })
    }

    private func frame(_ seal: JSONValue) -> CoreSettings {
        CoreSettings(generation: 1, schema: 3, document: document(seal))
    }

    @MainActor
    @Test("a new key is sealed once the connection is authenticated, and remembered")
    func firstLaunchSeals() async {
        let store = InMemorySettingsSealKeyStore()
        let daemon = Daemon()
        let seal = coordinator(store: store, daemon: daemon)

        seal.settingsArrived(frame(["state": "not_sealed"]), authenticated: false)
        #expect(daemon.sent.isEmpty, "not before the daemon has taken the app's proof")
        seal.authenticationSucceeded()
        await seal.pendingAdoption?.value

        #expect(daemon.sent == ["adopt_seal"])
        #expect(store.stored?.sealedBefore == true)
        #expect(seal.notice == nil && seal.adoptFailure == nil)

        seal.settingsArrived(frame(["state": "sealed", "changed": nil]), authenticated: true)
        #expect(seal.stateWord == "Sealed")
        #expect(daemon.sent == ["adopt_seal"], "asked once")
    }

    @MainActor
    @Test("it asks again on a new connection, not on every settings frame")
    func asksOncePerConnection() async {
        let store = InMemorySettingsSealKeyStore()
        let daemon = Daemon()
        daemon.reply = CoreReply(id: "x", ok: false, error: CoreReplyError(code: "refused", message: "could not write"))
        let seal = coordinator(store: store, daemon: daemon)

        seal.settingsArrived(frame(["state": "not_sealed"]), authenticated: true)
        await seal.pendingAdoption?.value
        seal.settingsArrived(frame(["state": "not_sealed"]), authenticated: true)
        await seal.pendingAdoption?.value
        #expect(daemon.sent == ["adopt_seal"])
        #expect(seal.notice == .notSealed(reason: "could not write"))
        #expect(store.stored?.sealedBefore == false, "a refusal records nothing")

        seal.settingsArrived(frame(["state": "not_sealed"]), authenticated: false)
        seal.settingsArrived(frame(["state": "not_sealed"]), authenticated: true)
        await seal.pendingAdoption?.value
        #expect(daemon.sent == ["adopt_seal", "adopt_seal"])
    }

    @MainActor
    @Test("with no key the app asks nothing of the daemon and says why")
    func noKeyNoAdopt() async {
        let store = InMemorySettingsSealKeyStore(problem: .needsApproval)
        let daemon = Daemon()
        let seal = coordinator(store: store, daemon: daemon)

        seal.settingsArrived(frame(["state": "unavailable"]), authenticated: true)
        seal.authenticationSucceeded()

        #expect(daemon.sent.isEmpty && seal.pendingAdoption == nil)
        #expect(seal.notice == .keychainUnavailable(.needsApproval))
        #expect(seal.stateWord == "Not sealed · Keychain unavailable")
    }

    @MainActor
    @Test("a seal the daemon already holds is recorded without asking it again")
    func recordsAnExistingSeal() {
        let store = InMemorySettingsSealKeyStore()
        let daemon = Daemon()
        let seal = coordinator(store: store, daemon: daemon)

        seal.settingsArrived(frame(["state": "sealed"]), authenticated: true)

        #expect(store.stored?.sealedBefore == true && daemon.sent.isEmpty)
    }

    @MainActor
    @Test("Keep the change sends keep_protected_change and says what happened")
    func keepTheChange() async {
        let daemon = Daemon()
        let seal = coordinator(store: InMemorySettingsSealKeyStore(), daemon: daemon)

        await seal.keepChange()

        #expect(daemon.sent == ["keep_protected_change"])
        #expect(seal.resultLine == "The change was kept and sealed.")
        daemon.reply = CoreReply(id: "x", ok: false, error: CoreReplyError(code: "nothing_to_keep", message: "there is no ignored change to keep"))
        await seal.keepChange()
        #expect(seal.resultLine == "there is no ignored change to keep")
        daemon.throwing = true
        await seal.keepChange()
        #expect(seal.resultLine == "The monitor did not answer.")
    }

    @MainActor
    @Test("Reset protection sends adopt_seal and remembers the seal")
    func resetProtection() async {
        let store = InMemorySettingsSealKeyStore()
        let daemon = Daemon()
        let seal = coordinator(store: store, daemon: daemon)

        await seal.resetProtection()

        #expect(daemon.sent == ["adopt_seal"])
        #expect(store.stored?.sealedBefore == true)
        #expect(seal.resultLine?.hasPrefix("Protection was reset") == true)
        #expect(!seal.working)
    }

    @MainActor
    @Test("Try again asks the Keychain, and a key that comes restarts the daemon so it gets it")
    func tryAgain() async {
        let store = InMemorySettingsSealKeyStore(problem: .needsApproval, problemClearsOnPrompt: true)
        let daemon = Daemon()
        let holder = SettingsSealKeyHolder(store: store)
        _ = holder.handoff()
        let seal = SettingsSealCoordinator(holder: holder, send: { try await daemon.send($0) })
        var restarts = 0
        seal.onNeedsDaemonRestart = { restarts += 1 }
        #expect(seal.notice == .keychainUnavailable(.needsApproval))

        await seal.tryKeychainAgain()

        #expect(restarts == 1 && store.prompts == 1)
        #expect(seal.keyProblem == nil)
        #expect(holder.handoff()?.isNew == true)
    }

    @MainActor
    @Test("Try again that is declined again changes nothing and restarts nothing")
    func tryAgainDeclined() async {
        let store = InMemorySettingsSealKeyStore(problem: .denied)
        let seal = coordinator(store: store, daemon: Daemon())
        var restarts = 0
        seal.onNeedsDaemonRestart = { restarts += 1 }

        await seal.tryKeychainAgain()

        #expect(restarts == 0)
        #expect(seal.keyProblem == .denied)
        #expect(seal.resultLine == "The Keychain still did not give JR-Bar its key.")
    }
}
