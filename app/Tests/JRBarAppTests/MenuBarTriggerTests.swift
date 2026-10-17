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
        _ = engine.matchedRules(for: .batteryPercent(80), rules: rules).map(\.action)
        #expect(engine.matchedRules(for: .batteryPercent(21), rules: rules).map(\.action).isEmpty)
        #expect(engine.matchedRules(for: .batteryPercent(19), rules: rules).map(\.action) == [.hideAll])
    }

    @Test("the first sample is a baseline — already-low never fires")
    func belowBaseline() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.batteryBelow(percent: 20))]
        #expect(engine.matchedRules(for: .batteryPercent(10), rules: rules).map(\.action).isEmpty)
    }

    @Test("holding at the threshold doesn't refire — edges, not levels")
    func belowEdgesOnce() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.batteryBelow(percent: 20))]
        _ = engine.matchedRules(for: .batteryPercent(30), rules: rules).map(\.action)
        #expect(engine.matchedRules(for: .batteryPercent(20), rules: rules).map(\.action) == [.hideAll])
        #expect(engine.matchedRules(for: .batteryPercent(20), rules: rules).map(\.action).isEmpty)
    }

    @Test("a charge through the threshold fires batteryAbove")
    func aboveFires() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.batteryAbove(percent: 80))]
        _ = engine.matchedRules(for: .batteryPercent(50), rules: rules).map(\.action)
        #expect(engine.matchedRules(for: .batteryPercent(80), rules: rules).map(\.action) == [.hideAll])
        // And back down doesn't refire — the edge is directional.
        _ = engine.matchedRules(for: .batteryPercent(70), rules: rules).map(\.action)
        #expect(engine.matchedRules(for: .batteryPercent(85), rules: rules).map(\.action) == [.hideAll])
    }

    @Test("the wrong direction never fires")
    func directionMatters() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.batteryBelow(percent: 20))]
        _ = engine.matchedRules(for: .batteryPercent(10), rules: rules).map(\.action)
        #expect(engine.matchedRules(for: .batteryPercent(25), rules: rules).map(\.action).isEmpty)
    }

    @Test("jumping over the threshold without landing on it still fires")
    func jumpCrossing() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.batteryBelow(percent: 50))]
        _ = engine.matchedRules(for: .batteryPercent(90), rules: rules).map(\.action)
        #expect(engine.matchedRules(for: .batteryPercent(30), rules: rules).map(\.action) == [.hideAll])
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
