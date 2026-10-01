import Foundation
import Testing
import JRBarUI
@testable import JRBarApp

/// Where the power policy meets the decorative passes. At normal power the
/// tank, the island's breath, the playing bars and the buddy tick at the
/// rates they always did and pause for the reasons they always did; Low
/// Power Mode or a serious thermal state halves each rate; a critical thermal
/// state also stills the passes that only decorate. Nothing here starts a
/// timer or waits for one: the policy is a value, cranked by hand.
@Suite("Decorative motion and power")
@MainActor
struct DecorativePowerTests {
    private static let halved = PowerPolicy(lowPowerMode: true)
    private static let serious = PowerPolicy(thermal: .serious)
    private static let critical = PowerPolicy(thermal: .critical)

    // MARK: The tank

    @Test("at normal power the tank's five passes run at exactly the rates they always did")
    func tankRatesAtNormalPower() {
        let rates = AquariumFrameRates(power: .normal, reduceMotion: false,
                                       stillTick: AquariumNightEase.restingTick)
        #expect(rates.still == 2.0)
        #expect(rates.plants == 1.0 / 20.0)
        #expect(rates.light == 1.0 / 12.0)
        #expect(rates.live == 1.0 / 30.0)
        // A Light & Dark flip eases on the quicker still tick, untouched.
        let easing = AquariumFrameRates(power: .normal, reduceMotion: false, stillTick: 1.0 / 15.0)
        #expect(easing.still == 1.0 / 15.0)
        // Fair is not pressure: a Mac that is merely warm changes nothing.
        let warm = AquariumFrameRates(power: PowerPolicy(thermal: .fair), reduceMotion: false,
                                      stillTick: AquariumNightEase.restingTick)
        #expect(warm == rates)
    }

    @Test("under Reduce Motion the moving passes keep their one-a-second heartbeat, at any power")
    func tankRatesUnderReduceMotion() {
        for power in [PowerPolicy.normal, Self.halved, Self.serious, Self.critical] {
            let rates = AquariumFrameRates(power: power, reduceMotion: true,
                                           stillTick: AquariumNightEase.restingTick)
            #expect(rates.plants == 1 && rates.light == 1 && rates.live == 1)
            #expect(rates.still == AquariumNightEase.restingTick)
        }
    }

    @Test("Low Power Mode or a serious thermal state halves every pass")
    func tankRatesUnderPressure() {
        for power in [Self.halved, Self.serious] {
            let rates = AquariumFrameRates(power: power, reduceMotion: false,
                                           stillTick: AquariumNightEase.restingTick)
            #expect(rates.still == 4.0)
            #expect(rates.plants == 1.0 / 10.0)
            #expect(rates.light == 1.0 / 6.0)
            #expect(rates.live == 1.0 / 15.0)
        }
    }

    @Test("the tank's pauses: out of sight as ever, decoration also at critical heat, the simulation never")
    func tankPauses() {
        for power in [PowerPolicy.normal, Self.halved, Self.serious] {
            #expect(!AquariumFrameRates.decorationPaused(power: power, occluded: false))
            #expect(AquariumFrameRates.decorationPaused(power: power, occluded: true))
            #expect(!AquariumFrameRates.livePaused(power: power, occluded: false))
            #expect(AquariumFrameRates.livePaused(power: power, occluded: true))
        }
        #expect(AquariumFrameRates.decorationPaused(power: Self.critical, occluded: false),
                "the plants and the light stand still")
        #expect(!AquariumFrameRates.livePaused(power: Self.critical, occluded: false),
                "the fish still swim: the live canvas carries the simulation")
    }

    @Test("the tank recovers by itself: the rates are a function of the policy alone")
    func tankRecovers() {
        var power = Self.critical
        #expect(AquariumFrameRates.decorationPaused(power: power, occluded: false))
        power.thermal = .nominal
        #expect(!AquariumFrameRates.decorationPaused(power: power, occluded: false))
        #expect(AquariumFrameRates(power: power, reduceMotion: false, stillTick: 2).live == 1.0 / 30.0)
    }

    // MARK: The island and the bars

    @Test("the island's breath is 15 frames a second while it has work, exactly as before, at normal power")
    func breathAtNormalPower() {
        let working = NotchIslandView.breathCadence(working: true, shown: true, reduceMotion: false,
                                                    bare: false, power: .normal)
        #expect(working.interval == 1.0 / 15.0 && working.live)
        // Every old reason to rest still rests it.
        let idle = NotchIslandView.breathCadence(working: false, shown: true, reduceMotion: false,
                                                 bare: false, power: .normal)
        let hidden = NotchIslandView.breathCadence(working: true, shown: false, reduceMotion: false,
                                                   bare: false, power: .normal)
        let still = NotchIslandView.breathCadence(working: true, shown: true, reduceMotion: true,
                                                  bare: false, power: .normal)
        let bare = NotchIslandView.breathCadence(working: true, shown: true, reduceMotion: false,
                                                 bare: true, power: .normal)
        #expect(!idle.live && !hidden.live && !still.live && !bare.live)
    }

    @Test("the breath halves under pressure and holds still at critical heat")
    func breathUnderPressure() {
        for power in [Self.halved, Self.serious] {
            let cadence = NotchIslandView.breathCadence(working: true, shown: true, reduceMotion: false,
                                                        bare: false, power: power)
            #expect(cadence.interval == 1.0 / 7.5 && cadence.live)
        }
        let critical = NotchIslandView.breathCadence(working: true, shown: true, reduceMotion: false,
                                                     bare: false, power: Self.critical)
        #expect(!critical.live, "the face holds still; its counts and dots read the same")
    }

    @Test("the playing bars tick at 12 frames a second at normal power, and rest as they always did")
    func barsAtNormalPower() {
        let playing = DecorativeBars.cadence(live: true, reduceMotion: false, power: .normal)
        #expect(playing.interval == DecorativeBars.frameInterval && playing.moving)
        #expect(!DecorativeBars.cadence(live: false, reduceMotion: false, power: .normal).moving)
        #expect(!DecorativeBars.cadence(live: true, reduceMotion: true, power: .normal).moving)
    }

    @Test("the playing bars halve under pressure and stand in their still frame at critical heat")
    func barsUnderPressure() {
        for power in [Self.halved, Self.serious] {
            let cadence = DecorativeBars.cadence(live: true, reduceMotion: false, power: power)
            #expect(cadence.interval == DecorativeBars.frameInterval * 2 && cadence.moving)
        }
        #expect(!DecorativeBars.cadence(live: true, reduceMotion: false, power: Self.critical).moving)
    }

    // MARK: The buddy

    @Test("the buddy's frame interval is untouched at normal power, at every size and rest")
    func buddyAtNormalPower() {
        var intervals = [NotchBuddyToy.activeInterval]
        for scale in stride(from: 1.0, through: 3.0, by: 0.5) {
            intervals.append(NotchBuddyToy.frameInterval(awake: false, lively: false, dragged: false, scale: scale))
        }
        for interval in intervals {
            #expect(PowerPolicy.normal.interval(interval) == interval)
        }
    }

    @Test("the buddy's walk halves under pressure: 30 frames a second becomes 15, asleep 4 becomes 2")
    func buddyUnderPressure() {
        for power in [Self.halved, Self.serious, Self.critical] {
            #expect(power.interval(NotchBuddyToy.activeInterval) == 1.0 / 15.0)
            let asleep = NotchBuddyToy.frameInterval(awake: false, lively: false, dragged: false, scale: 1)
            #expect(power.interval(asleep) == 0.5)
        }
    }
}
