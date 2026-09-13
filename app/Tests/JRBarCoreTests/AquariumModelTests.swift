import Foundation
import Testing
@testable import JRBarCore

/// `AquariumModel.reduce` is the tank's session → fish mapping
/// (docs/TOYS.md): pure, deterministic, and the only place a session
/// becomes a fish.
@Suite("Aquarium model")
struct AquariumModelTests {
    static func session(_ id: String, lifecycle: String? = "active", mode: String? = "working",
                        ask: Bool = false) -> CoreSession {
        CoreSession(id: id, provider: "claude", label: "run \(id)", mode: mode, lifecycle: lifecycle,
                    ask: ask ? CoreAsk(session: id, kind: "permission", openedAt: 1) : nil)
    }

    @Test("every session is a fish, in the session list's order")
    func mapping() {
        let now = Date()
        let fish = AquariumModel.reduce(sessions: [
            Self.session("a", mode: "working"),
            Self.session("b", mode: "working", ask: true),
            Self.session("c", lifecycle: "failed"),
            Self.session("d", lifecycle: "completed"),
            Self.session("e", lifecycle: "ended"),
            Self.session("f", mode: "idle_ready"),
        ], previous: [], now: now)
        #expect(fish.map(\.id) == ["a", "b", "c", "d", "e", "f"])
        #expect(fish.map(\.state) == [.swimming, .surfacing, .sinking, .leaving, .sinking, .swimming])
        #expect(fish.allSatisfy { $0.stateSince == now })
        #expect(fish.first?.label == "run a")
        #expect(fish.first?.providerID == "claude")
    }

    @Test("a fish keeps its swim across reduces; only the state word moves")
    func identity() {
        let t0 = Date()
        let first = AquariumModel.reduce(sessions: [Self.session("a")], previous: [], now: t0)[0]
        let t1 = t0 + 2
        let again = AquariumModel.reduce(sessions: [Self.session("a", ask: true)], previous: [first], now: t1)[0]
        #expect(again.lane == first.lane)
        #expect(again.speed == first.speed)
        #expect(again.direction == first.direction)
        #expect(again.state == .surfacing)
        #expect(again.stateSince == t1)
        // No state change, no new clock.
        let third = AquariumModel.reduce(sessions: [Self.session("a", ask: true)],
                                         previous: [again], now: t1 + 4)[0]
        #expect(third.stateSince == t1)
        // A renamed session relabels the same fish.
        var renamed = Self.session("a", ask: true)
        renamed.label = "docs sweep"
        let relabelled = AquariumModel.reduce(sessions: [renamed], previous: [third], now: t1 + 5)[0]
        #expect(relabelled.label == "docs sweep")
        #expect(relabelled.stateSince == t1)
    }

    @Test("a new fish's swim is a stable hash of its id")
    func deterministic() {
        let now = Date()
        let a = AquariumModel.reduce(sessions: [Self.session("same-id")], previous: [], now: now)[0]
        let b = AquariumModel.reduce(sessions: [Self.session("same-id")], previous: [], now: now + 100)[0]
        #expect(a.lane == b.lane)
        #expect(a.speed == b.speed)
        #expect(a.direction == b.direction)
        for fish in [a, b] {
            #expect((0...1).contains(fish.lane))
            #expect(fish.speed > 0)
            #expect(fish.direction == 1 || fish.direction == -1)
        }
    }

    @Test("a completion drifts off and retires; it never respawns while the session is listed")
    func leaving() {
        let t0 = Date()
        var fish = AquariumModel.reduce(sessions: [Self.session("a")], previous: [], now: t0)
        fish = AquariumModel.reduce(sessions: [Self.session("a", lifecycle: "completed")],
                                    previous: fish, now: t0 + 1)
        let leaver = fish[0]
        #expect(leaver.state == .leaving)
        #expect(leaver.stateSince == t0 + 1)
        #expect(abs(leaver.leaveProgress(at: t0 + 4) - 0.5) < 0.001)
        #expect(!leaver.isRetired(at: t0 + 6))
        #expect(leaver.isRetired(at: t0 + 7))
        // Retired fish stay in the list: a finished session is still
        // listed until the user clears it, so dropping the fish would
        // just spawn a fresh leaver on the next pass.
        let later = AquariumModel.reduce(sessions: [Self.session("a", lifecycle: "completed")],
                                         previous: fish, now: t0 + 60)
        #expect(later.count == 1)
        #expect(later[0].stateSince == t0 + 1)
        #expect(later[0].isRetired(at: t0 + 60))
        #expect(later[0].leaveProgress(at: t0 + 60) == 1)
    }

    @Test("a session that leaves the list takes its fish with it")
    func removal() {
        let now = Date()
        let fish = AquariumModel.reduce(sessions: [Self.session("a"), Self.session("b")],
                                        previous: [], now: now)
        let after = AquariumModel.reduce(sessions: [Self.session("b")], previous: fish, now: now)
        #expect(after.map(\.id) == ["b"])
    }

    @Test("a fish that comes back to life clears its exit")
    func revived() {
        let t0 = Date()
        var fish = AquariumModel.reduce(sessions: [Self.session("a", lifecycle: "completed")],
                                        previous: [], now: t0)
        #expect(fish[0].state == .leaving)
        fish = AquariumModel.reduce(sessions: [Self.session("a", mode: "working")],
                                    previous: fish, now: t0 + 2)
        #expect(fish[0].state == .swimming)
        #expect(fish[0].stateSince == t0 + 2)
        #expect(!fish[0].isRetired(at: t0 + 100))
    }

    @Test("an ask outranks work, and a failure outranks an ask")
    func precedence() {
        let now = Date()
        // `SessionActivity` owns precedence; the tank just inherits it.
        let asked = AquariumModel.reduce(sessions: [Self.session("a", mode: "working", ask: true)],
                                         previous: [], now: now)[0]
        #expect(asked.state == .surfacing)
        let failed = AquariumModel.reduce(sessions: [Self.session("a", lifecycle: "failed", ask: true)],
                                          previous: [], now: now)[0]
        #expect(failed.state == .sinking)
    }
}
