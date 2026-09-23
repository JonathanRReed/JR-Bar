import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// ⌘-drag on the island sets a timer: how travel maps to minutes, the
/// readout it draws, and the timer it starts on release. No pointer:
/// the toy's handlers take the travel directly.
@Suite("Notch timer drag")
@MainActor
struct NotchTimerDragTests {
    @Test("a minute a step to half an hour, then five-minute steps to three hours")
    func mapping() {
        let step = NotchTimerDrag.pointsPerStep
        #expect(NotchTimerDrag.minutes(forTravel: 0) == nil)
        #expect(NotchTimerDrag.minutes(forTravel: step - 0.5) == nil, "under a step is no timer")
        #expect(NotchTimerDrag.minutes(forTravel: -40) == nil, "leftward cancels")
        #expect(NotchTimerDrag.minutes(forTravel: step) == 1)
        #expect(NotchTimerDrag.minutes(forTravel: step * 25) == 25)
        #expect(NotchTimerDrag.minutes(forTravel: step * 31) == 35)
        #expect(NotchTimerDrag.minutes(forTravel: step * 1000) == NotchTimerDrag.maxMinutes)
    }

    @Test("the readout's words")
    func labels() {
        #expect(NotchTimerDrag.label(5) == "5 min")
        #expect(NotchTimerDrag.label(60) == "1 h")
        #expect(NotchTimerDrag.label(95) == "1 h 35 min")
        #expect(NotchTimerDrag.fraction(nil) == 0)
        #expect(NotchTimerDrag.fraction(NotchTimerDrag.maxMinutes) == 1)
    }

    private func makeToy() -> (NotchToy, ToysStore) {
        var toys = ToysState()
        toys.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: toys, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        return (toy, store)
    }

    @Test("the drag draws its minutes, and letting go starts that timer")
    func dragSetsTimer() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        #expect(toy.timerDragAllowed)
        let before = toy.cardModel.timers.entries.count
        toy.timerDragChanged(travel: NotchTimerDrag.pointsPerStep * 25)
        #expect(toy.activeOverlay?.subtitle == "25 min")
        #expect(toy.activeOverlay?.key == "timer-drag")
        #expect(NotchLevelScrub.target(ofKey: toy.activeOverlay?.key ?? "") == nil,
                "a scroll never mistakes the readout for a level")
        toy.timerDragEnded(travel: NotchTimerDrag.pointsPerStep * 25)
        #expect(toy.cardModel.timers.entries.count == before + 1)
        #expect(toy.cardModel.timers.entries.last?.label == "25 min timer")
        #expect(toy.activeOverlay?.subtitle == "25 min set")
    }

    @Test("letting go short of a minute starts nothing")
    func shortDragCancels() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        let before = toy.cardModel.timers.entries.count
        toy.timerDragChanged(travel: 2)
        #expect(toy.activeOverlay?.subtitle == "Drag right")
        toy.timerDragEnded(travel: 2)
        #expect(toy.cardModel.timers.entries.count == before)
        #expect(toy.activeOverlay == nil)
    }

    @Test("no timer drag over an ask's buttons, or with the gestures off")
    func gated() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.offer(AlcoveNotice(id: "a", kind: .ask, title: "Claude · t", subtitle: "needs you",
                               session: "claude:a", key: "ask:claude:a"))
        #expect(!toy.timerDragAllowed)
        toy.dismissCapsule()
        store.state.notch.pullGestures = false
        #expect(!toy.timerDragAllowed)
    }
}
