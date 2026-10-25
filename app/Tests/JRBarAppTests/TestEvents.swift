import Foundation
import Observation

/// Buffered signals survive an occupied main actor. Cancellation ends a wait.
@MainActor
final class TestEvents<Event: Sendable> {
    private let events = AsyncStream<Event>.makeStream()

    func send(_ event: Event) { events.continuation.yield(event) }

    func next(where matches: (Event) -> Bool = { _ in true }) async throws -> Event {
        for await event in events.stream where matches(event) { return event }
        throw CancellationError()
    }
}

@MainActor
func waitForObservedState(_ predicate: () -> Bool) async -> Bool {
    while !predicate(), !Task.isCancelled {
        let changes = AsyncStream<Void>.makeStream()
        withObservationTracking { _ = predicate() } onChange: {
            changes.continuation.yield(())
            changes.continuation.finish()
        }
        for await _ in changes.stream { break }
    }
    return !Task.isCancelled && predicate()
}
