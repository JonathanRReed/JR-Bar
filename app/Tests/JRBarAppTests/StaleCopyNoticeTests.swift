import Foundation
import Testing
@testable import JRBarApp

/// The second-install notice is marked as told only once the panel has
/// shown it, so a notice held for a panel that never opened is not lost.
@Suite("Stale copy notice")
@MainActor
struct StaleCopyNoticeTests {
    @Test("the told mark waits for the panel to show the notice")
    func markedWhenShown() throws {
        let suite = ScratchDefaults.suiteName("jrbar.tests.stale-copy")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let copy = URL(fileURLWithPath: "/Applications/JR-Bar.app.bak-20260921-105351")
        let home = URL(fileURLWithPath: "/Users/someone")
        let key = InstalledCopies.noticedKey(copy)

        let notices = LaunchNotices()
        var shown: [String] = []
        notices.showToast = { shown.append($0.key) }
        notices.say(InstalledCopies.notice(for: copy, home: home, defaults: defaults))
        #expect(notices.waiting.map(\.key) == ["stale-copy"], "held while the panel is shut")
        #expect(!defaults.bool(forKey: key), "queued is not told: the app may quit before the panel opens")

        notices.panelOpened()
        #expect(shown == ["stale-copy"])
        #expect(defaults.bool(forKey: key), "told once the panel showed it")
    }

    @Test("on an open panel it is told at once")
    func openPanelTellsAtOnce() throws {
        let suite = ScratchDefaults.suiteName("jrbar.tests.stale-copy-open")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let copy = URL(fileURLWithPath: "/Applications/JR-Bar 2.app")
        let notices = LaunchNotices()
        notices.panelIsOpen = { true }
        notices.showToast = { _ in }
        notices.say(InstalledCopies.notice(for: copy, home: URL(fileURLWithPath: "/Users/someone"), defaults: defaults))
        #expect(defaults.bool(forKey: InstalledCopies.noticedKey(copy)))
        #expect(notices.waiting.isEmpty)
    }
}
