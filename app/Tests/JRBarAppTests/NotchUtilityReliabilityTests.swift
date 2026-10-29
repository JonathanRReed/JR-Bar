import Foundation
import JRBarTestSupport
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Notch utility reliability", .temporaryDirectory, .serialized, .timeLimit(.minutes(2)), .renderProofAppearance)
@MainActor
struct NotchUtilityReliabilityTests {
    private func storeURL() -> URL {
        URL(fileURLWithPath: (TestTemporaryDirectory.currentURL.path + "/") + "jrbar-notch-timers-\(UUID().uuidString).json")
    }

    @Test("pause, resume and expiry use the supplied clock without a run-loop timer")
    func manualClock() throws {
        var now = Date(timeIntervalSinceReferenceDate: 1000)
        let model = ShelfTimerModel(storeURL: storeURL(), schedulingEnabled: false, clock: { now })
        let entry = model.add(label: "Tea", duration: 300, now: now)
        now = now.addingTimeInterval(60)
        model.pause(entry)
        let paused = try #require(model.entries.first)
        #expect(paused.pausedRemaining == 240)
        now = now.addingTimeInterval(600)
        model.resume(paused)
        #expect(model.entries.first?.deadline == now.addingTimeInterval(240))
        now = now.addingTimeInterval(240)
        var notices = 0
        model.onFire = { _ in notices += 1 }
        model.sweep()
        model.sweep()
        #expect(notices == 1)
        #expect(model.armedFor == nil)
    }

    @Test("invalid durations stay finite and invalid extensions change nothing")
    func invalidDurations() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let model = ShelfTimerModel(storeURL: storeURL(), schedulingEnabled: false, clock: { now })
        for duration in [Double.nan, Double.infinity, -Double.infinity] {
            let entry = model.add(label: " ", duration: duration, now: now)
            #expect(entry.label == "Timer")
            #expect(entry.deadline == now.addingTimeInterval(1))
        }
        let entry = try #require(model.entries.first)
        let before = model.entries
        for seconds in [Double.nan, Double.infinity, -60, 0] {
            model.extend(entry, by: seconds)
        }
        #expect(model.entries == before)
    }

    @Test("pausing at expiry leaves the due notification armed")
    func pauseAfterDeadline() throws {
        var now = Date(timeIntervalSinceReferenceDate: 1000)
        let url = storeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = ShelfTimerModel(storeURL: url, schedulingEnabled: false, clock: { now })
        let entry = model.add(label: "Tea", duration: 1, now: now)
        var notices = 0
        model.onFire = { _ in notices += 1 }
        now = entry.deadline
        model.pause(entry)
        #expect(model.entries.first?.paused == false)
        #expect(model.armedFor == entry.deadline)
        model.sweep()
        #expect(notices == 1)
        #expect(model.entries.first?.fired == true)
    }

    @Test("a fired timer stays done across a backward clock change and reload")
    func firedTimerAfterClockChange() throws {
        var now = Date(timeIntervalSinceReferenceDate: 1000)
        let url = storeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = ShelfTimerModel(storeURL: url, schedulingEnabled: false, clock: { now })
        let entry = model.add(label: "Tea", duration: 60, now: now)
        now = entry.deadline
        model.sweep()
        now = now.addingTimeInterval(-3600)
        let recovered = ShelfTimerModel(storeURL: url, schedulingEnabled: false, clock: { now })
        var notices = 0
        recovered.onFire = { _ in notices += 1 }
        recovered.pause(entry)
        recovered.sweep()
        let firedEntry = try #require(recovered.entries.first)
        #expect(firedEntry.fired)
        #expect(!firedEntry.paused)
        #expect(firedEntry.remaining(at: now) > 0)
        #expect(recovered.armedFor == nil)
        #expect(notices == 0)
        #expect(NotchTimerGlance(entries: recovered.entries, now: now)?.timeText == "Done")
    }

    @Test("timer recovery drops duplicate ids and invalid paused values")
    func validRecovery() throws {
        let url = storeURL()
        let future = Date(timeIntervalSinceReferenceDate: 2000)
        let records = [
            ShelfTimerModel.Entry(id: "good", label: "First", deadline: future, fired: false),
            ShelfTimerModel.Entry(id: "good", label: "Duplicate", deadline: future, fired: false),
            ShelfTimerModel.Entry(id: "", label: "No id", deadline: future, fired: false),
            ShelfTimerModel.Entry(id: "bad", label: "Negative pause", deadline: future,
                                  fired: false, pausedRemaining: -1),
        ]
        try JSONEncoder().encode(records).write(to: url)
        #expect(ShelfTimerModel.load(from: url).map(\.label) == ["First"])
    }

    @Test("expiry listeners can remove timers after the one-shot state is persisted")
    func removalDuringNotice() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let url = storeURL()
        let model = ShelfTimerModel(storeURL: url, schedulingEnabled: false, clock: { now })
        for label in ["Tea", "Build"] {
            model.add(label: label, duration: 1, now: now.addingTimeInterval(-2))
        }
        var delivered: [String] = []
        model.onFire = { entry in
            let allFired = ShelfTimerModel.load(from: url).allSatisfy { $0.fired }
            #expect(allFired)
            delivered.append(entry.label)
            model.remove(entry)
        }
        model.sweep()
        model.sweep()
        #expect(Set(delivered) == ["Tea", "Build"])
        #expect(model.entries.isEmpty)
    }

    @Test("a newer calendar refresh discards the earlier result while its own read is pending")
    func latestCalendarRefresh() async throws {
        let calendar = ShelfCalendarModel()
        calendar.scheduleRefreshOverride = {}
        calendar.authorization = { .fullAccess }
        let start = Date().addingTimeInterval(600)
        let old = ShelfCalendarModel.Event(title: "Old meeting", start: start,
                                          end: start.addingTimeInterval(600), url: nil)
        let gate = TestGate()
        let entered = TestSignal()
        defer { gate.signal(); calendar.stop() }
        calendar.fetchEvents = { _ in [old] }
        calendar.sync(enabled: true)
        calendar.fetchEvents = { _ in
            entered.signal()
            gate.wait()
            return []
        }
        calendar.sync(enabled: true)
        try #require(await entered.wait())
        #expect(calendar.state == .needsPermission, "the older read did not paint its stale event")
        gate.signal()
        await withCheckedContinuation { (settled: CheckedContinuation<Void, Never>) in
            calendar.readQueue.async { DispatchQueue.main.async { settled.resume() } }
        }
        #expect(calendar.state == .idle)
        calendar.stop()
    }

    @Test("undo clear restores stack references, selection and persisted state once")
    func undoClearShelf() async throws {
        let suite = "jrbar-notch-shelf-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let tray = ShelfTrayModel(defaults: defaults)
        tray.add([URL(fileURLWithPath: "/tmp/jrbar-fixture-one/a.txt"),
                  URL(fileURLWithPath: "/tmp/jrbar-fixture-two/b.txt")])
        await tray.refreshMetadata()
        let saved = tray.entries
        let stack = try #require(saved.first)
        tray.toggleSelection(stack)
        tray.removeAll()
        #expect(tray.entries.isEmpty)
        #expect(tray.canUndoClear)
        #expect(tray.clearedItemCount == 2)
        tray.undoClear()
        #expect(tray.entries == saved)
        #expect(tray.selectedIDs == [stack.id])
        #expect(!tray.canUndoClear)
        let restored = ShelfTrayModel(defaults: defaults)
        await restored.refreshMetadata()
        #expect(restored.entries == saved)
        tray.undoClear()
        #expect(tray.entries == saved)
    }

    @Test("a new landing retires undo clear and a disabled shelf cannot restore references")
    func undoClearBounds() throws {
        let defaults = try #require(UserDefaults(suiteName: "jrbar-notch-shelf-\(UUID().uuidString)"))
        let tray = ShelfTrayModel(defaults: defaults)
        tray.add([URL(fileURLWithPath: "/tmp/jrbar-fixture-one/a.txt")])
        tray.removeAll()
        tray.shelfEnabled = { false }
        tray.undoClear()
        #expect(tray.entries.isEmpty)
        #expect(tray.canUndoClear)
        tray.shelfEnabled = { true }
        tray.add([URL(fileURLWithPath: "/tmp/jrbar-fixture-two/b.txt")])
        #expect(!tray.canUndoClear)
        tray.undoClear()
        #expect(tray.items.map(\.path) == ["/tmp/jrbar-fixture-two/b.txt"])
    }

    @Test("closing after Clear Shelf keeps Undo but drops the old selection and anchor")
    func undoAfterSelectionClears() throws {
        let suite = "jrbar-shelf-close-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tray = ShelfTrayModel(defaults: defaults)
        for index in 1...3 {
            tray.add([URL(fileURLWithPath: "/tmp/jrbar-close-fixture-\(index)/file.txt")])
        }
        let saved = tray.entries
        tray.toggleSelection(saved[0])
        tray.toggleSelection(saved[1])
        tray.removeAll()
        #expect(tray.selectedIDs.isEmpty)
        tray.clearSelection()
        #expect(tray.canUndoClear)
        tray.undoClear()
        #expect(tray.entries == saved)
        #expect(tray.selectedIDs.isEmpty)
        tray.extendSelection(to: saved[2])
        #expect(tray.selectedIDs == [saved[2].id])
    }

    @Test("calendar filtering rejects impossible events and handles a zero limit")
    func calendarBounds() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let invalid = ShelfCalendarModel.Event(title: "Invalid", start: now.addingTimeInterval(60),
                                              end: now.addingTimeInterval(30), url: nil)
        #expect(ShelfCalendarModel.upcoming([invalid], now: now, limit: 3).isEmpty)
        #expect(ShelfCalendarModel.upcoming([invalid], now: now, limit: 0).isEmpty)
    }
}

@Suite("Notch timer row render proof", .temporaryDirectory, .serialized, .renderProofAppearance)
@MainActor
struct NotchTimerRowRenderProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func firedTimerAfterClockMovesBackward() throws {
        var clock = Date()
        let url = TestTemporaryDirectory.currentURL.appendingPathComponent("jrbar-clock-back-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = ShelfTimerModel(storeURL: url, schedulingEnabled: false, clock: { clock })
        let timer = model.add(label: "Tea", duration: 3600, now: clock)
        clock = timer.deadline
        model.sweep()
        clock = clock.addingTimeInterval(-3600)
        #expect(model.entries.first?.fired == true)
        #expect(model.entries.first?.overdue(at: clock) == false)
        let row = ShelfTimersRow(timers: model, style: .island)
            .padding(12)
            .frame(width: 350, height: 60)
            .background(Color.black)
        try ProofRender.write(row, size: CGSize(width: 350, height: 60), name: "notch-timers-fired-clock-back")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func clearedShelf() throws {
        let defaults = try #require(UserDefaults(suiteName: "jrbar-proof-shelf-\(UUID().uuidString)"))
        let tray = ShelfTrayModel(defaults: defaults)
        tray.add([URL(fileURLWithPath: "/tmp/jrbar-fixture-one/a.txt")])
        tray.removeAll()
        let row = ShelfTrayRow(tray: tray, style: .island)
            .padding(12)
            .frame(width: 350, height: 60)
            .background(Color.black)
        try ProofRender.write(row, size: CGSize(width: 350, height: 60), name: "notch-shelf-undo-clear")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func timerRows() throws {
        for (name, count, done) in [("notch-timers-running", 2, false),
                                    ("notch-timers-many", 8, false),
                                    ("notch-timers-done", 2, true)] {
            let now = Date()
            let model = ShelfTimerModel(storeURL: URL(fileURLWithPath: (TestTemporaryDirectory.currentURL.path + "/")
                + "jrbar-proof-timers-\(UUID().uuidString).json"), schedulingEnabled: false)
            for index in 0..<count {
                let entry = model.add(label: index == 0 ? "Tea" : "Review \(index)", duration: 300,
                                      now: done ? now.addingTimeInterval(-600) : now)
                if index == 1 && !done { model.pause(entry) }
            }
            if done { model.sweep() }
            let row = ShelfTimersRow(timers: model, style: .island)
                .padding(12)
                .frame(width: 350, height: 60)
                .background(Color.black)
            try ProofRender.write(row, size: CGSize(width: 350, height: 60), name: name)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func shelfAccessibilityTiles() throws {
        let folder = TestTemporaryDirectory.currentURL
            .appendingPathComponent("jrbar-shelf-keys-\(UUID().uuidString)", isDirectory: true)
        let references = folder.appendingPathComponent("Reference", isDirectory: true)
        let notes = folder.appendingPathComponent("Notes", isDirectory: true)
        let suite = "jrbar-proof-shelf-keys-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let files = [references.appendingPathComponent("Outline.txt"),
                     references.appendingPathComponent("Notes.txt"),
                     notes.appendingPathComponent("Checklist.txt")]
        for file in files { try Data("Fixture".utf8).write(to: file) }
        let tray = ShelfTrayModel(defaults: defaults)
        tray.add(Array(files.prefix(2)))
        tray.add([files[2]])
        #expect(tray.entries.count == 2)
        for dark in [true, false] {
            let row = ShelfTrayRow(tray: tray, style: dark ? .island : .glass)
                .padding(12)
                .frame(width: 350, height: 90)
                .background(dark ? Color.black : Color(nsColor: .windowBackgroundColor))
            try ProofRender.write(row, size: CGSize(width: 350, height: 90),
                                  name: "notch-shelf-accessibility-\(dark ? "dark" : "light")", dark: dark)
        }
    }

}
