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
    @Test func panelStoreReleasesItsMediaReader() {
        let monitor = FakeMonitor()
        let feed = MediaFeed(monitor: monitor)
        var store: PanelStore? = PanelStore(core: CoreModel(), mediaFeed: feed)
        #expect(store?.screenBarShown == true)
        #expect(feed.readerCount == 1)
        store = nil
        #expect(feed.readerCount == 0)
        #expect(monitor.stops == 1)
    }

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

    @Test("a nested media update retires the older delivery")
    func nestedUpdateWins() {
        let monitor = FakeMonitor()
        let feed = MediaFeed(monitor: monitor)
        var received: [[String]] = [[], [], []]
        var replaced = false
        let tokens = (0..<3).map { index in
            feed.subscribe { media in
                guard let media else { return }
                received[index].append(media.title)
                if media.title == "Old", !replaced {
                    replaced = true
                    monitor.onChange?(AlcoveMedia(title: "New", playing: true))
                }
            }
        }
        defer { tokens.forEach(feed.unsubscribe) }
        monitor.onChange?(AlcoveMedia(title: "Old", playing: true))
        #expect(received.allSatisfy { $0.last == "New" })
        #expect(feed.media?.title == "New")
    }

    @Test("readers removed during publication receive no later callback")
    func removalDuringDelivery() {
        let monitor = FakeMonitor()
        let feed = MediaFeed(monitor: monitor)
        var tokens: [UUID] = []
        var delivered = 0
        for _ in 0..<3 {
            tokens.append(feed.subscribe { media in
                guard media != nil else { return }
                delivered += 1
                tokens.forEach(feed.unsubscribe)
            })
        }
        monitor.onChange?(AlcoveMedia(title: "Track", playing: true))
        #expect(delivered == 1)
        #expect(feed.readerCount == 0)
        #expect(!feed.isRunning)
        #expect(feed.media == nil)
    }
}

extension MediaFeedTests {
    /// Records sends and seeks without touching the real adapter —
    /// the base impl would schedule a refresh that erases the fake
    /// media mid-test.
    private final class RecordingMonitor: AlcoveMediaMonitor {
        var seeks: [Double] = []
        var sent: [MediaRemoteBridge.Command] = []
        override func start() { markRunning(true) }
        override func stop() { markRunning(false) }
        override func send(_ command: MediaRemoteBridge.Command) { sent.append(command) }
        override func seek(to seconds: Double) { seeks.append(seconds) }
    }

    @Test("a scrub rides the live path only while media exists — silence is a lie")
    func seekRouting() {
        let monitor = RecordingMonitor()
        let feed = MediaFeed(monitor: monitor)
        feed.seek(to: 42)
        #expect(monitor.seeks.isEmpty, "no media means no player to seek")
        let token = feed.subscribe { _ in }
        monitor.onChange?(AlcoveMedia(title: "Papillon", playing: true))
        feed.seek(to: 42)
        #expect(monitor.seeks == [42])
        feed.unsubscribe(token)
    }

    @Test("the shelf model's scrub forwards to the feed and the hold keeps the playhead")
    func shelfScrub() {
        let monitor = RecordingMonitor()
        let feed = MediaFeed(monitor: monitor)
        let shelf = ShelfUtilityModel(feed: feed)
        shelf.start()
        monitor.onChange?(AlcoveMedia(title: "Papillon", playing: true,
                                      duration: 200, elapsed: 30,
                                      timestamp: Date().timeIntervalSinceReferenceDate))
        shelf.mediaScrub = 88
        shelf.beginScrub()
        #expect(shelf.elapsedShown() == 88, "the drag position is the playhead while held")
        shelf.commitScrub()
        #expect(monitor.seeks == [88])
        #expect(shelf.elapsedShown() == 88, "the hold covers the feed's ~0.4 s catch-up")
        shelf.stop()
    }

    @Test("a different track or player retires a held scrub before commit",
          arguments: [false, true])
    func changedTrackCannotReceiveOldSeek(_ changedPlayer: Bool) {
        let monitor = RecordingMonitor()
        let shelf = ShelfUtilityModel(feed: MediaFeed(monitor: monitor))
        shelf.start()
        defer { shelf.stop() }
        monitor.onChange?(AlcoveMedia(title: "Track A", playing: false,
                                     bundleIdentifier: "player.a", duration: 200, elapsed: 30))
        shelf.beginScrub()
        shelf.mediaScrub = 88
        monitor.onChange?(AlcoveMedia(title: changedPlayer ? "Track A" : "Track B", playing: false,
                                     bundleIdentifier: changedPlayer ? "player.b" : "player.a",
                                     duration: 200, elapsed: 12))
        #expect(shelf.mediaScrub == nil)
        #expect(shelf.elapsedShown() == 12)
        // The old gesture may still report its release before the view is replaced.
        shelf.mediaScrub = 88
        shelf.commitScrub()
        #expect(monitor.seeks.isEmpty)
        #expect(shelf.mediaScrub == nil)
    }

    @Test("position and play-state updates preserve a current track's scrub")
    func sameTrackKeepsScrub() {
        let monitor = RecordingMonitor()
        let shelf = ShelfUtilityModel(feed: MediaFeed(monitor: monitor))
        shelf.start()
        defer { shelf.stop() }
        monitor.onChange?(AlcoveMedia(title: "Track", artist: "Artist", playing: true,
                                     bundleIdentifier: "player.a", duration: 200, elapsed: 30))
        shelf.beginScrub()
        shelf.mediaScrub = 88
        monitor.onChange?(AlcoveMedia(title: "Track", artist: "Artist", playing: false,
                                     bundleIdentifier: "player.a", duration: 200, elapsed: 35))
        #expect(shelf.elapsedShown() == 88)
        shelf.commitScrub()
        #expect(monitor.seeks == [88])
    }

    @Test("cancel and media loss never commit a held position")
    func cancelledScrubDoesNotSeek() {
        let monitor = RecordingMonitor()
        let shelf = ShelfUtilityModel(feed: MediaFeed(monitor: monitor))
        shelf.start()
        defer { shelf.stop() }
        monitor.onChange?(AlcoveMedia(title: "Track", playing: false, duration: 200, elapsed: 30))
        shelf.beginScrub()
        shelf.mediaScrub = 88
        shelf.cancelScrub()
        shelf.commitScrub()
        #expect(shelf.elapsedShown() == 30)
        #expect(monitor.seeks.isEmpty)
        shelf.beginScrub()
        shelf.mediaScrub = 88
        monitor.onChange?(nil)
        shelf.commitScrub()
        #expect(shelf.mediaScrub == nil)
        #expect(monitor.seeks.isEmpty)
    }
}
