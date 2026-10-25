import Foundation
import Observation
import Testing
@testable import JRBarCore
@testable import JRBarApp

@Suite("App refresh dependencies")
@MainActor
struct AppCoreRefreshTests {
    @Test("ten thousand clock and health frames do not fan out to app refreshers")
    func calmFrames() {
        let core = CoreModel(socketPath: "/tmp/jrbar-refresh-unused.sock")
        core.handle(.connected)
        var refresh = AppCoreRefresh()
        core.apply(.state(CoreState(generation: 1)))
        #expect(refresh.take(core) == .all)
        var calls = 0
        for generation in 2...10_001 {
            core.apply(.state(CoreState(generation: generation, now: Double(generation),
                                       health: .object(["age": .number(Double(generation))]))))
            calls += refresh.take(core).rawValue.nonzeroBitCount
        }
        #expect(calls == 0)
        core.apply(.state(CoreState(generation: 10_002, sessions: [
            CoreSession(id: "fixture", provider: "claude", mode: "working")
        ])))
        #expect(refresh.take(core) == .roster)
        core.apply(.settings(CoreSettings(generation: 1, document: .object([:]))))
        #expect(refresh.take(core) == .settings)
        core.apply(.lights(CoreLights()))
        #expect(refresh.take(core) == .lights)
        core.handle(.disconnected(reason: "fixture"))
        #expect(refresh.take(core).contains(.connection))
    }

    @Test("health frames do not rearm the app observation")
    func observationStaysCalm() {
        let core = CoreModel(socketPath: "/tmp/jrbar-refresh-unused.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking { AppDelegate.observedAppFacts(core) } onChange: { flag.fired = true }
        for generation in 1...10_000 {
            core.apply(.state(CoreState(generation: generation, now: Double(generation))))
        }
        #expect(!flag.fired)
        core.apply(.state(CoreState(sessions: [CoreSession(id: "fixture", provider: "claude")])))
        #expect(flag.fired)
    }

    @Test("quota expiry and countdowns refresh without a changed frame")
    func expiryClock() {
        let usage = [CoreProviderUsage(id: "claude", windows: [
            CoreUsageWindow(name: "5h", usedPct: 40, resetsAt: 120),
            CoreUsageWindow(name: "weekly", usedPct: 20, resetsAt: 240)
        ])]
        #expect(AppCoreRefresh.nextTick(askTick: nil, usage: usage, now: 100) == 120)
        #expect(AppCoreRefresh.nextTick(askTick: 110, usage: usage, now: 100) == 110)
        #expect(AppCoreRefresh.nextTick(askTick: nil, usage: usage, now: 120) == 180)
        #expect(AppCoreRefresh.nextTick(askTick: nil, usage: usage, now: 240) == nil)
        #expect(AppCoreRefresh.nextTick(askTick: nil, usage: [], now: 100) == nil)
        let reading = AppDelegate.meterReading(of: usage[0], window: usage[0].windows[0], now: 120)
        #expect(reading.fraction == nil && !reading.current)
    }

    @Test("elapsed labels and snoozes keep their clock boundaries")
    func timedLabels() {
        #expect(AppCoreRefresh.nextTick(askTick: nil, usage: [], elapsedSince: [100], now: 100.2) == 101)
        #expect(AppCoreRefresh.nextTick(askTick: nil, usage: [], elapsedSince: [100], now: 160) == 220)
        #expect(AppCoreRefresh.nextTick(askTick: nil, usage: [], elapsedSince: [0], now: 86_400) == 90_000)
        #expect(AppCoreRefresh.nextTick(askTick: nil, usage: [], deadlines: [180], now: 170) == 180)
        #expect(AppCoreRefresh.nextTick(askTick: nil, usage: [], deadlines: [180], now: 180) == nil)
    }

    @Test("a pending Screen Bar write gets a wake at the end of its grace")
    func pendingWriteClock() {
        var sync = ScreenBarDaemonSync()
        sync.toggled(shown: true, live: true, now: Date(timeIntervalSince1970: 100))
        let until = sync.pending.map { $0.at.timeIntervalSince1970 + ScreenBarDaemonSync.pendingWindow }
        let deadlines = [until].compactMap { $0 }
        #expect(AppCoreRefresh.nextTick(askTick: nil, usage: [], deadlines: deadlines, now: 100) == 110)
        let decision = sync.reconcile(live: true, daemonValue: false, appValue: true,
                                      now: Date(timeIntervalSince1970: 110))
        #expect(decision == .adopt(false))
        #expect(sync.pending == nil)
    }

    @Test("device and quota changes keep their own refreshers")
    func usageSliceChanges() {
        let core = CoreModel(socketPath: "/tmp/jrbar-refresh-unused.sock")
        var refresh = AppCoreRefresh()
        core.apply(.state(CoreState()))
        _ = refresh.take(core)
        core.apply(.state(CoreState(usage: CoreUsage(providers: [CoreProviderUsage(id: "claude")]))))
        #expect(refresh.take(core) == .usage)
    }
}
