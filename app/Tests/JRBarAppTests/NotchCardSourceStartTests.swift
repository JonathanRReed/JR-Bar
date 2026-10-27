import AppKit
import JRBarCore
import JRBarTestSupport
import Testing
@testable import JRBarApp

@Suite("Notch card source starts", .temporaryDirectory)
@MainActor
struct NotchCardSourceStartTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Int] = [:]
        func note(_ source: String) { lock.withLock { values[source, default: 0] += 1 } }
        func count(_ source: String) -> Int { lock.withLock { values[source, default: 0] } }
    }

    @Test func oneReadPerSourceOnEachOpen() {
        let calls = Calls()
        let power = AlcovePowerState(hasBattery: false, onAC: true, charging: false,
                                     percent: 0, fullyCharged: false)
        let utility = ShelfUtilityModel(power: power)
        utility.startPower = {}
        utility.stopPower = {}
        utility.observeToggles = {}
        utility.stopToggles = {}
        utility.refreshToggles = {}
        utility.readOutputVolume = { nil }
        utility.readAdapterWatts = { nil }
        utility.readOutputs = { ([], nil) }
        utility.watchOutputs = { _ in {} }
        let tray = ShelfTrayModel(defaults: ScratchDefaults.open(ScratchDefaults.suiteName("source-starts")))
        let model = NotchCardModel(timers: ShelfTimerModel.scratch(), tray: tray, utility: utility)
        model.mediaEnabled = { false }
        model.mirrorEnabled = { false }
        model.readPrivacy = { calls.note("privacy"); return nil }
        model.calendar.authorization = { calls.note("calendar"); return .denied }
        model.reminders.authorization = { calls.note("reminders"); return .denied }
        defer { model.pinned = false }
        for opened in 1...2 {
            model.pinned = true
            for source in ["privacy", "calendar", "reminders"] {
                #expect(calls.count(source) == opened, "\(source) starts once per open")
            }
            model.pinned = false
        }
    }
}
