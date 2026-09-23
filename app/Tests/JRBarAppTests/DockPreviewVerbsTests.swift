import AppKit
import Foundation
import Testing
@testable import JRBarApp

/// The preview's window and app verbs: where New presses, and where
/// Center, Fill and Move To put a window.
struct DockPreviewVerbsTests {
    private typealias Item = AppleDockReader.MenuItemFacts

    @Test("New presses the app's own New Window item before any ⌘N")
    func newWindowByTitle() {
        let items = [
            Item(title: "New Tab", cmdChar: "T", cmdModifiers: 0, enabled: true),
            Item(title: "New Document", cmdChar: "N", cmdModifiers: 0, enabled: true),
            Item(title: "New Window", cmdChar: "N", cmdModifiers: 1, enabled: true),
        ]
        #expect(AppleDockReader.newWindowItemIndex(items) == 2,
                "the titled item wins even when ⌘N means New Document")
    }

    @Test("without a titled item, the leaf the app binds to plain ⌘N; submenus and disabled items never")
    func newWindowByShortcut() {
        let items = [
            Item(title: "New Window", cmdChar: nil, cmdModifiers: nil, enabled: true, hasSubmenu: true),
            Item(title: "New Window…", cmdChar: nil, cmdModifiers: nil, enabled: false),
            Item(title: "New Window with Profile - Basic", cmdChar: "N", cmdModifiers: 0, enabled: true),
            Item(title: "New Tab", cmdChar: "N", cmdModifiers: 2, enabled: true),
        ]
        #expect(AppleDockReader.newWindowItemIndex(items) == 2)
        #expect(AppleDockReader.newWindowItemIndex([
            Item(title: "Open…", cmdChar: "O", cmdModifiers: 0, enabled: true),
        ]) == nil, "nothing to press — the caller falls back to posting ⌘N")
        #expect(AppleDockReader.newWindowItemIndex([
            Item(title: "new window…", cmdChar: nil, cmdModifiers: nil, enabled: true),
        ]) == 0, "an ellipsis or case doesn't hide the title")
    }

    @Test("Center is two-thirds and centred, Fill is the visible frame")
    func centerAndFill() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        #expect(DockEnhanceMath.tileFrame(.fill, in: visible) == visible)
        let center = DockEnhanceMath.tileFrame(.center, in: visible)
        #expect(center.width == 960 && center.height == 583)
        #expect(abs(center.midX - visible.midX) < 1 && abs(center.midY - visible.midY) < 1)
    }

    @Test("the Now Playing row follows the app the source names — any app, not a fixed list")
    func mediaRowOwner() {
        #expect(DockEnhanceMath.showsMediaRow(mediaBundleID: "com.apple.Safari", appBundleID: "com.apple.Safari"),
                "a browser playing a video gets transport on its tile")
        #expect(!DockEnhanceMath.showsMediaRow(mediaBundleID: "com.spotify.client", appBundleID: "com.apple.Music"),
                "a track from another app never lands here")
        #expect(DockEnhanceMath.showsMediaRow(mediaBundleID: nil, appBundleID: "com.apple.Music"),
                "an anonymous source still lands on a known player")
        #expect(!DockEnhanceMath.showsMediaRow(mediaBundleID: nil, appBundleID: "com.apple.Safari"))
        #expect(DockEnhanceMath.readsMedia(appBundleID: "com.apple.Music", feedRunning: false))
        #expect(!DockEnhanceMath.readsMedia(appBundleID: "com.apple.Safari", feedRunning: false),
                "a hover never spawns the media helper to check a browser")
        #expect(DockEnhanceMath.readsMedia(appBundleID: "com.apple.Safari", feedRunning: true))
    }

    @Test("the scrubber prints playheads the way players do")
    func clock() {
        #expect(DockEnhanceMath.clock(0) == "0:00")
        #expect(DockEnhanceMath.clock(187.9) == "3:07")
        #expect(DockEnhanceMath.clock(3765) == "1:02:45")
        #expect(DockEnhanceMath.clock(.nan) == "0:00")
    }

    @Test("Move To keeps the size, clamps it to the target, and centres it there")
    func moveToDisplay() {
        let target = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let moved = DockEnhanceMath.moveFrame(CGRect(x: 100, y: 100, width: 800, height: 600), to: target)
        #expect(moved == CGRect(x: 2000, y: 227.5, width: 800, height: 600))
        let huge = DockEnhanceMath.moveFrame(CGRect(x: 0, y: 0, width: 3000, height: 2000), to: target)
        #expect(huge == target, "a window bigger than the screen lands fitted")
    }

    @Test("⌥-click keeps the preview up; plain, ⌘ and ⌃ clicks don't")
    func keepOpen() {
        #expect(DockEnhanceMath.keepsPanelOpen(.option))
        #expect(DockEnhanceMath.keepsPanelOpen([.option, .shift]))
        #expect(!DockEnhanceMath.keepsPanelOpen([]))
        #expect(!DockEnhanceMath.keepsPanelOpen([.option, .command]))
        #expect(!DockEnhanceMath.keepsPanelOpen(.control))
    }

    // MARK: Calendar glance

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-09-23 at `hour`:`minute` UTC.
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 23) -> Date {
        Self.utc.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func event(_ title: String, _ start: Date, minutes: Double = 30,
                       url: String? = nil) -> ShelfCalendarModel.Event {
        ShelfCalendarModel.Event(title: title, start: start, end: start.addingTimeInterval(minutes * 60),
                                 url: url.flatMap(URL.init(string:)))
    }

    @Test("the Calendar tile shows the rest of today, three at most, and when you're free")
    func calendarGlance() {
        let events = [event("Standup", at(9)), event("Review", at(14)), event("1:1", at(15)),
                      event("Retro", at(16)), event("Late", at(17))]
        let morning = DockEnhanceMath.calendarGlance(events, now: at(11), calendar: Self.utc)
        #expect(morning.events.map(\.title) == ["Review", "1:1", "Retro"], "past events drop, three at most")
        #expect(morning.freeUntil == at(14), "nothing on now — free until the next one")
        let busy = DockEnhanceMath.calendarGlance(events, now: at(9, 10), calendar: Self.utc)
        #expect(busy.events.first?.title == "Standup", "what's on now leads")
        #expect(busy.freeUntil == nil, "no free line while something is on")
        let evening = DockEnhanceMath.calendarGlance(
            [event("Tomorrow", at(9, day: 24))], now: at(20), calendar: Self.utc)
        #expect(evening.events.map(\.title) == ["Tomorrow"], "after the last one, the next inside 24 h")
        #expect(evening.freeUntil == nil)
        #expect(DockEnhanceMath.calendarGlance([], now: at(11), calendar: Self.utc).events.isEmpty)
    }

    @Test("a meeting app's tile offers Join only on the event whose link it opens")
    func meetingTiles() {
        #expect(DockEnhanceMath.meetingBundleIDs(for: URL(string: "https://us02web.zoom.us/j/123")) == ["us.zoom.xos"])
        #expect(DockEnhanceMath.meetingBundleIDs(for: URL(string: "https://notzoom.us/j/1")).isEmpty,
                "a lookalike host is not Zoom's")
        #expect(DockEnhanceMath.meetingBundleIDs(for: URL(string: "https://teams.microsoft.com/l/x"))
                .contains("com.microsoft.teams2"))
        #expect(DockEnhanceMath.meetingBundleIDs(for: nil).isEmpty)
        #expect(DockEnhanceMath.isMeetingApp("us.zoom.xos"))
        #expect(!DockEnhanceMath.isMeetingApp("com.apple.Safari"))
        let events = [event("Planning", at(14), url: "https://meet.google.com/abc"),
                      event("Sync", at(15), url: "https://acme.zoom.us/j/9")]
        #expect(DockEnhanceMath.meetingEvent(for: "us.zoom.xos", in: events, now: at(11),
                                             calendar: Self.utc)?.title == "Sync")
        #expect(DockEnhanceMath.meetingEvent(for: "com.apple.FaceTime", in: events, now: at(11),
                                             calendar: Self.utc) == nil)
    }
}
