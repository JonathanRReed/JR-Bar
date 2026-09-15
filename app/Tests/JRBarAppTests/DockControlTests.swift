import Foundation
import Testing
@testable import JRBarApp

/// `AppleDockControl`'s contract (docs/TOY-PARITY.md P1): the first
/// hide saves `autohide`, every write restarts the Dock, and
/// `restore()` puts the saved value back — logged, reversible, and
/// never writing `com.apple.dock` outside the explicit calls.
@Suite struct DockControlTests {

    /// The injectable suite — an in-memory `autohide` plus a write log.
    private final class FakeDefaults: AppleDockDefaults {
        var store: [String: Bool] = [:]
        var writes: [(String, Bool)] = []
        func boolValue(forKey key: String) -> Bool? { store[key] }
        func setBool(_ value: Bool, forKey key: String) {
            store[key] = value
            writes.append((key, value))
        }
    }

    private func makeControl(
        _ defaults: FakeDefaults
    ) -> (AppleDockControl, FakeDefaults, Restarter, Log) {
        // Isolated persistence — the crash-safe mirror defaults to
        // `.standard`, which parallel tests would share and corrupt.
        let persistence = UserDefaults(
            suiteName: "DockControlTests.\(UUID().uuidString)")!
        let control = AppleDockControl(defaults: defaults, persistence: persistence)
        let restarter = Restarter()
        control.restartDock = { restarter.count += 1 }
        let log = Log()
        control.onLog = { log.lines.append($0) }
        return (control, defaults, restarter, log)
    }

    private final class Restarter: @unchecked Sendable { var count = 0 }
    private final class Log: @unchecked Sendable { var lines: [String] = [] }

    @Test func hidingSavesTheLiveValueWritesAndRestarts() {
        let defaults = FakeDefaults()
        defaults.store["autohide"] = false
        let (control, _, restarter, _) = makeControl(defaults)

        control.setAppleDockHidden(true)

        #expect(defaults.store["autohide"] == true)
        #expect(control.savedAutohide == false, "the user's off is saved before our write")
        #expect(restarter.count == 1, "autohide takes on a Dock relaunch")
        #expect(control.isAppleDockHidden == true)
    }

    @Test func aSecondHideDoesNotResave() {
        let defaults = FakeDefaults()
        let (control, _, restarter, _) = makeControl(defaults)

        control.setAppleDockHidden(true)   // saves `false` (absent), writes true
        defaults.store["autohide"] = false // someone else flips it back
        control.setAppleDockHidden(true)   // must not overwrite the saved value

        #expect(control.savedAutohide == false)
        #expect(restarter.count == 2)
    }

    @Test func restorePutsTheSavedValueBack() {
        let defaults = FakeDefaults()
        defaults.store["autohide"] = false
        let (control, _, restarter, log) = makeControl(defaults)

        control.setAppleDockHidden(true)
        #expect(control.restore() == true)

        #expect(defaults.store["autohide"] == false)
        #expect(control.savedAutohide == nil)
        #expect(restarter.count == 2)
        #expect(log.lines.contains { $0.contains("Saved") })
        #expect(log.lines.contains { $0.contains("Restored") })
    }

    @Test func restorePreservesAUsersOn() {
        let defaults = FakeDefaults()
        defaults.store["autohide"] = true   // the user already auto-hides
        let (control, _, _, _) = makeControl(defaults)

        control.setAppleDockHidden(true)
        #expect(control.restore() == true)
        #expect(defaults.store["autohide"] == true,
                "restore means THEIR value, not the dock's default")
    }

    @Test func restoreWithNothingSavedIsANoOp() {
        let defaults = FakeDefaults()
        let (control, _, restarter, _) = makeControl(defaults)

        #expect(control.restore() == false)
        #expect(defaults.writes.isEmpty, "restore never invents a write")
        #expect(restarter.count == 0, "…nor a restart")
    }

    @Test func unhideWritesDirectly() {
        let defaults = FakeDefaults()
        defaults.store["autohide"] = true
        let (control, _, restarter, _) = makeControl(defaults)

        control.setAppleDockHidden(false)

        #expect(defaults.store["autohide"] == false)
        #expect(control.savedAutohide == nil, "unhide is not a hide — nothing was saved")
        #expect(restarter.count == 1)
    }

    @Test func absentAutohideReadsAsShown() {
        let defaults = FakeDefaults()
        let (control, _, _, _) = makeControl(defaults)
        #expect(control.isAppleDockHidden == false, "no key is the Dock's default: shown")
    }
}
