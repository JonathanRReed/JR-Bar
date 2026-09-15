import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The Replace bar's ordering contract (docs/TOY-PARITY.md P1): pins
/// first in pin order, running apps after, deduped by bundle id — a
/// running pin is one tile, not two. Pin edits and the Apple-Dock seed
/// report out through the persist callbacks.
@MainActor
@Suite struct DockModelTests {

    private func pin(_ id: String) -> DockItem {
        DockItem(bundleID: id, name: id, bundleURL: nil,
                 isRunning: false, isPinned: true, processIdentifier: nil)
    }

    private func run(_ id: String, pid: pid_t = 1) -> DockItem {
        DockItem(bundleID: id, name: id, bundleURL: nil,
                 isRunning: true, isPinned: false, processIdentifier: pid)
    }

    @Test func pinsFirstThenRunning() {
        let items = DockModel.ordered(
            pinned: [pin("b.pin"), pin("a.pin")],
            running: [run("x.run"), run("y.run")])
        #expect(items.map(\.bundleID) == ["b.pin", "a.pin", "x.run", "y.run"])
        #expect(items[0].isPinned && !items[0].isRunning)
        #expect(items[2].isRunning && !items[2].isPinned)
    }

    @Test func aRunningPinIsOneTile() {
        let items = DockModel.ordered(
            pinned: [pin("a.app")],
            running: [run("a.app", pid: 42), run("z.app")])
        #expect(items.map(\.bundleID) == ["a.app", "z.app"],
                "the running entry folds into the pin — no double tile")
        #expect(items[0].isRunning)
        #expect(items[0].isPinned)
        #expect(items[0].processIdentifier == 42, "the pid travels across for the actions")
    }

    @Test func duplicatesInEitherListAreDropped() {
        let items = DockModel.ordered(
            pinned: [pin("a"), pin("a"), pin("b")],
            running: [run("b"), run("c"), run("c")])
        #expect(items.map(\.bundleID) == ["a", "b", "c"])
    }

    @Test func emptyInputsGiveAnEmptyBar() {
        #expect(DockModel.ordered(pinned: [], running: []).isEmpty)
    }

    @Test func togglePinAddsThenRemoves() {
        let model = DockModel()
        var persisted: [[String]] = []
        model.onPinsChanged = { persisted.append($0) }
        let item = DockItem(bundleID: "com.example.App", name: "App", bundleURL: nil,
                            isRunning: false, isPinned: false, processIdentifier: nil)
        model.togglePin(item)
        #expect(model.pinnedIDs == ["com.example.App"])
        model.togglePin(item)
        #expect(model.pinnedIDs.isEmpty)
        #expect(persisted == [["com.example.App"], []],
                "every edit reports the new list for persistence")
    }

    @Test func movePinReordersInsideThePinnedRun() {
        let model = DockModel()
        model.togglePin(DockItem(bundleID: "a", name: "a", bundleURL: nil,
                                 isRunning: false, isPinned: false, processIdentifier: nil))
        model.togglePin(DockItem(bundleID: "b", name: "b", bundleURL: nil,
                                 isRunning: false, isPinned: false, processIdentifier: nil))
        model.togglePin(DockItem(bundleID: "c", name: "c", bundleURL: nil,
                                 isRunning: false, isPinned: false, processIdentifier: nil))
        model.movePin("a", before: "c")
        #expect(model.pinnedIDs == ["b", "a", "c"], "dragged lands at the target's slot")
    }

    @Test func movePinOntoANonPinIsANoOp() {
        let model = DockModel()
        var persisted: [[String]] = []
        model.onPinsChanged = { persisted.append($0) }
        model.togglePin(DockItem(bundleID: "a", name: "a", bundleURL: nil,
                                 isRunning: false, isPinned: false, processIdentifier: nil))
        model.movePin("a", before: "not-pinned")
        model.movePin("not-there", before: "a")
        #expect(model.pinnedIDs == ["a"])
        #expect(persisted.count == 1, "only the toggle reported")
    }

    @Test func theSeedMergesUnderExistingPinsAndReportsOnce() {
        let model = DockModel()
        model.settings = { DockSettings(pinned: ["user.pin"], seededFromAppleDock: false) }
        model.pinSource = { ["apple.one", "user.pin", "apple.two"] }
        var seeded: [[String]] = []
        model.onSeeded = { seeded.append($0) }
        model.runningApplications = { [] }
        model.start()
        #expect(model.pinnedIDs == ["user.pin", "apple.one", "apple.two"],
                "existing pins keep the lead; Apple's list appends deduped")
        #expect(seeded == [["user.pin", "apple.one", "apple.two"]])
        model.stop()
    }

    @Test func aSeededFlagSkipsTheReadEntirely() {
        let model = DockModel()
        model.settings = { DockSettings(pinned: ["user.pin"], seededFromAppleDock: true) }
        var read = false
        model.pinSource = { read = true; return ["apple.one"] }
        model.onSeeded = { _ in Issue.record("the seed must not rerun") }
        model.runningApplications = { [] }
        model.start()
        #expect(read == false)
        #expect(model.pinnedIDs == ["user.pin"])
        model.stop()
    }

    @Test func anUnreadableSuiteStillSealsTheFlag() {
        let model = DockModel()
        model.settings = { DockSettings() }
        model.pinSource = { nil }
        var seeded: [[String]] = []
        model.onSeeded = { seeded.append($0) }
        model.runningApplications = { [] }
        model.start()
        #expect(seeded == [[]], "failed reads seal too — no re-read every launch")
        model.stop()
    }

    @Test func showFinderOffDropsTheTile() {
        let model = DockModel()
        model.settings = { DockSettings(pinned: [DockModel.finderBundleID], showFinder: false,
                                        seededFromAppleDock: true) }
        model.runningApplications = { [] }
        model.start()
        #expect(model.items.count == 1 && model.items[0].isTrash,
                "Finder is filtered after ordering — the pin survives; only the Trash sentinel remains")
        #expect(model.pinnedIDs == [DockModel.finderBundleID])
        model.stop()
    }

    @Test func stopBeforeStartIsANoOp() {
        let model = DockModel()
        model.stop()
        #expect(!model.running)
    }
}
