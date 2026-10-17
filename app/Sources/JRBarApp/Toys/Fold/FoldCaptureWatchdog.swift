import Foundation

/// A capture that never delivers a frame must recover even after the lid
/// and its draw clock have stopped. One deadline belongs to each source.
@MainActor
final class FoldCaptureWatchdog {
    static let timeout: TimeInterval = 5
    typealias Cancellation = @MainActor () -> Void
    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Cancellation

    private let schedule: Schedule
    private var cancelScheduled: Cancellation?
    private var generation = 0

    init(schedule: @escaping Schedule = FoldCaptureWatchdog.scheduleOnMain) {
        self.schedule = schedule
    }

    isolated deinit { cancelScheduled?() }

    func arm(isCurrent: @escaping @MainActor () -> Bool,
             hasFrame: @escaping @MainActor () -> Bool,
             expired: @escaping @MainActor () -> Void) {
        cancel()
        let mine = generation
        cancelScheduled = schedule(Self.timeout) { [weak self] in
            guard let self, self.generation == mine else { return }
            self.cancelScheduled = nil
            self.generation += 1
            guard isCurrent(), !hasFrame() else { return }
            expired()
        }
    }

    func cancel() {
        generation += 1
        cancelScheduled?()
        cancelScheduled = nil
    }

    static let scheduleOnMain: Schedule = { delay, callback in
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { callback() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }
}
