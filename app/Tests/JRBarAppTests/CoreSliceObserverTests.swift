import Foundation
@testable import JRBarCore
import Observation
import Testing
@testable import JRBarApp

/// Which of the app's `CoreModel` observers a frame wakes. Each observer
/// names what it reads in a static `observedFacts`/`stateFacts`, and the
/// same function runs under its `withObservationTracking`: a frame that
/// changes only the sessions wakes only the session readers, and a frame
/// that changes only a health age wakes none of them.
@Suite("CoreModel slice observers")
@MainActor
struct CoreSliceObserverTests {
    final class Tripped: @unchecked Sendable { var fired = false }

    func wakes(_ read: () -> Void, when change: () -> Void) -> Bool {
        let tripped = Tripped()
        withObservationTracking(read) { tripped.fired = true }
        change()
        return tripped.fired
    }

    static func state(_ generation: Int, updated: Double, heardAge: Double) -> CoreState {
        let usage = CoreUsage(refreshedAt: 1_790_000_000, providers: [
            CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(key: "5h", name: "5h", usedPct: 40)]),
        ])
        return CoreState(
            generation: generation, now: 1_790_000_000 + Double(generation),
            aggregate: CoreAggregate(mode: "working", active: 1),
            sessions: [CoreSession(id: "claude:s1", provider: "claude", mode: "working", updatedAt: updated)],
            usage: usage,
            health: .object(["sources": .object(["claude": .object([
                "fresh": .bool(true), "heard_age_seconds": .number(heardAge)])])]),
            settingsGeneration: 9, catalogGeneration: 4)
    }

    static func liveCore() -> CoreModel {
        let core = CoreModel(socketPath: "/tmp/jrbar-test-none.sock")
        core.handle(.connected)
        core.apply(.state(state(1, updated: 100, heardAge: 5)))
        return core
    }

    @Test("a frame that moves only the sessions wakes only the session readers")
    func sessionsOnlyFrame() {
        let core = Self.liveCore()
        let frame = CoreMessage.state(Self.state(2, updated: 101, heardAge: 5))
        #expect(!wakes({ PresenceReporter.observedFacts(core) }, when: { core.apply(frame) }))
        let second = CoreMessage.state(Self.state(3, updated: 102, heardAge: 5))
        #expect(!wakes({ UsageCenterStore.observedFacts(core) }, when: { core.apply(second) }))
        let third = CoreMessage.state(Self.state(4, updated: 103, heardAge: 5))
        #expect(!wakes({ EffectStudioStore.observedFacts(core) }, when: { core.apply(third) }))
        let fourth = CoreMessage.state(Self.state(5, updated: 104, heardAge: 5))
        #expect(wakes({ AquariumToy.observedFacts(core) }, when: { core.apply(fourth) }),
                "the tank's fish are the sessions")
        let fifth = CoreMessage.state(Self.state(6, updated: 105, heardAge: 5))
        #expect(wakes({ EventCoordinator.stateFacts(core) }, when: { core.apply(fifth) }),
                "the buddy watches every session")
    }

    @Test("a frame that moves only a health age wakes none of them")
    func healthOnlyFrame() {
        let core = Self.liveCore()
        let readers: [(String, @MainActor (CoreModel) -> Void)] = [
            ("presence", PresenceReporter.observedFacts),
            ("usage center", UsageCenterStore.observedFacts),
            ("effect studio", EffectStudioStore.observedFacts),
            ("aquarium", AquariumToy.observedFacts),
            ("event coordinator", EventCoordinator.stateFacts),
        ]
        var generation = 10
        for (name, read) in readers {
            generation += 1
            let frame = CoreMessage.state(Self.state(generation, updated: 100, heardAge: Double(generation)))
            #expect(!wakes({ read(core) }, when: { core.apply(frame) }), "\(name) woke for a health age")
        }
    }
}
