import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// The triggers only an integrated JR-Bar can offer — the agents, the
/// usage headroom, SidePulse, the lid — plus the documented app
/// launch/quit and display attach/detach. Same contract as the system
/// ones: samples, a baseline first read, edges only.
@Suite("MenuBar trigger engine — native and desk triggers")
struct MenuBarNativeTriggerTests {
    private func rule(_ trigger: MenuBarTrigger, id: String = "r") -> MenuBarTriggerRule {
        MenuBarTriggerRule(id: id, enabled: true, trigger: trigger, action: .hideAll)
    }

    @Test("agent edges: working, needs-you and finished each fire once, the first sample is a baseline")
    func agentEdges() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.agentsStartedWorking, id: "w"), rule(.agentNeedsYou, id: "a"),
                     rule(.agentsFinished, id: "f")]
        // Already working at start: a baseline, nothing fires.
        #expect(engine.matchedRules(for: .agentState(.working), rules: rules).map(\.action).isEmpty)
        #expect(engine.matchedRules(for: .agentState(.working), rules: rules).map(\.action).isEmpty)
        // An ask opens.
        #expect(engine.matchedRules(for: .agentState(.needsInput), rules: rules).map(\.action) == [.hideAll])
        // Answered back into work: started-working fires, finished does not.
        #expect(engine.matchedRules(for: .agentState(.working), rules: [rules[0]]).map(\.action) == [.hideAll])
        // Done.
        #expect(engine.matchedRules(for: .agentState(.completed), rules: [rules[2]]).map(\.action) == [.hideAll])
        // Completed → idle is not another finish.
        #expect(engine.matchedRules(for: .agentState(.idle), rules: rules).map(\.action).isEmpty)
    }

    @Test("an ask answered back into work is not a finish; a failed run is")
    func finishedMeansRest() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.agentsFinished)]
        _ = engine.matchedRules(for: .agentState(.needsInput), rules: rules).map(\.action)
        #expect(engine.matchedRules(for: .agentState(.working), rules: rules).map(\.action).isEmpty)
        #expect(engine.matchedRules(for: .agentState(.failed), rules: rules).map(\.action) == [.hideAll])
    }

    @Test("usage headroom fires on the downward crossing only, like the battery")
    func quotaCrossing() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.quotaBelow(percent: 20))]
        #expect(engine.matchedRules(for: .quotaRemaining(10), rules: rules).map(\.action).isEmpty, "baseline")
        #expect(engine.matchedRules(for: .quotaRemaining(60), rules: rules).map(\.action).isEmpty)
        #expect(engine.matchedRules(for: .quotaRemaining(20), rules: rules).map(\.action) == [.hideAll])
        #expect(engine.matchedRules(for: .quotaRemaining(15), rules: rules).map(\.action).isEmpty)
    }

    @Test("SidePulse, the lid and the display count edge off their baselines")
    func deskEdges() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.sidePulseConnected, id: "on"), rule(.sidePulseDisconnected, id: "off"),
                     rule(.lidClosed, id: "shut"), rule(.lidOpened, id: "open"),
                     rule(.displayConnected, id: "d+"), rule(.displayDisconnected, id: "d-")]
        #expect(engine.matchedRules(for: .sidePulsePresent(false), rules: rules).map(\.action).isEmpty)
        #expect(engine.matchedRules(for: .sidePulsePresent(true), rules: [rules[0], rules[1]]).map(\.action) == [.hideAll])
        #expect(engine.matchedRules(for: .sidePulsePresent(true), rules: rules).map(\.action).isEmpty)
        #expect(engine.matchedRules(for: .clamshell(true), rules: rules).map(\.action).isEmpty, "baseline")
        #expect(engine.matchedRules(for: .clamshell(false), rules: [rules[2], rules[3]]).map(\.action) == [.hideAll])
        #expect(engine.matchedRules(for: .displayCount(1), rules: rules).map(\.action).isEmpty, "baseline")
        #expect(engine.matchedRules(for: .displayCount(2), rules: [rules[4], rules[5]]).map(\.action) == [.hideAll])
        #expect(engine.matchedRules(for: .displayCount(1), rules: [rules[5]]).map(\.action) == [.hideAll])
        #expect(engine.matchedRules(for: .displayCount(1), rules: rules).map(\.action).isEmpty)
    }

    @Test("app launch and quit match the bundle id case-insensitively and are events, not samples")
    func appLaunchQuit() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.appLaunched(bundleID: "us.zoom.xos"), id: "l"),
                     rule(.appQuit(bundleID: "us.zoom.xos"), id: "q")]
        #expect(engine.matchedRules(for: .appLaunched(bundleID: "US.Zoom.xos"), rules: [rules[0]]).map(\.action) == [.hideAll])
        #expect(engine.matchedRules(for: .appLaunched(bundleID: "us.zoom.xos"), rules: [rules[1]]).map(\.action).isEmpty)
        #expect(engine.matchedRules(for: .appTerminated(bundleID: "us.zoom.xos"), rules: rules).map(\.action) == [.hideAll])
        #expect(engine.matchedRules(for: .appTerminated(bundleID: "com.other"), rules: rules).map(\.action).isEmpty)
    }

    @Test("the new triggers round-trip through the settings file and read as one line")
    func codableAndSummary() throws {
        let triggers: [MenuBarTrigger] = [
            .agentsStartedWorking, .agentNeedsYou, .agentsFinished, .quotaBelow(percent: 15),
            .sidePulseConnected, .sidePulseDisconnected, .lidClosed, .lidOpened,
            .appLaunched(bundleID: "a.b"), .appQuit(bundleID: "a.b"),
            .displayConnected, .displayDisconnected,
        ]
        var settings = MenuBarSettings()
        settings.triggerRules = triggers.enumerated().map {
            MenuBarTriggerRule(id: "r\($0.offset)", trigger: $0.element, action: .showAll)
        }
        let back = try JSONDecoder().decode(MenuBarSettings.self,
                                             from: JSONEncoder().encode(settings))
        #expect(back.triggerRules == settings.triggerRules)
        #expect(MenuBarTriggerRule(trigger: .quotaBelow(percent: 15), action: .hideAll).summary
                == "when usage headroom falls to 15% → hide all items")
        #expect(MenuBarTriggerRule(trigger: .agentNeedsYou, action: .reveal(seconds: 5)).summary
                == "when an agent needs you → reveal for 5s")
    }

    // MARK: The daemon's facts

    @Test("headroom is the least any bindable, measured window has left — unmeasured is never zero")
    func tightestRemaining() {
        let usage = [
            CoreProviderUsage(id: "claude", windows: [
                CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 62, bindable: true),
                CoreUsageWindow(key: "weekly", name: "7d", usedPct: nil, bindable: true),
            ]),
            CoreProviderUsage(id: "codex", windows: [
                CoreUsageWindow(key: "catalog", name: "x", usedPct: 99, bindable: false),
                CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 81.5, bindable: true),
            ]),
        ]
        #expect(MenuBarCoreFacts.tightestRemaining(usage) == 18)
        #expect(MenuBarCoreFacts.tightestRemaining([]) == nil)
        #expect(MenuBarCoreFacts.tightestRemaining([
            CoreProviderUsage(id: "x", windows: [CoreUsageWindow(key: "k", name: "k", usedPct: nil,
                                                                 bindable: true)]),
        ]) == nil)
    }

    @Test("SidePulse is the strip or the Dot, present — the virtual Screen Bar never counts")
    func sidePulsePresence() {
        #expect(!MenuBarCoreFacts.sidePulsePresent([
            CoreDevice(id: "screen-bar", kind: "screen_bar", connected: true)]))
        #expect(!MenuBarCoreFacts.sidePulsePresent([
            CoreDevice(id: "pro", kind: "pro", connected: false)]))
        #expect(MenuBarCoreFacts.sidePulsePresent([
            CoreDevice(id: "dot", kind: "dot", connected: true)]))
    }

    @Test("only moved facts become samples; a dead feed says nothing; the first live read is a baseline")
    func factSamples() {
        let dead = MenuBarCoreFacts()
        #expect(MenuBarCoreFacts.samples(from: nil, to: dead).isEmpty)
        let live = MenuBarCoreFacts(live: true, agent: .working, askPending: false,
                                    quotaRemaining: 40, sidePulsePresent: true)
        #expect(MenuBarCoreFacts.samples(from: dead, to: live)
                == [.agentState(.working), .quotaRemaining(40), .sidePulsePresent(true)])
        #expect(MenuBarCoreFacts.samples(from: live, to: live).isEmpty)
        var asked = live
        asked.agent = .needsInput
        asked.quotaRemaining = nil
        #expect(MenuBarCoreFacts.samples(from: live, to: asked) == [.agentState(.needsInput)])
    }

    @MainActor
    @Test("the utility pushes moved facts into the trigger feed")
    func utilityPushesFacts() {
        let utility = MenuBarUtility()
        var facts = MenuBarCoreFacts(live: true, agent: .idle)
        utility.coreFacts = { facts }
        utility.coreFactsChanged()
        #expect(utility.lastCoreFacts == facts)
        facts.agent = .working
        utility.coreFactsChanged()
        #expect(utility.lastCoreFacts?.agent == .working)
        #expect(utility.actions.triggerEngine.lastAgent == .working)
    }

    @MainActor
    @Test("a stopped utility moves the baselines and acts on nothing — no rule writes, no scene")
    func stoppedUtilityActsOnNothing() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: false)
        state.triggerRules = [rule(.agentsStartedWorking)]
        state.curation.stateRules = [MenuBarStateRule(condition: .agentsWorking,
                                                      effects: [.ledScene(scene: "focus")])]
        utility.settings = { state }
        utility.onSettingsChange = { state = $0 }
        utility.hider.listingIsComplete = { true }
        utility.hider.listItems = { [] }
        utility.hider.onPlan = nil
        var scenes: [String] = []
        var quiet: [MenuBarQuietLease.Action] = []
        utility.stateRules.sceneLease.currentState = { .init(stream: "synthetic", revision: "manual-0") }
        utility.stateRules.sceneLease.send = { _, _, _, scene in
            if let scene { scenes.append(scene) }
            return .superseded
        }
        utility.stateRules.quietLease.currentRevision = { "synthetic" }
        utility.stateRules.quietLease.send = { action, _, _ in quiet.append(action); return .superseded }
        @Captured var facts = MenuBarCoreFacts(live: true, agent: .idle, askPending: true)
        utility.coreFacts = { facts }
        utility.coreFactsChanged()
        facts.agent = .working
        utility.coreFactsChanged()
        #expect(state.curation.overlay == nil, "the one-shot hide-all never fired")
        #expect(scenes.isEmpty, "the while rule's scene never took the strip")
        #expect(quiet.isEmpty)
        #expect(utility.stateRules.outcome == MenuBarStateOutcome())
        #expect(utility.stateRules.levels == MenuBarLevels(), "no level is heard while stopped")
        #expect(utility.actions.triggerEngine.lastAgent == .working, "the baseline still moved")
    }
}
