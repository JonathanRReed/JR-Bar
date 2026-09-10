import Foundation
import Testing
import JRBarLEDS
@testable import JRBarCore

@Suite("Effect model")
struct EffectModelTests {
    static func catalog() throws -> EffectCatalog {
        try JSONDecoder().decode(EffectCatalog.self, from: CoreFixtures.data("list_effects.json"))
    }

    static func assignments() throws -> EffectAssignmentDocument {
        try JSONDecoder().decode(EffectAssignmentDocument.self, from: CoreFixtures.data("list_assignments.json"))
    }

    @Test("list_effects decodes the registry, the pack and the cadences")
    func decodesCatalog() throws {
        let catalog = try Self.catalog()
        #expect(catalog.effects.count == 28)
        #expect(catalog.packs.map(\.id) == ["nightlab"])
        #expect(catalog.cadences.map(\.id) == ["calm", "deliberate", "double"])
        #expect(catalog.generation >= 1)

        let chase = try #require(catalog.effect("chase"))
        #expect(chase.label == "Chase")
        #expect(chase.meaning == "provider animation: chase")
        #expect(chase.meaningGroup == "Provider animation")
        #expect(chase.surfaces == ["screen_bar", "settings_preview"])
        #expect(chase.safety == .safe)
        #expect(chase.energy == .medium)
        #expect(chase.reduceMotionFallback == "steady")
        #expect(chase.catalog == "provider_animation")
        #expect(chase.role == "directional_flow")
        #expect(!chase.isFromPack)
        #expect(chase.parameters.map(\.name) == ["duration_seconds", "direction", "spacing", "softness"])
        #expect(chase.preview?.ledCount == 8)

        let alert = try #require(catalog.effect("alert"))
        #expect(alert.safety == .attention)
        #expect(alert.safety.warns)
        #expect(alert.meaningGroup == "Attention required")
        let cadence = try #require(alert.cadence)
        #expect(cadence.id == "deliberate")
        #expect(cadence.peakHz == 1.0)
        #expect(cadence.durationMs == 1000)
        #expect(cadence.summary == "1.0 Hz · 500 ms on / 500 ms off")

        let beacon = try #require(catalog.effect("pack:nightlab:beacon"))
        #expect(beacon.isFromPack)
        #expect(beacon.pack == "nightlab")
        #expect(beacon.safety == .critical)
        #expect(beacon.reduceMotionFallback == "pack:nightlab:coal")
        #expect(beacon.meaningGroup == "Pack · nightlab")
        #expect(beacon.parameter(named: "color")?.type == .color)
        #expect(beacon.parameter(named: "cadence")?.type == .choice)

        let pack = try #require(catalog.pack("nightlab"))
        #expect(pack.name == "Night Lab")
        #expect(pack.version == 2)
        #expect(pack.effectIDs.count == 4)
        #expect(pack.license?.spdxID == "CC0-1.0")
        #expect(pack.license?.sourceURL == "https://example.org/nightlab")
    }

    @Test("every preview parses and passes the presentation compiler")
    func previewsParse() throws {
        let catalog = try Self.catalog()
        for effect in catalog.effects {
            let preview = try #require(effect.preview, "\(effect.id) has a preview")
            #expect(preview.program.utf8.count <= LEDSLimits.maxProgramBytes, "\(effect.id) fits the 512-byte limit")
            do {
                let program = try LEDSProgram.parse(preview.program, ledCount: preview.ledCount)
                #expect(program.steps.count > 0, "\(effect.id) has steps")
            } catch {
                Issue.record("\(effect.id) failed to parse: \(error)")
            }
            let compiled = LEDSPresentationCompiler.compile(preview.program, ledCount: preview.ledCount)
            #expect(compiled.accepted, "\(effect.id) is presentation-safe: \(compiled.reasons)")
        }
    }

    @Test("parameters map to native controls and normalize into bounds")
    func parameterControls() throws {
        let catalog = try Self.catalog()
        let chase = try #require(catalog.effect("chase"))
        let duration = try #require(chase.parameter(named: "duration_seconds"))
        guard case .slider(let range, let step) = duration.control else { Issue.record("duration is a slider"); return }
        #expect(range == 0.3...10)
        #expect(step == 0.1)
        #expect(duration.unit == "seconds")
        #expect(duration.title == "Duration seconds")
        #expect(duration.normalize(.number(99)) == .number(10))
        #expect(duration.normalize(.string("x")) == .number(2.2))

        let direction = try #require(chase.parameter(named: "direction"))
        #expect(direction.control == .menu(choices: ["forward", "reverse"]))
        #expect(direction.normalize(.string("sideways")) == .string("forward"))

        let spacing = try #require(chase.parameter(named: "spacing"))
        #expect(spacing.control == .integerSlider(range: 1...6))
        #expect(spacing.normalize(.number(2.6)) == .number(3))
        #expect(spacing.normalize(.number(40)) == .number(6))

        let softness = try #require(chase.parameter(named: "softness"))
        guard case .slider(let softRange, let softStep) = softness.control else { Issue.record("softness is a slider"); return }
        #expect(softRange == 0...1)
        #expect(softStep == 0.01)

        let seed = try #require(catalog.effect("flicker")?.parameter(named: "seed"))
        #expect(seed.control == .stepper(range: 0...2_147_483_647))

        let toggle = try #require(catalog.effect("gradient")?.parameter(named: "smooth_morph"))
        #expect(toggle.control == .toggle)
        #expect(toggle.normalize(.bool(false)) == .bool(false))
        #expect(toggle.normalize(.string("yes")) == .bool(true))

        let palette = try #require(catalog.effect("aurora")?.parameter(named: "palette"))
        #expect(palette.control == .paletteEditor(minimum: 2, maximum: 4, allowEmpty: true))
        #expect(palette.normalize(.array([])) == .array([]))
        #expect(palette.normalize(.array([.string("#ff0000")])) == .array([]))
        #expect(palette.normalize(.array([.string("#ff0000"), .string("#00ff00"), .string("nope")])) == .array([.string("#FF0000"), .string("#00FF00")]))
        #expect(palette.normalize(.array((0..<6).map { _ in .string("#112233") })).arrayValue?.count == 4)

        let color = try #require(catalog.effect("pack:nightlab:ember")?.parameter(named: "color"))
        #expect(color.control == .colorWell)
        #expect(color.normalize(.string("#abcdef")) == .string("#ABCDEF"))
        #expect(color.normalize(.string("red")) == .string("#FF7A1A"))

        let cadence = try #require(catalog.effect("blink")?.parameter(named: "cadence"))
        #expect(cadence.control == .menu(choices: ["calm", "deliberate", "double"]))

        let normalized = chase.normalizedParameters(["spacing": .number(9), "unknown": .string("x")])
        #expect(normalized["spacing"] == .number(6))
        #expect(normalized["direction"] == .string("forward"))
        #expect(normalized["unknown"] == nil)
        #expect(chase.defaultParameters["softness"] == .number(1))
    }

    @Test("the library groups by meaning and filters by search")
    func grouping() throws {
        let catalog = try Self.catalog()
        let groups = catalog.groups()
        #expect(groups.first?.title == "Provider animation")
        #expect(groups.first?.effects.count == 19)
        #expect(groups.map(\.title).contains("Attention required"))
        #expect(groups.map(\.title).contains("Pack · nightlab"))
        let scan = catalog.groups(matching: "scan")
        #expect(scan.flatMap(\.effects).map(\.id) == ["scanner", "kitt"])
        let night = catalog.groups(matching: "NightLab".lowercased())
        #expect(night.count == 1 && night[0].effects.count == 4)
        #expect(catalog.groups(matching: "zzz").isEmpty)
    }

    @Test("list_assignments decodes, groups by precedence, and validates")
    func decodesAssignments() throws {
        let document = try Self.assignments()
        #expect(document.assignments.count == 5)
        #expect(document.activeScene == "calm")
        let working = try #require(document.assignment(scope: .semantic, targetID: "working"))
        #expect(working.effectID == "chase")
        #expect(working.parameters["duration_seconds"] == .number(1.6))
        #expect(working.targetLabel == "Working")
        #expect(working.id == "semantic|working")
        let global = try #require(document.assignment(scope: .global, targetID: nil))
        #expect(global.effectID == "breathe")
        #expect(global.targetLabel == "Everywhere")
        #expect(document.assignment(scope: .scene, targetID: "night")?.targetLabel == "Night")
        #expect(document.byScope.map(\.scope) == [.device, .provider, .scene, .semantic, .global])
        #expect(document.usage(of: "chase").count == 1)
        #expect(document.usage(of: "rainbow").isEmpty)

        #expect(EffectAssignment(effectID: "x", scope: .global).problem == nil)
        #expect(EffectAssignment(effectID: "x", scope: .global, targetID: "claude").problem == .globalWithTarget)
        #expect(EffectAssignment(effectID: "x", scope: .provider).problem == .missingTarget)
        #expect(EffectAssignment(effectID: "x", scope: .provider, targetID: " ").problem == .missingTarget)
        #expect(EffectAssignment(effectID: "x", scope: .semantic, targetID: "asking").problem == .urgentSemantic)
        #expect(EffectAssignment(effectID: "x", scope: .semantic, targetID: "working").problem == nil)
        #expect(EffectSemantic.assignable.count == 7)
        #expect(EffectScope.precedence.first == .device)
        #expect(EffectScene.dnd.label == "Do Not Disturb")

        // Round trip through the encoder keeps the wire names.
        let data = try JSONEncoder().encode(working)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"effect_id\":\"chase\""))
        #expect(text.contains("\"target_id\":\"working\""))
    }

    @Test("unknown safety, energy, scope and pack ids degrade instead of failing")
    func tolerant() throws {
        let json = #"{"effects":[{"id":"pack:x:y","safety":"weird","energy":"nuclear"}],"packs":[{"id":"x"}]}"#
        let catalog = try JSONDecoder().decode(EffectCatalog.self, from: Data(json.utf8))
        let effect = try #require(catalog.effects.first)
        #expect(effect.label == "pack:x:y")
        #expect(effect.safety == .safe)
        #expect(effect.energy == .low)
        #expect(effect.pack == "x")
        #expect(effect.preview == nil)
        #expect(catalog.packs[0].name == "x")
        let assignment = try JSONDecoder().decode(EffectAssignment.self, from: Data(#"{"scope":"galaxy"}"#.utf8))
        #expect(assignment.scope == .global)
        #expect(assignment.effectID == "none")
    }

    @Test("the daemon's apply_effect reply (effect/target, no parameters) decodes like the mock's rows")
    func daemonReplyShape() throws {
        // docs/CORE-PROTOCOL.md: `{effect, scope, target, assignments[{effect, scope, target}]}`.
        let json = #"{"effect":"comet","scope":"provider","target":"codex","assignments":[{"effect":"breathe","scope":"global","target":null},{"effect":"comet","scope":"provider","target":"codex"}]}"#
        let document = try JSONDecoder().decode(EffectAssignmentDocument.self, from: Data(json.utf8))
        #expect(document.assignments.count == 2)
        #expect(document.activeScene == nil)
        #expect(document.generation == 0)
        let codex = try #require(document.assignment(scope: .provider, targetID: "codex"))
        #expect(codex.effectID == "comet")
        #expect(codex.parameters.isEmpty)
        let global = try #require(document.assignment(scope: .global, targetID: nil))
        #expect(global.effectID == "breathe")
        #expect(global.problem == nil)
        // When both spellings are present the fuller one wins.
        let both = try JSONDecoder().decode(EffectAssignment.self, from: Data(#"{"effect_id":"a","effect":"b","scope":"scene","target_id":"night","target":"day"}"#.utf8))
        #expect(both.effectID == "a")
        #expect(both.targetID == "night")
    }

    @Test("the family line says what the meaning does not")
    func familyLine() throws {
        let catalog = try Self.catalog()
        // A provider animation's `meaning` is "provider animation: chase" —
        // the family and the id again. The line shows the family and the
        // role instead, and never repeats itself.
        let chase = try #require(catalog.effect("chase"))
        #expect(chase.meaning == "provider animation: chase")
        #expect(chase.familyLine == "Provider animation · directional flow")
        let auto = try #require(catalog.effect("auto"))
        #expect(auto.familyLine == "Provider animation · adaptive")
        // A general effect's meaning is the only thing that says anything,
        // and its role ("general") is not worth a word.
        let alert = try #require(catalog.effect("alert"))
        #expect(alert.familyLine == "General · attention required")
        let none = try #require(catalog.effect("none"))
        #expect(none.familyLine == "General · steady color")
        // Nothing at all still reads as a family, not an empty line.
        let bare = EffectDefinition(id: "x", label: "X", meaning: "")
        #expect(bare.familyLine == "General")
        // A meaning that only restates the family is dropped too.
        let restating = EffectDefinition(id: "x", label: "X", meaning: "Provider animation", catalog: "provider_animation")
        #expect(restating.familyLine == "Provider animation")
    }
}
