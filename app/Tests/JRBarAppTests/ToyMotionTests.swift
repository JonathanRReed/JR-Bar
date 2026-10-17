import Foundation
import JRBarUI
import Testing
@testable import JRBarApp

@Suite("Toy motion budgets")
struct ToyMotionTests {
    @Test func confettiProductionCadenceRecovers() {
        var power = PowerPolicy.normal
        #expect(ConfettiView.frameInterval(power: power) == 1.0 / 60)
        power.lowPowerMode = true
        #expect(ConfettiView.frameInterval(power: power) == 1.0 / 30)
        power.lowPowerMode = false
        #expect(ConfettiView.frameInterval(power: power) == 1.0 / 60)
        for thermal in [PowerPolicy.Thermal.serious, .critical] {
            power.thermal = thermal
            #expect(ConfettiView.frameInterval(power: power) == 1.0 / 30)
        }
        power.thermal = .nominal
        #expect(ConfettiView.frameInterval(power: power) == 1.0 / 60)
    }

    @Test func confettiPreviewHonorsMotionAndHeat() {
        let active = ConfettiPreviewTile.clock(replaying: true, reduceMotion: false)
        #expect(!active.paused && !active.flash)
        #expect(active.interval == 1.0 / 30)

        let reduced = ConfettiPreviewTile.clock(replaying: true, reduceMotion: true)
        #expect(reduced.paused && reduced.flash)
        let hot = ConfettiPreviewTile.clock(replaying: true, reduceMotion: false,
                                           power: PowerPolicy(thermal: .critical))
        #expect(hot.paused && hot.flash)
        let resting = ConfettiPreviewTile.clock(replaying: false, reduceMotion: false)
        #expect(resting.paused && !resting.flash)

        let lowPower = ConfettiPreviewTile.clock(replaying: true, reduceMotion: false,
                                                power: PowerPolicy(lowPowerMode: true))
        #expect(!lowPower.paused && !lowPower.flash)
        #expect(lowPower.interval == 1.0 / 15)
    }

    @Test func buddyPausesDecorationWhenCoveredReducedOrHot() {
        let base = 1.0 / 30
        #expect(!NotchBuddyView.clock(interval: base, visible: true, reduceMotion: false).paused)
        #expect(NotchBuddyView.clock(interval: base, visible: false, reduceMotion: false).paused)
        #expect(NotchBuddyView.clock(interval: base, visible: true, reduceMotion: true).paused)
        let hot = NotchBuddyView.clock(interval: base, visible: true, reduceMotion: false,
                                      power: PowerPolicy(thermal: .critical))
        #expect(hot.paused)
        let lowPower = NotchBuddyView.clock(interval: base, visible: true, reduceMotion: false,
                                           power: PowerPolicy(lowPowerMode: true))
        #expect(!lowPower.paused && lowPower.interval == base * 2)
    }
}
