import Foundation
import Testing
@testable import JRBarCore

@Suite("Screen Bar playback anchor")
struct ScreenBarPlaybackAnchorTests {
    private let wallNow = 1_800_000_000.0

    @Test("old hardware anchors keep their elapsed phase")
    func oldAnchors() {
        for age in [21_600.0, 86_400.0, 604_800.0] {
            let anchor = ScreenBarPlaybackAnchor.mediaTime(
                forEpoch: wallNow - age, wallNow: wallNow, mediaNow: 1_000)
            #expect(anchor == 1_000 - age)
        }
    }

    @Test("wake remaps wall time after the media clock paused")
    func wakeRemapsPhase() {
        let epoch = wallNow - 30
        let before = ScreenBarPlaybackAnchor.mediaTime(
            forEpoch: epoch, wallNow: wallNow, mediaNow: 1_000)
        let after = ScreenBarPlaybackAnchor.mediaTime(
            forEpoch: epoch, wallNow: wallNow + 28_800, mediaNow: 1_010)
        #expect(before == 970)
        #expect(after == -27_820)
        #expect(after.map { 1_010 - $0 } == 28_830)
    }

    @Test("future anchors allow only fifty milliseconds of clock skew")
    func futureAnchors() {
        #expect(ScreenBarPlaybackAnchor.mediaTime(
            forEpoch: 100.05, wallNow: 100, mediaNow: 1_000) != nil)
        #expect(ScreenBarPlaybackAnchor.mediaTime(
            forEpoch: 100.051, wallNow: 100, mediaNow: 1_000) == nil)
    }

    @Test("invalid epochs and clocks never enter playback")
    func invalidClocks() {
        for epoch in [0.0, -1.0, Double.nan, .infinity, -.infinity] {
            #expect(ScreenBarPlaybackAnchor.mediaTime(
                forEpoch: epoch, wallNow: wallNow, mediaNow: 1_000) == nil)
        }
        for wall in [0.0, -1.0, Double.nan, .infinity, -.infinity] {
            #expect(ScreenBarPlaybackAnchor.mediaTime(
                forEpoch: 100, wallNow: wall, mediaNow: 1_000) == nil)
        }
        for media in [-1.0, Double.nan, .infinity, -.infinity] {
            #expect(ScreenBarPlaybackAnchor.mediaTime(
                forEpoch: 100, wallNow: wallNow, mediaNow: media) == nil)
        }
        #expect(ScreenBarPlaybackAnchor.mediaTime(
            forEpoch: Double.leastNonzeroMagnitude,
            wallNow: Double.greatestFiniteMagnitude,
            mediaNow: 0) == -Double.greatestFiniteMagnitude)
    }
}
