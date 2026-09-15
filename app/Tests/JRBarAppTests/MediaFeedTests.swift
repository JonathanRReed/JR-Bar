import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// One Now Playing helper for every surface: the feed starts its
/// monitor with the first reader, stops it with the last, and hands
/// every reader the same media.
@MainActor
@Suite("Media feed")
struct MediaFeedTests {
    /// A monitor that never spawns the helper — start/stop only flip
    /// the flag and `onChange` is driven by hand.
    private final class FakeMonitor: AlcoveMediaMonitor {
        var starts = 0
        var stops = 0
        override func start() { starts += 1; markRunning(true) }
        override func stop() { stops += 1; markRunning(false); onChange?(nil) }
    }

    @Test("the monitor runs while any reader is subscribed, and only then")
    func lifecycle() {
        let monitor = FakeMonitor()
        let feed = MediaFeed(monitor: monitor)
        #expect(!feed.isRunning)
        var a: AlcoveMedia?? = nil
        var b: AlcoveMedia?? = nil
        let ta = feed.subscribe { a = .some($0) }
        #expect(monitor.starts == 1)
        #expect(a == .some(nil), "a new reader hears the current (empty) media at once")
        let media = AlcoveMedia(title: "Papillon", playing: true)
        monitor.onChange?(media)
        #expect(a == .some(media))
        let tb = feed.subscribe { b = .some($0) }
        #expect(monitor.starts == 1, "a second reader shares the running monitor")
        #expect(b == .some(media), "…and hears the held media immediately")
        feed.unsubscribe(ta)
        #expect(monitor.stops == 0)
        feed.unsubscribe(tb)
        #expect(monitor.stops == 1)
        #expect(feed.media == nil)
        feed.unsubscribe(tb)
        #expect(monitor.stops == 1, "a stale token is a no-op")
    }

    @Test("the shelf model and the toy read the one feed")
    func sharedBySurfaces() {
        let monitor = FakeMonitor()
        let feed = MediaFeed(monitor: monitor)
        let shelf = ShelfUtilityModel(feed: feed)
        shelf.start()
        #expect(monitor.starts == 1)
        monitor.onChange?(AlcoveMedia(title: "Ligeti", playing: false))
        #expect(shelf.media?.title == "Ligeti")
        shelf.stop()
        #expect(monitor.stops == 1)
        #expect(shelf.media == nil)
    }
}
