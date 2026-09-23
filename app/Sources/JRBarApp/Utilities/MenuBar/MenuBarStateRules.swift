import AppKit
import CoreGraphics
import JRBarCore

/// The levels the "while" rules read: the latest sample of each thing
/// the trigger feed and the daemon's feed report. nil is "not known
/// yet", and an unknown level never holds — a rule never fires on a
/// guess.
struct MenuBarLevels: Equatable, Sendable {
    var micLive: Bool?
    var focusOn: Bool?
    var screenLocked: Bool?
    var onAC: Bool?
    var batteryPercent: Int?
    /// nil until a read lands; `.some(nil)` is "no readable network".
    var ssid: String??
    var frontmost: String?
    var running: Set<String>?
    var agent: AgentAggregateState?
    var askPending: Bool?
    var quotaRemaining: Int?
    var sidePulse: Bool?
    var lidClosed: Bool?
    var displayCount: Int?
    var minuteOfDay: Int?

    /// Fold one sample in. Events that only mean "something moved" (a
    /// Wi-Fi change without a name) leave the levels alone.
    mutating func absorb(_ event: MenuBarTriggerEvent) {
        switch event {
        case .screenLocked: screenLocked = true
        case .screenUnlocked: screenLocked = false
        case .appActivated(let id): frontmost = id
        case .minute(let hour, let minute): minuteOfDay = hour * 60 + minute
        case .onACPower(let on): onAC = on
        case .batteryPercent(let percent): batteryPercent = percent
        case .wifiChanged: break
        case .wifiSSID(let ssid): self.ssid = .some(ssid)
        case .micInUse(let live): micLive = live
        case .focusOn(let on): focusOn = on
        case .agentState(let state): agent = state
        case .quotaRemaining(let percent): quotaRemaining = percent
        case .sidePulsePresent(let present): sidePulse = present
        case .clamshell(let shut): lidClosed = shut
        case .appLaunched(let id): running = (running ?? []).union([id])
        case .appTerminated(let id): running?.remove(id)
        case .displayCount(let count): displayCount = count
        }
    }
}

/// What the holding rules add up to right now — the first holding rule
/// (in list order) wins each slot, so the list is also the priority.
struct MenuBarStateOutcome: Equatable, Sendable {
    /// The rules whose condition holds, in list order.
    var holding: [String] = []
    var overlay: MenuBarOverlay.Kind?
    var profileName: String?
    var ledScene: String?
    var quietAgents = false
}

/// The pure half: conditions against levels, rules against conditions.
enum MenuBarStateRuleEngine {
    /// Whether an agent session is live — working, or asking mid-work.
    nonisolated static func agentsBusy(_ levels: MenuBarLevels) -> Bool? {
        levels.agent.map { $0 == .working || $0 == .needsInput }
    }

    /// Whether `condition` holds; nil while its level is unknown.
    nonisolated static func holds(_ condition: MenuBarCondition, in levels: MenuBarLevels) -> Bool? {
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        switch condition {
        case .microphoneLive: return levels.micLive
        case .focusOn: return levels.focusOn
        case .screenLocked: return levels.screenLocked
        case .onBattery: return levels.onAC.map { !$0 }
        case .batteryAtOrBelow(let percent): return levels.batteryPercent.map { $0 <= percent }
        case .wifiIs(let wanted):
            guard let known = levels.ssid else { return nil }
            return known.map { same($0, wanted) } ?? false
        case .appFrontmost(let id): return levels.frontmost.map { same($0, id) }
        case .appRunning(let id): return levels.running.map { $0.contains { same($0, id) } }
        case .agentsWorking: return agentsBusy(levels)
        case .agentNeedsYou:
            guard levels.agent != nil || levels.askPending != nil else { return nil }
            return levels.agent == .needsInput || levels.askPending == true
        case .agentsIdle:
            guard let busy = agentsBusy(levels) else { return nil }
            return !busy && levels.askPending != true
        case .quotaAtOrBelow(let percent): return levels.quotaRemaining.map { $0 <= percent }
        case .sidePulseConnected: return levels.sidePulse
        case .lidClosed: return levels.lidClosed
        case .externalDisplay: return levels.displayCount.map { $0 > 1 }
        case .timeBetween(let start, let end):
            return levels.minuteOfDay.map { minute in
                start <= end ? (minute >= start && minute < end) : (minute >= start || minute < end)
            }
        }
    }

    /// Whether a rule holds: enabled, its level known, and the level
    /// (or its negation) true.
    nonisolated static func holds(_ rule: MenuBarStateRule, in levels: MenuBarLevels) -> Bool {
        guard rule.enabled, let holds = holds(rule.condition, in: levels) else { return false }
        return rule.negated ? !holds : holds
    }

    /// The outcome of every holding rule.
    nonisolated static func resolve(_ rules: [MenuBarStateRule],
                                    levels: MenuBarLevels) -> MenuBarStateOutcome {
        var outcome = MenuBarStateOutcome()
        for rule in rules where holds(rule, in: levels) {
            outcome.holding.append(rule.id)
            for effect in rule.effects {
                switch effect {
                case .quietBar where outcome.overlay == nil: outcome.overlay = .hideEverything
                case .showEverything where outcome.overlay == nil: outcome.overlay = .showEverything
                case .useProfile(let name) where outcome.profileName == nil: outcome.profileName = name
                case .ledScene(let scene) where outcome.ledScene == nil: outcome.ledScene = scene
                case .quietAgents: outcome.quietAgents = true
                default: break
                }
            }
        }
        return outcome
    }

    /// Of a manual layer and a rule's, the one that came last wins:
    /// setting Show all mid-call beats the call's quiet bar, and a call
    /// that starts after yesterday's Show all beats it back.
    nonisolated static func ruleWins(ruleSince: Date?, manualSince: Date?) -> Bool {
        guard let ruleSince else { return false }
        guard let manualSince else { return true }
        return ruleSince >= manualSince
    }
}

/// The runtime half: folds samples into the levels, resolves on every
/// change, and turns an outcome that moved into its effects — the bar's
/// layers (the utility re-plans), the LED scene (restored after), and
/// the agents' quiet (leased, renewed, ended). Only transitions act:
/// a sample that changes nothing costs a resolve and a compare.
@MainActor
final class MenuBarStateRunner {
    /// The rules — the utility reads them from settings.
    var rules: @MainActor () -> [MenuBarStateRule] = { [] }
    /// The bar's layers moved — the utility re-plans.
    var onLayersChange: @MainActor () -> Void = {}
    /// Anything in the outcome moved — the card's "holding now" line.
    var onOutcomeChange: @MainActor () -> Void = {}
    /// The LED scene now, and the write that sets it.
    var currentScene: @MainActor () -> String? = { nil }
    var setScene: @MainActor (String) -> Void = { _ in }
    /// The persisted "scene before the rule" — read and written through
    /// the utility's settings so a relaunch mid-rule still restores.
    var sceneBeforeRule: @MainActor () -> String? = { nil }
    var setSceneBeforeRule: @MainActor (String?) -> Void = { _ in }
    /// The daemon's quiet: seconds of lease, 0 ends it.
    var quietAgents: @MainActor (Int) -> Void = { _ in }

    private(set) var levels = MenuBarLevels()
    private(set) var outcome = MenuBarStateOutcome()
    /// When the rule overlay and the rule profile took hold.
    private(set) var overlaySince: Date?
    private(set) var profileSince: Date?
    private var quietRenewal: Task<Void, Never>?

    /// The quiet lease a rule takes — short, so a crash mid-rule lets the
    /// agents speak again within minutes — and how often it renews.
    nonisolated static let quietLeaseSeconds = 900
    nonisolated static let quietRenewSeconds: TimeInterval = 600

    /// One sample in.
    func absorb(_ event: MenuBarTriggerEvent, now: Date = Date()) {
        levels.absorb(event)
        evaluate(now: now)
    }

    /// Replace levels wholesale — the seed at start, and the daemon
    /// facts that ride no event (an open ask).
    func update(now: Date = Date(), _ mutate: (inout MenuBarLevels) -> Void) {
        mutate(&levels)
        evaluate(now: now)
    }

    /// Resolve and act on whatever moved.
    func evaluate(now: Date = Date()) {
        let next = MenuBarStateRuleEngine.resolve(rules(), levels: levels)
        guard next != outcome else { return }
        let previous = outcome
        outcome = next
        if next.overlay != previous.overlay { overlaySince = next.overlay == nil ? nil : now }
        if next.profileName != previous.profileName {
            profileSince = next.profileName == nil ? nil : now
        }
        if next.ledScene != previous.ledScene { sceneMoved(from: previous.ledScene, to: next.ledScene) }
        if next.quietAgents != previous.quietAgents { quietMoved(next.quietAgents) }
        if next.overlay != previous.overlay || next.profileName != previous.profileName {
            onLayersChange()
        }
        onOutcomeChange()
    }

    /// Everything a rule holds, let go — the utility stopping, or every
    /// rule switched off.
    func stop(now: Date = Date()) {
        levels = MenuBarLevels()
        let previous = outcome
        outcome = MenuBarStateOutcome()
        overlaySince = nil
        profileSince = nil
        if previous.ledScene != nil { sceneMoved(from: previous.ledScene, to: nil) }
        if previous.quietAgents { quietMoved(false) }
        if previous.overlay != nil || previous.profileName != nil { onLayersChange() }
        if previous != MenuBarStateOutcome() { onOutcomeChange() }
    }

    /// The scene a rule wants. Entering remembers yours (once — a scene
    /// already remembered is a relaunch mid-rule, not yours); leaving
    /// puts yours back unless you changed the scene yourself meanwhile.
    private func sceneMoved(from old: String?, to new: String?) {
        if let new {
            if sceneBeforeRule() == nil, let current = currentScene(), current != new {
                setSceneBeforeRule(current)
            }
            if currentScene() != new { setScene(new) }
            return
        }
        guard let before = sceneBeforeRule() else { return }
        setSceneBeforeRule(nil)
        if old == nil || currentScene() == old { setScene(before) }
    }

    /// The agents' quiet: a short lease renewed while the rule holds, so
    /// the daemon's own clock ends it if JR-Bar goes away.
    private func quietMoved(_ on: Bool) {
        quietRenewal?.cancel()
        quietRenewal = nil
        guard on else {
            quietAgents(0)
            return
        }
        quietAgents(Self.quietLeaseSeconds)
        quietRenewal = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.quietRenewSeconds * 1e9))
                guard !Task.isCancelled, let self, self.outcome.quietAgents else { return }
                self.quietAgents(Self.quietLeaseSeconds)
            }
        }
    }

    isolated deinit { quietRenewal?.cancel() }

    /// The levels no sample carries at start: which apps run, which is in
    /// front, whether the screen is locked. The feed's first poll fills
    /// the rest.
    static func seedLevels() -> MenuBarLevels {
        var levels = MenuBarLevels()
        levels.running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        levels.frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        levels.screenLocked = screenIsLocked()
        levels.displayCount = NSScreen.screens.count
        levels.lidClosed = MenuBarSystemTriggerSource.clamshellClosed()
        return levels
    }

    /// The session's lock flag — public CoreGraphics, no permission.
    nonisolated static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
