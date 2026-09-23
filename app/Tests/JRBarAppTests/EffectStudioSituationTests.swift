import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// "Try a situation" answers the way the daemon's
/// `resolve_effect_assignment` does. The table is the one
/// `tests/test_effect_situation_parity.py` checks the daemon against.
@Suite("Effect Studio · situations")
@MainActor
struct EffectStudioSituationTests {
    private static let document = EffectAssignmentDocument(assignments: [
        EffectAssignment(effectID: "pulse", scope: .global),
        EffectAssignment(effectID: "comet", scope: .semantic, targetID: "completion"),
        EffectAssignment(effectID: "ember", scope: .scene, targetID: "night"),
        EffectAssignment(effectID: "aurora", scope: .provider, targetID: "codex"),
        EffectAssignment(effectID: "tide", scope: .providerInstance, targetID: "codex:work"),
        EffectAssignment(effectID: "bloom", scope: .project, targetID: "Claude in VS Code"),
        EffectAssignment(effectID: "glint", scope: .device, targetID: "pro-1"),
        EffectAssignment(effectID: "alert", scope: .semantic, targetID: "asking"),
    ])

    private static func situation(_ semantic: EffectSemantic, _ scene: String, _ provider: String?,
                                  instance: String? = nil, project: String? = nil, device: String? = nil) -> EffectSituation {
        EffectSituation(semantic: semantic, scene: scene, provider: provider, instance: instance, project: project, device: device)
    }

    /// Same rows, same order, as the Python table.
    private static let cases: [(EffectSituation, String)] = [
        (situation(.completion, "calm", "claude"), "comet"),
        (situation(.completion, "night", "claude"), "ember"),
        (situation(.completion, "night", "codex"), "aurora"),
        (situation(.completion, "calm", "codex", instance: "codex:work"), "tide"),
        (situation(.completion, "calm", "codex", project: "Claude in VS Code"), "bloom"),
        (situation(.completion, "night", "codex", device: "pro-1"), "glint"),
        (situation(.notification, "calm", "claude"), "pulse"),
        (situation(.asking, "night", "codex", device: "pro-1"), "reserved"),
        (situation(.failure, "calm", "codex"), "reserved"),
    ]

    @Test func theTableMatchesTheDaemon() {
        for (situation, expected) in Self.cases {
            let outcome = EffectSituationResolver.resolve(situation, in: Self.document)
            if expected == "reserved" {
                #expect(outcome.reserved, "\(situation)")
                #expect(outcome.winner == nil)
            } else {
                #expect(!outcome.reserved)
                #expect(outcome.winner?.effectID == expected, "\(situation)")
            }
        }
    }

    @Test func theWinnerShadowsEveryLooserMatch() {
        let outcome = EffectSituationResolver.resolve(Self.situation(.completion, "night", "codex", device: "pro-1"), in: Self.document)
        #expect(outcome.winner?.scope == .device)
        #expect(outcome.shadowed.map(\.effectID) == ["aurora", "ember", "comet", "pulse"], "most specific first, like the walk")
    }

    @Test func nothingNamedIsTheDefault() {
        let empty = EffectAssignmentDocument()
        let outcome = EffectSituationResolver.resolve(Self.situation(.completion, "calm", "claude"), in: empty)
        #expect(outcome.winner == nil && !outcome.reserved && outcome.shadowed.isEmpty)
        #expect(EffectSituationResolver.resolve(Self.situation(.completion, "calm", nil), in: nil).winner == nil)
    }

    @Test func theScreenBarResolvesNoDeviceRows() {
        // The Screen Bar is not a device target: with no device the walk
        // skips the scope and the provider decides.
        let outcome = EffectSituationResolver.resolve(Self.situation(.completion, "night", "codex", device: nil), in: Self.document)
        #expect(outcome.winner?.effectID == "aurora")
    }

    @Test func theMonitorsAnswerIsPreferredAndReadsTheSame() throws {
        // `resolve_effect` for (completion, night, codex, pro-1) against
        // the same table, as core_lights.resolve_effect writes it.
        let reply = Data("""
        {"semantic": "completion", "scene": "night", "urgent": false,
         "winner": {"scope": "device", "target_id": "pro-1", "effect_id": "glint"},
         "ladder": [
          {"scope": "device", "target_id": "pro-1", "applicable": true, "effect_id": "glint", "wins": true},
          {"scope": "project", "target_id": null, "applicable": false, "effect_id": null, "wins": false},
          {"scope": "provider_instance", "target_id": null, "applicable": false, "effect_id": null, "wins": false},
          {"scope": "provider", "target_id": "codex", "applicable": true, "effect_id": "aurora", "wins": false},
          {"scope": "scene", "target_id": "night", "applicable": true, "effect_id": "ember", "wins": false},
          {"scope": "semantic", "target_id": "completion", "applicable": true, "effect_id": "comet", "wins": false},
          {"scope": "global", "target_id": null, "applicable": true, "effect_id": "pulse", "wins": false}
         ]}
        """.utf8)
        let daemon = try JSONDecoder().decode(ResolvedEffectReply.self, from: reply).outcome
        let mirror = EffectSituationResolver.resolve(Self.situation(.completion, "night", "codex", device: "pro-1"), in: Self.document)
        #expect(daemon == mirror, "the monitor and the mirror tell the same story")

        let urgent = Data(#"{"semantic": "ask", "scene": "calm", "urgent": true, "winner": null, "ladder": []}"#.utf8)
        #expect(try JSONDecoder().decode(ResolvedEffectReply.self, from: urgent).outcome.reserved)
    }

    @Test func theRequestSpeaksTheDaemonsWords() {
        let args = EffectSituationResolver.request(for: Self.situation(.asking, "night", "codex", device: "pro-1"))
        #expect(args == ["semantic": "ask", "scene": "night", "provider": "codex", "device": "pro-1"])
        #expect(EffectSituationResolver.request(for: Self.situation(.completion, "calm", nil))
                == ["semantic": "completion", "scene": "calm"], "absent ids are left out, never sent empty")
        #expect(EffectSituationResolver.request(for: Self.situation(.quota, "calm", nil)) == nil)
    }

    @Test func theSentenceNamesTheDecidingScope() {
        let aurora = EffectDefinition(id: "aurora", label: "Aurora", meaning: "provider animation: aurora")
        let row = EffectAssignment(effectID: "aurora", scope: .provider, targetID: "codex")
        #expect(EffectSituationPanel.sentence(winner: row, effect: aurora, where: "Codex") == "Plays Aurora — Provider · Codex decides.")
        let hide = EffectAssignment(effectID: "none", scope: .scene, targetID: "night")
        #expect(EffectSituationPanel.sentence(winner: hide, effect: nil, where: "Night") == "Nothing plays — Scene · Night decides.")
        let gone = EffectAssignment(effectID: "pack:old:glow", scope: .global)
        #expect(EffectSituationPanel.sentence(winner: gone, effect: nil, where: "Everywhere")
                == "The Everywhere row decides, but its effect is not installed, so the monitor's default plays.")
    }
}
