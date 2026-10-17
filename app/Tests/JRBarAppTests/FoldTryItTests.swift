import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// Try it is a three-second demo on a timer; switching the toy off ends
/// it at once instead of letting it play out.
@Suite("Fold Try it") @MainActor
struct FoldTryItTests {
    @Test("switching the toy off stops the demo and hands the angle back")
    func offStopsTheDemo() throws {
        let core = CoreModel()
        var state = ToysState()
        state.fold.enabled = false
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let fold = try #require(store.fold)
        fold.tryIt()
        #expect(fold.tryingIt)
        #expect(fold.simulatedAngle != nil)
        fold.isOn = false
        #expect(!fold.tryingIt, "the timer is gone with the toy")
        #expect(fold.simulatedAngle == nil)
    }

    @Test("a slider drag takes over the demo and ignores its late ticks")
    func sliderTakesOverTheDemo() throws {
        let core = CoreModel()
        var state = ToysState()
        state.fold.enabled = false
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let fold = try #require(store.fold)
        defer { fold.isOn = false }
        fold.tryIt()
        let generation = fold.tryGeneration
        let angle = try #require(fold.simulatedAngle)
        fold.beginSimulate()
        #expect(!fold.tryingIt)
        #expect(fold.simulating)
        #expect(fold.simulatedAngle == angle)
        fold.simulateBinding.wrappedValue = 70
        fold.advanceTryIt(elapsed: 0.5, start: 110, reference: 90, generation: generation)
        #expect(fold.simulatedAngle == 70)
        fold.endSimulate()
        #expect(!fold.simulating)
        #expect(fold.simulatedAngle == nil)

        fold.tryIt()
        let newerAngle = fold.simulatedAngle
        fold.advanceTryIt(elapsed: 4, start: 110, reference: 90, generation: generation)
        #expect(fold.tryingIt, "a retired tick cannot finish the newer demo")
        #expect(fold.simulatedAngle == newerAngle)
    }

}
