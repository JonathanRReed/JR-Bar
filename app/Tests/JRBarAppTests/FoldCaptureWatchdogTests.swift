import Foundation
import Testing
@testable import JRBarApp

@Suite("Fold capture watchdog")
@MainActor
struct FoldCaptureWatchdogTests {
    @MainActor
    final class Deadline {
        let delay: TimeInterval
        let fire: @MainActor () -> Void
        var cancelled = false

        init(delay: TimeInterval, fire: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.fire = fire
        }
    }

    @MainActor
    final class Scheduler {
        var deadlines: [Deadline] = []

        func schedule(_ delay: TimeInterval, _ callback: @escaping @MainActor () -> Void)
            -> FoldCaptureWatchdog.Cancellation {
            let deadline = Deadline(delay: delay, fire: callback)
            deadlines.append(deadline)
            return { deadline.cancelled = true }
        }
    }

    @MainActor
    final class Readiness {
        var current = true
        var hasFrame = false
    }

    @Test("a frameless source retries once without a display tick or sensor reading")
    func parkedLidRecoversCapture() throws {
        let scheduler = Scheduler()
        let watchdog = FoldCaptureWatchdog(schedule: { delay, fire in
            scheduler.schedule(delay, fire)
        })
        var retries = 0
        watchdog.arm(isCurrent: { true }, hasFrame: { false }, expired: { retries += 1 })
        let deadline = try #require(scheduler.deadlines.first)
        #expect(deadline.delay == 5)
        #expect(retries == 0)
        deadline.fire()
        #expect(retries == 1)
        deadline.fire()
        #expect(retries == 1, "a deadline copied into a queue cannot fire twice")
    }

    @Test("a delivered frame cancels recovery, including a copied deadline")
    func firstFrameCancelsRecovery() throws {
        let scheduler = Scheduler()
        let watchdog = FoldCaptureWatchdog(schedule: { delay, fire in
            scheduler.schedule(delay, fire)
        })
        var retries = 0
        watchdog.arm(isCurrent: { true }, hasFrame: { false }, expired: { retries += 1 })
        let deadline = try #require(scheduler.deadlines.first)
        watchdog.cancel()
        #expect(deadline.cancelled)
        deadline.fire()
        #expect(retries == 0)
    }

    @Test("a source with a frame and a retired source never retry")
    func deliveryChecksCurrentReadiness() {
        for state in [(current: true, frame: true), (current: false, frame: false)] {
            let scheduler = Scheduler()
            let watchdog = FoldCaptureWatchdog(schedule: { delay, fire in
                scheduler.schedule(delay, fire)
            })
            let readiness = Readiness()
            var retries = 0
            watchdog.arm(isCurrent: { readiness.current }, hasFrame: { readiness.hasFrame },
                         expired: { retries += 1 })
            readiness.current = state.current
            readiness.hasFrame = state.frame
            scheduler.deadlines[0].fire()
            #expect(retries == 0)
        }
    }

    @Test("replacing a capture cancels its deadline and starts a fresh five seconds")
    func replacementOwnsItsDeadline() {
        let scheduler = Scheduler()
        let watchdog = FoldCaptureWatchdog(schedule: { delay, fire in
            scheduler.schedule(delay, fire)
        })
        var expired: [String] = []
        watchdog.arm(isCurrent: { true }, hasFrame: { false }, expired: { expired.append("old") })
        watchdog.arm(isCurrent: { true }, hasFrame: { false }, expired: { expired.append("new") })
        #expect(scheduler.deadlines.count == 2)
        #expect(scheduler.deadlines[0].cancelled)
        #expect(scheduler.deadlines[1].delay == 5)
        scheduler.deadlines[0].fire()
        #expect(expired.isEmpty)
        scheduler.deadlines[1].fire()
        #expect(expired == ["new"])
    }

    @Test("releasing the watchdog cancels its scheduled work")
    func teardownCancelsDeadline() throws {
        let scheduler = Scheduler()
        var watchdog: FoldCaptureWatchdog? = FoldCaptureWatchdog(schedule: { delay, fire in
            scheduler.schedule(delay, fire)
        })
        watchdog?.arm(isCurrent: { true }, hasFrame: { false }, expired: {})
        let deadline = try #require(scheduler.deadlines.first)
        watchdog = nil
        #expect(deadline.cancelled)
        deadline.fire()
    }
}
