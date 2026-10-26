import Testing
@testable import JRBarApp

@Suite struct StudioPlaybackWarningTests {
    @Test func clampedStudioPlaybackNamesItsActualDuration() {
        let warnings = StudioFleetPreview.playbackWarnings(
            ["The safety compiler adjusted the timing: loop_cadence_clamped."],
            program: "#123456 700ms linear\noff 700ms linear\nrepeat", ledCount: 8)
        #expect(warnings.last == "Playing a 1.40 s cycle.")
    }
}
