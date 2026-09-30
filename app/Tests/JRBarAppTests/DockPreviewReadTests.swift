import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The hover previews' window read behind the switcher's hung-app backoff.
/// A stub reader stands in for Accessibility and the clock is an argument,
/// so nothing here touches AX or waits.
@MainActor
@Suite("Dock preview read")
struct DockPreviewReadTests {
    /// A reader that counts its calls and answers as told, by pid.
    private final class Reads {
        var asked: [pid_t] = []
        var hung: Set<pid_t> = []
        func read(_ pid: pid_t) -> (windows: [DockPreviewWindow], unresponsive: Bool) {
            asked.append(pid)
            if hung.contains(pid) { return ([], true) }
            return ([card(id: Int(pid) * 10, title: "Window of \(pid)")], false)
        }
    }

    nonisolated private static func card(id: Int, title: String) -> DockPreviewWindow {
        DockPreviewWindow(id: id, title: title, minimized: false, fullScreen: nil,
                          frame: nil, thumbnail: nil, element: nil, windowID: CGWindowID(id))
    }

    private func answered(_ read: DockPreviewRead) -> [String]? {
        read.answered?.map(\.title)
    }

    @Test("a hung app is asked once, skipped inside the backoff, and asked again after")
    func hungAppRests() {
        let reads = Reads()
        reads.hung = [7]
        var backoff = DockAXBackoff()
        let first = DockPreviewRead.read(pid: 7, backoff: &backoff, now: 100, reader: reads.read)
        guard case .unresponsive = first else {
            Issue.record("the hung read should report unresponsive")
            return
        }
        #expect(reads.asked == [7])
        let second = DockPreviewRead.read(pid: 7, backoff: &backoff, now: 105, reader: reads.read)
        guard case .skipped = second else {
            Issue.record("inside the backoff the pid should be skipped")
            return
        }
        #expect(reads.asked == [7], "no second wait: the reader was not asked")
        let third = DockPreviewRead.read(pid: 7, backoff: &backoff,
                                         now: 100 + DockAXBackoff.backoff + 0.1, reader: reads.read)
        guard case .unresponsive = third else {
            Issue.record("after the backoff it should be asked again")
            return
        }
        #expect(reads.asked == [7, 7])
    }

    @Test("an answered read clears the pid, and only the hung pid is skipped")
    func answerClearsAndOnlyTheHungRest() {
        let reads = Reads()
        reads.hung = [7]
        var backoff = DockAXBackoff()
        _ = DockPreviewRead.read(pid: 7, backoff: &backoff, now: 100, reader: reads.read)
        let other = DockPreviewRead.read(pid: 8, backoff: &backoff, now: 101, reader: reads.read)
        #expect(answered(other) == ["Window of 8"], "another app is asked as usual")
        // It recovers and answers once its rest is over, which clears it.
        reads.hung = []
        let later = 100 + DockAXBackoff.backoff + 1
        let recovered = DockPreviewRead.read(pid: 7, backoff: &backoff, now: later, reader: reads.read)
        #expect(answered(recovered) == ["Window of 7"])
        let again = DockPreviewRead.read(pid: 7, backoff: &backoff, now: later + 0.1, reader: reads.read)
        #expect(answered(again) == ["Window of 7"], "an answer cleared the pid")
    }

    @Test("a genuinely empty answer is an answer, not a hang")
    func emptyIsAnAnswer() {
        var backoff = DockAXBackoff()
        let read = DockPreviewRead.read(pid: 3, backoff: &backoff, now: 10) { _ in ([], false) }
        #expect(answered(read) == [])
        #expect(!backoff.skips(3, now: 10.1))
    }

    @Test("the hover read and the switcher share one backoff, both ways")
    func backoffIsShared() {
        let controller = DockSwitcherController(tap: SwitcherKeyTap())
        let reads = Reads()
        // A hang the ⌥⇥ strip saw is skipped by the hover read.
        controller.noteAX(7, unresponsive: true, now: 100)
        let skipped = controller.readWindows(pid: 7, now: 101, reader: reads.read)
        guard case .skipped = skipped else {
            Issue.record("the strip's hang should spare the hover read")
            return
        }
        #expect(reads.asked.isEmpty)
        // A hang the hover read saw is seen by the strip's side.
        reads.hung = [9]
        _ = controller.readWindows(pid: 9, now: 200, reader: reads.read)
        #expect(controller.axSkips(9, now: 201))
        #expect(!controller.axSkips(9, now: 200 + DockAXBackoff.backoff + 0.1))
        #expect(!controller.axSkips(8, now: 201), "only the pid that hung")
    }

    @Test("a worker's finished read is an answer, or the timeout — an empty list is still an answer")
    func readingBecomesARead() {
        let hung = DockPreviewRead(([], true))
        guard case .unresponsive = hung else {
            Issue.record("a lapsed timeout is unresponsive, whatever windows came with it")
            return
        }
        #expect(answered(DockPreviewRead(([Self.card(id: 1, title: "One")], false))) == ["One"])
        #expect(answered(DockPreviewRead(([], false))) == [], "nothing open is an answer, not a hang")
        #expect(answered(hung) == nil)
    }

    // MARK: A minimized tile's owner

    private func row(_ pid: pid_t, _ windowID: CGWindowID, _ title: String) -> SwitcherWindowRow {
        SwitcherWindowRow(pid: pid, windowID: windowID, title: title,
                          bounds: CGRect(x: 0, y: 0, width: 300, height: 200), onScreen: false)
    }

    /// A window the way AX lists it for a row: the same native id.
    nonisolated private static func parked(_ windowID: CGWindowID, minimized: Bool) -> DockPreviewWindow {
        DockPreviewWindow(id: Int(windowID), title: "Draft", minimized: minimized, fullScreen: nil,
                          frame: CGRect(x: 0, y: 0, width: 300, height: 200), thumbnail: nil,
                          element: nil, windowID: windowID)
    }

    /// A reader over fixed lists that counts what it was asked.
    private final class Lists {
        var asked: [pid_t] = []
        var lists: [pid_t: [DockPreviewWindow]] = [:]
        var hung: Set<pid_t> = []
        func read(_ pid: pid_t) -> (windows: [DockPreviewWindow], unresponsive: Bool) {
            asked.append(pid)
            return hung.contains(pid) ? ([], true) : (lists[pid] ?? [], false)
        }
    }

    @Test("a title one app claims is that app's, read once, and its list comes back with the answer")
    func minimizedSoleClaimant() {
        let lists = Lists()
        lists.lists[7] = [Self.parked(70, minimized: true)]
        let read = DockMinimizedRead.read(title: "Draft", rows: [row(7, 70, "Draft"), row(8, 80, "Other")],
                                          resting: [], reader: lists.read)
        #expect(read.owner == 7)
        #expect(lists.asked == [7], "one read for the owner's list, none for the check")
        #expect(read.windows.map(\.windowID) == [70])
        #expect(read.answered == [7] && read.unresponsive.isEmpty)
    }

    @Test("two apps claim a title: each is asked once, and the one whose window is minimized owns it")
    func minimizedSharedTitle() {
        let lists = Lists()
        lists.lists[7] = [Self.parked(70, minimized: true)]
        lists.lists[8] = [Self.parked(80, minimized: false)]
        let read = DockMinimizedRead.read(title: "Draft", rows: [row(7, 70, "Draft"), row(8, 80, "Draft")],
                                          resting: [], reader: lists.read)
        #expect(read.owner == 7)
        #expect(lists.asked.sorted() == [7, 8], "the owner's list was kept, not read a second time")
        #expect(read.answered == [7, 8])
    }

    @Test("a resting app is not asked and reads as having no windows")
    func minimizedRestingIsNotAsked() {
        let lists = Lists()
        lists.lists[7] = [Self.parked(70, minimized: true)]
        let read = DockMinimizedRead.read(title: "Draft", rows: [row(7, 70, "Draft"), row(8, 80, "Draft")],
                                          resting: [8], reader: lists.read)
        #expect(lists.asked == [7], "pid 8 rests")
        #expect(read.owner == 7, "the one app that could answer is the owner")
        #expect(read.answered == [7] && read.unresponsive.isEmpty, "a skipped app is neither noted")
    }

    @Test("an app that did not answer is reported, and names no owner on its own say-so")
    func minimizedHungClaimant() {
        let lists = Lists()
        lists.hung = [7]
        lists.lists[8] = [Self.parked(80, minimized: false)]
        let read = DockMinimizedRead.read(title: "Draft", rows: [row(7, 70, "Draft"), row(8, 80, "Draft")],
                                          resting: [], reader: lists.read)
        #expect(read.owner == nil, "no list shows a minimized window: real ambiguity, the card stays tile-backed")
        #expect(read.unresponsive == [7] && read.answered == [8])
        #expect(read.windows.isEmpty)
    }

    @Test("a title no window claims has no owner and reads nothing")
    func minimizedNoClaimant() {
        let lists = Lists()
        let read = DockMinimizedRead.read(title: "Gone", rows: [row(7, 70, "Draft")], resting: [],
                                          reader: lists.read)
        #expect(read.owner == nil && read.windows.isEmpty)
        #expect(lists.asked.isEmpty)
    }

    // MARK: One live refresh at a time

    @Test("one live refresh reads at a time; every burst while it does folds into one re-run")
    func refreshGateFoldsBursts() {
        var gate = DockLiveRefreshGate()
        let first = gate.request(force: false)
        #expect(first, "the first ask starts a read")
        #expect(gate.inFlight)
        let second = gate.request(force: false)
        let third = gate.request(force: false)
        #expect(!second && !third, "a burst mid-read starts none")
        let rerun = gate.finish()
        #expect(rerun == DockLiveRefreshGate.Rerun(force: false), "one re-run for all of them")
        #expect(!gate.inFlight)
        let again = gate.request(force: false)
        #expect(again, "the re-run asks as a fresh request")
        let none = gate.finish()
        #expect(none == nil, "no burst, no re-run")
    }

    @Test("a forced ask folded into the re-run keeps its force")
    func refreshGateKeepsForce() {
        var gate = DockLiveRefreshGate()
        _ = gate.request(force: false)
        _ = gate.request(force: true)
        _ = gate.request(force: false)
        let rerun = gate.finish()
        #expect(rerun == DockLiveRefreshGate.Rerun(force: true))
        let after = gate.finish()
        #expect(after == nil, "a re-run is asked for once")
    }
}
