import Foundation
import Testing
@testable import JRBarApp

/// Following Alcove's capsule is opt-in by the renderer pick: the
/// setting alone never starts the window-list poll while JR-Bar draws
/// the notch.
@Suite("Alcove follower opt-in")
@MainActor
struct AlcoveFollowerTests {
    @Test("the setting alone does not follow; naming Alcove the renderer does")
    func optIn() {
        let before = AlcoveFollower.rendererChosen
        defer { AlcoveFollower.noteRenderer(chosen: before) }
        AlcoveFollower.noteRenderer(chosen: false)
        let follower = AlcoveFollower()
        follower.enabled = true
        #expect(!follower.isPolling, "JR-Bar draws the notch: no poll")
        #expect(follower.statusDescription == "off (JR-Bar draws the notch)")
        follower.enabled = false
        #expect(follower.statusDescription == "off")

        // The post is synchronous on this (main) thread, so the box is
        // only ever touched here.
        final class Heard: @unchecked Sendable { var count = 0 }
        let heard = Heard()
        let token = NotificationCenter.default.addObserver(
            forName: AlcoveFollower.rendererChangedNotification, object: nil, queue: nil) { _ in heard.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        AlcoveFollower.noteRenderer(chosen: true)
        AlcoveFollower.noteRenderer(chosen: true)
        #expect(heard.count == 1, "only a change is announced")
        #expect(AlcoveFollower.rendererChosen)
    }
}
