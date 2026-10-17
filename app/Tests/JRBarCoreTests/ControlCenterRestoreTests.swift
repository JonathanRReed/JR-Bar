import Foundation
import Testing
@testable import JRBarCore

/// A preference store that lives in a dictionary and counts its writes, so
/// the restore is proved without touching `com.apple.controlcenter`.
private final class FakeDefaults: DefaultsStoring {
    var values: [String: Any]
    private(set) var writes: [String] = []

    init(_ values: [String: Any] = [:]) { self.values = values }

    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) {
        writes.append(defaultName)
        values[defaultName] = value
    }
    func removeObject(forKey defaultName: String) {
        writes.append(defaultName)
        values[defaultName] = nil
    }
}

private func hiddenControlCenter() -> FakeDefaults {
    var values: [String: Any] = [:]
    for name in ControlCenterRestore.coveredKeys { values["NSStatusItem Visible \(name)"] = false }
    values["NSStatusItem Visible SomethingElse"] = false
    return FakeDefaults(values)
}

@Suite("Control Center restore: the one-time undo of the old combined item")
struct ControlCenterRestoreTests {
    @Test("it puts back the saved originals, removes keys that were never set, then clears its record")
    func restoresSavedOriginals() {
        let cc = hiddenControlCenter()
        // Battery was visible, Wi-Fi was already hidden by the person, the rest were never set.
        let ours = FakeDefaults([ControlCenterRestore.savedKey: ["Battery": true, "WiFi": false]])
        var relaunches = 0
        let outcome = ControlCenterRestore.run(controlCenter: cc, ours: ours) { relaunches += 1 }

        #expect(cc.values["NSStatusItem Visible Battery"] as? Bool == true)
        #expect(cc.values["NSStatusItem Visible WiFi"] as? Bool == false, "an original of hidden stays hidden")
        for name in ["Bluetooth", "Sound", "NowPlaying", "FocusModes"] {
            #expect(cc.values["NSStatusItem Visible \(name)"] == nil, "\(name) was never set, so it is unset again")
        }
        #expect(outcome.restored == ["Battery", "Bluetooth", "Sound", "NowPlaying", "FocusModes"])
        #expect(ours.values[ControlCenterRestore.savedKey] == nil)
        #expect(relaunches == 1)
    }

    @Test("it never writes a key it did not own")
    func writesOnlyItsOwnKeys() {
        let cc = hiddenControlCenter()
        cc.values["com.apple.something.else"] = "left alone"
        let ours = FakeDefaults([ControlCenterRestore.savedKey: ["Battery": true]])
        _ = ControlCenterRestore.run(controlCenter: cc, ours: ours) {}

        let owned = Set(ControlCenterRestore.coveredKeys.map { "NSStatusItem Visible \($0)" })
        #expect(Set(cc.writes).isSubset(of: owned))
        #expect(cc.values["NSStatusItem Visible SomethingElse"] as? Bool == false)
        #expect(cc.values["com.apple.something.else"] as? String == "left alone")
    }

    @Test("with no saved record it does nothing at all")
    func skipsWithoutARecord() {
        let cc = hiddenControlCenter()
        let ours = FakeDefaults()
        var relaunches = 0
        let outcome = ControlCenterRestore.run(controlCenter: cc, ours: ours) { relaunches += 1 }

        #expect(cc.writes.isEmpty)
        #expect(ours.writes.isEmpty)
        #expect(relaunches == 0)
        #expect(outcome.skipped != nil)
        #expect(outcome.restored.isEmpty)
    }

    @Test("a key the person changed since is theirs and is left alone")
    func respectsLaterChoices() {
        let cc = hiddenControlCenter()
        cc.values["NSStatusItem Visible Sound"] = true
        cc.values["NSStatusItem Visible Bluetooth"] = nil
        let ours = FakeDefaults([ControlCenterRestore.savedKey: ["Sound": true, "Battery": true]])
        let outcome = ControlCenterRestore.run(controlCenter: cc, ours: ours) {}

        #expect(!outcome.restored.contains("Sound"))
        #expect(!outcome.restored.contains("Bluetooth"))
        #expect(!cc.writes.contains("NSStatusItem Visible Sound"))
        #expect(!cc.writes.contains("NSStatusItem Visible Bluetooth"))
        #expect(cc.values["NSStatusItem Visible Battery"] as? Bool == true)
    }

    @Test("running it twice changes nothing the second time")
    func isIdempotent() {
        let cc = hiddenControlCenter()
        let ours = FakeDefaults([ControlCenterRestore.savedKey: ["Battery": true]])
        _ = ControlCenterRestore.run(controlCenter: cc, ours: ours) {}
        let writesAfterFirst = cc.writes.count
        var relaunches = 0
        let second = ControlCenterRestore.run(controlCenter: cc, ours: ours) { relaunches += 1 }

        #expect(cc.writes.count == writesAfterFirst)
        #expect(relaunches == 0)
        #expect(second.skipped != nil)
    }

    @Test("an empty record still clears itself and leaves Control Center alone")
    func emptyRecord() {
        let cc = FakeDefaults()
        let ours = FakeDefaults([ControlCenterRestore.savedKey: [String: Bool]()])
        var relaunches = 0
        let outcome = ControlCenterRestore.run(controlCenter: cc, ours: ours) { relaunches += 1 }
        #expect(cc.writes.isEmpty)
        #expect(relaunches == 0)
        #expect(ours.values[ControlCenterRestore.savedKey] == nil)
        #expect(outcome.skipped == nil)
    }

    @Test("the notice says what became of the extras, in plain words, or nothing")
    func noticeWording() {
        #expect(ControlCenterRestore.noticeText(retired: [], restored: []) == nil)
        let all = ControlCenterRestore.noticeText(retired: ["combined", "agents", "spacers"],
                                                  restored: ["Battery", "WiFi"])
        #expect(all?.hasPrefix("JR-Bar now has one menu bar item, the icon.") == true)
        #expect(all?.contains("readout on the JR-Bar icon's face") == true)
        #expect(all?.contains("agent item is gone") == true)
        #expect(all?.contains("Spacer items are gone") == true)
        #expect(all?.contains("Control Center's Battery, Wi-Fi items are back") == true)
        let one = ControlCenterRestore.noticeText(retired: [], restored: ["FocusModes"])
        #expect(one?.contains("Control Center's Focus item is back") == true)
    }
}
