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
