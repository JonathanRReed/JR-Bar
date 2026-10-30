import Foundation
import IOKit.pwr_mgt
@testable import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("Shared Keep Awake display choice", .serialized, .timeLimit(.minutes(1)))
struct KeepAwakeDisplayChoiceTests {
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
