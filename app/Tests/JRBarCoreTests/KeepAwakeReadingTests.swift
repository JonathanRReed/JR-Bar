import Foundation
import Testing
@testable import JRBarCore

/// The one keep-awake hold as the chip and the footer say it: the
/// daemon's three states, a yield to heat or the battery, and the app's
/// own assertion while the daemon is away.
@Suite("Keep-awake reading")
struct KeepAwakeReadingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func hold(_ json: String) throws -> CoreAwakeHold {
        try JSONDecoder().decode(CoreAwakeHold.self, from: Data(json.utf8))
    }

    @Test("the daemon's three words become three states")
    func states() throws {
        #expect(KeepAwakeReading(hold: nil).state == .off)
        #expect(KeepAwakeReading(hold: try hold(#"{"state":"off"}"#)).state == .off)
        #expect(KeepAwakeReading(hold: try hold(#"{"state":"agents","agents":3}"#)).state == .agents(count: 3))
        let until = now.timeIntervalSince1970 + 42 * 60
        let countdown = KeepAwakeReading(hold: try hold(
            #"{"state":"manual","lease":{"kind":"duration","until":\#(until)},"display":true}"#))
        #expect(countdown.state == .lease(.until(Date(timeIntervalSince1970: until))))
        #expect(countdown.display)
        #expect(KeepAwakeReading(hold: try hold(#"{"state":"manual","lease":{"kind":"agents","until":1}}"#)).state
                    == .lease(.agentsFinish), "an agents lease's until is its backstop, not a countdown")
        #expect(KeepAwakeReading(hold: try hold(#"{"state":"manual","lease":{"kind":"indefinite"}}"#)).state
                    == .lease(.indefinite))
    }

    @Test("held is the Mac's truth; the lease is the chip's light and all a tap ends")
    func litAndTap() throws {
        let agents = KeepAwakeReading(hold: try hold(#"{"state":"agents","agents":2}"#))
        #expect(agents.holding)
        #expect(!agents.leaseInForce, "the agents' hold is their switch's, not the chip's")
        let manual = KeepAwakeReading(hold: try hold(#"{"state":"manual","lease":{"kind":"indefinite"}}"#))
        #expect(manual.holding && manual.leaseInForce)
        let warm = KeepAwakeReading(hold: try hold(#"{"state":"manual","lease":{"kind":"indefinite"},"suspended":"thermal"}"#))
        #expect(!warm.holding, "a yield took the hold away")
        #expect(warm.leaseInForce, "the demand stands")
        #expect(!KeepAwakeReading(hold: nil).holding)
    }

    @Test("the chip's word: a countdown, the agents, a pause")
    func chipTitles() throws {
        #expect(KeepAwakeReading(state: .off).chipTitle(now: now) == "Awake")
        #expect(KeepAwakeReading(state: .lease(.indefinite)).chipTitle(now: now) == "Awake")
        #expect(KeepAwakeReading(state: .agents(count: 3)).chipTitle(now: now) == "3 agents")
        #expect(KeepAwakeReading(state: .agents(count: 1)).chipTitle(now: now) == "1 agent")
        #expect(KeepAwakeReading(state: .agents(count: 0)).chipTitle(now: now) == "Agents")
        func left(_ seconds: TimeInterval) -> String {
            KeepAwakeReading(state: .lease(.until(now.addingTimeInterval(seconds)))).chipTitle(now: now)
        }
        #expect(left(42 * 60) == "42m")
        #expect(left(41 * 60 + 1) == "42m", "rounded up: never 0 while it runs")
        #expect(left(20) == "1m")
        #expect(left(120 * 60) == "2h")
        #expect(left(65 * 60) == "1h 5m")
        #expect(left(-5) == "Awake", "a countdown past its end waits for the daemon's word")
        #expect(KeepAwakeReading(state: .lease(.indefinite), suspended: "battery").chipTitle(now: now) == "Paused")
    }

    @Test("the tooltip says whose hold it is and what a click does")
    func chipHelp() {
        #expect(KeepAwakeReading(state: .off).chipHelp(now: now).contains("display may still sleep"))
        #expect(KeepAwakeReading(state: .off, display: true).chipHelp(now: now).contains("will not lock"))
        let agents = KeepAwakeReading(state: .agents(count: 2)).chipHelp(now: now)
        #expect(agents.contains("2 agents"))
        #expect(agents.contains("Settings › Notifications › Power"))
        #expect(agents.contains("Click to keep it awake"))
        let countdown = KeepAwakeReading(state: .lease(.until(now.addingTimeInterval(90 * 60))), display: true)
            .chipHelp(now: now)
        #expect(countdown.contains("1 h 30 min more"))
        #expect(countdown.contains("click to allow sleep"))
        #expect(countdown.hasSuffix("The display stays on too."))
        let warm = KeepAwakeReading(state: .lease(.agentsFinish), suspended: "thermal").chipHelp(now: now)
        #expect(warm.hasPrefix("Paused: too warm."))
        #expect(warm.contains("until the agents finish"))
    }

    @Test("the footer's quiet line, with a shorter one for a crowded footer")
    func footer() {
        #expect(KeepAwakeReading(state: .off).footerLine(now: now) == nil)
        let countdown = KeepAwakeReading(state: .lease(.until(now.addingTimeInterval(42 * 60)))).footerLine(now: now)
        #expect(countdown?.full == "Awake · 42 min left")
        #expect(countdown?.short == "42m")
        #expect(KeepAwakeReading(state: .agents(count: 3)).footerLine(now: now)?.full == "Awake · 3 agents working")
        #expect(KeepAwakeReading(state: .agents(count: 1)).footerLine(now: now)?.short == "1 agent")
        #expect(KeepAwakeReading(state: .agents(count: 0)).footerLine(now: now)?.full == "Awake · a few minutes more")
        #expect(KeepAwakeReading(state: .lease(.agentsFinish)).footerLine(now: now)?.full == "Awake until the agents finish")
        #expect(KeepAwakeReading(state: .lease(.indefinite)).footerLine(now: now)?.full == "Awake until you turn it off")
        let low = KeepAwakeReading(state: .agents(count: 2), suspended: "battery").footerLine(now: now)
        #expect(low?.full == "Awake paused · battery low")
        #expect(low?.short == "Paused")
    }

    @Test("the app's own assertion reads the same way while the daemon is away")
    func local() {
        #expect(KeepAwakeReading(localHeld: false, until: nil, display: true).state == .off)
        #expect(KeepAwakeReading(localHeld: true, until: nil, display: false).state == .lease(.indefinite))
        let end = now.addingTimeInterval(600)
        let timed = KeepAwakeReading(localHeld: true, until: end, display: false)
        #expect(timed.state == .lease(.until(end)))
        #expect(timed.showsCountdown)
        #expect(!KeepAwakeReading(state: .lease(.until(end)), suspended: "thermal").showsCountdown)
    }
}
