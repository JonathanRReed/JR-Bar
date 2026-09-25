import AppKit
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// "Still allowing them to be an option", the other half: a utility
/// switched off costs nothing. Each utility is turned off through the
/// seam its card uses, and nothing of it may be left behind — no global
/// monitor, no event tap, no repeating timer or clock, no capture stream,
/// no panel on screen.
///
/// The notch, the shelf, the Keep Awake card, the Data Hoarder, Agent
/// Overview and the Screen Bar's pointer watch are turned on (with their
/// system hands replaced by counters) and then off. The Screen Bar's band
/// itself, the Menu Bar and the Dock are only built off and checked:
/// showing the band would put a panel on screen, and starting the Menu
/// Bar or the Dock would take the Mac's menu bar or the Dock's
/// accessibility, which no suite may do. Their on-then-off cases are
/// written and disabled, each naming the lane whose files need the
/// stand-ins that would let them run.
@Suite("Utility off-cost", .serialized)
@MainActor
struct UtilityOffCostTests {
    final class Monitors {
        var installed = 0
        var removed = 0
        var live: Int { installed - removed }
    }

    private func notchToy() -> (NotchToy, ToysStore, Monitors) {
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        let monitors = Monitors()
        toy.installShakeMonitor = { _, _ in
            monitors.installed += 1
            return NSObject()
        }
        toy.removeShakeMonitor = { _ in monitors.removed += 1 }
        toy.shelfRivalsRunning = { [] }
        return (toy, store, monitors)
    }

    @Test("the Notch switched off drops its island, its timers and its shake")
    func notchOff() {
        let (toy, store, monitors) = notchToy()
        defer { withExtendedLifetime(store) {} }
        // Up, as reconcile leaves it on a notched screen, with the shake
        // standing and a grow armed.
        toy.islandVisible = true
        toy.runtimeEnabled = true
        toy.syncShakeMonitor()
        #expect(monitors.live == 2)
        toy.setHovered(true)
        #expect(toy.expandWork != nil)
        // The card's switch.
        toy.isOn = false
        #expect(!toy.islandVisible, "no island left drawn")
        #expect(monitors.live == 0, "no global monitor left")
        #expect(toy.shakeDragMonitor == nil && toy.shakeUpMonitor == nil)
        #expect(toy.expandWork == nil && toy.peekWork == nil && toy.capsuleWork == nil,
                "no timer left armed")
        #expect(!toy.cardModel.utility.running, "the card's media and power reads are down")
        #expect(!toy.cardModel.utility.watchingOutputs, "no sound-device listener left")
        toy.runtimeEnabled = false
    }

    @Test("the Shelf switched off takes its shake monitors down")
    func shelfOff() {
        let (toy, store, monitors) = notchToy()
        defer { withExtendedLifetime(store) {} }
        toy.islandVisible = true
        toy.runtimeEnabled = true
        toy.syncShakeMonitor()
        #expect(monitors.live == 2)
        store.state.notch.shelfEnabled = false
        toy.syncShakeMonitor()
        #expect(monitors.live == 0)
        toy.runtimeEnabled = false
        toy.syncShakeMonitor()
    }

    @Test("the Keep Awake card switched off holds nothing and runs no clock")
    func keepAwakeOff() throws {
        let suite = "UtilityOffCostTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        final class Assertions { var held: Set<IOPMAssertionID> = []; var next: IOPMAssertionID = 1 }
        let assertions = Assertions()
        state.takeAssertion = { _ in
            assertions.next += 1
            assertions.held.insert(assertions.next)
            return assertions.next
        }
        state.releaseAssertion = { assertions.held.remove($0) }
        let utility = KeepAwakeUtility(toggles: SystemTogglesStore(state: state))
        // No monitor connected: the app's own assertion, on a countdown.
        KeepAwakeMenu.perform(.seconds(900), on: utility.toggles)
        #expect(utility.isOn)
        #expect(assertions.held.count == 1)
        #expect(state.awakeClockRunning)
        utility.isOn = false
        #expect(!utility.isOn)
        #expect(assertions.held.isEmpty, "no power assertion left")
        #expect(!state.awakeClockRunning, "no countdown clock left")
    }

    @Test("the Data Hoarder switched off stops capturing")
    func dataHoarderOff() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "jrbar-offcost-\(UUID().uuidString)")
        let watched = root.appending(path: "sessions")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root.appending(path: "archive")))
        model.captureSettings.captureSources[watched.path] = true
        model.enabled = true
        await model.applyCaptureNow()
        #expect(model.captureRunning)
        #expect(!(await model.capture.activeSourceIDs).isEmpty)
        model.enabled = false
        await model.applyCaptureNow()
        #expect(!model.captureRunning)
        #expect(await model.capture.activeSourceIDs.isEmpty, "no file watcher left")
    }

    @Test("Agent Overview has nothing to run, on or off")
    func agentOverviewOff() {
        let core = CoreModel()
        let utility = AgentUtility(core: core)
        // The store's seat: the card writes, the store keeps it.
        final class Store { var settings = AgentOrganizerSettings() }
        let store = Store()
        utility.settings = { store.settings }
        utility.onSettingsChange = { store.settings = $0 }
        // On: its rules are read where each event lands, so nothing starts.
        utility.isOn = true
        utility.applySettings()
        #expect(utility.isOn)
        #expect(utility.status != .off)
        utility.isOn = false
        utility.applySettings()
        #expect(!utility.isOn)
        #expect(utility.status == .off)
    }

    // The Menu Bar and the Dock are built the way UtilitiesStore builds
    // them and left off; their `applySettings` is not called here, since
    // its recovery paths may hand saved values back to the system's own
    // domains, which no suite may touch.

    @Test("a Menu Bar built off holds no engine, no reveal and no Item Bar")
    func menuBarOff() {
        let utility = MenuBarUtility()
        var settings = MenuBarSettings()
        settings.enabled = false
        utility.settings = { settings }
        #expect(!utility.running)
        #expect(!utility.bar.isOpen, "no panel on screen")
        #expect(!utility.reveal.revealed)
    }

    @Test("a Dock built off watches nothing and draws nothing")
    func dockOff() {
        let utility = DockUtility()
        var settings = DockSettings()
        settings.enabled = false
        utility.settings = { settings }
        #expect(!utility.running)
        #expect(!utility.enhance.running, "no Dock watcher or preview panel")
        #expect(!utility.switcher.running, "no switcher chord tap")
    }

    @Test("a Menu Bar switched on and then off leaves no status item, reveal or Item Bar",
          .disabled("owner: lane menubar — MenuBarUtility.start() puts JR-Bar's control items on the real menu bar and probes Accessibility; it needs stand-ins for the boundary items and the hider before a suite may start it"))
    func menuBarOnThenOff() {
        let utility = MenuBarUtility()
        var settings = MenuBarSettings()
        settings.enabled = true
        utility.settings = { settings }
        utility.applySettings()
        settings.enabled = false
        utility.applySettings()
        #expect(!utility.running)
        #expect(!utility.bar.isOpen)
        #expect(!utility.reveal.revealed)
    }

    @Test("a Dock switched on and then off lets go of its watcher and its chord tap",
          .disabled("owner: lane dock — DockUtility.start() restores com.apple.dock through AppleDockControl and starts the AX watcher and the switcher's event tap; it needs stand-ins for all three before a suite may start it"))
    func dockOnThenOff() {
        let utility = DockUtility()
        var settings = DockSettings()
        settings.enabled = true
        utility.settings = { settings }
        utility.applySettings()
        settings.enabled = false
        utility.applySettings()
        #expect(!utility.running)
        #expect(!utility.enhance.running)
        #expect(!utility.switcher.running)
    }

    @Test("the Screen Bar switched off lets go of every pointer monitor and its hover poll")
    func screenBarPointerWatchOff() {
        let interaction = ScreenBarInteraction(card: NotchCardPresenter(model: makeTestCardModel()),
                                               hitRects: { [] }, focus: { nil })
        let monitors = Monitors()
        interaction.installMonitor = { _, _, _ in
            monitors.installed += 1
            return NSObject()
        }
        interaction.removeMonitor = { _ in monitors.removed += 1 }
        // Shown: the app delegate starts the band's gestures.
        interaction.start()
        #expect(monitors.installed > 0)
        #expect(interaction.monitorCount == monitors.installed)
        #expect(interaction.isPolling)
        // Off: the same call the Screen Bar switch makes.
        interaction.stop()
        #expect(monitors.live == 0, "no global or local monitor left")
        #expect(interaction.monitorCount == 0)
        #expect(!interaction.isPolling, "no hover poll left armed")
        #expect(!interaction.hovering)
    }

    @Test("a Screen Bar never shown runs no clock, has no window up, and steps aside for nobody")
    func screenBarOff() {
        let bar = ScreenBarController()
        #expect(!bar.isShown)
        // A name left from before the band went away.
        ScreenBarLiveStatus.shared.steppedAsideForApp = "Keynote"
        bar.hide()
        #expect(!bar.isShown)
        #expect(!bar.clockRunning, "no frame clock")
        #expect(!bar.panelOnScreen, "no band on screen")
        #expect(ScreenBarLiveStatus.shared.steppedAsideForApp == nil,
                "Settings never says the band stepped aside while it is off")
    }
}
