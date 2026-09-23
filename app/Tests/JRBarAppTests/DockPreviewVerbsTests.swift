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
}
