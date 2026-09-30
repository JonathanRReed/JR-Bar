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
}
