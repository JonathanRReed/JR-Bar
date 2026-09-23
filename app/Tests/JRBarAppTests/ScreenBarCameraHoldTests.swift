import Foundation
import Testing
@testable import JRBarApp

/// "Hold still on camera" leans on the notch island's privacy-dot poll —
/// the only camera reading there is. The row may promise the hold only
/// while that poll runs, and otherwise says where to turn it on.
@Suite("Screen Bar camera hold")
@MainActor
struct ScreenBarCameraHoldTests {
    @Test func theHoldCanSeeACameraOnlyWhileTheIslandPolls() {
        #expect(ScreenBarCameraHold.readable(islandVisible: true, indicatorsOn: true))
        // The Notch toy off, Alcove or Boring Notch drawing, or the
        // island hidden all park it — no poll, no camera.
        #expect(!ScreenBarCameraHold.readable(islandVisible: false, indicatorsOn: true))
        // The island up with its dots switched off polls nothing either.
        #expect(!ScreenBarCameraHold.readable(islandVisible: true, indicatorsOn: false))
        #expect(!ScreenBarCameraHold.readable(islandVisible: false, indicatorsOn: false))
    }

    @Test func theRowNamesWhatItLeansOnEitherWay() {
        let live = ScreenBarCameraHold.subtitle(cameraReadable: true)
        let off = ScreenBarCameraHold.subtitle(cameraReadable: false)
        #expect(live.contains("the band stops moving"))
        #expect(live.contains("notch island's camera reading"))
        #expect(off.contains("notch island's camera reading, which is off"))
        // Off, it never promises a hold it cannot make.
        #expect(!off.contains("stops moving"))
    }

    @Test func theOffRowPointsAtTheSwitchesThatStartThePoll() {
        let off = ScreenBarCameraHold.subtitle(cameraReadable: false)
        #expect(off.contains("Toys › Notch"))
        #expect(off.contains("render with JR-Bar"))
        #expect(off.contains("Show the island"))
        #expect(off.contains("Mic & camera indicators"))
    }

    @Test func theStatusStartsUnreadableUntilTheIslandReports() {
        // Nothing has wired the island in a test process, so the row
        // must not read as live.
        #expect(ScreenBarLiveStatus().cameraReadable == false)
    }
}
