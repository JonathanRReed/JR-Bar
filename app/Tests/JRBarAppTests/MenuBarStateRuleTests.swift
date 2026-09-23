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

    @MainActor
    private final class Recorder {
        var scene: String? = "calm"
        var before: String?
        var quiet: [Int] = []
        /// The daemon's override slot as the rule reads it, and the
        /// quiets put back ("mode:seconds").
        var current: MenuBarQuiet?
        var restored: [String] = []
        var layers = 0
        func wire(_ runner: MenuBarStateRunner, rules: [MenuBarStateRule]) {
            runner.rules = { rules }
            runner.currentScene = { [unowned self] in self.scene }
            runner.setScene = { [unowned self] in self.scene = $0 }
            runner.sceneBeforeRule = { [unowned self] in self.before }
            runner.setSceneBeforeRule = { [unowned self] in self.before = $0 }
            runner.quietAgents = { [unowned self] in self.quiet.append($0) }
            runner.currentQuiet = { [unowned self] in self.current }
            runner.restoreQuiet = { [unowned self] in self.restored.append("\($0):\($1)") }
            runner.onLayersChange = { [unowned self] in self.layers += 1 }
        }
    }

    @MainActor
    @Test("a scene held while the rule lasts puts yours back after")
    func sceneRestores() {
        let runner = MenuBarStateRunner()
        let recorder = Recorder()
        recorder.wire(runner, rules: [rule(.microphoneLive, [.ledScene(scene: "focus")])])
        runner.absorb(.micInUse(false))
        #expect(recorder.scene == "calm")
        runner.absorb(.micInUse(true))
        #expect(recorder.scene == "focus")
        #expect(recorder.before == "calm")
        runner.absorb(.micInUse(false))
        #expect(recorder.scene == "calm")
        #expect(recorder.before == nil)
        #expect(recorder.layers == 0, "a scene-only rule never re-plans the bar")
    }

    @MainActor
    @Test("a scene you changed yourself mid-rule is left alone")
    func sceneUserWins() {
        let runner = MenuBarStateRunner()
        let recorder = Recorder()
        recorder.wire(runner, rules: [rule(.microphoneLive, [.ledScene(scene: "focus")])])
        runner.absorb(.micInUse(true))
        recorder.scene = "night"
        runner.absorb(.micInUse(false))
        #expect(recorder.scene == "night")
        #expect(recorder.before == nil)
    }

    @MainActor
    @Test("a relaunch mid-rule keeps the scene remembered before it, not the rule's own")
    func sceneRelaunch() {
        let runner = MenuBarStateRunner()
        let recorder = Recorder()
        recorder.scene = "focus"
        recorder.before = "calm"
        recorder.wire(runner, rules: [rule(.microphoneLive, [.ledScene(scene: "focus")])])
        runner.absorb(.micInUse(true))
        #expect(recorder.before == "calm")
        runner.absorb(.micInUse(false))
        #expect(recorder.scene == "calm")
    }

    @MainActor
    @Test("the agents' quiet is leased on entry and ended on exit; stop lets everything go")
    func quietLease() {
        let runner = MenuBarStateRunner()
        let recorder = Recorder()
        recorder.wire(runner, rules: [rule(.agentsWorking, [.quietAgents, .quietBar])])
        runner.absorb(.agentState(.working))
        #expect(recorder.quiet == [MenuBarStateRunner.quietLeaseSeconds])
        #expect(recorder.layers == 1)
        runner.absorb(.agentState(.working))
        #expect(recorder.quiet.count == 1, "a repeat sample changes nothing")
        runner.stop()
        #expect(recorder.quiet == [MenuBarStateRunner.quietLeaseSeconds, 0])
        #expect(recorder.layers == 2)
        #expect(runner.outcome == MenuBarStateOutcome())
    }

    /// The daemon's echo of a lease taken at `at`.
    private func leaseEcho(at date: Date) -> MenuBarQuiet {
        MenuBarQuiet(mode: "pause",
                     until: date.timeIntervalSince1970 + Double(MenuBarStateRunner.quietLeaseSeconds) + 0.4)
    }

    @MainActor
    @Test("a quiet of yours that outlasts the lease runs on; a shorter one comes back after the rule")
    func quietKeepsYours() {
        let t0 = Date(timeIntervalSince1970: 10_000)
        let epoch = t0.timeIntervalSince1970
        let rules = [rule(.microphoneLive, [.quietAgents])]
        // Two hours of Dim set by hand: no lease, and nothing ended.
        let long = MenuBarStateRunner()
        let yours = Recorder()
        yours.wire(long, rules: rules)
        yours.current = MenuBarQuiet(mode: "dim", until: epoch + 7200)
        long.absorb(.micInUse(true), now: t0)
        long.holdQuiet(now: t0.addingTimeInterval(600))
        long.absorb(.micInUse(false), now: t0.addingTimeInterval(700))
        #expect(yours.quiet.isEmpty && yours.restored.isEmpty)
        // Five minutes of Mute: the lease replaces it, and it comes back
        // with the time it had left — no 0 in between.
        let short = MenuBarStateRunner()
        let mute = Recorder()
        mute.wire(short, rules: rules)
        mute.current = MenuBarQuiet(mode: "mute", until: epoch + 300)
        short.absorb(.micInUse(true), now: t0)
        #expect(mute.quiet == [MenuBarStateRunner.quietLeaseSeconds])
        mute.current = leaseEcho(at: t0)
        short.absorb(.micInUse(false), now: t0.addingTimeInterval(60))
        #expect(mute.restored == ["mute:240"])
        #expect(mute.quiet == [MenuBarStateRunner.quietLeaseSeconds])
        // Twenty minutes of Dim runs down under the rule: the renewal
        // takes the lease before it ends, and puts the rest back after.
        let fading = MenuBarStateRunner()
        let dim = Recorder()
        dim.wire(fading, rules: rules)
        dim.current = MenuBarQuiet(mode: "dim", until: epoch + 1200)
        fading.absorb(.micInUse(true), now: t0)
        #expect(dim.quiet.isEmpty)
        fading.holdQuiet(now: t0.addingTimeInterval(600))
        #expect(dim.quiet == [MenuBarStateRunner.quietLeaseSeconds])
        dim.current = leaseEcho(at: t0.addingTimeInterval(600))
        fading.absorb(.micInUse(false), now: t0.addingTimeInterval(700))
        #expect(dim.restored == ["dim:500"])
        // A rule that ends before the daemon's echo lands still puts
        // yours back.
        let quick = MenuBarStateRunner()
        let blink = Recorder()
        blink.wire(quick, rules: rules)
        blink.current = MenuBarQuiet(mode: "mute", until: epoch + 300)
        quick.absorb(.micInUse(true), now: t0)
        quick.absorb(.micInUse(false), now: t0.addingTimeInterval(0.2))
        #expect(blink.restored == ["mute:300"])
    }

    @MainActor
    @Test("a quiet changed or ended by hand mid-rule is yours: no renewal, nothing ended after")
    func quietChangedByHand() {
        let t0 = Date(timeIntervalSince1970: 10_000)
        let epoch = t0.timeIntervalSince1970
        let rules = [rule(.microphoneLive, [.quietAgents])]
        let lease = MenuBarStateRunner.quietLeaseSeconds
        // The lease renews while it is the quiet in force, and ends after.
        let steady = MenuBarStateRunner()
        let ours = Recorder()
        ours.wire(steady, rules: rules)
        steady.absorb(.micInUse(true), now: t0)
        ours.current = leaseEcho(at: t0)
        steady.holdQuiet(now: t0.addingTimeInterval(600))
        #expect(ours.quiet == [lease, lease])
        ours.current = leaseEcho(at: t0.addingTimeInterval(600))
        steady.absorb(.micInUse(false), now: t0.addingTimeInterval(700))
        #expect(ours.quiet == [lease, lease, 0])
        // An hour of Dim set mid-rule: the renewal stands down and the
        // rule's end leaves it.
        let changed = MenuBarStateRunner()
        let dim = Recorder()
        dim.wire(changed, rules: rules)
        changed.absorb(.micInUse(true), now: t0)
        dim.current = MenuBarQuiet(mode: "dim", until: epoch + 100 + 3600)
        changed.holdQuiet(now: t0.addingTimeInterval(600))
        changed.absorb(.micInUse(false), now: t0.addingTimeInterval(700))
        #expect(dim.quiet == [lease])
        #expect(dim.restored.isEmpty)
        // The quiet ended by hand mid-rule stays ended.
        let ended = MenuBarStateRunner()
        let off = Recorder()
        off.wire(ended, rules: rules)
        off.current = MenuBarQuiet(mode: "mute", until: epoch + 300)
        ended.absorb(.micInUse(true), now: t0)
        off.current = nil
        ended.holdQuiet(now: t0.addingTimeInterval(600))
        ended.absorb(.micInUse(false), now: t0.addingTimeInterval(700))
        #expect(off.quiet == [lease])
        #expect(off.restored.isEmpty, "the Mute the lease replaced is not revived")
    }

    // MARK: Through the utility

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
