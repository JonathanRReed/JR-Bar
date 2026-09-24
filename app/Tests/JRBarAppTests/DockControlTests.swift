import Foundation
import Testing
@testable import JRBarApp

/// `AppleDockControl`'s contract (docs/TOY-PARITY.md P1): what an old
/// Replace build saved before hiding Apple's Dock is picked up at
/// launch, `restore()` puts it back with one Dock restart — logged —
/// and with nothing saved it never writes `com.apple.dock` at all.
@Suite struct DockControlTests {

    /// The injectable suite — an in-memory `autohide` plus a write log.
    private final class FakeDefaults: AppleDockDefaults {
        var store: [String: Bool] = [:]
        var writes: [(String, Bool)] = []
        func setBool(_ value: Bool, forKey key: String) {
            store[key] = value
            writes.append((key, value))
        }
        func setDouble(_ value: Double, forKey key: String) {}
        func removeValue(forKey key: String) {}
        func synchronize() {}
    }

    /// The key an old build's hide mirrored `autohide` into.
    static let savedAutohideKey = "JRBarDock.savedAutohide"

    private func makeControl(
        _ defaults: FakeDefaults, saved: Bool? = nil
    ) -> (AppleDockControl, Restarter, Log, UserDefaults) {
        // Isolated persistence — the crash-safe mirror defaults to
        // `.standard`, which parallel tests would share and corrupt.
        let persistence = UserDefaults(
            suiteName: "DockControlTests.\(UUID().uuidString)")!
        if let saved { persistence.set(saved, forKey: Self.savedAutohideKey) }
        let control = AppleDockControl(defaults: defaults, persistence: persistence)
        let restarter = Restarter()
        control.restartDock = { restarter.count += 1 }
        let log = Log()
        control.onLog = { log.lines.append($0) }
        return (control, restarter, log, persistence)
    }

    private final class Restarter: @unchecked Sendable { var count = 0 }
    private final class Log: @unchecked Sendable { var lines: [String] = [] }

    @Test func restorePutsTheSavedValueBack() {
        let defaults = FakeDefaults()
        defaults.store["autohide"] = true   // the old bar's hide
        let (control, restarter, log, persistence) = makeControl(defaults, saved: false)
        #expect(control.savedAutohide == false, "the saved value is picked up at launch")

        #expect(control.restore() == true)

        #expect(defaults.store["autohide"] == false)
        #expect(control.savedAutohide == nil)
        #expect(restarter.count == 1, "autohide takes on a Dock relaunch")
        #expect(log.lines.contains { $0.contains("Restored") })
        #expect(persistence.object(forKey: Self.savedAutohideKey) == nil,
                "the next launch finds nothing left to restore")
    }

    @Test func restorePreservesAUsersOn() {
        let defaults = FakeDefaults()
        defaults.store["autohide"] = true   // the user already auto-hid
        let (control, _, _, _) = makeControl(defaults, saved: true)

        #expect(control.restore() == true)
        #expect(defaults.store["autohide"] == true,
                "restore means THEIR value, not the dock's default")
    }

    @Test func restoreRunsOnce() {
        let defaults = FakeDefaults()
        let (control, restarter, _, _) = makeControl(defaults, saved: false)

        #expect(control.restore() == true)
        #expect(control.restore() == false, "handed back — nothing left to write")
        #expect(defaults.writes.count == 1)
        #expect(restarter.count == 1)
    }

    @Test func restoreWithNothingSavedIsANoOp() {
        let defaults = FakeDefaults()
        let (control, restarter, _, _) = makeControl(defaults)

        #expect(control.restore() == false)
        #expect(defaults.writes.isEmpty, "restore never invents a write")
        #expect(restarter.count == 0, "…nor a restart")
    }
}
