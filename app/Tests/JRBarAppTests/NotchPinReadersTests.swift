import EventKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// What the pin reads, kept off the frame the island grows on: who holds
/// the microphone, the calendar's next events, the sensor poll. Each
/// still reads only when it used to — the calendar only while the card
/// is pinned — and a read that lands after the card folded is dropped.
@Suite("Notch pin readers", .serialized)
@MainActor
struct NotchPinReadersTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var onMain: [Bool] = []
        func note() { lock.withLock { onMain.append(Thread.isMainThread) } }
        var count: Int { lock.withLock { onMain.count } }
        var anyOnMain: Bool { lock.withLock { onMain.contains(true) } }
    }

    /// Lets every main-queue hop queued behind `queue`'s work run.
    private func settle(_ queue: DispatchQueue) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { DispatchQueue.main.async { done.resume() } }
        }
    }

    private func liveCard() -> NotchCardModel {
        let model = makeTestCardModel()
        model.readPrivacy = nil
        model.readsPrivacyOffMain = true
        return model
    }

    // MARK: Privacy

    @Test("with the monitor's reading the line is right at once and the names come off main")
    func privacyFromTheMonitor() async {
        let model = liveCard()
        let names = Calls()
        model.knownSensors = { NotchSensorState(microphoneInUse: true) }
        model.readMicrophoneNames = {
            names.note()
            return ["Zoom"]
        }
        model.readSensorsOffMain = { Issue.record("the monitor already knows"); return NotchSensorState() }
        model.pinned = true
        #expect(model.privacyLine == "Microphone in use", "the row is there, and sized, as the card grows")
        await settle(model.privacyQueue)
        #expect(model.privacyLine == "Microphone · Zoom")
        #expect(names.count == 1)
        #expect(!names.anyOnMain)
        // The next open says the names it last saw straight away.
        model.pinned = false
        #expect(model.privacyLine == nil)
        model.pinned = true
        #expect(model.privacyLine == "Microphone · Zoom")
        await settle(model.privacyQueue)
        model.pinned = false
    }

    @Test("nothing live by the monitor's reading reads nothing at all")
    func privacyQuiet() async {
        let model = liveCard()
        let reads = Calls()
        model.knownSensors = { NotchSensorState() }
        model.readMicrophoneNames = { reads.note(); return [] }
        model.readSensorsOffMain = { reads.note(); return NotchSensorState() }
        model.pinned = true
        await settle(model.privacyQueue)
        #expect(model.privacyLine == nil)
        #expect(reads.count == 0)
        model.pinned = false
    }

    @Test("without a monitor the whole read is off main, and a fold before it lands drops it")
    func privacyWithoutAMonitor() async {
        let model = liveCard()
        let reads = Calls()
        model.readSensorsOffMain = {
            reads.note()
            return NotchSensorState(cameraInUse: true)
        }
        model.pinned = true
        #expect(model.privacyLine == nil, "nothing read on the pin's turn")
        await settle(model.privacyQueue)
        #expect(model.privacyLine == "Camera in use")
        #expect(!reads.anyOnMain)
        // Folded while a read is out: the late answer is not drawn.
        model.pinned = false
        model.pinned = true
        model.pinned = false
        await settle(model.privacyQueue)
        #expect(model.privacyLine == nil)
    }

    @Test("a headless card has no reader, so the line it was given stays through a pin")
    func headlessCardKeepsItsLine() {
        let model = makeTestCardModel()
        model.privacyLine = "Microphone · Zoom"
        model.pinned = true
        #expect(model.privacyLine == "Microphone · Zoom")
        model.pinned = false
    }

    // MARK: Calendar

    @Test("the calendar reads only once pinned, off main, and a fold drops a late reading")
    func calendarOffMain() async {
        let calendar = ShelfCalendarModel()
        let fetches = Calls()
        let start = Date().addingTimeInterval(600)
        calendar.authorization = { .fullAccess }
        calendar.fetchEvents = { _ in
            fetches.note()
            return [ShelfCalendarModel.Event(title: "Standup", start: start,
                                             end: start.addingTimeInterval(900), url: nil)]
        }
        calendar.sync(enabled: false)
        #expect(fetches.count == 0, "switched off, never read")
        #expect(calendar.state == .hidden)
        calendar.sync(enabled: true)
        #expect(calendar.state == .hidden, "the last reading stands until the new one lands")
        await settle(calendar.readQueue)
        #expect(calendar.state == .events([ShelfCalendarModel.Event(title: "Standup", start: start,
                                                                     end: start.addingTimeInterval(900),
                                                                     url: nil)]))
        #expect(fetches.count == 1)
        #expect(!fetches.anyOnMain)
        // Unpinned before a reading lands: it is dropped.
        calendar.fetchEvents = { _ in
            fetches.note()
            return []
        }
        calendar.sync(enabled: true)
        calendar.stop()
        await settle(calendar.readQueue)
        #expect(calendar.state != .idle, "the fold's epoch dropped the late read")
        calendar.stop()
    }

    @Test("the pinned card is what starts the calendar's read")
    func calendarOnlyWhilePinned() {
        let model = makeTestCardModel()
        let fetches = Calls()
        model.calendar.authorization = { .fullAccess }
        model.calendar.fetchEvents = { _ in fetches.note(); return [] }
        model.rows = [NotchIslandRow(id: "claude:1", label: "fix-tests", provider: "claude", activity: .working)]
        model.show(.shelf)
        #expect(fetches.count == 0, "an unpinned card never reads the calendar")
    }

    // MARK: Sensor poll

    @Test("the sensor poll reads the audio and camera daemons off the main thread")
    func sensorPollOffMain() async {
        let monitor = NotchSensorMonitor()
        let reads = Calls()
        monitor.reader = {
            reads.note()
            return NotchSensorState(microphoneInUse: true)
        }
        var edges: [NotchSensorState] = []
        monitor.onChange = { edges.append($0) }
        monitor.start()
        #expect(edges.isEmpty, "the start never waits on a read")
        await settle(monitor.readQueue)
        #expect(edges == [NotchSensorState(microphoneInUse: true)])
        #expect(monitor.state.microphoneInUse)
        #expect(reads.count >= 1)
        #expect(!reads.anyOnMain)
        monitor.stop()
        #expect(monitor.state == NotchSensorState())
    }

    // MARK: The utility's start

    @Test("a live card's output list waits a turn when the output has a volume; a headless one reads at once")
    func outputsDeferredOnALiveCard() async {
        let utility = ShelfUtilityModel(feed: MediaFeed(monitor: QuietMonitor()))
        let reads = Calls()
        utility.readOutputs = {
            reads.note()
            return ([CoreAudioOutputs.Device(id: 41, name: "Speakers", transport: nil)], 41)
        }
        utility.watchOutputs = { _ in {} }
        utility.start()
        let deferred = SystemLevelReader.outputVolume() != nil
        if deferred {
            #expect(reads.count == 0, "not on the turn the card grows")
            await settle(DispatchQueue.global())
        }
        #expect(reads.count == 1)
        #expect(utility.outputs.count == 1)
        utility.stop()

        let headless = ShelfUtilityModel(feed: MediaFeed(monitor: QuietMonitor()))
        headless.inlineReads = true
        headless.readOutputs = { ([CoreAudioOutputs.Device(id: 41, name: "Speakers", transport: nil)], 41) }
        headless.watchOutputs = { _ in {} }
        headless.start()
        #expect(headless.outputs.count == 1, "a render proof reads in the turn it draws")
        headless.stop()
    }

    private final class QuietMonitor: AlcoveMediaMonitor {
        override func start() { markRunning(true) }
        override func stop() { markRunning(false) }
    }
}
