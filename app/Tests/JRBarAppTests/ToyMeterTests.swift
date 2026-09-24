import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Each toy's card says what it costs, measured: frames drawn and sensor
/// reads tick a meter, and the card reads the rate back over the last
/// few seconds.
@Suite("Toy meter")
@MainActor
struct ToyMeterTests {
    @Test("the rate counts only the window's ticks")
    func rateOverWindow() {
        let meter = ToyMeter()
        #expect(meter.rate(at: 100) == 0)
        #expect(meter.drawing(at: 100) == nil, "nothing drew")
        // 30 a second for four seconds.
        for k in 0..<120 { meter.tick(at: 96 + Double(k) / 30) }
        #expect(abs(meter.rate(at: 100) - 30) < 0.5)
        #expect(meter.drawing(at: 100) == "Drawing 30 fps")
        // Two seconds on, a third of the window is empty.
        #expect(abs(meter.rate(at: 102) - 10) < 0.5)
        #expect(meter.rate(at: 110) == 0, "it all aged out")
        // A tick from the future (a clock hiccup) never counts early.
        meter.tick(at: 500)
        #expect(meter.rate(at: 110) == 0)
    }

    @Test("a slow rest rate reads as such, and the ring caps a runaway")
    func restAndOverflow() {
        let meter = ToyMeter(capacity: 16)
        for k in 0..<12 { meter.tick(at: 10 + Double(k) / 4) }
        #expect(abs(meter.rate(at: 13) - 4) < 0.4)
        let runaway = ToyMeter(capacity: 16)
        for k in 0..<1000 { runaway.tick(at: 20 + Double(k) / 300) }
        #expect(runaway.rate(at: 23.4) <= 16 / ToyMeter.window, "the ring holds what it can")
    }

    @Test("the buddy's line: measured frames, then the pacing rule; nothing while off")
    func buddyLine() {
        let core = CoreModel()
        var state = ToysState()
        state.notchBuddy.enabled = true
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let buddy = store.notchBuddy
        let now = ToyMeter.uptime
        #expect(buddy.cost(at: now)?.hasPrefix("Not drawing right now") == true)
        for k in 0..<12 { buddy.meter.tick(at: now - 3 + Double(k) / 4) }
        let line = buddy.cost(at: now) ?? ""
        #expect(line.hasPrefix("Drawing 4 fps"), "\(line)")
        #expect(line.contains("none when covered"))
        store.state.notchBuddy.enabled = false
        #expect(buddy.cost(at: now) == nil)
    }

    @Test("confetti costs nothing between bursts, and quotes what the last one measured")
    func confettiLine() throws {
        let toy = ConfettiToy()
        #expect(toy.cost(at: ToyMeter.uptime)?.hasPrefix("Nothing runs between bursts") == true)
        let meter = ConfettiDrawMeter()
        for milliseconds in [1.8, 2.0, 2.2, 2.4, 3.0, 2.1, 1.9, 2.3, 2.6, 4.0] { meter.record(milliseconds) }
        let summary = try #require(meter.summary(at: ProcessInfo.processInfo.systemUptime))
        #expect(summary.frames == 10)
        #expect(summary.p50 == 2.2 && summary.p90 == 3.0)
        toy.lastBurst = summary
        let line = toy.cost(at: ToyMeter.uptime) ?? ""
        #expect(line.hasPrefix("Nothing runs between bursts · the last burst ran"), "\(line)")
        #expect(line.contains("2.2 ms a frame (p90 3.0 ms)"), "\(line)")
    }
}
