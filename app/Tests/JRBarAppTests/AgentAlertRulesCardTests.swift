import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The Agent Overview card's rules table writes through the utility's
/// settings seat, and a rule edited back to "follow" is removed.
@MainActor
@Suite struct AgentAlertRulesCardTests {
    @Test("a rule lands in the organizer settings, and editing it back to default removes it")
    func writes() {
        let utility = AgentUtility(core: CoreModel())
        var stored = AgentOrganizerSettings()
        utility.settings = { stored }
        utility.onSettingsChange = { stored = $0 }

        utility.setAlertRule(AgentAlertRule(asks: false), for: "grok")
        #expect(stored.alertRules["grok"]?.asks == false)
        #expect(utility.alertRule(for: "grok").asks == false)

        utility.bindRule("grok", \.asks).wrappedValue = true
        #expect(stored.alertRules["grok"] == nil)
        #expect(utility.alertRule(for: "grok").isDefault)
    }

    @Test("the table lists providers with rules or sessions, in the settings' order")
    func providers() {
        let utility = AgentUtility(core: CoreModel())
        var stored = AgentOrganizerSettings()
        stored.alertRules = ["kiro": AgentAlertRule(sounds: false), "claude": AgentAlertRule(failures: false)]
        utility.settings = { stored }
        #expect(utility.alertProviders == ["claude", "kiro"])
    }

    @Test("quiet while you watch writes through, and the card's one way to the sessions is the Overview")
    func quietAndOverview() {
        let utility = AgentUtility(core: CoreModel())
        var stored = AgentOrganizerSettings()
        utility.settings = { stored }
        utility.onSettingsChange = { stored = $0 }
        utility.bind(\.quietWhenPaneFrontmost).wrappedValue = false
        #expect(stored.quietWhenPaneFrontmost == false)

        var opened = 0
        utility.onOpenOverview = { opened += 1 }
        utility.openFullOverview()
        #expect(opened == 1)
    }
}
