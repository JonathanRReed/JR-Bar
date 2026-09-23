import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The meeting heads-up: which event earns one and when, the watch's
/// single-timer cadence, the island's verb face for it, and a running
/// meeting as a quiet stretch. Events are handed in; no EventKit.
@Suite("Notch meeting heads-up")
@MainActor
struct NotchMeetingTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let zoom = URL(string: "https://www.zoom.us/j/123")!

    private func event(_ title: String, startsIn start: TimeInterval, lasts: TimeInterval = 1800,
                       url: URL? = URL(string: "https://www.zoom.us/j/123")) -> ShelfCalendarModel.Event {
        ShelfCalendarModel.Event(title: title, start: t0.addingTimeInterval(start),
                                 end: t0.addingTimeInterval(start + lasts), url: url)
    }

    @Test("a heads-up lands two minutes out, only for a joinable meeting, and never twice")
    func dueSoon() {
        let standup = event("Standup", startsIn: 100)
        let lunch = event("Lunch", startsIn: 60, url: nil)
        #expect(ShelfMeetingWatch.dueSoon([standup, lunch], now: t0, announced: []) == standup)
        #expect(ShelfMeetingWatch.dueSoon([event("Later", startsIn: 600)], now: t0, announced: []) == nil,
                "ten minutes out is not yet")
        #expect(ShelfMeetingWatch.dueSoon([standup], now: t0,
                                          announced: [ShelfMeetingWatch.key(standup)]) == nil)
        // The Mac woke three minutes into it: nothing is said late.
        #expect(ShelfMeetingWatch.dueSoon([event("Missed", startsIn: -180)], now: t0, announced: []) == nil)
        // The soonest wins when two are due.
        let first = event("First", startsIn: 30)
        #expect(ShelfMeetingWatch.dueSoon([standup, first], now: t0, announced: []) == first)
    }

    @Test("the live meeting is the joinable one running now, the latest to start")
    func live() {
        let long = event("Planning", startsIn: -3000, lasts: 7200)
        let quick = event("Sync", startsIn: -60)
        #expect(ShelfMeetingWatch.live([long, quick], now: t0) == quick)
        #expect(ShelfMeetingWatch.live([event("Focus block", startsIn: -60, url: nil)], now: t0) == nil)
        #expect(ShelfMeetingWatch.live([event("Over", startsIn: -4000, lasts: 1800)], now: t0) == nil)
    }

    @Test("the watch wakes for the next edge — heads-up, start or end — a hair past it")
    func nextWake() {
        let standup = event("Standup", startsIn: 600)
        #expect(ShelfMeetingWatch.nextWake([standup], now: t0) == t0.addingTimeInterval(480.5))
        let running = event("Running", startsIn: -60, lasts: 300)
        #expect(ShelfMeetingWatch.nextWake([running], now: t0) == t0.addingTimeInterval(240.5))
        #expect(ShelfMeetingWatch.nextWake([event("Unjoinable", startsIn: 60, url: nil)], now: t0) == nil)
    }

    @Test("the countdown and the detail line")
    func copy() {
        #expect(ShelfMeetingWatch.countdown(to: t0.addingTimeInterval(110), now: t0) == "in 2 min")
        #expect(ShelfMeetingWatch.countdown(to: t0.addingTimeInterval(45), now: t0) == "in 1 min")
        #expect(ShelfMeetingWatch.countdown(to: t0.addingTimeInterval(20), now: t0) == "now")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let meeting = ShelfCalendarModel.Event(title: "Standup", start: t0, end: t0.addingTimeInterval(1800),
                                               url: zoom)
        let line = ShelfMeetingWatch.detail(meeting, calendar: utc, locale: Locale(identifier: "en_GB"))
        #expect(line.hasSuffix(" · zoom.us"), "the host names where it is, without www")
        #expect(line.contains("–"))
    }

    @Test("a reading says each heads-up once and moves the live meeting")
    func noteOnce() {
        let watch = ShelfMeetingWatch()
        var said: [String] = []
        var lives: [String?] = []
        watch.onSoon = { said.append($0.title) }
        watch.onLiveChange = { lives.append($0?.title) }
        let standup = event("Standup", startsIn: 90)
        watch.note([standup], now: t0)
        watch.note([standup], now: t0.addingTimeInterval(30))
        #expect(said == ["Standup"], "a re-read never repeats a heads-up")
        watch.note([standup], now: t0.addingTimeInterval(120))
        #expect(watch.live == standup)
        watch.note([standup], now: t0.addingTimeInterval(90 + 1800 + 1))
        #expect(watch.live == nil)
        #expect(lives == ["Standup", nil])
    }

    private func makeToy() -> (NotchToy, ToysStore) {
        var toys = ToysState()
        toys.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        toys.notch.meetingAlerts = true
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: toys, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        return (toy, store)
    }

    @Test("the heads-up is a verb capsule about the meeting; off, nothing is said")
    func toyHeadsUp() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        let standup = event("Standup", startsIn: 100)
        toy.noteMeetingSoon(standup)
        #expect(toy.activeCapsule?.kind == .meeting)
        #expect(toy.activeCapsule?.title == "Standup")
        #expect(toy.activeCapsule?.kind.hasVerbs == true, "it wears the verb face, with Join")
        #expect(toy.headsUpMeeting == standup)
        toy.dismissCapsule()

        store.state.notch.meetingAlerts = false
        toy.noteMeetingSoon(event("Retro", startsIn: 100))
        #expect(toy.activeCapsule == nil)
    }

    @Test("a running meeting is a quiet stretch named after it")
    func meetingIsQuiet() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        let standup = event("Standup", startsIn: -60)
        toy.meetingWatch.note([standup], now: t0)
        #expect(toy.quietContext == "Standup")
        toy.offer(AlcoveNotice(id: "c", kind: .completed, title: "Claude · t", subtitle: "finished",
                               session: "claude:c", key: "completed:c"))
        #expect(toy.activeCapsule == nil, "news waits out the meeting")
        toy.meetingWatch.note([standup], now: t0.addingTimeInterval(1800))
        #expect(toy.capsuleQueue.current?.title == "While you were in Standup")
    }

    @Test("a meeting's heads-up is never held, and old settings default it off")
    func notHeldAndOptIn() throws {
        #expect(!AlcoveCapsuleQueue.holdsWhileQuiet(.meeting))
        let settings = try JSONDecoder().decode(NotchSettings.self, from: Data("{}".utf8))
        #expect(settings.meetingAlerts == false)
    }
}
