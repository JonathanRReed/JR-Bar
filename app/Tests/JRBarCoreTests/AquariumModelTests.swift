import Foundation
import Testing
@testable import JRBarCore

/// `AquariumModel.reduce` is the tank's session → fish mapping
/// (docs/TOYS.md): pure, deterministic, and the only place a session
/// becomes a fish.
@Suite("Aquarium model")
struct AquariumModelTests {
    static func session(_ id: String, lifecycle: String? = "active", mode: String? = "working",
                        ask: Bool = false, updatedAt: Double? = nil,
                        provider: String = "claude", kind: String = "main",
                        parent: String? = nil) -> CoreSession {
        CoreSession(id: id, provider: provider, kind: kind, parent: parent,
                    label: "run \(id)", mode: mode, lifecycle: lifecycle,
                    updatedAt: updatedAt,
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

    @Test("a new fish enters the tank at reduce time & keeps its entrance")
    func entrance() {
        let t0 = Date()
        let first = AquariumModel.reduce(sessions: [Self.session("a")], previous: [], now: t0)[0]
        #expect(first.enteredAt == t0)
        // A state change is not a re-entry: the fish keeps its entrance.
        let again = AquariumModel.reduce(sessions: [Self.session("a", ask: true)],
                                         previous: [first], now: t0 + 5)[0]
        #expect(again.enteredAt == t0)
        #expect(again.stateSince == t0 + 5)
        // A fish that leaves & comes back is a new fish with a new entrance.
        let later = AquariumModel.reduce(sessions: [Self.session("a")], previous: [], now: t0 + 9)[0]
        #expect(later.enteredAt == t0 + 9)
    }

    @Test("the session's updated_at lands on the fish & survives reduces that drop it")
    func activity() {
        let t0 = Date()
        var fish = AquariumModel.reduce(sessions: [Self.session("a", updatedAt: 1_000)],
                                        previous: [], now: t0)[0]
        #expect(fish.lastUpdate == Date(timeIntervalSince1970: 1_000))
        // A later reduce without the field keeps the last known activity.
        fish = AquariumModel.reduce(sessions: [Self.session("a")], previous: [fish], now: t0 + 1)[0]
        #expect(fish.lastUpdate == Date(timeIntervalSince1970: 1_000))
        // A newer stamp replaces it.
        fish = AquariumModel.reduce(sessions: [Self.session("a", updatedAt: 2_000)],
                                    previous: [fish], now: t0 + 2)[0]
        #expect(fish.lastUpdate == Date(timeIntervalSince1970: 2_000))
        // A session that never carried one stays nil.
        let quiet = AquariumModel.reduce(sessions: [Self.session("b")], previous: [], now: t0)[0]
        #expect(quiet.lastUpdate == nil)
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

    @Test("each known provider gets its species; anything else is a minnow")
    func species() {
        let table: [String: FishSpecies] = [
            "claude": .clownfish,
            "codex": .shark,
            "grok": .shark,
            "gemini": .angelfish,
            "antigravity": .puffer,
            "openclaw": .puffer,
            "hermes": .seahorse,
            "opencode": .betta,
            "kiro": .betta,
            "t3code": .betta,
            "devin": .tang,
            "cursor": .tetra,
            "pi": .tetra,
        ]
        for (provider, species) in table {
            #expect(FishSpecies.forProvider(provider) == species, "\(provider)")
        }
        // Case-insensitive, and the unknowns & empties are minnows.
        #expect(FishSpecies.forProvider("Claude") == .clownfish)
        #expect(FishSpecies.forProvider("some-new-agent") == .minnow)
        #expect(FishSpecies.forProvider("") == .minnow)
        // Reduce stamps the species on the fish.
        let fish = AquariumModel.reduce(sessions: [Self.session("a", provider: "gemini")],
                                        previous: [], now: Date())[0]
        #expect(fish.species == .angelfish)
        #expect(!fish.isFry)
        #expect(fish.anchorID == nil)
    }

    @Test("a sub-agent is a fry schooling around its parent's fish")
    func fry() {
        let now = Date()
        let fish = AquariumModel.reduce(sessions: [
            Self.session("w1", kind: "worker", parent: "a"),
            Self.session("a"),
            Self.session("w2", kind: "worker", parent: "a"),
        ], previous: [], now: now)
        // Session order is kept: worker, main, worker.
        #expect(fish.map(\.id) == ["w1", "a", "w2"])
        let parent = fish[1]
        for fry in [fish[0], fish[2]] {
            #expect(fry.isFry)
            #expect(fry.anchorID == "a")
            // The school wears its parent's species.
            #expect(fry.species == parent.species)
            // And gets the same stable swim machinery as any fish.
            #expect((0...1).contains(fry.lane))
            #expect(fry.state == .swimming)
        }
        // A fry keeps its place across reduces.
        let again = AquariumModel.reduce(sessions: [
            Self.session("w1", kind: "worker", parent: "a"),
            Self.session("a"),
            Self.session("w2", kind: "worker", parent: "a"),
        ], previous: fish, now: now + 3)
        #expect(again[0].isFry)
        #expect(again[0].anchorID == "a")
        #expect(again[0].enteredAt == now)
    }

    @Test("a fry whose parent isn't listed schools near the largest same-provider fish")
    func looseSchool() {
        let now = Date()
        let fish = AquariumModel.reduce(sessions: [
            Self.session("codex-1", provider: "codex"),
            Self.session("codex-2", provider: "codex"),
            Self.session("claude-1", provider: "claude"),
            Self.session("w", provider: "codex", kind: "worker", parent: "ghost"),
        ], previous: [], now: now)
        let fry = fish[3]
        #expect(fry.isFry)
        // The ghost parent resolves to a same-provider fish — the one
        // that will draw largest.
        let codex = [fish[0], fish[1]]
        let biggest = codex.max { $0.bodySize < $1.bodySize }!
        #expect(fry.anchorID == biggest.id)
        #expect(fry.species == .shark)
    }

    @Test("a fry with no same-provider fish free-swims")
    func freeFry() {
        let fish = AquariumModel.reduce(sessions: [
            Self.session("a", provider: "claude"),
            Self.session("w", provider: "codex", kind: "worker", parent: "ghost"),
        ], previous: [], now: Date())
        #expect(fish[1].isFry)
        #expect(fish[1].anchorID == nil)
        // It keeps its own provider's species when it has no school.
        #expect(fish[1].species == .shark)
    }

    @Test("a school caps at eight fry; extras merge away")
    func fryCap() {
        let sessions = [Self.session("a")]
            + (0..<12).map { Self.session("w\($0)", kind: "worker", parent: "a") }
        let fish = AquariumModel.reduce(sessions: sessions, previous: [], now: Date())
        let fry = fish.filter(\.isFry)
        #expect(fry.count == AquariumModel.maxFryPerSchool)
        #expect(fry.allSatisfy { $0.anchorID == "a" })
        // The first eight workers, in list order.
        #expect(fry.map(\.id) == (0..<8).map { "w\($0)" })
    }

    @Test("a parent's completion takes its school with it")
    func schoolLeaves() {
        let t0 = Date()
        var fish = AquariumModel.reduce(sessions: [
            Self.session("a"),
            Self.session("w", kind: "worker", parent: "a"),
        ], previous: [], now: t0)
        fish = AquariumModel.reduce(sessions: [
            Self.session("a", lifecycle: "completed"),
            Self.session("w", kind: "worker", parent: "a"),
        ], previous: fish, now: t0 + 1)
        #expect(fish[0].state == .leaving)
        #expect(fish[1].state == .leaving)
        // On the same clock, so the school retires with the parent.
        #expect(fish[1].stateSince == fish[0].stateSince)
        #expect(fish[1].isRetired(at: t0 + 8) == fish[0].isRetired(at: t0 + 8))
    }

    @Test("a parent's failure sinks its school")
    func schoolSinks() {
        let t0 = Date()
        var fish = AquariumModel.reduce(sessions: [
            Self.session("a"),
            Self.session("w", kind: "worker", parent: "a"),
        ], previous: [], now: t0)
        fish = AquariumModel.reduce(sessions: [
            Self.session("a", lifecycle: "failed"),
            Self.session("w", kind: "worker", parent: "a"),
        ], previous: fish, now: t0 + 1)
        #expect(fish[0].state == .sinking)
        #expect(fish[1].state == .sinking)
        #expect(fish[1].stateSince == fish[0].stateSince)
    }

    @Test("a worker's own failure still sinks just the fry")
    func fryFailsAlone() {
        let fish = AquariumModel.reduce(sessions: [
            Self.session("a"),
            Self.session("w", lifecycle: "failed", kind: "worker", parent: "a"),
        ], previous: [], now: Date())
        #expect(fish[0].state == .swimming)
        #expect(fish[1].state == .sinking)
    }

    @Test("the decor set is seeded: same seed, same layout")
    func decor() {
        let a = AquariumModel.decorSet()
        let b = AquariumModel.decorSet()
        #expect(a == b)
        #expect(AquariumModel.decorSet(seed: "tank") == a)
        #expect(AquariumModel.decorSet(seed: "other") != a)
        // Every piece sits in the tank.
        for piece in a {
            #expect((0...1).contains(piece.x))
            #expect((0...1).contains(piece.depth))
            #expect(piece.scale > 0)
        }
        // The signature pieces are always there, first in the set so
        // a sparse density keeps them.
        let kinds = a.map(\.kind)
        #expect(kinds.first == .chest)
        #expect(kinds.contains(.starfish))
        #expect(kinds.contains(.coral))
        #expect(kinds.filter { $0 == .kelp }.count >= 3)
        #expect(kinds.filter { $0 == .rock }.count >= 2)
    }
}
