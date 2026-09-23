import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The toggle strip as one app-level truth: every store instance reads
/// the same state, the Dock chip rides the live driver (never a Dock
/// restart when the driver is there), and a flip made while the Dock
/// utility's preview holds the Dock out waits for the hold. No system
/// call is made — the driver and the defaults are fakes.
@MainActor
@Suite struct SystemTogglesStoreTests {
    /// A Dock that records what it was told.
    final class FakeDock: DockAutohideDriver {
        var isAutohideEnabled = false
        var sets: [Bool] = []
        func setAutohideEnabled(_ enabled: Bool) {
            sets.append(enabled)
            isAutohideEnabled = enabled
        }
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "SystemTogglesStoreTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test func everyInstanceReadsTheOneTruth() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dock = FakeDock()
        let state = SystemTogglesStore.State(dockDriver: dock, defaults: defaults)
        // The glass card and the island's card each build a store; a
        // shortcut drives a third. They are one strip.
        let card = SystemTogglesStore(state: state)
        let island = SystemTogglesStore(state: state)
        card.apply(.dockAutoHide)
        #expect(dock.sets == [true])
        #expect(island.isOn[.dockAutoHide] == true)
        island.apply(.dockAutoHide)
        #expect(dock.sets == [true, false])
        #expect(card.isOn[.dockAutoHide] == false)
    }

    @Test func setLeavesAChipAlreadyThereAlone() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dock = FakeDock()
        dock.isAutohideEnabled = true
        let store = SystemTogglesStore(state: .init(dockDriver: dock, defaults: defaults))
        store.set(.dockAutoHide, on: true)
        #expect(dock.sets.isEmpty)
        store.set(.dockAutoHide, on: false)
        #expect(dock.sets == [false])
    }

    @Test func aFlipDuringThePreviewHoldLandsWhenTheHoldLetsGo() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dock = FakeDock()
        let state = SystemTogglesStore.State(dockDriver: dock, defaults: defaults)
        // A mutable answer the @Sendable probe can read.
        final class Hold: @unchecked Sendable { var active = true }
        let hold = Hold()
        state.dockHoldActive = { hold.active }
        let store = SystemTogglesStore(state: state)
        store.apply(.dockAutoHide)
        // Nothing touches the Dock under the hold — its restore would
        // undo the flip — and the chip says why it has not moved.
        #expect(dock.sets.isEmpty)
        #expect(store.lastError?.contains("preview closes") == true)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(dock.sets.isEmpty)
        hold.active = false
        // The wait re-checks every 250 ms on the main actor; a busy
        // suite can hold that for a while, so give it a deadline, not a
        // fixed nap.
        let deadline = Date().addingTimeInterval(5)
        while dock.sets.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // One more re-check's worth past the deadline: a main thread held
        // longer than it wakes this loop ahead of the re-check that came
        // due meanwhile, and the deadline alone would miss a flip that
        // is next in line.
        if dock.sets.isEmpty { try await Task.sleep(nanoseconds: 300_000_000) }
        #expect(dock.sets == [true])
        #expect(store.isOn[.dockAutoHide] == true)
    }

    @Test func theLockChipsWordFollowsThePasswordDelay() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: FakeDock(), defaults: defaults)
        let store = SystemTogglesStore(state: state)
        #expect(store.title(for: .lock) == "Lock")
        state.lockDelay = .after(seconds: 300)
        #expect(store.title(for: .lock) == "Display")
        #expect(store.help(for: .lock).contains("password"))
        #expect(store.title(for: .darkMode) == "Dark")
    }

    @Test func theCaptionPutsARefusalBeforeAReport() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: FakeDock(), defaults: defaults)
        let store = SystemTogglesStore(state: state)
        #expect(store.caption == nil)
        state.lastNote = "Ejected “USB”."
        #expect(store.caption == "Ejected “USB”.")
        state.lastError = "Dark: refused"
        #expect(store.caption == "Dark: refused")
    }

    @Test func theDisplayOptionPersistsWithoutTakingAHold() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: FakeDock(), defaults: defaults)
        state.setAwakeKeepsDisplay(true)
        #expect(!state.awake.held)
        #expect(SystemTogglesStore.State(dockDriver: FakeDock(), defaults: defaults).awakeKeepsDisplay)
    }

    // MARK: Awake is the daemon's lease

    /// The daemon's side of the lease: what it was sent and how it
    /// answers. No assertion is ever taken — every path here stays on the
    /// daemon, or fakes the app's own hold.
    final class FakeLease {
        var sent: [CoreAwakeRequest?] = []
        var answer: SystemTogglesStore.LeaseAnswer = .taken
    }

    /// The app's own power assertions, counted instead of taken.
    final class FakeAssertions {
        var taken = 0
        var released = 0
    }

    private func leased(_ defaults: UserDefaults, hold: String? = nil) throws
        -> (SystemTogglesStore, SystemTogglesStore.State, FakeLease) {
        let state = SystemTogglesStore.State(dockDriver: FakeDock(), defaults: defaults)
        let fake = FakeLease()
        state.sendLease = { request in
            fake.sent.append(request)
            return fake.answer
        }
        let decoded = try hold.map { try JSONDecoder().decode(CoreAwakeHold.self, from: Data($0.utf8)) }
        state.noteDaemonHold(decoded, live: true)
        return (SystemTogglesStore(state: state), state, fake)
    }

    private func settle(_ state: SystemTogglesStore.State) async {
        let deadline = Date().addingTimeInterval(5)
        while state.applying.contains(.keepAwake), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test func theAwakeChipSendsTheLeaseNotAnAssertion() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, state, fake) = try leased(defaults, hold: #"{"state":"off"}"#)
        #expect(store.title(for: .keepAwake) == "Awake")
        #expect(store.isOn[.keepAwake] == false)
        store.apply(.keepAwake)
        #expect(store.applying.contains(.keepAwake), "the chip pulses until the daemon answers")
        await settle(state)
        #expect(fake.sent == [CoreAwakeRequest(.indefinite, display: false)])
        #expect(!state.awake.held, "one hold: the daemon's")
        // The daemon's next frame is what lights the chip.
        state.noteDaemonHold(try JSONDecoder().decode(CoreAwakeHold.self, from: Data(
            #"{"state":"manual","lease":{"kind":"indefinite"}}"#.utf8)), live: true)
        #expect(store.isOn[.keepAwake] == true)
        store.apply(.keepAwake)
        await settle(state)
        #expect(fake.sent.last == .some(nil), "a lit chip's tap is release_awake")
    }

    @Test func theAgentsHoldNamesItselfAndATapTakesALease() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, state, fake) = try leased(defaults, hold: #"{"state":"agents","agents":3}"#)
        // Unlit — the light is the person's lease — but the word says who
        // holds the Mac, so the three states read apart.
        #expect(store.isOn[.keepAwake] == false)
        #expect(store.title(for: .keepAwake) == "3 agents")
        #expect(store.help(for: .keepAwake).contains("Click to keep it awake"))
        state.setAwakeKeepsDisplay(true)
        #expect(fake.sent.isEmpty, "the agents' hold is not the chip's to re-shape")
        store.apply(.keepAwake)
        await settle(state)
        #expect(fake.sent == [CoreAwakeRequest(.indefinite, display: true)])
        // A link's off cannot end the agents' hold; it says whose it is.
        store.set(.keepAwake, on: false)
        #expect(fake.sent.count == 1)
        #expect(store.caption?.contains("agents hold it") == true)
    }

    @Test func aTimedHoldIsACountdownLease() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, state, fake) = try leased(defaults)
        store.holdAwake(seconds: 3600)
        await settle(state)
        #expect(fake.sent == [CoreAwakeRequest(.seconds(3600), display: false)])
        let end = Date().timeIntervalSince1970 + 42 * 60 + 30
        state.noteDaemonHold(try JSONDecoder().decode(CoreAwakeHold.self, from: Data(
            #"{"state":"manual","lease":{"kind":"duration","until":\#(end)}}"#.utf8)), live: true)
        #expect(store.title(for: .keepAwake) == "43m")
        #expect(store.awakeUntil.map { abs($0.timeIntervalSince1970 - end) < 0.001 } == true)
        // The display option re-sends the same lease, its end kept.
        state.setAwakeKeepsDisplay(true)
        await settle(state)
        #expect(fake.sent.last == .some(CoreAwakeRequest(.until(end), display: true)))
    }

    @Test func aRefusalIsSaidOnTheStrip() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, state, fake) = try leased(defaults)
        fake.answer = .refused("No agent is working right now.")
        store.apply(.keepAwake)
        await settle(state)
        #expect(store.caption == "Awake: No agent is working right now.")
        #expect(!state.awake.held, "a refusal is not a reason to hold anyway")
    }

    @Test func aHoldTakenWhileTheDaemonWasAwayBecomesItsLease() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: FakeDock(), defaults: defaults)
        let fake = FakeLease()
        state.sendLease = { request in
            fake.sent.append(request)
            return fake.answer
        }
        // Stand in for an assertion the app took while the daemon was
        // away (id 0 is never a real one; releasing it is a no-op).
        state.awake.held = true
        state.noteDaemonHold(nil, live: false)
        #expect(state.isOn[.keepAwake] == true)
        state.noteDaemonHold(try JSONDecoder().decode(CoreAwakeHold.self, from: Data(#"{"state":"off"}"#.utf8)),
                             live: true)
        let deadline = Date().addingTimeInterval(5)
        while state.awake.held, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(fake.sent == [CoreAwakeRequest(.indefinite, display: false)])
        #expect(!state.awake.held, "handed over, then let go: one hold")
    }

    @Test func anOlderDaemonLeavesTheHoldToTheApp() throws {
        #expect(SystemTogglesStore.State.answer(CoreReply(id: "1", ok: true)) == .taken)
        #expect(SystemTogglesStore.State.answer(CoreReply(id: "1", ok: false,
            error: CoreReplyError(code: "unknown_command"))) == .unavailable)
        #expect(SystemTogglesStore.State.answer(CoreReply(id: "1", ok: false,
            error: CoreReplyError(code: "refused", message: "No agent is working right now.")))
                == .refused("No agent is working right now."))
        func lease(_ json: String) throws -> CoreAwakeLease {
            try JSONDecoder().decode(CoreAwakeLease.self, from: Data(json.utf8))
        }
        #expect(SystemTogglesStore.State.sameShape(try lease(#"{"kind":"agents","sessions":["s1"]}"#))
                    == .untilAgentsFinish(sessions: ["s1"]))
        #expect(SystemTogglesStore.State.sameShape(try lease(#"{"kind":"agents","sessions":[]}"#))
                    == .untilAgentsFinish(sessions: nil), "no sessions: every main session running now")
        #expect(SystemTogglesStore.State.sameShape(try lease(#"{"kind":"indefinite"}"#)) == .indefinite)
    }

    @Test func aDaemonWithoutTheLeaseLeavesAHoldTheChipCanLetGo() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, state, fake) = try leased(defaults)
        // Stand-in assertions: id 0 is never a real one.
        let assertions = FakeAssertions()
        state.takeAssertion = { _ in assertions.taken += 1; return 0 }
        state.releaseAssertion = { _ in assertions.released += 1 }
        fake.answer = .unavailable
        store.apply(.keepAwake)
        await settle(state)
        #expect(fake.sent == [CoreAwakeRequest(.indefinite, display: false)])
        #expect(state.awake.held, "the app's own assertion stands in")
        #expect(store.isOn[.keepAwake] == true, "and the chip shows the hold it took")
        // The daemon's frames keep coming; none re-asks a daemon that said
        // it cannot take the hold.
        for _ in 0..<3 { state.noteDaemonHold(nil, live: true) }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(fake.sent.count == 1)
        #expect(state.awake.held)
        // The lit chip's tap lets the assertion go.
        store.apply(.keepAwake)
        #expect(!state.awake.held)
        #expect(store.isOn[.keepAwake] == false)
        // A link's on and off move the same assertion, without a lease.
        store.set(.keepAwake, on: true)
        #expect(state.awake.held)
        store.set(.keepAwake, on: false)
        #expect(!state.awake.held)
        #expect(fake.sent.count == 1)
        #expect(assertions.taken == 2 && assertions.released == 2)
        // The next connection is asked afresh.
        state.noteDaemonHold(nil, live: false)
        state.noteDaemonHold(nil, live: true)
        fake.answer = .taken
        store.apply(.keepAwake)
        await settle(state)
        #expect(fake.sent.count == 2)
        #expect(!state.awake.held, "a daemon that takes it holds the one hold")
    }

    @Test func automationAnswersMapToWhatTheChipSays() {
        #expect(AutomationPermission.classify(noErr) == .granted)
        #expect(AutomationPermission.classify(OSStatus(-1744)) == .needsConsent)
        #expect(AutomationPermission.classify(OSStatus(-1743)) == .denied)
        // System Events not running: macOS cannot say yet.
        #expect(AutomationPermission.classify(OSStatus(-600)) == .unavailable)
    }

    @Test func aSavedLevelIsPerScopeAndDevice() {
        #expect(AudioMute.savedLevelKey(uid: "BuiltInSpeakerDevice", scope: .output)
                != AudioMute.savedLevelKey(uid: "BuiltInSpeakerDevice", scope: .input))
        #expect(AudioMute.savedLevelKey(uid: "A", scope: .output) != AudioMute.savedLevelKey(uid: "B", scope: .output))
    }

    @Test func theStripPersistsInCanonicalOrder() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SystemTogglesStore(state: .init(dockDriver: FakeDock(), defaults: defaults))
        #expect(store.strip == SystemToggle.defaultStrip)
        store.setInStrip(.hiddenFiles, false)
        store.setInStrip(.desktopIcons, false)
        #expect(!store.strip.contains(.hiddenFiles))
        // A chip coming back takes its own place, not the end.
        store.setInStrip(.hiddenFiles, true)
        #expect(store.strip.firstIndex(of: .hiddenFiles) == 2)
        let reloaded = SystemTogglesStore(state: .init(dockDriver: FakeDock(), defaults: defaults))
        #expect(reloaded.strip == store.strip)
    }
}
