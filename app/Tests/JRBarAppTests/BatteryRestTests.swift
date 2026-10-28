import Foundation
import JRBarCore
import JRBarUI
import Testing
@testable import JRBarApp

/// Decorations rest on battery: the shared power policy carries the
/// charger, the tank's ornaments hold still while it is out (unless its
/// card says keep going), its chip says so, and plugging in resumes.
/// Every power state here is synthetic; nothing reads the real battery.
@Suite("Battery rest")
@MainActor
struct BatteryRestTests {
    private static let battery = PowerPolicy(onBattery: true)

    @Test("battery alone moves nothing else the policy decides")
    func batteryLeavesTheBudget() {
        #expect(Self.battery.budget == .full)
        #expect(Self.battery.interval(1.0 / 30.0) == 1.0 / 30.0)
        #expect(!Self.battery.pauses(occluded: false))
        #expect(Self.battery.rests())
        #expect(!Self.battery.rests(keepGoing: true))
        #expect(!PowerPolicy.normal.rests())
        // The notch and buddy read only the budget, so their clocks are
        // the same on battery as on mains.
        #expect(NotchBuddyView.clock(interval: 1.0 / 30.0, visible: true, reduceMotion: false,
                                     power: Self.battery)
                == NotchBuddyView.clock(interval: 1.0 / 30.0, visible: true, reduceMotion: false))
    }

    @Test("the feed follows the charger when told, and only then")
    func feedFollowsTheCharger() {
        final class Facts { var policy = PowerPolicy.normal }
        let facts = Facts()
        let center = NotificationCenter()
        let conditions = PowerConditions(read: { facts.policy }, center: center)
        #expect(!conditions.policy.onBattery)
        facts.policy = Self.battery
        #expect(!conditions.policy.onBattery, "nothing re-reads on its own")
        conditions.refresh()
        #expect(conditions.policy.onBattery)
        facts.policy = .normal
        conditions.refresh()
        #expect(!conditions.policy.onBattery, "plugging in resumes")
    }

    @Test("on battery the tank's ornaments rest, unless its card keeps them going")
    func tankRests() {
        var settings = AquariumSettings()
        let resting = AquariumView(fixture: .init(fish: [], settings: settings, power: Self.battery))
        #expect(resting.batteryRest)
        #expect(!resting.isStill, "the window's fish keep swimming")
        settings.restOnBattery = false
        let going = AquariumView(fixture: .init(fish: [], settings: settings, power: Self.battery))
        #expect(!going.batteryRest)
        let mains = AquariumView(fixture: .init(fish: [], settings: AquariumSettings()))
        #expect(!mains.batteryRest, "a fixture is on mains unless it says so")
    }

    @Test("the ornaments' clock holds while resting and runs on after")
    func ornamentClockHolds() {
        let tank = AquariumView(fixture: .init(fish: [], power: Self.battery))
        let clock = tank.motion.ornamentClock
        #expect(clock.time(at: 100, still: false) == 100)
        #expect(clock.time(at: 105, still: true) == 100)
        #expect(clock.time(at: 130, still: true) == 100)
        #expect(clock.time(at: 131, still: false) == 131)
    }

    @Test("the chip says the tank is resting on battery, open or closed")
    func chips() throws {
        #expect(AquariumToy.closedStatus(wallpaper: "LG", connected: ["LG"], saverMinutes: 0, resting: true)
                == .note("Window closed · wallpaper on LG resting on battery"))
        #expect(AquariumToy.closedStatus(wallpaper: nil, connected: [], saverMinutes: 10, resting: true)
                == .note("Window closed · still screensaver after 10 min on battery"))
        #expect(AquariumToy.closedStatus(wallpaper: nil, connected: [], saverMinutes: 0, resting: true)
                == .note("Window closed · still counting pearls"))
        let core = CoreModel()
        var state = ToysState()
        state.aquarium.enabled = true
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let tank = try #require(store.aquarium)
        tank.power = { Self.battery }
        #expect(tank.batteryResting)
        #expect(tank.cost(at: 0)?.contains("resting on battery") == true)
        store.state.aquarium.restOnBattery = false
        #expect(!tank.batteryResting)
        #expect(tank.cost(at: 0)?.contains("battery") == false)
        tank.power = { .normal }
        store.state.aquarium.restOnBattery = true
        #expect(!tank.batteryResting, "on mains nothing rests")
    }

    @Test("the switch is on by default, and a file without it reads on")
    func settingDefaults() throws {
        #expect(AquariumSettings().restOnBattery)
        let old = try JSONDecoder().decode(AquariumSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(old.restOnBattery)
        var off = AquariumSettings()
        off.restOnBattery = false
        let round = try JSONDecoder().decode(AquariumSettings.self, from: JSONEncoder().encode(off))
        #expect(!round.restOnBattery)
        let junk = try JSONDecoder().decode(AquariumSettings.self,
                                            from: Data(#"{"restOnBattery":"yes"}"#.utf8))
        #expect(junk.restOnBattery)
    }
}
