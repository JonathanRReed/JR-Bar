import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("Fold owner shutdown")
struct FoldShutdownTests {
    @Test("terminal shutdown retires the demo, observers and later controls without changing preferences")
    func terminalRetirement() throws {
        let core = CoreModel()
        var state = ToysState()
        state.fold.enabled = false
        state.fold.hingeVoice = .off
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let fold = try #require(store.fold)
        #expect(fold.notificationObserverCount > 0)
        fold.tryIt()
        #expect(fold.tryingIt)
        let retiredDemo = fold.tryGeneration
        fold.shutdown()
        #expect(fold.isShutdown)
        #expect(!fold.tryingIt && !fold.simulating)
        #expect(fold.notificationObserverCount == 0)
        #expect(!fold.overlayOnScreen)
        fold.advanceTryIt(elapsed: 0.5, start: 110, reference: 90, generation: retiredDemo)
        fold.simulateBinding.wrappedValue = 70
        fold.isOn = true
        fold.tryIt()
        fold.shutdown()
        #expect(!fold.isOn && !fold.tryingIt && !fold.simulating)
        #expect(fold.simulatedAngle == nil)
        #expect(store.state.fold == state.fold)
    }

    @Test("an observation already queued cannot re-arm a retired owner", .timeLimit(.minutes(1)))
    func queuedObservationCannotRestart() async throws {
        let core = CoreModel()
        var state = ToysState()
        state.fold.enabled = false
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let fold = try #require(store.fold)
        store.state.fold.jitterTolerance += 0.25
        fold.shutdown()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
        #expect(fold.isShutdown)
        #expect(fold.notificationObserverCount == 0)
        #expect(!fold.overlayOnScreen && !fold.simulating)
    }
}
