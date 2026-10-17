import AppKit
import JRBarCore
import Testing
import os
@testable import JRBarApp

@MainActor
@Suite("Buddy terminal shutdown")
struct BuddyShutdownTests {
    private final class Center: NotificationCenter, @unchecked Sendable {
        private let removed = OSAllocatedUnfairLock(initialState: 0)
        var removals: Int { removed.withLock { $0 } }
        override func removeObserver(_ observer: Any) {
            removed.withLock { $0 += 1 }
            super.removeObserver(observer)
        }
    }

    @Test("normal off remains reopenable; terminal shutdown retires observers exactly once")
    func terminalIsDistinctFromOff() {
        let screens = Center(), workspace = Center()
        let buddy = NotchBuddyToy(core: CoreModel(), notificationCenter: screens, workspaceCenter: workspace)
        var layouts = 0
        buddy.onVisibilityChange = { layouts += 1 }
        buddy.isOn = false
        buddy.isOn = true
        #expect(!buddy.isShutdown)
        #expect(layouts == 2)
        #expect(screens.removals == 0 && workspace.removals == 0)
        buddy.shutdown()
        let dismissals = buddy.panelDismissals
        buddy.shutdown()
        buddy.isOn = true
        buddy.finishTuck()
        buddy.promptRename(near: nil)
        buddy.presentCard(near: nil)
        #expect(buddy.isShutdown && !buddy.isOn)
        #expect(buddy.panelDismissals == dismissals)
        #expect(screens.removals == 1 && workspace.removals == 1)
        #expect(layouts == 2)
        #expect(buddy.livelyUntil == nil)
    }

    @Test("a queued session open cannot run after owner shutdown")
    func queuedOpenIsRetired() async throws {
        let core = CoreModel()
        core.apply(.state(CoreState(sessions: [CoreSession(id: "fixture", provider: "claude", mode: "waiting")])))
        let buddy = NotchBuddyToy(core: core, notificationCenter: Center(), workspaceCenter: Center())
        var opened: [String] = []
        buddy.openSession = { opened.append($0); return nil }
        #expect(buddy.openAskingSession(id: "fixture"))
        let task = try #require(buddy.openInFlight)
        buddy.shutdown()
        await task.value
        #expect(opened.isEmpty)
        #expect(buddy.openInFlight == nil)
        #expect(!buddy.openAskingSession(id: "fixture"))
    }

    @Test("queued document observations cannot publish or re-arm a terminal Buddy")
    func queuedObservationIsRetired() async {
        let core = CoreModel()
        let buddy = NotchBuddyToy(core: core, notificationCenter: Center(), workspaceCenter: Center())
        _ = buddy.sessionDigest()
        core.apply(.state(CoreState(sessions: [CoreSession(id: "fixture", provider: "claude", mode: "working")])))
        buddy.shutdown()
        let version = buddy.digestVersion
        await Task { @MainActor in }.value
        #expect(buddy.digestVersion == version)
        #expect(buddy.sessionDigest().working == 0)
        core.apply(.state(CoreState(sessions: [])))
        await Task { @MainActor in }.value
        #expect(buddy.digestVersion == version)
        #expect(buddy.accessibilityStatus == "Nothing running")
    }
}
