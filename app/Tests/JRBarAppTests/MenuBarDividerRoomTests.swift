import CoreGraphics
import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// Whether the divider has room on this bar, and what a crowded bar
/// costs. Every case is a pure table over injected inputs and a
/// hand-cranked clock.
@Suite("Menu Bar — the divider's room")
struct MenuBarDividerRoomTests {
    @Test("an icon that holds the row for a few seconds means the divider has room")
    func roomHolds() {
        var watch = MenuBarDividerRoomWatch()
        #expect(watch.room == .unknown)
        watch.note(iconOnRow: true, spacerIsMinimal: false, now: 0)
        #expect(watch.room == .unknown)
        watch.note(iconOnRow: true, spacerIsMinimal: false, now: 2.9)
        #expect(watch.room == .unknown)
        watch.note(iconOnRow: true, spacerIsMinimal: false, now: 3)
        #expect(watch.room == .holds)
    }

    @Test("an icon macOS parks with no spacer to blame means no room")
    func roomMissing() {
        var watch = MenuBarDividerRoomWatch()
        watch.note(iconOnRow: false, spacerIsMinimal: true, now: 0)
        watch.note(iconOnRow: false, spacerIsMinimal: true, now: 7.9)
        #expect(watch.room == .unknown)
        watch.note(iconOnRow: false, spacerIsMinimal: true, now: 8)
        #expect(watch.room == .noRoom)
        // It comes back and stays: the verdict follows.
        watch.note(iconOnRow: true, spacerIsMinimal: true, now: 9)
        watch.note(iconOnRow: true, spacerIsMinimal: true, now: 12)
        #expect(watch.room == .holds)
    }

    @Test("an icon parked under a long spacer is the cap's business, not a verdict")
    func roomParkedUnderSpacer() {
        var watch = MenuBarDividerRoomWatch()
        for t in stride(from: 0.0, through: 30, by: 1) {
            watch.note(iconOnRow: false, spacerIsMinimal: false, now: t)
        }
        #expect(watch.room == .unknown)
    }

    @Test("three parked lessons inside a minute mean no room; spread out they do not")
    func roomLessons() {
        var tight = MenuBarDividerRoomWatch()
        tight.noteParkedLesson(now: 0)
        tight.noteParkedLesson(now: 20)
        #expect(tight.room == .unknown)
        tight.noteParkedLesson(now: 40)
        #expect(tight.room == .noRoom)
        var spread = MenuBarDividerRoomWatch()
        for t in [0.0, 50, 110, 170] { spread.noteParkedLesson(now: t) }
        #expect(spread.room == .unknown)
        tight.reset()
        #expect(tight.room == .unknown)
    }

    // MARK: What a crowded bar costs

    @Test("the fewest items that free the icon's seat go first, widest first")
    func itemsToFree() {
        // The icon wants 24 + 8 = 32 pt.
        #expect(MenuBarRoomHelp.itemsToFree(widths: [26, 34, 40, 22], need: 32) == 1)
        #expect(MenuBarRoomHelp.itemsToFree(widths: [26, 22, 20], need: 60) == 3)
        #expect(MenuBarRoomHelp.itemsToFree(widths: [26, 22], need: 200) == 2,
                "even all of them would not seat it: say all of them")
        #expect(MenuBarRoomHelp.itemsToFree(widths: [], need: 32) == 0)
        #expect(MenuBarRoomHelp.itemsToFree(widths: [0, 0, 30], need: 32) == 1,
                "a zero-width entry frees nothing")
    }

    @Test("the help line counts the overflow and the items to remove, in plain words")
    func helpLine() {
        #expect(MenuBarRoomHelp.line(parked: 0, remove: 1)
                == "Quit or switch off at least 1 menu bar item to give the JR-Bar icon a place.")
        #expect(MenuBarRoomHelp.line(parked: 1, remove: 2)
                == "macOS is holding 1 item in its « overflow. Quit or switch off at least 2 menu bar items to give the JR-Bar icon a place.")
        #expect(MenuBarRoomHelp.line(parked: 7, remove: 1).hasPrefix("macOS is holding 7 items in its « overflow."))
    }
}
