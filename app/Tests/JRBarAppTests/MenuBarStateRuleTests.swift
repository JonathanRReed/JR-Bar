import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// "While" rules: levels that hold a layer, a scene or the agents' quiet
/// for exactly as long as they last, and put everything back after.
@Suite("Menu Bar — while rules")
struct MenuBarStateRuleTests {
    private func rule(_ condition: MenuBarCondition, negated: Bool = false,
                      _ effects: [MenuBarRuleEffect], id: String = UUID().uuidString) -> MenuBarStateRule {
        MenuBarStateRule(id: id, condition: condition, negated: negated, effects: effects)
    }

    // MARK: Conditions

    @Test("an unknown level never holds — negated or not")
    func unknownNeverHolds() {
        let levels = MenuBarLevels()
        #expect(MenuBarStateRuleEngine.holds(.microphoneLive, in: levels) == nil)
        #expect(!MenuBarStateRuleEngine.holds(rule(.microphoneLive, [.quietBar]), in: levels))
        #expect(!MenuBarStateRuleEngine.holds(rule(.microphoneLive, negated: true, [.quietBar]),
                                              in: levels))
    }

    @Test("the system levels read as their samples say")
    func systemLevels() {
        var levels = MenuBarLevels()
        levels.absorb(.micInUse(true))
        levels.absorb(.onACPower(false))
        levels.absorb(.batteryPercent(18))
        levels.absorb(.wifiSSID("Office"))
        levels.absorb(.appActivated(bundleID: "us.zoom.xos"))
        levels.absorb(.screenLocked)
        levels.absorb(.displayCount(2))
        levels.absorb(.clamshell(true))
        #expect(MenuBarStateRuleEngine.holds(.microphoneLive, in: levels) == true)
        #expect(MenuBarStateRuleEngine.holds(.onBattery, in: levels) == true)
        #expect(MenuBarStateRuleEngine.holds(.batteryAtOrBelow(percent: 20), in: levels) == true)
        #expect(MenuBarStateRuleEngine.holds(.batteryAtOrBelow(percent: 10), in: levels) == false)
        #expect(MenuBarStateRuleEngine.holds(.wifiIs(ssid: "office"), in: levels) == true)
        #expect(MenuBarStateRuleEngine.holds(.appFrontmost(bundleID: "US.ZOOM.XOS"), in: levels) == true)
        #expect(MenuBarStateRuleEngine.holds(.screenLocked, in: levels) == true)
        #expect(MenuBarStateRuleEngine.holds(.externalDisplay, in: levels) == true)
        #expect(MenuBarStateRuleEngine.holds(.lidClosed, in: levels) == true)
        levels.absorb(.wifiSSID(nil))
        #expect(MenuBarStateRuleEngine.holds(.wifiIs(ssid: "Office"), in: levels) == false,
                "a known no-network is a real false")
        levels.absorb(.screenUnlocked)
        #expect(MenuBarStateRuleEngine.holds(.screenLocked, in: levels) == false)
    }

    @Test("running apps follow launch and quit from the seeded set")
    func runningApps() {
        var levels = MenuBarLevels()
        #expect(MenuBarStateRuleEngine.holds(.appRunning(bundleID: "a"), in: levels) == nil)
        levels.running = ["a"]
        levels.absorb(.appLaunched(bundleID: "b"))
        #expect(MenuBarStateRuleEngine.holds(.appRunning(bundleID: "b"), in: levels) == true)
        levels.absorb(.appTerminated(bundleID: "a"))
        #expect(MenuBarStateRuleEngine.holds(.appRunning(bundleID: "a"), in: levels) == false)
    }

    @Test("the agents' levels: busy covers an ask mid-work, idle needs no ask open")
    func agentLevels() {
        var levels = MenuBarLevels()
        levels.absorb(.agentState(.needsInput))
        #expect(MenuBarStateRuleEngine.holds(.agentsWorking, in: levels) == true)
        #expect(MenuBarStateRuleEngine.holds(.agentNeedsYou, in: levels) == true)
        #expect(MenuBarStateRuleEngine.holds(.agentsIdle, in: levels) == false)
        levels.absorb(.agentState(.completed))
        levels.askPending = true
        #expect(MenuBarStateRuleEngine.holds(.agentNeedsYou, in: levels) == true)
        #expect(MenuBarStateRuleEngine.holds(.agentsIdle, in: levels) == false)
        levels.askPending = false
        #expect(MenuBarStateRuleEngine.holds(.agentsIdle, in: levels) == true)
        levels.absorb(.quotaRemaining(12))
        #expect(MenuBarStateRuleEngine.holds(.quotaAtOrBelow(percent: 15), in: levels) == true)
        levels.absorb(.sidePulsePresent(true))
        #expect(MenuBarStateRuleEngine.holds(.sidePulseConnected, in: levels) == true)
    }

    @Test("a time window can span midnight")
    func timeWindow() {
        var levels = MenuBarLevels()
        let night = MenuBarCondition.timeBetween(startMinute: 22 * 60, endMinute: 7 * 60)
        let day = MenuBarCondition.timeBetween(startMinute: 9 * 60, endMinute: 17 * 60)
        levels.absorb(.minute(hour: 23, minute: 30))
        #expect(MenuBarStateRuleEngine.holds(night, in: levels) == true)
        #expect(MenuBarStateRuleEngine.holds(day, in: levels) == false)
        levels.absorb(.minute(hour: 6, minute: 59))
        #expect(MenuBarStateRuleEngine.holds(night, in: levels) == true)
        levels.absorb(.minute(hour: 17, minute: 0))
        #expect(MenuBarStateRuleEngine.holds(day, in: levels) == false, "the end is exclusive")
    }

    // MARK: Resolution

    @Test("the first holding rule wins each slot; any rule can quiet the agents")
    func resolveOrder() {
        var levels = MenuBarLevels()
        levels.micLive = true
        levels.focusOn = true
        let rules = [
            rule(.microphoneLive, [.quietBar, .useProfile(name: "Meeting"), .ledScene(scene: "focus")],
                 id: "mic"),
            rule(.focusOn, [.showEverything, .useProfile(name: "Deep"), .quietAgents], id: "focus"),
            rule(.screenLocked, [.quietBar], id: "lock"),
        ]
        let outcome = MenuBarStateRuleEngine.resolve(rules, levels: levels)
        #expect(outcome.holding == ["mic", "focus"])
        #expect(outcome.overlay == .hideEverything)
        #expect(outcome.profileName == "Meeting")
        #expect(outcome.ledScene == "focus")
        #expect(outcome.quietAgents)
        var off = rules
        off[0].enabled = false
        let second = MenuBarStateRuleEngine.resolve(off, levels: levels)
        #expect(second.overlay == .showEverything)
        #expect(second.profileName == "Deep")
    }

    @Test("the later of a manual layer and a rule's wins")
    func latestWins() {
        let t0 = Date(timeIntervalSince1970: 100)
        let t1 = Date(timeIntervalSince1970: 200)
        #expect(!MenuBarStateRuleEngine.ruleWins(ruleSince: nil, manualSince: t0))
        #expect(MenuBarStateRuleEngine.ruleWins(ruleSince: t0, manualSince: nil))
        #expect(MenuBarStateRuleEngine.ruleWins(ruleSince: t1, manualSince: t0))
        #expect(!MenuBarStateRuleEngine.ruleWins(ruleSince: t0, manualSince: t1))
    }

    // MARK: The runner's effects

    // MARK: Through the utility

    @MainActor
    @Test("renaming an active holding profile preserves its layer and acquisition time")
    func renameHoldingProfile() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: false)
        state.concealedApps = ["base-app": .shown]
        state.profiles = [MenuBarSettings.Profile(id: "work", name: "Work",
                                                  concealedApps: ["base-app": .alwaysHidden]),
                          MenuBarSettings.Profile(id: "other", name: "Travel")]
        state.curation.stateRules = [rule(.microphoneLive, [.useProfile(name: "work")], id: "hold")]
        utility.settings = { state }
        utility.stateRules.rules = { state.curation.stateRules }
        let acquired = Date(timeIntervalSince1970: 100)
        var reconcileTime = acquired.addingTimeInterval(1)
        var writes = 0
        utility.onSettingsChange = { [weak utility] in
            state = $0
            writes += 1
            #expect(utility != nil)
            utility?.stateRules.evaluate(now: reconcileTime)
            #expect(utility?.stateRules.profileSince == acquired)
        }
        utility.stateRules.absorb(.micInUse(true), now: acquired)
        #expect(utility.liveSettings().concealedApps == ["base-app": .alwaysHidden])

        let before = state
        for name in ["Travel", "None", ""] {
            utility.renameProfile(id: "work", to: name)
            #expect(state == before)
            #expect(utility.stateRules.outcome.profileName == "work")
            #expect(utility.stateRules.profileSince == acquired)
        }
        #expect(writes == 0)
        utility.renameProfile(id: "work", to: "Office")
        #expect(writes == 1)
        utility.stateRules.evaluate(now: acquired.addingTimeInterval(1))
        #expect(utility.stateRules.outcome.profileName == "Office")
        #expect(utility.stateRules.profileSince == acquired)
        #expect(utility.liveSettings().concealedApps == ["base-app": .alwaysHidden])

        utility.applyProfile(id: MenuBarProfiles.noneID)
        #expect(writes == 2)
        #expect(utility.liveSettings().concealedApps == ["base-app": .shown])
        reconcileTime = Date.distantFuture
        utility.renameProfile(id: "work", to: "Studio")
        #expect(writes == 3)
        utility.stateRules.evaluate(now: Date.distantFuture)
        #expect(utility.stateRules.outcome.profileName == "Studio")
        #expect(utility.stateRules.profileSince == acquired)
        #expect(utility.liveSettings().concealedApps == ["base-app": .shown],
                "renaming a held profile must not override a later manual choice")
        utility.stateRules.absorb(.micInUse(false), now: Date.distantFuture)
        #expect(utility.stateRules.profileSince == nil)
    }

    @MainActor
    @Test("a duplicate profile rename keeps the held layer with its original owner")
    func duplicateRenameHeldOwner() {
        for renamedID in ["first", "second"] {
            let utility = MenuBarUtility()
            var state = MenuBarSettings(enabled: false)
            state.profiles = [
                MenuBarSettings.Profile(id: "first", name: "Work", concealedApps: ["app": .hidden]),
                MenuBarSettings.Profile(id: "second", name: "work", concealedApps: ["app": .alwaysHidden]),
            ]
            state.curation.stateRules = [rule(.microphoneLive, [.useProfile(name: "WORK")], id: "hold")]
            state.triggerRules = [MenuBarTriggerRule(trigger: .focusEnabled,
                                                    action: .applyProfile(name: "work"))]
            utility.settings = { state }
            utility.stateRules.rules = { state.curation.stateRules }
            let acquired = Date(timeIntervalSince1970: 100)
            utility.stateRules.absorb(.micInUse(true), now: acquired)
            #expect(utility.liveSettings().concealedApps == ["app": .hidden])
            var writes = 0
            utility.onSettingsChange = { [weak utility] in
                state = $0
                writes += 1
                #expect(utility != nil)
                guard let utility else { return }
                utility.stateRules.evaluate(now: acquired.addingTimeInterval(1))
                #expect(utility.stateRules.profileSince == acquired)
                #expect(utility.liveSettings().concealedApps == ["app": .hidden])
            }
            utility.renameProfile(id: renamedID, to: "Office")
            #expect(writes == 1)
            let expectedName = renamedID == "first" ? "Office" : "WORK"
            #expect(utility.stateRules.outcome.profileName == expectedName)
            #expect(utility.stateRules.profileSince == acquired)
            #expect(utility.liveSettings().concealedApps == ["app": .hidden])
            let owner = state.profiles.first {
                $0.name.caseInsensitiveCompare(expectedName) == .orderedSame
            }
            #expect(owner?.id == "first")
            if case .applyProfile(let name) = state.triggerRules[0].action {
                utility.menuBarActions(utility.actions, applyProfile: name)
            }
            #expect(state.curation.activeProfileID == "first")
        }
    }

    @MainActor
    @Test("changing a rule's profile effect takes a new acquisition time")
    func editedProfileEffectReacquires() {
        let runner = MenuBarStateRunner()
        var rules = [rule(.microphoneLive, [.useProfile(name: "Work")], id: "hold")]
        runner.rules = { rules }
        let acquired = Date(timeIntervalSince1970: 100)
        let edited = acquired.addingTimeInterval(1)
        runner.absorb(.micInUse(true), now: acquired)
        rules[0].effects = [.useProfile(name: "Office")]
        runner.evaluate(now: edited)
        #expect(runner.outcome.profileName == "Office")
        #expect(runner.profileSince == edited)
    }

    @MainActor
    @Test("a profile rename without a settings writer leaves the held profile alone")
    func renameWithoutWriter() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: false)
        state.profiles = [MenuBarSettings.Profile(id: "work", name: "Work")]
        state.curation.stateRules = [rule(.microphoneLive, [.useProfile(name: "Work")])]
        utility.settings = { state }
        utility.stateRules.rules = { state.curation.stateRules }
        let acquired = Date(timeIntervalSince1970: 100)
        utility.stateRules.absorb(.micInUse(true), now: acquired)
        utility.renameProfile(id: "work", to: "Office")
        #expect(state.profiles[0].name == "Work")
        #expect(utility.stateRules.outcome.profileName == "Work")
        #expect(utility.stateRules.profileSince == acquired)
    }

    @MainActor
    @Test("a while rule's quiet bar and profile are layers — the map is never written")
    func utilityLayers() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: false)
        state.concealedApps = ["slack": .hidden, "zoom": .shown]
        state.profiles = [MenuBarSettings.Profile(id: "m", name: "Meeting",
                                                  concealedApps: ["zoom": .alwaysHidden],
                                                  coverMaterial: .hud)]
        state.curation.stateRules = [rule(.microphoneLive, [.useProfile(name: "meeting")])]
        utility.settings = { state }
        utility.onSettingsChange = { state = $0 }
        utility.hider.listingIsComplete = { true }
        utility.hider.listItems = { [] }
        utility.hider.onPlan = nil
        utility.stateRules.rules = { state.curation.stateRules }
        utility.stateRules.absorb(.micInUse(true))
        #expect(utility.liveSettings().concealedApps == ["slack": .hidden, "zoom": .alwaysHidden])
        #expect(utility.liveSettings().coverMaterial == .hud)
        #expect(state.concealedApps == ["slack": .hidden, "zoom": .shown])
        #expect(state.curation.activeProfileID == nil)
        #expect(utility.holdingStateRules.count == 1)
        // A manual switch made after the rule took hold wins.
        utility.applyProfile(id: MenuBarProfiles.noneID)
        #expect(utility.liveSettings().concealedApps == ["slack": .hidden, "zoom": .shown])
        utility.stateRules.absorb(.micInUse(false))
        #expect(utility.holdingStateRules.isEmpty)
        #expect(utility.liveSettings().concealedApps == ["slack": .hidden, "zoom": .shown])
    }

    @MainActor
    @Test("a manual show-all set after the rule's quiet bar beats it; the rule ending leaves it")
    func utilityOverlayRace() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: false)
        state.concealedApps = ["slack": .hidden]
        state.curation.stateRules = [rule(.microphoneLive, [.quietBar])]
        utility.settings = { state }
        utility.onSettingsChange = { state = $0 }
        utility.hider.listingIsComplete = { true }
        utility.hider.listItems = { [] }
        utility.hider.onPlan = nil
        utility.stateRules.rules = { state.curation.stateRules }
        utility.stateRules.absorb(.micInUse(true))
        #expect(utility.activeOverlay == .hideEverything)
        #expect(utility.liveSettings().concealedApps == ["slack": .hidden])
        utility.showAllListed()
        #expect(utility.activeOverlay == .showEverything)
        utility.stateRules.absorb(.micInUse(false))
        #expect(utility.activeOverlay == .showEverything)
        utility.restoreCuratedBar()
        #expect(utility.activeOverlay == nil)
    }

    @MainActor
    @Test("restore stands a rule's quiet bar down until the rule next takes hold; the file is untouched")
    func utilityRestoreBeatsRule() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: false)
        state.concealedApps = ["slack": .hidden]
        state.curation.stateRules = [rule(.microphoneLive, [.quietBar])]
        utility.settings = { state }
        utility.onSettingsChange = { state = $0 }
        utility.hider.listingIsComplete = { true }
        utility.hider.listItems = { [] }
        utility.hider.onPlan = nil
        utility.stateRules.rules = { state.curation.stateRules }
        utility.stateRules.absorb(.micInUse(true), now: Date().addingTimeInterval(-10))
        #expect(utility.activeOverlay == .hideEverything)
        #expect(utility.overlayNote == MenuBarLayers.ruleOverlayNote(.hideEverything))
        utility.restoreCuratedBar()
        #expect(utility.activeOverlay == nil)
        #expect(utility.overlayNote == nil)
        #expect(utility.liveSettings().concealedApps == ["slack": .hidden])
        #expect(state.curation.overlay == nil)
        utility.stateRules.absorb(.micInUse(false))
        utility.stateRules.absorb(.micInUse(true), now: Date().addingTimeInterval(1))
        #expect(utility.activeOverlay == .hideEverything, "the rule taking hold again wins")
    }

    /// The daemon's feed as a test steers it.
    @MainActor
    private final class Feed {
        var facts = MenuBarCoreFacts()
    }

    @MainActor
    @Test("legacy saved scene names are discarded without changing the daemon")
    func utilityDiscardsLegacyScene() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: false)
        state.curation.sceneBeforeRule = "calm"
        utility.settings = { state }
        utility.onSettingsChange = { state = $0 }
        var writes = 0
        utility.stateRules.sceneLease.send = { _, _, _, _ in writes += 1; return .superseded }
        let feed = Feed()
        utility.coreFacts = { [unowned feed] in feed.facts }
        utility.coreFactsChanged()
        #expect(state.curation.sceneBeforeRule == "calm")
        feed.facts.live = true
        utility.coreFactsChanged()
        #expect(state.curation.sceneBeforeRule == nil)
        #expect(writes == 0)
    }

    // MARK: The file

    @Test("rules round-trip; an unknown effect drops alone, an unknown condition drops the rule")
    func codable() throws {
        var settings = MenuBarSettings()
        settings.curation.stateRules = [
            rule(.wifiIs(ssid: "Home"), negated: true,
                 [.quietBar, .useProfile(name: "Out"), .ledScene(scene: "travel"), .quietAgents],
                 id: "a"),
            rule(.timeBetween(startMinute: 1320, endMinute: 420), [.showEverything], id: "b"),
        ]
        settings.curation.sceneBeforeRule = "calm"
        let back = try JSONDecoder().decode(MenuBarSettings.self,
                                            from: JSONEncoder().encode(settings))
        #expect(back.curation.stateRules == settings.curation.stateRules)
        #expect(back.curation.sceneBeforeRule == "calm")
        let json = #"{"stateRules":[{"id":"x","condition":{"microphoneLive":{}},"effects":[{"quietBar":{}},{"teleport":{}}]},{"id":"y","condition":{"moonPhase":{}},"effects":[]}]}"#
        let curation = try JSONDecoder().decode(MenuBarCuration.self, from: Data(json.utf8))
        #expect(curation.stateRules.map(\.id) == ["x"])
        #expect(curation.stateRules.first?.effects == [.quietBar])
    }

    @Test("a rule reads as one line")
    func summary() {
        #expect(rule(.microphoneLive, [.useProfile(name: "Meeting"), .ledScene(scene: "focus"),
                                       .quietAgents]).summary
                == "while the microphone is live → use “Meeting” + the focus scene + quiet the agents")
        #expect(rule(.wifiIs(ssid: "Office"), negated: true, [.quietBar]).summary
                == "while not: on Wi-Fi “Office” → tuck everything away")
        #expect(MenuBarCondition.timeBetween(startMinute: 540, endMinute: 1020).label
                == "between 09:00 and 17:00")
    }
}
