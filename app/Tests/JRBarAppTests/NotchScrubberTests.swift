import SwiftUI
import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("Notch scrubber")
struct NotchScrubberTests {
    private final class RecordingMonitor: AlcoveMediaMonitor {
        var seeks: [Double] = []
        override func start() { markRunning(true) }
        override func stop() { markRunning(false) }
        override func seek(to seconds: Double) { seeks.append(seconds) }
    }

    @Test("a duration change retires a scrub even when track labels match",
          arguments: [Optional(200.0), nil])
    func changedDurationCannotReceiveOldSeek(_ originalDuration: Double?) {
        let monitor = RecordingMonitor()
        let shelf = ShelfUtilityModel(feed: MediaFeed(monitor: monitor))
        shelf.start()
        defer { shelf.stop() }
        monitor.onChange?(AlcoveMedia(title: "Track", artist: "Artist", album: "Album",
                                     playing: false, bundleIdentifier: "player.a",
                                     duration: originalDuration, elapsed: 30))
        shelf.beginScrub()
        shelf.mediaScrub = 90
        // A replacement or a duration correction must retire the old drag.
        monitor.onChange?(AlcoveMedia(title: "Track", artist: "Artist", album: "Album",
                                     playing: false, bundleIdentifier: "player.a",
                                     duration: 240, elapsed: 12))
        #expect(shelf.mediaScrub == nil)
        #expect(shelf.elapsedShown() == 12)
        shelf.mediaScrub = 90
        shelf.commitScrub()
        #expect(monitor.seeks.isEmpty)
        #expect(shelf.mediaScrub == nil)
    }

    @Test("invalid durations share the absent duration identity")
    func invalidDurationsAreNormalized() {
        let absent = ShelfUtilityModel.MediaTrack(AlcoveMedia(title: "Track", playing: false))
        for duration in [0.0, -1, Double.infinity, Double.nan] {
            let track = ShelfUtilityModel.MediaTrack(
                AlcoveMedia(title: "Track", playing: false, duration: duration))
            #expect(track == absent)
        }
    }

    @Test("keyboard and VoiceOver seek by seconds rather than a fraction of a long track")
    func playbackAdjustment() {
        var events: [String] = []
        let scrubber = NotchScrubber(value: 600, range: 0...7200, step: 5,
                                    tint: .white, track: .gray, label: "Playback position",
                                    valueText: "10:00", onScrub: { events.append("seek:\($0)") },
                                    onEditing: { events.append("editing:\($0)") }, onCancel: {})
        scrubber.adjust(increment: true)
        #expect(events == ["editing:true", "seek:605.0", "editing:false"])
        events.removeAll()
        scrubber.adjust(increment: false)
        #expect(events == ["editing:true", "seek:595.0", "editing:false"])
    }

    @Test("adjustments clamp and do not resubmit an unchanged endpoint")
    func endpointAdjustment() {
        var values: [Double] = []
        var edits: [Bool] = []
        func scrubber(_ value: Double) -> NotchScrubber {
            NotchScrubber(value: value, range: 0...1, step: 0.05,
                          tint: .white, track: .gray, label: "Volume", valueText: "",
                          onScrub: { values.append($0) }, onEditing: { edits.append($0) }, onCancel: {})
        }
        scrubber(0.98).adjust(increment: true)
        scrubber(0.02).adjust(increment: false)
        #expect(values == [1, 0])
        #expect(edits == [true, false, true, false])
        scrubber(1).adjust(increment: true)
        scrubber(0).adjust(increment: false)
        #expect(values == [1, 0])
        #expect(edits == [true, false, true, false])
    }
}
