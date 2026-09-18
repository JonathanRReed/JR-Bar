import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// The battery-level half of the trigger engine — Bartender's "battery
/// below X%" rule. The engine's contract: samples, not events, and the
/// first sample is a baseline that never fires.
@Suite("MenuBar trigger engine — battery levels")
struct MenuBarTriggerTests {
    private func rule(_ trigger: MenuBarTrigger) -> MenuBarTriggerRule {
        MenuBarTriggerRule(id: "r1", enabled: true, trigger: trigger,
                           action: .hideAll)
    }

    @Test("a drop through the threshold fires batteryBelow")
    func belowFires() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.batteryBelow(percent: 20))]
        _ = engine.actions(for: .batteryPercent(80), rules: rules)
        #expect(engine.actions(for: .batteryPercent(21), rules: rules).isEmpty)
        #expect(engine.actions(for: .batteryPercent(19), rules: rules) == [.hideAll])
    }

    @Test("the first sample is a baseline — already-low never fires")
    func belowBaseline() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.batteryBelow(percent: 20))]
        #expect(engine.actions(for: .batteryPercent(10), rules: rules).isEmpty)
    }

    @Test("holding at the threshold doesn't refire — edges, not levels")
    func belowEdgesOnce() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.batteryBelow(percent: 20))]
        _ = engine.actions(for: .batteryPercent(30), rules: rules)
        #expect(engine.actions(for: .batteryPercent(20), rules: rules) == [.hideAll])
        #expect(engine.actions(for: .batteryPercent(20), rules: rules).isEmpty)
    }

    @Test("a charge through the threshold fires batteryAbove")
    func aboveFires() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.batteryAbove(percent: 80))]
        _ = engine.actions(for: .batteryPercent(50), rules: rules)
        #expect(engine.actions(for: .batteryPercent(80), rules: rules) == [.hideAll])
        // And back down doesn't refire — the edge is directional.
        _ = engine.actions(for: .batteryPercent(70), rules: rules)
        #expect(engine.actions(for: .batteryPercent(85), rules: rules) == [.hideAll])
    }

    @Test("the wrong direction never fires")
    func directionMatters() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.batteryBelow(percent: 20))]
        _ = engine.actions(for: .batteryPercent(10), rules: rules)
        #expect(engine.actions(for: .batteryPercent(25), rules: rules).isEmpty)
    }

    @Test("jumping over the threshold without landing on it still fires")
    func jumpCrossing() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.batteryBelow(percent: 50))]
        _ = engine.actions(for: .batteryPercent(90), rules: rules)
        #expect(engine.actions(for: .batteryPercent(30), rules: rules) == [.hideAll])
    }

    @Test("battery rules decode from persisted state")
    func batteryRuleCodable() throws {
        let rule = MenuBarTriggerRule(trigger: .batteryBelow(percent: 15),
                                      action: .reveal(seconds: 3))
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(MenuBarTriggerRule.self, from: data)
        #expect(decoded.trigger == .batteryBelow(percent: 15))
        #expect(decoded.action == .reveal(seconds: 3))
        #expect(decoded.summary == "when the battery falls to 15% → reveal for 3s")
    }
}
