import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The timers' upgrades: pause and resume on absolute deadlines, the
/// done chip's snooze, a timer set to a quota reset, and the agent
/// nudge that retires quietly once its run has finished. Each model
/// writes to its own temporary file.
@Suite("Shelf timer upgrades")
@MainActor
struct ShelfTimerUpgradeTests {
    private func makeModel() -> ShelfTimerModel {
        ShelfTimerModel(storeURL: URL(fileURLWithPath: NSTemporaryDirectory()
            + "jrbar-test-timers-\(UUID().uuidString).json"))
    }

    @Test("pause banks the time left and fires nothing; resume carries on from there")
    func pauseResume() throws {
        let model = makeModel()
        let entry = model.add(label: "Tea", duration: 300)
        model.pause(entry)
        let paused = try #require(model.entries.first)
        #expect(paused.paused)
        #expect(!paused.overdue)
        #expect(abs(paused.remaining - 300) < 2)
        model.resume(paused)
        let running = try #require(model.entries.first)
        #expect(!running.paused)
        #expect(abs(running.deadline.timeIntervalSinceNow - 300) < 2)
    }

    @Test("+1 and +5 extend a running timer and re-arm a done one")
    func extend() async throws {
        let model = makeModel()
        let running = model.add(label: "Build", duration: 60)
        model.extend(running, by: 300)
        #expect(abs((model.entries.first?.remaining ?? 0) - 360) < 2)

        let done = makeModel()
        var fired = 0
        done.onFire = { _ in fired += 1 }
        let entry = done.add(label: "Quick", duration: 1)
        try await Task.sleep(for: .seconds(1.2))
        done.sweep()
        #expect(fired == 1)
        #expect(done.entries.first?.fired == true)
        done.extend(entry, by: 60)
        let again = try #require(done.entries.first)
        #expect(!again.fired, "snoozed: it will fire again")
        #expect(abs(again.remaining - 60) < 2)
    }

    @Test("a timer to a quota reset takes the absolute instant, within the shelf's range")
    func untilReset() {
        let model = makeModel()
        let now = Date()
        #expect(model.add(label: "Claude 5h reset", until: now.addingTimeInterval(3600), now: now) != nil)
        #expect(model.add(label: "past", until: now.addingTimeInterval(-10), now: now) == nil)
        #expect(model.add(label: "too far", until: now.addingTimeInterval(ShelfTimerModel.maxDuration + 60),
                          now: now) == nil)
    }

    @Test("a nudge whose run finished retires without a word; one still running speaks")
    func nudge() async throws {
        let model = makeModel()
        var spoken: [String] = []
        model.onFire = { spoken.append($0.label) }
        model.onFireNotice = { spoken.append("island:" + $0.label) }
        model.firePredicate = { entry in entry.watchSession == "claude:busy" }
        model.add(label: "busy", duration: 1, watchSession: "claude:busy")
        model.add(label: "done", duration: 1, watchSession: "claude:done")
        try await Task.sleep(for: .seconds(1.2))
        model.sweep()
        #expect(spoken.sorted() == ["busy", "island:busy"])
        #expect(model.entries.map(\.label) == ["busy"], "the finished run's nudge is gone")
    }

    @Test("a timers file from before pause and nudges still loads")
    func legacyFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "jrbar-test-timers-\(UUID().uuidString).json")
        let future = Date().addingTimeInterval(600).timeIntervalSinceReferenceDate
        try Data(#"[{"id":"a","label":"Old","deadline":\#(future),"fired":false}]"#.utf8).write(to: url)
        let model = ShelfTimerModel(storeURL: url)
        let entry = try #require(model.entries.first)
        #expect(entry.label == "Old")
        #expect(!entry.paused)
        #expect(entry.watchSession == nil)
    }

    @Test("the island speaks a due timer in its own capsule, and a nudge names its run")
    func islandCapsule() {
        var toys = ToysState()
        toys.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        core.apply(.state(CoreState(sessions: [CoreSession(id: "claude:w", provider: "claude",
                                                            mode: "working")])))
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: toys,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        defer { withExtendedLifetime(store) {} }
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        let entry = ShelfTimerModel.Entry(id: "t", label: "claude still working", deadline: Date(),
                                          fired: true, watchSession: "claude:w")
        toy.noteTimerFired(entry)
        #expect(toy.activeCapsule?.kind == .timer)
        #expect(toy.activeCapsule?.session == "claude:w")
        #expect(toy.activeCapsule?.subtitle == "still working")
        #expect(toy.sessionStillWorking("claude:w"))
        #expect(!toy.sessionStillWorking("claude:gone"))
    }
}
