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
