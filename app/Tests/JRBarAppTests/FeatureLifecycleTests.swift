import AppKit
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("Optional feature teardown", .serialized)
struct FeatureLifecycleTests {
    private func stopped(_ resources: [String: Int], feature: String) {
        #expect(resources.values.allSatisfy { $0 == 0 }, "\(feature): \(resources)")
    }

    private func store(_ core: CoreModel, notchRuntime: Bool = false) -> ToysStore {
        ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                  cardModel: makeTestCardModel(), notchRuntimeEnabled: notchRuntime,
                  nativeSourcesEnabled: false)
    }

    @Test("Aquarium counts with its window closed and stops completely when off")
    func closedAquariumKeepsCounting() async throws {
        let core = CoreModel()
        let toys = store(core)
        let tank = try #require(toys.aquarium)
        defer { toys.shutdown() }
        #expect(tank.switchLabel == "Aquarium")
        tank.isOn = true
        tank.closeWindow()
        #expect(tank.isOn && !tank.ownsWindow && !tank.game.windowOpen)
        #expect(tank.economyRunning && tank.sessionObservationRunning && tank.connectionObservationRunning)
        core.apply(.state(CoreState(sessions: [CoreSession(id: "closed", provider: "claude", mode: "completed")], asks: [])))
        await drain()
        tank.noteEvent(CoreEvent(id: "reset", kind: "quota_reset", provider: "claude"))
        #expect(tank.game.away.completions == 1)
        #expect(tank.game.pendingVisitors.contains(.submarine))
        #expect(tank.lastResetAt != nil)
        // Changing an ambient switch while closed must not reopen the window.
        toys.state.aquarium.idleFillMinutes = 10
        #expect(!tank.ownsWindow && tank.ambientRunning)
        toys.state.aquarium.idleFillMinutes = 0
        #expect(!tank.ownsWindow && !tank.ambientRunning)
        tank.isOn = true
        #expect(tank.awayNotice?.completions == 1)
        #expect(tank.game.away.isEmpty)
        tank.isOn = false
        await drain()
        let game = tank.game
        let resetAt = tank.lastResetAt
        tank.noteEvent(CoreEvent(id: "off-reset", kind: "quota_reset", provider: "claude"))
        core.apply(.state(CoreState(sessions: [CoreSession(id: "off", provider: "claude", mode: "completed")], asks: [])))
        await drain()
        #expect(tank.game == game && tank.lastResetAt == resetAt)
        stopped(tank.lifecycleResources, feature: "aquarium")
    }

    @Test("every registered owner releases what it starts", arguments: FeatureLifecycleRegistry.features)
    func onThenOff(_ contract: FeatureLifecycleContract) async throws {
        switch contract.id {
        case "aquarium":
            let core = CoreModel()
            let toys = store(core)
            let tank = try #require(toys.aquarium)
            defer { toys.shutdown() }
            tank.isOn = true
            #expect(tank.economyRunning && tank.sessionObservationRunning)
            tank.isOn = false
            await drain()
            stopped(tank.lifecycleResources, feature: contract.id)
            let game = tank.game
            tank.noteEvent(CoreEvent(id: "off", kind: "quota_reset", provider: "claude"))
            core.apply(.state(CoreState(sessions: [CoreSession(id: "new", provider: "claude", mode: "working")], asks: [])))
            await drain()
            #expect(tank.game == game)
            stopped(tank.lifecycleResources, feature: contract.id)
            tank.isOn = true
            #expect(tank.economyRunning)
            tank.isOn = false
            await drain()
            stopped(tank.lifecycleResources, feature: contract.id)
        case "notch":
            let toys = store(CoreModel(), notchRuntime: true)
            defer { toys.shutdown() }
            let notch = toys.notch!
            notch.isOn = true
            #expect(notch.notificationObserverCount > 0)
            notch.isOn = false
            await drain()
            stopped(notch.lifecycleResources, feature: contract.id)
            notch.isOn = true
            #expect(notch.notificationObserverCount > 0)
            notch.isOn = false
            await drain()
            stopped(notch.lifecycleResources, feature: contract.id)
        case "screen-bar":
            let bar = ScreenBarController(planRenderer: { _ in nil }, reduceMotionOverride: false,
                                          nativeNoticesEnabled: false)
            bar.apply(programText: "#ff0000 1s linear\n#000000 1s linear\nrepeat")
            bar.show()
            #expect(bar.ownsDisplayLink)
            #expect(bar.ownsPanel && bar.observingSystem)
            bar.hide()
            await drain()
            stopped(bar.lifecycleResources, feature: contract.id)
            bar.show()
            #expect(bar.ownsPanel)
            bar.hide()
            await drain()
            stopped(bar.lifecycleResources, feature: contract.id)
        case "announcements":
            let owner = NotchAnnouncements()
            var enabled = true
            var localSources = 0
            var bluetooth = 0
            owner.isAllowed = { enabled }
            owner.startLocalSources = { localSources += 3 }
            owner.stopLocalSources = { localSources = 0 }
            owner.startBluetooth = { bluetooth += 1 }
            owner.stopBluetooth = { bluetooth -= 1 }
            for _ in 0..<2 {
                enabled = true
                owner.sync()
                #expect(localSources == 3 && bluetooth == 1)
                enabled = false
                owner.sync()
                #expect(localSources == 0 && bluetooth == 0)
                #expect(!owner.started && !owner.bluetoothStarted)
            }
        case "fold":
            let toys = store(CoreModel())
            defer { toys.shutdown() }
            let pumps = PumpFactory()
            let sensor = LidAngleSensor(makePump: { pumps.make() })
            let fold = FoldToy(core: CoreModel(), store: toys, makeTickLink: { _ in nil }, sensor: sensor)
            defer { fold.shutdown() }
            for _ in 0..<2 {
                fold.isOn = true
                #expect(sensor.isPolling)
                fold.isOn = false
                await drain()
                stopped(fold.lifecycleResources, feature: contract.id)
                #expect(pumps.live == 0)
            }
        case "confetti":
            let toys = store(CoreModel())
            defer { toys.shutdown() }
            toys.state.confetti.landing = .fall
            toys.state.confetti.sound = false
            toys.confetti.isOn = true
            toys.confetti.testBurst(provider: "claude")
            #expect((toys.confetti.lifecycleResources["windows"] ?? 0) > 0)
            toys.confetti.isOn = false
            await drain()
            stopped(toys.confetti.lifecycleResources, feature: contract.id)
        case "buddy":
            let core = CoreModel()
            let toys = store(core)
            defer { toys.shutdown() }
            let buddy = toys.notchBuddy
            buddy.isOn = true
            _ = buddy.sessionDigest()
            #expect(buddy.sessionObservationRunning && buddy.notificationObserverCount > 0)
            buddy.isOn = false
            await drain()
            stopped(buddy.lifecycleResources, feature: contract.id)
            core.apply(.state(CoreState(sessions: [], asks: [])))
            await drain()
            stopped(buddy.lifecycleResources, feature: contract.id)
        case "presence", "focus":
            var enabled = true
            var reads = 0
            let reporter = PresenceReporter(isConnected: { true }, presence: { nil }, send: { _ in true },
                                            readFocus: { reads += 1; return false }, focusCheckInterval: 60,
                                            enabled: { enabled }, focusEnabled: { enabled })
            reporter.coreChanged()
            #expect(reporter.wantsSensors && reporter.focusPolling && reporter.watchingActivation)
            enabled = false
            reporter.coreChanged()
            #expect(!reporter.wantsSensors && !reporter.focusPolling && !reporter.watchingActivation)
            #expect(!reporter.renewalRunning)
            let stoppedReads = reads
            reporter.focusMayHaveChanged()
            #expect(reads == stoppedReads)
        case "shelf-media":
            let monitor = Monitor()
            let feed = MediaFeed(monitor: monitor)
            let model = ShelfUtilityModel(feed: feed)
            var power = 0
            var watches = 0
            model.startPower = { power += 1 }
            model.stopPower = { power -= 1 }
            model.refreshToggles = {}
            model.observeToggles = {}
            model.stopToggles = {}
            model.readOutputVolume = { nil }
            model.readOutputs = { ([], nil) }
            model.readAdapterWatts = { nil }
            model.watchOutputs = { _ in watches += 1; return { watches -= 1 } }
            model.start()
            #expect(feed.readerCount == 1)
            model.syncMedia(enabled: false)
            #expect(feed.readerCount == 0 && !model.readingMedia)
            model.stop()
            #expect(!model.running && !model.watchingOutputs)
            #expect(power == 0 && watches == 0 && !feed.isRunning)
        case "shelf-timers":
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let timers = ShelfTimerModel(storeURL: folder.appendingPathComponent("timers.json"))
            _ = timers.add(label: "Fixture", duration: 3600)
            #expect(timers.clockRunning)
            timers.setEnabled(false)
            #expect(!timers.clockRunning && timers.liveTimers == 0 && timers.notificationObserverCount == 0)
            timers.setEnabled(true)
            #expect(timers.clockRunning)
            timers.setEnabled(false)
            #expect(!timers.clockRunning && timers.liveTimers == 0 && timers.notificationObserverCount == 0)
        case "sound":
            let sounds = SoundPlayer()
            sounds.microphoneLive = { false }
            sounds.playbackOverride = { _, _ in {} }
            sounds.startChime("Glass", interval: 60)
            #expect(sounds.isChiming)
            sounds.preferences = { SoundPreferences(volume: 0) }
            sounds.ringChime("Glass")
            #expect(!sounds.isChiming && sounds.liveChimeTimers == 0)
            sounds.startChime("Glass", interval: 60)
            #expect(!sounds.isChiming && sounds.liveChimeTimers == 0)
        default:
            Issue.record("No lifecycle exercise for \(contract.id)")
        }
    }

    @Test("the recorder sees a run-loop timer after its owner drops the reference")
    func recordsRealTimerLifetime() {
        let handles = FeatureLifecycleHandles()
        weak var native: Timer?
        do {
            let timer = Timer(timeInterval: 3600, repeats: true) { _ in }
            native = timer
            handles.track(timer: timer)
            RunLoop.main.add(timer, forMode: .common)
        }
        defer { native?.invalidate() }
        #expect(handles.liveTimers == 1)
        native?.invalidate()
        #expect(handles.liveTimers == 0)
    }

    @Test("Control Center listeners stop after the last open card")
    func sharedToggleListeners() {
        let state = SystemTogglesStore.State()
        state.appearanceCenter = NotificationCenter()
        var audioReaders = 0
        state.startAudio = { audioReaders += 1 }
        state.stopAudio = { audioReaders -= 1 }
        let first = SystemTogglesStore(state: state)
        let second = SystemTogglesStore(state: state)
        first.startObserving()
        second.startObserving()
        #expect(audioReaders == 1 && state.appearanceObserver != nil)
        first.stopObserving()
        #expect(audioReaders == 1)
        second.stopObserving()
        #expect(audioReaders == 0 && state.appearanceObserver == nil && !state.listening)
    }

    @Test("a stopped lid transport cannot publish into its replacement")
    func retiredSensor() {
        let factory = PumpFactory()
        let sensor = LidAngleSensor(makePump: { factory.make() })
        #expect(factory.live == 0)
        sensor.setPolling(true)
        let old = factory.pumps[0]
        sensor.setPolling(false)
        sensor.setPolling(true)
        old.publishAvailability?(true)
        #expect(!sensor.available)
        sensor.setPolling(false)
        #expect(factory.live == 0)
    }

    private func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private final class Monitor: AlcoveMediaMonitor {
        override func start() { markRunning(true) }
        override func stop() { markRunning(false); onChange?(nil) }
    }

    private final class PumpFactory {
        var pumps: [Pump] = []
        var live: Int { pumps.filter { !$0.closed }.count }
        func make() -> Pump { let pump = Pump(); pumps.append(pump); return pump }
    }

    private final class Pump: LidSensorPump, @unchecked Sendable {
        var publish: (@MainActor @Sendable (LidAngleSensor.Sample) -> Void)?
        var publishAvailability: (@MainActor @Sendable (Bool) -> Void)?
        let reads = SensorReadMeter()
        var closed = false
        func setPolling(_ on: Bool) {}
        func setArmingAngle(_ value: Double) {}
        func setQuiet(_ center: Double?) {}
        func close() { closed = true }
    }
}
