import Foundation
import Testing
@testable import JRBarUI

/// The decorative-motion budget: at normal power nothing changes, Low Power
/// Mode or a serious thermal state halves the frame rate, a critical state
/// also stops the passes that only decorate, and all of it lifts when the
/// Mac recovers. The facts are injected values, and no timer runs.
@Suite("Power policy")
struct PowerPolicyTests {
    private static let thermals: [PowerPolicy.Thermal] = [.nominal, .fair, .serious, .critical]

    @Test("normal power is the full budget, and every interval and pause is exactly what it was")
    func normalPowerChangesNothing() {
        for policy in [PowerPolicy.normal, PowerPolicy(thermal: .fair)] {
            #expect(policy.budget == .full)
            for base in [1.0 / 60, 1.0 / 30, 1.0 / 20, 1.0 / 15, 1.0 / 12, 0.25, 0.5, 1, 2] {
                #expect(policy.interval(base) == base)
            }
            #expect(!policy.pauses(occluded: false))
            #expect(policy.pauses(occluded: true), "out of sight stays paused, as it always was")
            #expect(!policy.pauses(occluded: false, decorativeOnly: false))
            #expect(policy.pauses(occluded: true, decorativeOnly: false))
        }
        #expect(PowerPolicy() == .normal)
    }

    @Test("Low Power Mode or a serious thermal state halves every frame rate and pauses nothing")
    func pressureHalvesTheRate() {
        for policy in [PowerPolicy(lowPowerMode: true), PowerPolicy(thermal: .serious),
                       PowerPolicy(lowPowerMode: true, thermal: .serious)] {
            #expect(policy.budget == .halved)
            #expect(policy.interval(1.0 / 30) == 1.0 / 15)
            #expect(policy.interval(1.0 / 12) == 1.0 / 6)
            #expect(policy.interval(2) == 4)
            #expect(!policy.pauses(occluded: false), "halved, not stopped")
            #expect(policy.pauses(occluded: true))
        }
    }

    @Test("a critical thermal state stops the passes that only decorate, and halves the rest")
    func criticalStopsDecoration() {
        for policy in [PowerPolicy(thermal: .critical), PowerPolicy(lowPowerMode: true, thermal: .critical)] {
            #expect(policy.budget == .paused)
            #expect(policy.pauses(occluded: false), "a decorative pass stands still")
            #expect(!policy.pauses(occluded: false, decorativeOnly: false),
                    "a pass that carries state keeps running")
            #expect(policy.interval(1.0 / 30) == 1.0 / 15, "and runs at half the rate")
        }
    }

    @Test("Reduce Motion keeps the pass's own heartbeat whatever the budget")
    func reduceMotionKeepsItsHeartbeat() {
        for thermal in Self.thermals {
            for lowPower in [false, true] {
                let policy = PowerPolicy(lowPowerMode: lowPower, thermal: thermal)
                #expect(policy.interval(1.0 / 30, reduceMotion: true) == 1)
                #expect(policy.interval(1.0 / 30, reduceMotion: true, heartbeat: 0.5) == 0.5)
            }
        }
    }

    @Test("recovery restores the full rate: the budget is a function of the facts alone")
    func recoveryRestoresTheRate() {
        var policy = PowerPolicy(lowPowerMode: true, thermal: .critical)
        #expect(policy.budget == .paused)
        policy.thermal = .serious
        #expect(policy.budget == .halved)
        policy.thermal = .fair
        #expect(policy.budget == .halved, "Low Power Mode is still on")
        policy.lowPowerMode = false
        #expect(policy.budget == .full)
        #expect(policy == PowerPolicy(thermal: .fair))
        #expect(policy.interval(1.0 / 30) == 1.0 / 30)
    }

    @Test("the budget never gets looser as the thermal state climbs")
    func thermalOrderIsMonotonic() {
        for lowPower in [false, true] {
            let budgets = Self.thermals.map { PowerPolicy(lowPowerMode: lowPower, thermal: $0).budget.rawValue }
            #expect(budgets == budgets.sorted())
        }
    }

    @Test("the system's thermal states map one for one")
    func thermalStatesMap() {
        #expect(PowerPolicy.Thermal(.nominal) == .nominal)
        #expect(PowerPolicy.Thermal(.fair) == .fair)
        #expect(PowerPolicy.Thermal(.serious) == .serious)
        #expect(PowerPolicy.Thermal(.critical) == .critical)
    }

    // MARK: The live feed

    /// A hand-cranked set of facts the feed reads.
    @MainActor
    private final class Facts {
        var policy = PowerPolicy.normal
    }

    @MainActor
    @Test("the feed starts at what the system says and moves only when a re-read differs")
    func feedFollowsTheFacts() {
        let facts = Facts()
        facts.policy = PowerPolicy(lowPowerMode: true)
        let conditions = PowerConditions(read: { facts.policy }, center: NotificationCenter())
        #expect(conditions.policy.budget == .halved)
        facts.policy = .normal
        #expect(conditions.policy.budget == .halved, "nothing re-reads on its own: no timer")
        conditions.refresh()
        #expect(conditions.policy == .normal)
        facts.policy = PowerPolicy(thermal: .critical)
        conditions.refresh()
        #expect(conditions.policy.budget == .paused)
    }

    @MainActor
    @Test("Low Power Mode's and the thermal state's notifications each re-read the facts")
    func notificationsReRead() {
        let facts = Facts()
        let center = NotificationCenter()
        let conditions = PowerConditions(read: { facts.policy }, center: center)
        #expect(conditions.policy == .normal)
        facts.policy = PowerPolicy(lowPowerMode: true)
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        #expect(conditions.policy.budget == .halved)
        facts.policy = PowerPolicy(thermal: .serious)
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        #expect(conditions.policy == PowerPolicy(thermal: .serious))
        facts.policy = .normal
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        #expect(conditions.policy == .normal, "and it recovers on its own")
    }

    @MainActor
    @Test("a notification that moves nothing is not a change")
    func unchangedReadIsQuiet() {
        let facts = Facts()
        let conditions = PowerConditions(read: { facts.policy }, center: NotificationCenter())
        final class Hits: @unchecked Sendable { var count = 0 }
        let hits = Hits()
        func watch() {
            withObservationTracking({ _ = conditions.policy }, onChange: { hits.count += 1 })
        }
        watch()
        conditions.refresh()
        #expect(hits.count == 0, "the same answer redraws nothing")
        facts.policy = PowerPolicy(lowPowerMode: true)
        conditions.refresh()
        #expect(hits.count == 1, "a different one does")
    }

    @MainActor
    @Test("the app's own feed reads the real system once and holds a policy")
    func sharedFeedExists() {
        // The value depends on the machine's state, so only its shape is
        // asserted: it is a policy, and it agrees with a fresh system read.
        let conditions = PowerConditions.shared
        conditions.refresh()
        #expect(conditions.policy == PowerConditions.systemPolicy())
    }
}
