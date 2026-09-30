import Foundation
import Testing
@testable import JRBarApp

/// The Screen Bar's two stores (the app's remembered visibility and the
/// daemon's `virtual_status_device_enabled`) and how they are brought
/// back into step. Every clock is passed in.
@Suite("Screen Bar daemon sync")
struct ScreenBarDaemonSyncTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func later(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    // MARK: A choice made while the daemon is down

    @Test("a toggle made while the daemon was down is pushed on reconnect, not undone")
    func offlineToggleSurvivesReconnect() {
        var sync = ScreenBarDaemonSync()
        sync.toggled(shown: false, live: false, now: start)
        let first = sync.reconcile(live: true, daemonValue: true, appValue: false, now: later(3))
        #expect(first == .push(false))
    }

    @Test("the offline choice is spent once and does not stick")
    func offlineChoiceIsSpentOnce() {
        var sync = ScreenBarDaemonSync()
        sync.toggled(shown: false, live: false, now: start)
        _ = sync.reconcile(live: true, daemonValue: true, appValue: false, now: later(3))
        let echoed = sync.reconcile(live: true, daemonValue: false, appValue: false, now: later(4))
        #expect(echoed == .agree)
        let elsewhere = sync.reconcile(live: true, daemonValue: true, appValue: false, now: later(60))
        #expect(elsewhere == .adopt(true), "a change made elsewhere later is followed as usual")
    }

    @Test("the offline choice outlives every pass while the daemon is still down")
    func offlineChoiceOutlivesDisconnectedPasses() {
        var sync = ScreenBarDaemonSync()
        sync.toggled(shown: false, live: false, now: start)
        let down = sync.reconcile(live: false, daemonValue: true, appValue: false, now: later(1))
        let stillDown = sync.reconcile(live: false, daemonValue: true, appValue: false, now: later(2))
        #expect(down == .none)
        #expect(stillDown == .none)
        #expect(sync.changedOffline)
        let back = sync.reconcile(live: true, daemonValue: true, appValue: false, now: later(5))
        #expect(back == .push(false))
    }

    @Test("a click while connected supersedes an earlier offline click")
    func liveToggleClearsTheOfflineFlag() {
        var sync = ScreenBarDaemonSync()
        sync.toggled(shown: false, live: false, now: start)
        sync.toggled(shown: false, live: true, now: later(1))
        #expect(!sync.changedOffline)
        let inside = sync.reconcile(live: true, daemonValue: true, appValue: false, now: later(2))
        #expect(inside == .wait, "our own write is still landing")
        let after = sync.reconcile(live: true, daemonValue: true, appValue: false, now: later(30))
        #expect(after == .adopt(true), "never a stale push")
    }

    @Test("an offline toggle that ends where the daemon already is sends nothing")
    func offlineRoundTripAgrees() {
        var sync = ScreenBarDaemonSync()
        sync.toggled(shown: false, live: false, now: start)
        sync.toggled(shown: true, live: false, now: later(1))
        let decision = sync.reconcile(live: true, daemonValue: true, appValue: true, now: later(2))
        #expect(decision == .agree)
        #expect(!sync.changedOffline, "the flag is spent even when nothing needed sending")
    }

    @Test("an offline choice with no settings document pushes the app's value once")
    func offlineChoiceWithNoDocument() {
        var sync = ScreenBarDaemonSync()
        sync.toggled(shown: false, live: false, now: start)
        let first = sync.reconcile(live: true, daemonValue: nil, appValue: false, now: later(1))
        #expect(first == .push(false))
        let second = sync.reconcile(live: true, daemonValue: nil, appValue: false, now: later(2))
        #expect(second == .none)
    }

    @Test("a write lost to a dropped connection is kept as an offline choice")
    func lostWriteIsKept() {
        var sync = ScreenBarDaemonSync()
        sync.toggled(shown: false, live: true, now: start)
        #expect(sync.pending?.value == false)
        sync.pushLostOffline()
        #expect(sync.pending == nil)
        let down = sync.reconcile(live: false, daemonValue: true, appValue: false, now: later(1))
        #expect(down == .none)
        let back = sync.reconcile(live: true, daemonValue: true, appValue: false, now: later(4))
        #expect(back == .push(false))
    }

    // MARK: What was already true

    @Test("matching values agree and clear a matching pending write")
    func matchClearsPending() {
        var sync = ScreenBarDaemonSync()
        sync.toggled(shown: false, live: true, now: start)
        let echo = sync.reconcile(live: true, daemonValue: false, appValue: false, now: later(1))
        #expect(echo == .agree)
        #expect(sync.pending == nil)
        #expect(sync.synced)
    }

    @Test("a mismatch with no write of ours in flight is the daemon's newer choice")
    func mismatchAdopts() {
        var sync = ScreenBarDaemonSync()
        let decision = sync.reconcile(live: true, daemonValue: true, appValue: false, now: start)
        #expect(decision == .adopt(true))
        #expect(sync.synced)
    }

    @Test("a mismatch waits out the pending window, then follows the daemon")
    func pendingWindowEdges() {
        var sync = ScreenBarDaemonSync()
        sync.toggled(shown: false, live: true, now: start)
        let nearly = sync.reconcile(live: true, daemonValue: true, appValue: false, now: later(9.9))
        #expect(nearly == .wait)
        let exactly = sync.reconcile(live: true, daemonValue: true, appValue: false, now: later(10))
        #expect(exactly == .adopt(true))

        var slower = ScreenBarDaemonSync()
        slower.toggled(shown: false, live: true, now: start)
        let well = slower.reconcile(live: true, daemonValue: true, appValue: false, now: later(45))
        #expect(well == .adopt(true))
    }

    @Test("with no settings document the app's value is pushed once, on first contact")
    func noDocumentPushesOnce() {
        var sync = ScreenBarDaemonSync()
        let first = sync.reconcile(live: true, daemonValue: nil, appValue: true, now: start)
        #expect(first == .push(true))
        let second = sync.reconcile(live: true, daemonValue: nil, appValue: true, now: later(1))
        #expect(second == .none)
    }

    @Test("not connected decides nothing and forgets what was synced or in flight")
    func disconnectedResets() {
        var sync = ScreenBarDaemonSync()
        sync.toggled(shown: true, live: true, now: start)
        _ = sync.reconcile(live: true, daemonValue: true, appValue: true, now: later(1))
        #expect(sync.synced)
        let decision = sync.reconcile(live: false, daemonValue: nil, appValue: true, now: later(2))
        #expect(decision == .none)
        #expect(!sync.synced)
        #expect(sync.pending == nil)
        let again = sync.reconcile(live: true, daemonValue: nil, appValue: true, now: later(3))
        #expect(again == .push(true), "first contact after a reconnect pushes again")
    }

    @Test("a refused write is no longer in flight, so the next mismatch is followed")
    func refusedWriteAdopts() {
        var sync = ScreenBarDaemonSync()
        sync.toggled(shown: false, live: true, now: start)
        sync.pushRefused()
        #expect(sync.pending == nil)
        let decision = sync.reconcile(live: true, daemonValue: true, appValue: false, now: later(1))
        #expect(decision == .adopt(true))
    }
}
