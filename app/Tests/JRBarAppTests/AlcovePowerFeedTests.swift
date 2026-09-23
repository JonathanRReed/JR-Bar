import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// One power poll for every surface: the island, the card's battery row
/// and the Screen Bar's ear share `AlcovePowerFeed`. Readings are
/// staged and ticks driven by hand — no IOKit, no timer.
@Suite("Power feed")
@MainActor
struct AlcovePowerFeedTests {
    private static let battery = AlcovePowerState(hasBattery: true, onAC: false, charging: false,
                                                  percent: 80, fullyCharged: false)
    private static let charging = AlcovePowerState(hasBattery: true, onAC: true, charging: true,
                                                   percent: 80, fullyCharged: false)

    /// The staged battery — a box, so the feed's read sees each change.
    @MainActor
    private final class Staged {
        var reading = AlcovePowerFeedTests.battery
        var reads = 0
    }

    private func makeFeed(_ staged: Staged) -> AlcovePowerFeed {
        let feed = AlcovePowerFeed()
        feed.schedulesTimer = false
        feed.read = {
            staged.reads += 1
            return staged.reading
        }
        return feed
    }

    @Test("three monitors share one poll and each hears one real transition")
    func sharedPoll() {
        let staged = Staged()
        let feed = makeFeed(staged)
        let island = AlcovePowerMonitor(feed: feed)
        let card = AlcovePowerMonitor(feed: feed)
        let ear = AlcovePowerMonitor(feed: feed)
        var heard: [String] = []
        island.onTransition = { _, _ in heard.append("island") }
        card.onTransition = { _, _ in heard.append("card") }
        ear.onTransition = { _, _ in heard.append("ear") }
        island.start()
        card.start()
        ear.start()
        #expect(feed.subscriberCount == 3)
        #expect(staged.reads == 1, "one baseline read, not three")
        #expect(heard.isEmpty, "the baseline never speaks")

        feed.pollNow()
        #expect(staged.reads == 2)
        #expect(heard.isEmpty, "no change, no news")

        staged.reading = Self.charging
        feed.pollNow()
        #expect(heard.sorted() == ["card", "ear", "island"])
    }

    @Test("a late subscriber joins silently and reads the current state")
    func lateJoiner() {
        let staged = Staged()
        let feed = makeFeed(staged)
        let island = AlcovePowerMonitor(feed: feed)
        island.start()
        staged.reading = Self.charging
        feed.pollNow()
        let card = AlcovePowerMonitor(feed: feed)
        var cardHeard = 0
        card.onTransition = { _, _ in cardHeard += 1 }
        card.start()
        #expect(cardHeard == 0, "the state it joined in is not a transition")
        #expect(card.current == Self.charging, "but it reads what the feed knows")
    }

    @Test("the last monitor out stops the poll and forgets the reading")
    func lastOutStops() {
        let feed = makeFeed(Staged())
        feed.schedulesTimer = true
        let island = AlcovePowerMonitor(feed: feed)
        let card = AlcovePowerMonitor(feed: feed)
        island.start()
        card.start()
        #expect(feed.isPolling)
        island.stop()
        #expect(feed.isPolling, "one still listens")
        card.stop()
        #expect(!feed.isPolling)
        #expect(feed.latest == nil)
        #expect(!card.running)
        card.stop()   // a second stop is harmless
    }
}
