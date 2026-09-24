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

    // MARK: The power facts

    private func pinned(_ reading: KeepAwakeReading) -> KeepAwakeReading {
        var reading = reading
        reading.locale = Locale(identifier: "en_GB")
        reading.timeZone = TimeZone(identifier: "UTC")!
        return reading
    }

    private func power(_ json: String) throws -> CorePower {
        try JSONDecoder().decode(CorePower.self, from: Data(json.utf8))
    }

    @Test("the agents' grace names the time it lets go, in the Mac's clock")
    func grace() throws {
        let end = now.addingTimeInterval(4 * 60)
        let reading = pinned(KeepAwakeReading(hold: try hold(
            #"{"state":"agents","agents":0,"grace_until":\#(end.timeIntervalSince1970)}"#)))
        #expect(reading.graceUntil == end)
        #expect(reading.footerLine(now: now)?.full == "Awake · lets go at 08:04")
        #expect(reading.footerLine(now: now)?.short == "08:04")
        #expect(reading.chipHelp(now: now).hasPrefix("Held awake until 08:04"))
        #expect(reading.footerLine(now: end.addingTimeInterval(1))?.full == "Awake · a few minutes more",
                "past its end the grace waits for the daemon's word")
        var american = reading
        american.locale = Locale(identifier: "en_US")
        #expect(american.footerLine(now: now)?.full == "Awake · lets go at 8:04\u{202F}AM"
                || american.footerLine(now: now)?.full == "Awake · lets go at 8:04 AM")
    }

    @Test("a battery that will not outlast the run, and a charger that cannot carry it, take the line")
    func runway() throws {
        let short = pinned(KeepAwakeReading(power: try power(
            #"{"hold":{"state":"agents","agents":3},"battery":{"percent":18,"runway":{"agents":3,"minutes_left":25,"short":true}}}"#)))
        #expect(short.footerLine(now: now)?.full == "Awake · battery ~25 min left")
        #expect(short.facts() == ["On battery with 3 agents working: about 25 min left"])
        #expect(short.chipHelp(now: now).hasSuffix("\nOn battery with 3 agents working: about 25 min left"))
        let charger = pinned(KeepAwakeReading(power: try power(
            #"{"hold":{"state":"agents","agents":2},"battery":{"runway":{"agents":2,"adapter_short":true,"full_speed_watts":96}}}"#)))
        #expect(charger.footerLine(now: now)?.short == "Charger short")
        #expect(charger.facts() == ["The charger can't keep up — the battery still falls under the agents' load; this Mac charges at full speed on 96 W"])
        let fine = KeepAwakeReading(power: try power(#"{"hold":{"state":"agents","agents":2},"battery":{"runway":{"agents":2,"short":false}}}"#))
        #expect(fine.facts().isEmpty)
        #expect(fine.footerLine(now: now)?.full == "Awake · 2 agents working")
    }

    @Test("a charger falling behind never says Awake while nothing holds the Mac")
    func runwayNeedsAHold() throws {
        let released = pinned(KeepAwakeReading(power: try power(
            #"{"hold":{"state":"off"},"battery":{"runway":{"agents":2,"adapter_short":true}}}"#)))
        #expect(released.footerLine(now: now) == nil)
        #expect(released.facts().contains { $0.hasPrefix("The charger can't keep up") }, "the fact stays in the tooltip")
        let lid = pinned(KeepAwakeReading(power: try power(
            #"{"hold":{"state":"off"},"closed_lid":{"holding":true},"battery":{"runway":{"agents":2,"adapter_short":true}}}"#)))
        #expect(lid.footerLine(now: now)?.short == "Charger short", "the closed-lid hold holds the Mac")
    }

    @Test("the last release says when and why; a closed-lid stretch reads as one story")
    func lastRelease() throws {
        let at = now.timeIntervalSince1970 - 10 * 60
        let expired = pinned(KeepAwakeReading(power: try power(
            #"{"hold":{"state":"off"},"last_release":{"kind":"lease_ended","reason":"expired","at":\#(at)}}"#)))
        #expect(expired.facts() == ["Last let go at 07:50 — time up"])
        #expect(expired.footerLine(now: now)?.full == "Let go at 07:50 · time up", "recent news while nothing holds")
        #expect(expired.footerLine(now: now.addingTimeInterval(3600)) == nil, "old news stays in the tooltip")
        #expect(expired.chipHelp(now: now).hasSuffix("\nLast let go at 07:50 — time up"))
        let slept = pinned(KeepAwakeReading(power: try power(
            #"{"last_release":{"kind":"slept","reason":"agents_idle","at":\#(at),"duration":9600,"finished":3,"slept_at":\#(at)}}"#)))
        #expect(slept.facts() == ["Ran 2 h 40 min with the lid closed, 3 finished, slept at 07:50"])
        #expect(slept.footerLine(now: now)?.full == "Slept at 07:50")
        let warm = pinned(KeepAwakeReading(power: try power(
            #"{"last_release":{"kind":"suspended","reason":"thermal","at":\#(at)}}"#)))
        #expect(warm.facts() == ["Last let go at 07:50 — too warm"])
    }

    // MARK: lane utilities

    @Test func lowPowerModeSaysSoInsteadOfItsWireWord() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let paused = KeepAwakeReading(state: .lease(.indefinite), suspended: "low_power")
        #expect(paused.footerLine(now: now)?.full == "Awake paused · Low Power Mode is on")
        #expect(paused.chipHelp(now: now).contains("Low Power Mode is on"))
        #expect(!paused.chipHelp(now: now).contains("low_power"))
        #expect(KeepAwakeReading.releaseWords("low_power") == "Low Power Mode")
    }
}
