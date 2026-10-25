import Foundation
import Observation

/// Buffered signals survive an occupied main actor. Cancellation ends a wait.
@MainActor
public final class TestEvents<Event: Sendable> {
    nonisolated private let events = AsyncStream<Event>.makeStream()

    nonisolated public init() {}

    nonisolated public func send(_ event: Event) { events.continuation.yield(event) }

    public func next(where matches: (Event) -> Bool = { _ in true }) async throws -> Event {
        for await event in events.stream where matches(event) { return event }
        throw CancellationError()
    }
}

@MainActor
public func waitForObservedState(_ predicate: () -> Bool) async -> Bool {
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

/// Holds synchronous work on its owning Dispatch queue until its test releases it.
/// The test must release in defer and await the work before returning.
public final class TestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false

    public init() {}

    public func wait() {
        condition.lock()
        defer { condition.unlock() }
        while !open { condition.wait() }
    }

    public func signal() {
        condition.lock()
        open = true
        condition.broadcast()
        condition.unlock()
    }
}

/// A buffered callback signal. A cancelled test stops waiting without blocking a thread.
public final class TestSignal: Sendable {
    private let events = AsyncStream<Void>.makeStream()
    public init() {}
    public func signal() { events.continuation.yield(()) }
    public func wait() async -> Bool {
        for await _ in events.stream { return true }
        return false
    }
}
