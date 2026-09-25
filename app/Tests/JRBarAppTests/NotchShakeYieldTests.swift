import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The shake summon and the shelf apps that own the same gesture: while
/// Dropover, Yoink or Dropzone runs, JR-Bar's shake monitors stand down
/// so one shake never opens two shelves, and they come back when the
/// rival quits. An excluded app in front never gets the shelf.
@Suite("Notch shake yield")
@MainActor
struct NotchShakeYieldTests {
    /// Counts the monitors the toy asks for instead of installing any.
    private final class Monitors {
        var installed = 0
        var removed = 0
        var live: Int { installed - removed }
    }

    private final class Running: @unchecked Sendable {
        var rivals: [UtilityRivals.Rival] = []
        var frontmost: String?
    }

    private static let dropover = UtilityRivals.known.first { $0.name == "Dropover" }!

    private func makeToy() -> (NotchToy, ToysStore, Monitors, Running) {
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: state, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        let monitors = Monitors()
        let running = Running()
        toy.installShakeMonitor = { _, _ in
            monitors.installed += 1
            return NSObject()
        }
        toy.removeShakeMonitor = { _ in monitors.removed += 1 }
        toy.shelfRivalsRunning = { running.rivals }
        toy.shakeFrontmostApp = { running.frontmost }
        // The island is up, as `reconcile` would leave it on a notched
        // screen; only the shake's own gate is under test.
        toy.islandVisible = true
        toy.runtimeEnabled = true
        return (toy, store, monitors, running)
    }

    private func finish(_ toy: NotchToy, _ store: ToysStore) {
        toy.runtimeEnabled = false
        toy.syncShakeMonitor()
        withExtendedLifetime(store) {}
    }

    @Test("with no shelf app running the shake's monitors stand")
    func noRivalInstalls() {
        let (toy, store, monitors, _) = makeToy()
        defer { finish(toy, store) }
        toy.syncShakeMonitor()
        #expect(monitors.live == 2, "the drag and the release")
    }

    @Test("Dropover running installs no monitor; its quit brings them back")
    func dropoverYields() {
        let (toy, store, monitors, running) = makeToy()
        defer { finish(toy, store) }
        running.rivals = [Self.dropover]
        toy.syncShakeMonitor()
        #expect(monitors.installed == 0, "one shake must not open two shelves")
        #expect(toy.shakeYieldingTo.map(\.name) == ["Dropover"])
        // The workspace's quit note is what re-asks.
        running.rivals = []
        toy.noteWorkspaceChange()
        #expect(monitors.live == 2, "Dropover quit: the shake is JR-Bar's again")
        // Dropover launching again takes the monitors down at once.
        running.rivals = [Self.dropover]
        toy.noteWorkspaceChange()
        #expect(monitors.live == 0)
    }

    @Test("the rivals are asked once per launch or quit, however often the island reconciles")
    func rivalsAskedOncePerWorkspaceChange() {
        let (toy, store, monitors, running) = makeToy()
        defer { finish(toy, store) }
        var asks = 0
        toy.shelfRivalsRunning = {
            asks += 1
            return running.rivals
        }
        for _ in 0..<20 { toy.syncShakeMonitor() }
        #expect(asks == 1, "a doc that changes no app list asks LaunchServices nothing")
        #expect(monitors.live == 2)
        running.rivals = [Self.dropover]
        toy.noteWorkspaceChange()
        #expect(asks == 2, "a launch renews the answer")
        #expect(monitors.live == 0, "and the shake stands down in the same turn")
        for _ in 0..<20 { toy.syncShakeMonitor() }
        _ = toy.shakeYieldingTo
        #expect(asks == 2)
    }

    @Test("with the yield switched off nothing asks after the rivals at all")
    func yieldOffNeverAsks() {
        let (toy, store, monitors, _) = makeToy()
        defer { finish(toy, store) }
        store.state.notch.shelfYieldToRivals = false
        var asks = 0
        toy.shelfRivalsRunning = {
            asks += 1
            return [Self.dropover]
        }
        toy.syncShakeMonitor()
        toy.noteWorkspaceChange()
        #expect(asks == 0)
        #expect(monitors.live == 2)
    }

    @Test("with the yield switched off both shelves answer, as before")
    func yieldOffKeepsMonitors() {
        let (toy, store, monitors, running) = makeToy()
        defer { finish(toy, store) }
        store.state.notch.shelfYieldToRivals = false
        running.rivals = [Self.dropover]
        toy.syncShakeMonitor()
        #expect(monitors.live == 2)
        #expect(toy.shakeYieldingTo.isEmpty)
    }

    @Test("the shelf switched off takes the shake with it")
    func shelfOffInstallsNothing() {
        let (toy, store, monitors, _) = makeToy()
        defer { finish(toy, store) }
        store.state.notch.shelfEnabled = false
        toy.syncShakeMonitor()
        #expect(monitors.installed == 0)
    }

    /// Six 60-point swings in half a second — a shake at any sensitivity.
    private func shake(_ toy: NotchToy) {
        for index in 0..<14 {
            toy.noteDragSample(x: index.isMultiple(of: 2) ? 100 : 160, at: 10 + Double(index) * 0.03)
        }
    }

    @Test("an excluded app in front keeps the shelf down; others summon it")
    func exclusionsBlockTheSummon() {
        let (toy, store, _, running) = makeToy()
        defer { finish(toy, store) }
        // The summon itself needs no runtime; the headless toy grows
        // without a window or the haptic.
        toy.runtimeEnabled = false
        store.state.notch.shelfShakeExcludedBundleIDs = ["com.seriflabs.affinitydesigner2"]
        running.frontmost = "com.seriflabs.affinitydesigner2"
        shake(toy)
        #expect(!toy.shelfSummoned, "a shake over an excluded app is the work, not a request")
        running.frontmost = "com.apple.finder"
        shake(toy)
        #expect(toy.shelfSummoned)
        toy.shelfDragAbandoned()
    }

    @Test("the pure gate folds every switch in")
    func gate() {
        let on = NotchSettings(enabled: true)
        #expect(NotchToy.wantsShakeMonitor(runtimeEnabled: true, settings: on, drawingIsland: true,
                                           islandVisible: true, rivalsRunning: false))
        #expect(!NotchToy.wantsShakeMonitor(runtimeEnabled: true, settings: on, drawingIsland: true,
                                            islandVisible: true, rivalsRunning: true))
        #expect(!NotchToy.wantsShakeMonitor(runtimeEnabled: false, settings: on, drawingIsland: true,
                                            islandVisible: true, rivalsRunning: false))
        var noShake = on
        noShake.shelfShakeToSummon = false
        #expect(!NotchToy.wantsShakeMonitor(runtimeEnabled: true, settings: noShake, drawingIsland: true,
                                            islandVisible: true, rivalsRunning: false))
        #expect(NotchToy.shakeAllowed(frontmost: nil, excluded: ["a"]))
        #expect(!NotchToy.shakeAllowed(frontmost: "a", excluded: ["a"]))
    }
}
