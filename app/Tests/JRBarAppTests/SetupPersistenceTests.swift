import Foundation
import Testing
@testable import JRBarApp

@MainActor
@Suite("Setup persistence", .serialized)
struct SetupPersistenceTests {
    nonisolated static var isolatedDefaultPersistence: Bool {
        ProcessInfo.processInfo.environment["JRBAR_SETUP_PERSISTENCE_PROBE"] == "1"
    }

    @Test(.enabled(if: SetupPersistenceTests.isolatedDefaultPersistence), arguments: [false, true])
    func failedDefaultSaveKeepsSetupOpenAndAllowsRetry(openToys: Bool) throws {
        let root = try #require(ProcessInfo.processInfo.environment["XDG_STATE_HOME"])
        let directory = URL(fileURLWithPath: root)
        try #require(directory.deletingLastPathComponent().resolvingSymlinksInPath().path
                     == FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
        try #require(directory.lastPathComponent.hasPrefix("jrbar-setup-persistence-v305-"))
        let file = SetupStateFile()
        try #require(file.url == directory.appending(path: "jrbar/setup.json"))
        try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = SetupStore(model: SetupModel(), load: { SetupState() })
        var finished = 0
        var openedToys = 0
        store.onFinished = { finished += 1 }
        store.onOpenToys = { openedToys += 1 }
        if openToys { store.finishToToys() } else { store.finish() }

        #expect(!store.hasFinished)
        #expect(!store.completedSteps.contains(.done))
        #expect(finished == 0)
        #expect(openedToys == 0)
        #expect(file.load().finishedAt == nil)

        try FileManager.default.removeItem(at: file.url)
        if openToys { store.finishToToys() } else { store.finish() }
        #expect(store.hasFinished)
        #expect(store.completedSteps.contains(.done))
        #expect(finished == 1)
        #expect(openedToys == (openToys ? 1 : 0))
        #expect(file.load().finishedAt != nil)
    }

    @Test(arguments: [false, true])
    func failedFinishRetainsDurableStateAndRunOutcomesUntilRetry(openToys: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = SetupStateFile(url: directory.appending(path: "setup.json"))
        let prior = SetupState(completedSteps: ["welcome"], skippedSteps: ["agents"],
                               finishedAt: 12, whatsNewSeen: "older-release")
        try file.save(prior)
        var fail = false
        let store = SetupStore(load: { file.load() }, persist: { candidate in
            if fail { throw CocoaError(.fileWriteNoPermission) }
            try file.save(candidate)
        })
        store.goNext()
        store.skip()
        let durableBeforeFinish = file.load()
        let completedBeforeFinish = store.completedSteps
        let skippedBeforeFinish = store.skippedSteps
        var finished = 0
        var opened = 0
        store.onFinished = { finished += 1 }
        store.onOpenToys = { opened += 1 }
        fail = true
        if openToys { store.finishToToys() } else { store.finish() }
        #expect(store.state == durableBeforeFinish)
        #expect(file.load() == durableBeforeFinish)
        #expect(store.completedSteps == completedBeforeFinish)
        #expect(store.skippedSteps == skippedBeforeFinish)
        #expect(store.persistenceFailure == "Setup could not be saved. Try again.")
        #expect(finished == 0)
        #expect(opened == 0)

        fail = false
        if openToys { store.finishToToys() } else { store.finish() }
        #expect(store.persistenceFailure == nil)
        #expect(store.completedSteps.contains(.done))
        #expect(store.state.finishedAt != durableBeforeFinish.finishedAt)
        #expect(store.whatsNewSeen == "older-release")
        #expect(file.load() == store.state)
        #expect(finished == 1)
        #expect(opened == (openToys ? 1 : 0))
    }

    @Test
    func bookkeepingWritesPreserveStoredOutcomesAndRetryAfterFailure() async {
        let prior = SetupState(completedSteps: ["welcome", "done"], skippedSteps: ["agents"],
                               finishedAt: 12, presentedCount: 1,
                               grantedPermissions: ["camera"], whatsNewSeen: "older-release")
        var durable = prior
        var fail = true
        var model = SetupModel()
        model.refreshPermissions = { [.camera: .denied] }
        let store = SetupStore(model: model, load: { prior }, persist: { candidate in
            if fail { throw CocoaError(.fileWriteNoPermission) }
            durable = candidate
        })
        store.markWhatsNewSeen("new-release")
        #expect(store.state == prior)
        #expect(durable == prior)
        _ = await store.reviewPermissionHealth()
        #expect(store.state == prior)
        #expect(durable == prior)
        store.present()
        #expect(store.state == prior)
        #expect(store.persistenceFailure != nil)

        fail = false
        store.markWhatsNewSeen("new-release")
        #expect(store.persistenceFailure == nil)
        #expect(store.whatsNewSeen == "new-release")
        _ = await store.reviewPermissionHealth()
        #expect(store.state.grantedPermissions == [])
        #expect(store.state.completedSteps == prior.completedSteps)
        #expect(store.state.skippedSteps == prior.skippedSteps)
        #expect(store.state.finishedAt == prior.finishedAt)
        #expect(durable == store.state)

        store.present()
        #expect(store.state.presentedCount == prior.presentedCount + 1)
        #expect(store.state.completedSteps.isEmpty)
        #expect(store.state.skippedSteps.isEmpty)
        #expect(durable == store.state)
    }
}
