import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The Now Playing helper's line protocol and evidence line. No helper
/// is launched: the parse and the log wording are pure.
@Suite("Notch media adapter")
@MainActor
struct NotchMediaAdapterTests {
    @Test("null, blank and unparseable lines are nothing playing")
    func nothingPlaying() {
        #expect(AlcoveMediaAdapter.parse(Data("null".utf8)) == nil)
        #expect(AlcoveMediaAdapter.parse(Data("   ".utf8)) == nil)
        #expect(AlcoveMediaAdapter.parse(Data("{not json".utf8)) == nil)
    }

    @Test("the first answer's evidence line says how long, and whether a track was playing")
    func evidence() {
        #expect(AlcoveMediaAdapter.firstLineNote(after: 0.2374, track: true)
                == "helper live after 237 ms — a track is playing")
        #expect(AlcoveMediaAdapter.firstLineNote(after: 1.5, track: false)
                == "helper live after 1500 ms — nothing playing")
    }
}

/// The Now Playing helper's restart pace, and the monitor's restart after a
/// failure. The monitor here never spawns perl and never reads the system's
/// MediaRemote: `startAdapter` is a counter and the restart's wait is
/// captured, then fired by hand, so no timer is involved.
@MainActor
@Suite("Notch media retry")
struct NotchMediaRetryTests {
    /// A monitor whose helper is a counter and whose restart wait is a
    /// list of (delay, closure) the test fires itself.
    @MainActor
    private final class RetryMonitor: AlcoveMediaMonitor {
        var starts = 0
        var armed: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
        var reported: [AlcoveMedia?] = []

        override func startAdapter() {
            starts += 1
            markAdapterLive(true)
        }

        override func armAdapterRetry(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
            armed.append((delay, work))
        }
    }

    private final class Clock {
        var date = Date(timeIntervalSince1970: 2_000_000)
    }

    /// A monitor already started the way `start` leaves it, its helper
    /// counted once, and a clock the test moves.
    private func runningMonitor(_ clock: Clock) -> RetryMonitor {
        let monitor = RetryMonitor()
        monitor.now = { clock.date }
        // An hour: the bridge fallback's own poll never comes due here.
        monitor.pollInterval = 3600
        monitor.markRunning(true)
        monitor.startAdapter()
        return monitor
    }

    // MARK: The pace

    @Test("the delays come out 5, 30, 120, then none")
    func delaysThenNone() {
        var policy = AlcoveAdapterRetryPolicy()
        #expect(policy.nextDelay(liveFor: nil) == 5)
        #expect(policy.nextDelay(liveFor: nil) == 30)
        #expect(policy.nextDelay(liveFor: nil) == 120)
        #expect(policy.nextDelay(liveFor: nil) == nil)
        #expect(policy.nextDelay(liveFor: nil) == nil, "spent stays spent")
    }

    @Test("a first line and an instant death does not reset the count")
    func shortLifeKeepsCounting() {
        var policy = AlcoveAdapterRetryPolicy()
        #expect(policy.nextDelay(liveFor: 0) == 5)
        #expect(policy.nextDelay(liveFor: 0.5) == 30)
        #expect(policy.nextDelay(liveFor: 59.9) == 120)
        #expect(policy.nextDelay(liveFor: 59.9) == nil)
    }

    @Test("a helper that stayed up a minute earns a fresh budget")
    func stableLifeResets() {
        var policy = AlcoveAdapterRetryPolicy()
        #expect(policy.nextDelay(liveFor: nil) == 5)
        #expect(policy.nextDelay(liveFor: nil) == 30)
        #expect(policy.nextDelay(liveFor: policy.stableAfter) == 5)
        policy.reset()
        #expect(policy.nextDelay(liveFor: nil) == 5)
    }

    // MARK: The monitor

    @Test("a failure arms one restart at 5 s, and firing it starts the helper again")
    func failureRestarts() {
        let monitor = runningMonitor(Clock())
        monitor.adapterDidFail()
        #expect(monitor.armed.map(\.delay) == [5])
        #expect(monitor.starts == 1)
        monitor.armed[0].work()
        #expect(monitor.starts == 2)
    }

    @Test("repeated failures stop after three restarts and never arm a fourth")
    func budgetIsSpent() {
        let monitor = runningMonitor(Clock())
        for _ in 0..<3 {
            monitor.adapterDidFail()
            monitor.armed.last?.work()
        }
        #expect(monitor.armed.map(\.delay) == [5, 30, 120])
        #expect(monitor.starts == 4)
        monitor.adapterDidFail()
        #expect(monitor.armed.count == 3, "the budget is spent: no fourth")
        #expect(monitor.starts == 4)
    }

    @Test("stop cancels the pending restart, and a stale restart never starts a second helper")
    func stopCancels() {
        let monitor = runningMonitor(Clock())
        monitor.adapterDidFail()
        let pending = monitor.armed[0].work
        monitor.stop()
        pending()
        #expect(monitor.starts == 1, "a parked island holds no child process")

        // A stop then a start, and only then the old restart fires.
        let again = runningMonitor(Clock())
        again.adapterDidFail()
        let stale = again.armed[0].work
        again.stop()
        again.markRunning(true)
        again.startAdapter()
        stale()
        #expect(again.starts == 2, "the restart armed before the stop is retired")
    }

    @Test("a stop gives the next start a fresh budget")
    func stopResetsTheBudget() {
        let monitor = runningMonitor(Clock())
        for _ in 0..<3 {
            monitor.adapterDidFail()
            monitor.armed.last?.work()
        }
        monitor.stop()
        monitor.markRunning(true)
        monitor.startAdapter()
        monitor.adapterDidFail()
        #expect(monitor.armed.last?.delay == 5)
        #expect(monitor.armed.count == 4)
    }

    @Test("a failure while not running arms nothing")
    func notRunningArmsNothing() {
        let monitor = RetryMonitor()
        monitor.adapterDidFail()
        #expect(monitor.armed.isEmpty)
    }

    @Test("after a failure the bridge reads again; the restarted helper takes the reads back")
    func failureHandsToTheBridgeAndBack() {
        let monitor = runningMonitor(Clock())
        var seen: [Bool] = []
        monitor.onChange = { media in seen.append(media != nil) }
        #expect(monitor.adapterLive)
        monitor.adapterDidFail()
        #expect(!monitor.adapterLive)
        #expect(seen == [false], "the bridge path ran a read at once and found nothing playing")
        monitor.armed[0].work()
        #expect(monitor.adapterLive, "the restarted helper is the reader again")
    }

    @Test("a helper that lived a minute after its first line gets the short wait again; one that died at once does not")
    func stableLifeGetsTheShortWait() {
        let clock = Clock()
        let monitor = runningMonitor(clock)
        // Dies with no first line: 5 s, then 30 s.
        monitor.adapterDidFail()
        monitor.armed.last?.work()
        monitor.adapterDidFail()
        monitor.armed.last?.work()
        #expect(monitor.armed.map(\.delay) == [5, 30])
        // It speaks, lives a minute, then dies: the budget is fresh.
        monitor.adapterDidReport(nil)
        clock.date = clock.date.addingTimeInterval(60)
        monitor.adapterDidFail()
        #expect(monitor.armed.last?.delay == 5)
        monitor.armed.last?.work()
        // It speaks and dies at once: no reset, the next wait is 30 s.
        monitor.adapterDidReport(nil)
        monitor.adapterDidFail()
        #expect(monitor.armed.last?.delay == 30)
    }
}
