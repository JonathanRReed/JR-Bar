import Foundation
import Testing
@testable import JRBarCore

/// Earned marks: a fish's rarity comes from what its session actually
/// did — two hours of work for the tide stripe, six sub-agents at once
/// for the star specks — one per fish, kept for life.
@Suite("Aquarium variants")
struct AquariumVariantTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("two hours of its session's work earn the tide stripe, once")
    func tide() {
        var game = AquariumGame()
        var earned: [AquariumGameEffect] = []
        // Fed enough to grow, so growth has work to spend.
        for _ in 0..<AquariumRules.feedingsPerStage { game.apply(.pelletEaten(fishID: "s"), now: t0) }
        // Twenty-second beats for just under two hours, then one more.
        let beats = Int(AquariumVariant.tideSeconds / 20)
        for k in 0..<beats {
            let effects = game.apply(.workTick(seconds: 20, working: ["s"]),
                                     now: t0.addingTimeInterval(Double(k) * 20))
            earned += effects.filter { if case .variantEarned = $0 { true } else { false } }
        }
        #expect(earned == [.variantEarned("s", .tide)])
        #expect(game.pets["s"]?.earnedVariant == .tide)
        #expect(game.pets["s"]?.workedTotal == AquariumVariant.tideSeconds)
        #expect((game.pets["s"]?.workSeconds ?? 0) < AquariumVariant.tideSeconds,
                "growth spends workSeconds; the lifetime total keeps counting")
        let more = game.apply(.workTick(seconds: 20, working: ["s"]),
                              now: t0.addingTimeInterval(Double(beats) * 20))
        #expect(!more.contains(.variantEarned("s", .tide)))
    }

    @Test("a session leading six sub-agents earns its fish the star specks")
    func starry() {
        var game = AquariumGame()
        var facts = AquariumFleetFacts(largestSchool: 5)
        facts.schools = ["lead": 5, "other": 2]
        #expect(game.apply(.fleet(facts), now: t0).allSatisfy {
            if case .variantEarned = $0 { false } else { true }
        })
        facts.schools = ["lead": 6]
        let effects = game.apply(.fleet(facts), now: t0)
        #expect(effects.contains(.variantEarned("lead", .starry)))
        #expect(game.pets["lead"]?.earnedVariant == .starry)
        #expect(!game.apply(.fleet(facts), now: t0).contains(.variantEarned("lead", .starry)))
    }

    @Test("first earned wins: a tide-striped fish doesn't turn starry")
    func oneMark() {
        var game = AquariumGame()
        game.pets["s"] = FishCare(createdAt: 1)
        game.pets["s"]?.variant = AquariumVariant.tide.rawValue
        var facts = AquariumFleetFacts()
        facts.schools = ["s": 8]
        game.apply(.fleet(facts), now: t0)
        #expect(game.pets["s"]?.earnedVariant == .tide)
    }

    @Test("the fleet read counts each parent's live school")
    func schoolsRead() {
        let sessions = [CoreSession(id: "a", provider: "claude", mode: "tool_running")]
            + (0..<3).map { CoreSession(id: "a\($0)", provider: "claude", kind: "worker", parent: "a",
                                        mode: "tool_running") }
            + [CoreSession(id: "b1", provider: "codex", kind: "worker", parent: "b", lifecycle: "completed")]
        let facts = AquariumFleetFacts.read(CoreState(sessions: sessions), now: t0)
        #expect(facts.schools == ["a": 3])
    }

    @Test("a mark reads tolerantly: an unknown one is no mark")
    func decode() throws {
        let care = try JSONDecoder().decode(FishCare.self, from: Data(#"""
            {"stage": 2, "variant": "plaid", "workedTotal": "lots"}
            """#.utf8))
        #expect(care.variant == nil && care.workedTotal == 0 && care.stage == 2)
        var marked = FishCare()
        marked.variant = AquariumVariant.starry.rawValue
        marked.workedTotal = 99
        let back = try JSONDecoder().decode(FishCare.self, from: JSONEncoder().encode(marked))
        #expect(back.earnedVariant == .starry && back.workedTotal == 99)
    }
}
