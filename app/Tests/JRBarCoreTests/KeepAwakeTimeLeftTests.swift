import Foundation
import JRBarCore
import Testing

/// The cup's steam and the five-minute heads-up, pure: the steps a
/// countdown fades through, which holds get a notice, and what "+30 min"
/// makes of the end. A "while this runs" lease reads by its command's name.
@Suite("Keep Awake time left")
struct KeepAwakeTimeLeftTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func countdown(minutes: Double, startedAgo: Double) -> (KeepAwakeReading, Date) {
        let now = start.addingTimeInterval(startedAgo * 60)
        var reading = KeepAwakeReading(state: .lease(.until(now.addingTimeInterval(minutes * 60))))
        reading.startedAt = start
        return (reading, now)
    }

    @Test("the steam fades in steps as a countdown runs out")
    func steamSteps() {
        // A 60-minute session, read at several points.
        let table: [(Double, KeepAwakeSteam)] = [
            (60, .full), (31, .full), (29, .low), (16, .low), (14, .faint), (6, .faint), (5, .faint), (0.5, .faint),
        ]
        for (left, steam) in table {
            let (reading, now) = countdown(minutes: left, startedAgo: 60 - left)
            #expect(reading.steam(now: now) == steam, "\(left) min left")
        }
        let (over, now) = countdown(minutes: 0, startedAgo: 60)
        #expect(over.steam(now: now.addingTimeInterval(1)) == .none)
    }

    @Test("the last five minutes are a wisp even in a long session")
    func lastFiveMinutes() {
        #expect(KeepAwakeSteam.level(left: 299, total: 8 * 3600) == .faint)
        #expect(KeepAwakeSteam.level(left: 301, total: 600) == .full)
        #expect(KeepAwakeSteam.level(left: 1200, total: nil) == .full)
    }

    @Test("a hold with no end steams steadily, and nothing held has no steam")
    func steadySteam() {
        let now = start
        #expect(KeepAwakeReading(state: .lease(.indefinite)).steam(now: now) == .full)
        #expect(KeepAwakeReading(state: .lease(.agentsFinish)).steam(now: now) == .full)
        #expect(KeepAwakeReading(state: .lease(.whileRunning("swift"))).steam(now: now) == .full)
        #expect(KeepAwakeReading(state: .agents(count: 2)).steam(now: now) == .full)
        #expect(KeepAwakeReading(state: .off).steam(now: now) == .none)
        var paused = KeepAwakeReading(state: .lease(.indefinite))
        paused.suspended = "thermal"
        #expect(paused.steam(now: now) == .none)
        var failed = KeepAwakeReading(state: .lease(.indefinite))
        failed.holdFailed = true
        #expect(failed.steam(now: now) == .none)
    }

    @Test("each step has its own look")
    func steamLooks() {
        #expect(KeepAwakeSteam.none.symbol == "cup.and.saucer.fill")
        #expect(KeepAwakeSteam.full.symbol == "cup.and.heat.waves.fill")
        let opacities = KeepAwakeSteam.allCases.map(\.opacity)
        #expect(opacities == opacities.sorted())
        #expect(Set(opacities).count == KeepAwakeSteam.allCases.count)
    }

    @Test("a countdown longer than five minutes gets one heads-up at its end minus five")
    func headsUpPlan() throws {
        let (reading, now) = countdown(minutes: 30, startedAgo: 0)
        let plan = try #require(KeepAwakeHeadsUp.plan(for: reading, now: now))
        #expect(plan.fireAt == now.addingTimeInterval(25 * 60))
        #expect(plan.title == "Awake for 5 more minutes")
        let body = plan.body(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(body == "The Mac can sleep at 08:30. +30 min keeps it awake longer.")
    }

    @Test("no heads-up without a countdown the Mac is held on")
    func noHeadsUp() {
        let now = start
        let short = KeepAwakeReading(state: .lease(.until(now.addingTimeInterval(4 * 60))))
        #expect(KeepAwakeHeadsUp.plan(for: short, now: now) == nil, "under the lead")
        for state in [KeepAwakeReading.State.off, .agents(count: 1), .lease(.indefinite),
                      .lease(.agentsFinish), .lease(.whileRunning("swift"))] {
            #expect(KeepAwakeHeadsUp.plan(for: KeepAwakeReading(state: state), now: now) == nil)
        }
        var paused = KeepAwakeReading(state: .lease(.until(now.addingTimeInterval(3600))))
        paused.suspended = "battery"
        #expect(KeepAwakeHeadsUp.plan(for: paused, now: now) == nil)
    }

    @Test("+30 min adds half an hour, inside one lease's day")
    func extendedEnd() {
        let now = start
        let end = now.addingTimeInterval(5 * 60)
        #expect(KeepAwakeHeadsUp.extendedEnd(from: end, now: now) == end.addingTimeInterval(1800))
        let late = now.addingTimeInterval(23.9 * 3600)
        #expect(KeepAwakeHeadsUp.extendedEnd(from: late, now: now) == now.addingTimeInterval(86400))
        let passed = now.addingTimeInterval(-60)
        #expect(KeepAwakeHeadsUp.extendedEnd(from: passed, now: now) == now.addingTimeInterval(1800))
    }

    @Test("a while-this-runs lease reads by its command's name, never its arguments")
    func processLease() throws {
        let json = #"{"state":"manual","active":true,"lease":{"kind":"process","pid":4242,"label":"swift","started_at":1800000000,"until":1800086400}}"#
        let hold = try JSONDecoder().decode(CoreAwakeHold.self, from: Data(json.utf8))
        #expect(hold.lease?.waitsOnProcess == true)
        #expect(hold.lease?.pid == 4242)
        let reading = KeepAwakeReading(hold: hold)
        #expect(reading.state == .lease(.whileRunning("swift")))
        #expect(reading.startedAt == start)
        #expect(reading.footerLine(now: start)?.full == "Awake while swift runs")
        #expect(reading.chipTitle(now: start) == "swift")
        #expect(reading.chipHelp(now: start).hasPrefix("Keeping the Mac awake while swift runs"))
        #expect(reading.leaseInForce)
        #expect(!reading.showsCountdown)
        let unnamed = KeepAwakeReading(hold: try JSONDecoder().decode(
            CoreAwakeHold.self, from: Data(#"{"state":"manual","active":true,"lease":{"kind":"process","pid":9}}"#.utf8)))
        #expect(unnamed.state == .lease(.whileRunning("a command")))
        #expect(unnamed.chipTitle(now: start) == "Awake")
    }

    @Test("the command finishing is said in the release line")
    func exitedRelease() throws {
        var reading = KeepAwakeReading(state: .off)
        reading.timeZone = TimeZone(secondsFromGMT: 0)!
        reading.locale = Locale(identifier: "en_GB")
        reading.lastRelease = try JSONDecoder().decode(
            CorePowerRelease.self, from: Data(#"{"kind":"lease_ended","reason":"exited","at":1800000000}"#.utf8))
        #expect(reading.footerLine(now: start.addingTimeInterval(60))?.full == "Let go at 08:00 · the command finished")
    }

    @Test("the while-this-runs request sends the pid and the name")
    func processRequest() {
        let request = CoreAwakeRequest(.whileRunning(pid: 4242, label: "swift"))
        #expect(request.arguments["pid"] == .number(4242))
        #expect(request.arguments["label"] == .string("swift"))
        #expect(request.arguments["display"] == .bool(false), "the computer, not the display")
    }
}
