import Foundation
import Observation
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// Scratch probes for the settings-shell review. Not for the repo.
@MainActor
@Suite("Review probes")
struct ReviewProbeTests {
    final class Fired: @unchecked Sendable { var count = 0 }

    static func watch(_ read: () -> Void) -> Fired {
        let fired = Fired()
        withObservationTracking(read) { fired.count += 1 }
        return fired
    }

    static func makeCore() -> CoreModel {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-review-probe.sock")
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
                                          document: .object(["idle_dim_enabled": .bool(true)]))))
        return core
    }

    @Test("probe: a reopened window is told the monitor came back")
    func reopenedWindowFollowsLive() {
        let core = Self.makeCore()
        let settings = SettingsStore(core: core)
        core.handle(.connected)
        core.apply(.state(CoreState()))
        settings.syncMirrors()
        #expect(settings.isLive)
        settings.settingsWindowDidClose()
        core.handle(.disconnected(reason: "probe"))
        settings.syncMirrors()
        // Reopen: the page reads the fact (offline) and observes it.
        let seen = settings.isLive
        let watched = Self.watch { _ = settings.isLive }
        core.handle(.connected)
        core.apply(.state(CoreState()))
        settings.syncMirrors()
        #expect(!seen)
        #expect(settings.isLive)
        #expect(watched.count == 1, "PROBE: the row showing offline was not invalidated when the monitor came back")
        withExtendedLifetime(core) {}
    }

    @Test("probe: the newer launch-at-login read's answer stands")
    func launchAtLoginReadsLandInOrder() async {
        final class Gate: @unchecked Sendable { let release = DispatchSemaphore(value: 0) }
        let gate = Gate()
        let settings = SettingsStore(core: Self.makeCore())
        settings.launchAtLoginStatus = { gate.release.wait(); return false }
        let older = settings.refreshLaunchAtLogin()
        settings.launchAtLoginStatus = { true }
        let newer = settings.refreshLaunchAtLogin()
        await newer.value
        #expect(settings.launchAtLogin)
        gate.release.signal()
        await older.value
        #expect(settings.launchAtLogin, "PROBE: the older, slower read landed last and overwrote the newer answer")
    }
}
