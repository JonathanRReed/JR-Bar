import Foundation
import IOKit.pwr_mgt
@testable import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("Shared Keep Awake display choice", .serialized, .timeLimit(.minutes(1)))
struct KeepAwakeDisplayChoiceTests {
    @Test func displayFactsMustBelongToThisConnectionAndUseTheNewestGeneration() {
        let settings = CoreSettings(generation: 2, document: .object(["keep_display_awake": .bool(false)]))
        let old = CoreSettingsFrame(settings: settings, stream: "old", connectionRevision: 1)
        let current = CoreSettingsFrame(settings: settings, stream: "current", connectionRevision: 2)
        let receipt = SystemTogglesStore.State.DisplayChoiceReceipt(connection: 2, generation: 3, value: true)
        let oldReceipt = SystemTogglesStore.State.DisplayChoiceReceipt(connection: 1, generation: 9, value: true)
        #expect(SystemTogglesStore.State.latestDisplayChoice(frame: old, connection: 2,
                                                            stream: "current", receipt: nil) == nil)
        #expect(SystemTogglesStore.State.latestDisplayChoice(frame: current, connection: 2,
                                                            stream: "current", receipt: receipt) == true)
        #expect(SystemTogglesStore.State.latestDisplayChoice(frame: nil, connection: 2,
                                                            stream: "current", receipt: receipt) == true)
        #expect(SystemTogglesStore.State.latestDisplayChoice(frame: current, connection: 2,
                                                            stream: "current", receipt: oldReceipt) == false)
        let newerSettings = CoreSettings(generation: 4, document: settings.document)
        let newer = CoreSettingsFrame(settings: newerSettings, stream: "current", connectionRevision: 2)
        #expect(SystemTogglesStore.State.latestDisplayChoice(frame: newer, connection: 2,
                                                            stream: "current", receipt: receipt) == false)
    }

    @Test(arguments: [false, true])
    func handoverWaitsForTheDisplaySaveAttempt(saved: Bool) async throws {
        let suite = ScratchDefaults.suiteName("display-handover-order")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        state.takeAssertion = { _ in 7 }
        state.releaseAssertion = { _ in kIOReturnSuccess }
        defer { state.noteDaemonHold(nil, live: false); state.setAwake(false) }
        state.setAwakeKeepsDisplay(true)
        state.holdAwake(seconds: 900)
        let end = try #require(state.awakeUntil)
        var canonical = false
        var attempted = false
        var requests: [CoreAwakeRequest?] = []
        state.readDisplayChoice = { canonical }
        state.writeDisplayChoice = { _ in
            attempted = true
            await drainMainQueue()
            #expect(state.awake.held)
            #expect(requests.isEmpty)
            if saved { canonical = true }
            return saved
        }
        defer { state.writeDisplayChoice = nil }
        state.sendLease = { request in
            #expect(attempted, "The shared preference must be attempted before dropping the local assertion")
            #expect(state.awake.held)
            requests.append(request)
            return .taken
        }
        defer { state.sendLease = nil }
        state.noteDaemonHold(nil, live: true)
        state.receiveDisplayChoice(false)
        await state.displayChoiceTask?.value
        await state.handoverTask?.value
        #expect(requests == [CoreAwakeRequest(.until(end.timeIntervalSince1970), display: false)])
        #expect(!state.awake.held)
        #expect((state.displayChoiceError == nil) == saved)
    }

    @Test func appLeasesFollowTheSharedDisplayChoice() async throws {
        let suite = ScratchDefaults.suiteName("display-lease-default")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        state.receiveDisplayChoice(true)
        state.takeAssertion = { _ in Issue.record("Daemon tests must not take power assertions"); return nil }
        var requests: [CoreAwakeRequest?] = []
        state.sendLease = { requests.append($0); return .taken }
        state.noteDaemonHold(nil, live: true)
        state.holdAwake(seconds: 900)
        await state.leaseTask?.value
        state.holdAwake(seconds: nil)
        await state.leaseTask?.value
        state.holdAwakeUntilAgentsFinish()
        await state.leaseTask?.value
        #expect(state.awakeKeepsDisplay)
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0?.display == false },
                "App sessions must not freeze the shared preference into a lease override")
    }

    @Test func continuingALeasePreservesOnlyItsExplicitDisplayOverride() async throws {
        let flags: [Bool?] = [nil, false, true]
        for flag in flags {
            let suite = ScratchDefaults.suiteName("display-lease-continuation")
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
            state.receiveDisplayChoice(true)
            state.takeAssertion = { _ in Issue.record("Daemon tests must not take power assertions"); return nil }
            var requests: [CoreAwakeRequest?] = []
            state.sendLease = { requests.append($0); return .taken }
            let field = flag.map { ",\"display\":\($0)" } ?? ""
            let raw = #"{"state":"manual","active":false,"lease":{"kind":"duration","source":"cli","until":1800003600\#(field)}}"#
            let hold = try JSONDecoder().decode(CoreAwakeHold.self, from: Data(raw.utf8))
            state.noteDaemonHold(hold, live: true)
            defer { state.noteDaemonHold(nil, live: false) }
            state.retryAwake()
            await state.leaseTask?.value
            state.extendAwake(now: Date(timeIntervalSince1970: 1_800_000_000))
            await state.leaseTask?.value
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { $0?.display == (flag ?? false) })
        }
    }

    @Test func aSharedChoiceChangeClearsOnlyLegacyAppOverrides() async throws {
        for source in ["app", "cli"] {
            let suite = ScratchDefaults.suiteName("display-legacy-override")
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
            state.receiveDisplayChoice(true)
            state.takeAssertion = { _ in Issue.record("Daemon tests must not take power assertions"); return nil }
            var requests: [CoreAwakeRequest?] = []
            state.sendLease = { requests.append($0); return .taken }
            let raw = #"{"state":"manual","active":true,"lease":{"kind":"duration","source":"\#(source)","display":true,"until":1800003600}}"#
            let hold = try JSONDecoder().decode(CoreAwakeHold.self, from: Data(raw.utf8))
            state.noteDaemonHold(hold, live: true)
            defer { state.noteDaemonHold(nil, live: false) }
            state.receiveDisplayChoice(false)
            await state.leaseTask?.value
            if source == "app" {
                let request = try #require(requests.first ?? nil)
                #expect(request.display == false)
                #expect(request.shape == .until(1_800_003_600))
            } else {
                #expect(requests.isEmpty, "An explicit client override remains that client's choice")
            }
        }
    }

    @Test(arguments: [false, true])
    func mergePreservesEitherChoice(manual: Bool) async throws {
        for daemon in [false, true] {
            let suite = ScratchDefaults.suiteName("display-merge")
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(1, forKey: SystemTogglesStore.awakeDisplayMigrationKey)
            defaults.set(manual, forKey: SystemTogglesStore.awakeDisplayDefaultsKey)
            let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
            var writes: [Bool] = []
            state.writeDisplayChoice = { writes.append($0); return true }
            state.noteDaemonHold(nil, live: true)
            state.receiveDisplayChoice(daemon)
            await state.displayChoiceTask?.value
            let merged = manual || daemon
            #expect(state.awakeKeepsDisplay == merged)
            #expect(writes == (merged == daemon ? [] : [merged]))
            #expect(defaults.bool(forKey: SystemTogglesStore.awakeDisplayUnifiedKey))
            #expect(defaults.object(forKey: SystemTogglesStore.awakeDisplayPendingKey) == nil)
            let relaunched = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
            relaunched.receiveDisplayChoice(!merged)
            #expect(relaunched.awakeKeepsDisplay == !merged, "later daemon choices replace the cache")
        }
    }

    @Test func failedMigrationRetriesWithoutLosingTheChoice() async throws {
        let suite = ScratchDefaults.suiteName("display-merge-failure")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: SystemTogglesStore.awakeDisplayMigrationKey)
        defaults.set(true, forKey: SystemTogglesStore.awakeDisplayDefaultsKey)
        let first = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        first.writeDisplayChoice = { _ in false }
        first.noteDaemonHold(nil, live: true)
        first.receiveDisplayChoice(false)
        await first.displayChoiceTask?.value
        #expect(first.awakeKeepsDisplay)
        #expect(first.displayChoiceError != nil)
        let toggles = SystemTogglesStore(state: first)
        #expect(toggles.lastError == first.displayChoiceError)
        #expect(toggles.caption == first.displayChoiceError)
        #expect(!defaults.bool(forKey: SystemTogglesStore.awakeDisplayUnifiedKey))
        let relaunched = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        var writes: [Bool] = []
        relaunched.writeDisplayChoice = { writes.append($0); return true }
        relaunched.noteDaemonHold(nil, live: true)
        relaunched.receiveDisplayChoice(false)
        await relaunched.displayChoiceTask?.value
        #expect(writes == [true])
        #expect(defaults.bool(forKey: SystemTogglesStore.awakeDisplayUnifiedKey))
        #expect(relaunched.displayChoiceError == nil)
    }

    @Test func aNewChoiceWinsOverAMigrationAlreadySaving() async throws {
        let suite = ScratchDefaults.suiteName("display-merge-order")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: SystemTogglesStore.awakeDisplayMigrationKey)
        defaults.set(true, forKey: SystemTogglesStore.awakeDisplayDefaultsKey)
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        var writes: [Bool] = []
        state.writeDisplayChoice = { [weak state] on in
            writes.append(on)
            if writes.count == 1 {
                state?.setAwakeKeepsDisplay(false)
            }
            return true
        }
        state.noteDaemonHold(nil, live: true)
        state.receiveDisplayChoice(false)
        let migration = state.displayChoiceTask
        await migration?.value
        await state.displayChoiceTask?.value
        #expect(writes == [true, false])
        #expect(!state.awakeKeepsDisplay)
        #expect(defaults.object(forKey: SystemTogglesStore.awakeDisplayPendingKey) == nil)
    }

    @Test func settingsEventsUpdateTheOfflineCacheAndLocalAssertion() async throws {
        let suite = ScratchDefaults.suiteName("display-cache")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        var kinds: [String] = []
        state.takeAssertion = { kinds.append($0 as String); return 7 }
        state.releaseAssertion = { _ in kIOReturnSuccess }
        state.receiveDisplayChoice(false)
        state.holdAwake(seconds: 900)
        let deadline = state.awakeUntil
        state.receiveDisplayChoice(true)
        #expect(kinds == [kIOPMAssertionTypeNoIdleSleep as String,
                          kIOPMAssertionTypePreventUserIdleDisplaySleep as String])
        #expect(state.awakeUntil == deadline)
        state.holdAwake(seconds: 0)
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "display-choice-unused.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
                                          document: .object(["keep_display_awake": .bool(true)]))))
        state.attachLease(to: core)
        core.apply(.settings(CoreSettings(generation: 2, schema: CoreProtocol.knownSettingsSchema,
                                          document: .object(["keep_display_awake": .bool(false)]))))
        await drainMainQueue()
        #expect(!state.awakeKeepsDisplay)
        #expect(!defaults.bool(forKey: SystemTogglesStore.awakeDisplayDefaultsKey))
    }

    @Test func anOfflineOffChoiceSurvivesReconnect() async throws {
        let suite = ScratchDefaults.suiteName("display-offline")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: SystemTogglesStore.awakeDisplayMigrationKey)
        defaults.set(true, forKey: SystemTogglesStore.awakeDisplayUnifiedKey)
        defaults.set(true, forKey: SystemTogglesStore.awakeDisplayDefaultsKey)
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        state.setAwakeKeepsDisplay(false)
        let relaunched = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        var writes: [Bool] = []
        relaunched.writeDisplayChoice = { writes.append($0); return true }
        relaunched.noteDaemonHold(nil, live: true)
        relaunched.receiveDisplayChoice(true)
        await relaunched.displayChoiceTask?.value
        #expect(writes == [false])
        #expect(!relaunched.awakeKeepsDisplay)
    }
}
