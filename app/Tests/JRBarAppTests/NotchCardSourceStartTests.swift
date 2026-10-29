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

    @Test(arguments: PermissionRequestTests.permissions)
    func oneReadPerSourceOnEachOpenAndPermissionRefresh(permission: SetupPermission) {
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
        let center = NotificationCenter()
        let model = NotchCardModel(timers: ShelfTimerModel.scratch(), tray: tray, utility: utility,
                                  permissionCenter: center)
        model.mediaEnabled = { false }
        model.mirrorEnabled = { false }
        model.readPrivacy = { calls.note("privacy"); return nil }
        model.calendar.authorization = { calls.note("calendar"); return .denied }
        model.reminders.authorization = { calls.note("reminders"); return .denied }
        defer { model.pinned = false }
        for opened in 1...2 {
            model.pinned = true
            for source in ["privacy", "calendar", "reminders"] {
                #expect(calls.count(source) == (opened - 1) * 3 + 1, "\(source) starts once per open")
            }
            center.post(name: PermissionRequest.didChange, object: permission)
            for source in ["calendar", "reminders"] {
                #expect(calls.count(source) == (opened - 1) * 3 + 2)
            }
            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            for source in ["calendar", "reminders"] {
                #expect(calls.count(source) == opened * 3)
            }
            model.pinned = false
            center.post(name: PermissionRequest.didChange, object: nil)
        }
    }
}
