import Foundation
import JRBarCore
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Buddy control power")
@MainActor
struct BuddyControlPowerTests {
    private let start = Date(timeIntervalSince1970: 2_000)
    private let restrained = [PowerPolicy(lowPowerMode: true), PowerPolicy(thermal: .serious)]

    @Test("only the hovered roster tile runs, at thirty frames per second at normal power")
    func rosterAtNormalPower() {
        for character in BuddyCharacter.allCases {
            let pacing = BuddyRosterPaces.paces(character, hovered: .cat, reduceMotion: false)
            let clock = BuddyRosterPaces.clock(pacing: pacing, power: .normal)
            #expect(clock.interval == 1.0 / 30.0)
            #expect(clock.paused == (character != .cat))
        }
    }

    @Test("the hovered roster tile halves its frame rate under restraint and stands still at critical heat")
    func rosterUnderPressure() {
        for power in restrained {
            let clock = BuddyRosterPaces.clock(pacing: true, power: power)
            #expect(clock.interval == 1.0 / 15.0)
            #expect(!clock.paused)
            #expect(BuddyRosterPaces.clock(pacing: false, power: power).paused)
        }
        #expect(BuddyRosterPaces.clock(pacing: true, power: PowerPolicy(thermal: .critical)).paused)
        let pacing = BuddyRosterPaces.paces(.cat, hovered: .cat, reduceMotion: true)
        #expect(BuddyRosterPaces.clock(pacing: pacing, power: .normal).paused)
    }

    @Test("a throttled treat burst still finishes on time and asks for fewer frames")
    func treatBurstUnderPressure() {
        let end = start.addingTimeInterval(BuddyBurstSchedule.span)
        let normal = frames(BuddyBurstSchedule(end: end))
        for power in restrained {
            let schedule = BuddyBurstSchedule(end: end, power: power)
            let throttled = frames(schedule)
            #expect(schedule.interval == 1.0 / 30.0)
            #expect(throttled.first == start)
            #expect(throttled.last == end)
            #expect(throttled.count < normal.count)
            #expect(abs(Double(throttled.count) - Double(normal.count) / 2) <= 2)
        }
    }

    @Test("critical heat and Reduce Motion stop treat decoration and idle cards remain still")
    func treatBurstPauses() {
        let end = start.addingTimeInterval(BuddyBurstSchedule.span)
        for power in [PowerPolicy.normal] + restrained + [PowerPolicy(thermal: .critical)] {
            #expect(frames(BuddyBurstSchedule(end: nil, power: power)) == [start])
            let reduced = BuddyBurstSchedule(end: end, reduceMotion: true, power: power)
            #expect(reduced.end == nil)
            #expect(frames(reduced) == [start])
        }
        let critical = BuddyBurstSchedule(end: end, power: PowerPolicy(thermal: .critical))
        #expect(critical.end == nil)
        #expect(frames(critical) == [start])
    }

    @Test("cooling restores the hovered roster and only the remaining treat burst")
    func controlsRecover() {
        var power = PowerPolicy(thermal: .critical)
        let end = start.addingTimeInterval(BuddyBurstSchedule.span)
        #expect(BuddyRosterPaces.clock(pacing: true, power: power).paused)
        #expect(BuddyBurstSchedule(end: end, power: power).end == nil)
        power.thermal = .nominal
        let clock = BuddyRosterPaces.clock(pacing: true, power: power)
        #expect(!clock.paused)
        #expect(clock.interval == 1.0 / 30.0)
        let schedule = BuddyBurstSchedule(end: end, power: power)
        let halfway = start.addingTimeInterval(BuddyBurstSchedule.span / 2)
        let remaining = Array(schedule.entries(from: halfway, mode: .normal).prefix(1_000))
        #expect(remaining.first == halfway)
        #expect(remaining.last == end)
        #expect(Array(schedule.entries(from: end, mode: .normal)) == [end])
    }

    private func frames(_ schedule: BuddyBurstSchedule) -> [Date] {
        Array(schedule.entries(from: start, mode: .normal).prefix(1_000))
    }
}
