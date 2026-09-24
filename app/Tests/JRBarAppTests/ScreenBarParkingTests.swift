import Foundation
import Testing
@testable import JRBarApp

/// The band parks when nobody can see it: every edge of shown, the
/// display asleep and the full-screen video step-aside settles once,
/// and the hover poll stops on the edge down and re-arms on the edge
/// back. No panel is shown and no timer is waited on.
@Suite("Screen Bar parking")
@MainActor
struct ScreenBarParkingTests {
    @Test("each fact's edge settles once; the clocks run only while somebody can see the band")
    func everyEdge() {
        var band = ScreenBarVisibility()
        #expect(!band.live)
        #expect(band.settle() == nil, "hidden from the start: nothing to park")

        band.shown = true
        #expect(band.settle() == true, "shown: the clocks start")
        #expect(band.settle() == nil, "an edge is reported once")

        band.displayAsleep = true
        #expect(band.settle() == false, "the display sleeps: everything parks")
        band.displayAsleep = false
        #expect(band.settle() == true, "and wakes with it")

        band.steppedAside = true
        #expect(band.settle() == false, "stepped aside for a movie: parked")
        band.displayAsleep = true
        #expect(band.settle() == nil, "already parked")
        band.steppedAside = false
        #expect(band.settle() == nil, "still asleep")
        band.displayAsleep = false
        #expect(band.settle() == true)

        band.shown = false
        #expect(band.settle() == false, "hide parks")
        band.displayAsleep = true
        band.displayAsleep = false
        #expect(band.settle() == nil, "a wake with the band hidden starts nothing")

        band.displayAsleep = true
        band.shown = true
        #expect(band.settle() == nil, "shown while asleep waits for the wake")
        band.displayAsleep = false
        #expect(band.settle() == true)
    }

    @Test("the hover poll parks on the edge down and re-arms on the edge back")
    func hoverPollParks() {
        let interaction = ScreenBarInteraction(card: NotchCardPresenter(model: makeTestCardModel()),
                                               hitRects: { [] }, focus: { nil })
        interaction.setParked(false)
        #expect(!interaction.isPolling, "not started: nothing to arm")
        interaction.setParked(true)
        interaction.start()
        defer { interaction.stop() }
        #expect(!interaction.isPolling, "started parked: the poll waits for the edge back")
        interaction.setParked(false)
        #expect(interaction.isPolling)
        interaction.setParked(true)
        #expect(!interaction.isPolling, "the display slept or a movie took the screen")
        #expect(!interaction.hovering)
        interaction.setParked(false)
        #expect(interaction.isPolling)
        interaction.stop()
        #expect(!interaction.isPolling)
    }
}
