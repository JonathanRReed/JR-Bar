import Foundation
@testable import JRBarApp

/// A main-queue stand-in for the timer seams (`NotchToy.capsuleTimer`,
/// `DockWindowObserver.timer`): work armed here waits on a virtual
/// clock that moves only when the test says so. A proof about a timer
/// chain then never races a main queue the parallel suite is crowding —
/// a GitHub runner once held one capsule chain past a minute — and a
/// chain that never arms its next hop fails at once instead of timing
/// out.
@MainActor
final class ManualTimers {
    private struct Armed {
        let due: TimeInterval
        let order: Int
        let work: DispatchWorkItem
    }

    /// Seconds since the test began, on the virtual clock.
    private(set) var now: TimeInterval = 0
    private var armed: [Armed] = []
    private var order = 0
    private let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// The virtual clock as a `Date`, for a `Date`-reading seam.
    var date: Date { epoch.addingTimeInterval(now) }

    /// The seam: `work` runs once the clock reaches `delay` from now.
    func arm(_ delay: TimeInterval, _ work: DispatchWorkItem) {
        order += 1
        armed.append(Armed(due: now + max(0, delay), order: order, work: work))
    }

    /// Armed work that has not run and was not cancelled.
    var live: Int { armed.filter { !$0.work.isCancelled }.count }

    /// When the next live timer comes due, on the virtual clock.
    var nextDue: TimeInterval? { next()?.due }

    /// Move the clock to the next live timer and run it — false when
    /// nothing is armed, which is exactly what a wedged chain looks like.
    @discardableResult
    func fireNext() -> Bool {
        guard let next = next() else { return false }
        armed.removeAll { $0.order == next.order }
        now = max(now, next.due)
        next.work.perform()
        return true
    }

    /// Move the clock by `seconds`, running whatever comes due on the
    /// way in due order — work armed by that work included.
    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let next = next(), next.due <= target { fireNext() }
        now = target
    }

    private func next() -> Armed? {
        armed.removeAll { $0.work.isCancelled }
        return armed.min { ($0.due, $0.order) < ($1.due, $1.order) }
    }
}

extension ManualTimers {
    /// `toy`'s capsule line — its timers and the shelf's clock — on a
    /// fresh hand-cranked pair.
    static func driving(_ toy: NotchToy) -> ManualTimers {
        let timers = ManualTimers()
        toy.capsuleTimer = { delay, work in timers.arm(delay, work) }
        toy.capsuleClock = { timers.date }
        return timers
    }
}
