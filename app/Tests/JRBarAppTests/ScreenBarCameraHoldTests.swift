import Foundation
import Testing
@testable import JRBarApp

/// "Hold still on camera" leans on the notch's sensor monitor — the only
/// camera reading there is — which runs for whichever surface needs it:
/// the island's dots, the Screen Bar's ears or the presence report. The
/// row may promise the hold only while that monitor reads with the
/// indicators on, and otherwise says which switch starts it.
@Suite("Screen Bar camera hold")
@MainActor
struct ScreenBarCameraHoldTests {
    @Test func theHoldCanSeeACameraOnlyWhileTheMonitorReads() {
        #expect(ScreenBarCameraHold.readable(monitorReading: true, indicatorsOn: true))
        // Nothing asked the monitor to read — no camera to hold on.
        #expect(!ScreenBarCameraHold.readable(monitorReading: false, indicatorsOn: true))
        // A reading taken only for the presence report, with the dots
        // switched off, is not the person's consent to the hold.
        #expect(!ScreenBarCameraHold.readable(monitorReading: true, indicatorsOn: false))
        #expect(!ScreenBarCameraHold.readable(monitorReading: false, indicatorsOn: false))
    }

    @Test func theRowNamesWhatItDoesOrWhatItNeeds() {
        let live = ScreenBarCameraHold.subtitle(cameraReadable: true)
        let off = ScreenBarCameraHold.subtitle(cameraReadable: false)
        #expect(live.contains("the band stops moving"))
        #expect(off.contains("Needs a camera reading"))
        // Off, it never promises a hold it cannot make.
        #expect(!off.contains("stops moving"))
        // It no longer sends anyone to the island: the ears read too.
        #expect(!off.contains("Show the island"))
    }

    @Test func theOffRowPointsAtTheSwitchThatStartsTheReading() {
        let off = ScreenBarCameraHold.subtitle(cameraReadable: false)
        #expect(off.contains("Utilities › Notch"))
        #expect(off.contains("Mic & camera indicators"))
    }

    @Test func theStatusStartsUnreadableUntilTheMonitorReports() {
        // Nothing has wired the monitor in a test process, so the row
        // must not read as live.
        #expect(ScreenBarLiveStatus().cameraReadable == false)
    }
}
