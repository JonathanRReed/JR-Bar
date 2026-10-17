import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("System toggle ordering")
struct SystemToggleOrderingTests {
    @MainActor
    final class Replies {
        var commands: [String] = []
        var commandReplies: [CheckedContinuation<(output: String?, error: String?), Never>] = []
        var settles: [CheckedContinuation<Void, Never>] = []
        var reads: [SystemToggle] = []
        var readReplies: [CheckedContinuation<Bool, Never>] = []
        var stopped = false

        func wire(_ state: SystemTogglesStore.State) {
            state.runCommand = { [self] command in
                guard !stopped else { return (nil, "Synthetic cleanup") }
                commands.append(command)
                return await withCheckedContinuation { commandReplies.append($0) }
            }
            state.settleShell = { [self] in
                guard !stopped else { return }
                await withCheckedContinuation { settles.append($0) }
            }
            state.readToggle = { [self] toggle in
                guard !stopped else { return false }
                reads.append(toggle)
                return await withCheckedContinuation { readReplies.append($0) }
            }
        }

        func wait(_ ready: @MainActor () -> Bool, timeout: Duration = .seconds(5)) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !ready(), clock.now < deadline { await Task.yield() }
            return ready()
        }

        func clean() {
            stopped = true
            let commands = commandReplies; commandReplies.removeAll()
            let waits = settles; settles.removeAll()
            let readings = readReplies; readReplies.removeAll()
            for reply in commands { reply.resume(returning: (nil, "Synthetic cleanup")) }
            for reply in waits { reply.resume() }
            for reply in readings { reply.resume(returning: false) }
        }

        func finishCommand(error: String? = nil, reading: Bool) async throws {
            let commandReady = await wait { !self.commandReplies.isEmpty }
            try #require(commandReady)
            commandReplies.removeFirst().resume(returning: (nil, error))
            let settleReady = await wait { !self.settles.isEmpty }
            try #require(settleReady)
            settles.removeFirst().resume()
            let readReady = await wait { !self.readReplies.isEmpty }
            try #require(readReady)
            readReplies.removeFirst().resume(returning: reading)
        }
    }

    private func fixture() throws -> (SystemTogglesStore, Replies, UserDefaults, String) {
        let suite = "jrbar-toggle-order-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        state.isOn[.hiddenFiles] = false
        state.isOn[.desktopIcons] = false
        let replies = Replies()
        replies.wire(state)
        return (SystemTogglesStore(state: state), replies, defaults, suite)
    }

    @Test("an old refresh cannot undo completed action read-back")
    func oldRefreshCannotOverwriteAction() async throws {
        let (store, replies, defaults, suite) = try fixture()
        defer { replies.clean(); defaults.removePersistentDomain(forName: suite) }
        let refresh = try #require(store.refresh(.hiddenFiles))
        let oldReadReady = await replies.wait { replies.readReplies.count == 1 }
        try #require(oldReadReady)
        store.set(.hiddenFiles, on: true)
        let commandReady = await replies.wait { !replies.commandReplies.isEmpty }
        try #require(commandReady)
        replies.commandReplies.removeFirst().resume(returning: (nil, nil))
        let settleReady = await replies.wait { !replies.settles.isEmpty }
        try #require(settleReady)
        replies.settles.removeFirst().resume()
        let currentReadReady = await replies.wait { replies.readReplies.count == 2 }
        try #require(currentReadReady)
        replies.readReplies.removeLast().resume(returning: true)
        let actionFinished = await replies.wait { store.applying.isEmpty }
        try #require(actionFinished)
        replies.readReplies.removeFirst().resume(returning: false)
        await refresh.value
        #expect(store.isOn[.hiddenFiles] == true)
        store.set(.hiddenFiles, on: false)
        let decided = await replies.wait { replies.commands.count == 2 || store.applying.isEmpty }
        try #require(decided)
        #expect(replies.commands.count == 2)
        if replies.commands.count == 2 { try await replies.finishCommand(reading: false) }
    }

    @Test("only the newest refresh across shared store instances can publish")
    func newestSharedRefreshWins() async throws {
        let (store, replies, defaults, suite) = try fixture()
        defer { replies.clean(); defaults.removePersistentDomain(forName: suite) }
        let other = SystemTogglesStore(state: store.state)
        let first = try #require(store.refresh(.hiddenFiles))
        let firstReady = await replies.wait { replies.readReplies.count == 1 }
        try #require(firstReady)
        let second = try #require(other.refresh(.hiddenFiles))
        let secondReady = await replies.wait { replies.readReplies.count == 2 }
        try #require(secondReady)
        replies.readReplies.removeLast().resume(returning: true)
        await second.value
        replies.readReplies.removeFirst().resume(returning: false)
        await first.value
        #expect(store.isOn[.hiddenFiles] == true)
    }

    @Test("an initial action probe invalidates an older refresh even without a write")
    func initialProbeInvalidatesRefresh() async throws {
        let (store, replies, defaults, suite) = try fixture()
        defer { replies.clean(); defaults.removePersistentDomain(forName: suite) }
        store.state.isOn[.hiddenFiles] = nil
        let refresh = try #require(store.refresh(.hiddenFiles))
        let oldReadReady = await replies.wait { replies.readReplies.count == 1 }
        try #require(oldReadReady)
        store.set(.hiddenFiles, on: true)
        let actionReadReady = await replies.wait { replies.readReplies.count == 2 }
        try #require(actionReadReady)
        replies.readReplies.removeLast().resume(returning: true)
        let actionFinished = await replies.wait { store.applying.isEmpty }
        try #require(actionFinished)
        replies.readReplies.removeFirst().resume(returning: false)
        await refresh.value
        #expect(store.isOn[.hiddenFiles] == true)
        #expect(replies.commands.isEmpty)
    }

    @Test("a refresh during an action starts no competing probe")
    func busyRefreshIsSkipped() throws {
        let (store, replies, defaults, suite) = try fixture()
        defer { replies.clean(); defaults.removePersistentDomain(forName: suite) }
        store.set(.hiddenFiles, on: true)
        #expect(store.refresh(.hiddenFiles) == nil)
    }

    @Test("an initial chip probe honors a matching explicit target without a write")
    func chipProbeAvoidsRedundantWrite() async throws {
        let (store, replies, defaults, suite) = try fixture()
        defer { replies.clean(); defaults.removePersistentDomain(forName: suite) }
        store.state.isOn[.hiddenFiles] = nil
        store.apply(.hiddenFiles)
        let reading = await replies.wait { !replies.readReplies.isEmpty }
        try #require(reading)
        store.set(.hiddenFiles, on: false)
        replies.readReplies.removeFirst().resume(returning: false)
        let returned = await replies.wait { !store.applying.contains(.hiddenFiles) || !replies.commands.isEmpty }
        try #require(returned)
        #expect(replies.commands.isEmpty)
        #expect(!store.applying.contains(.hiddenFiles))
        #expect(store.state.pendingShellTargets.isEmpty)
    }

    @Test("the latest explicit target follows a held opposite write")
    func oppositeTarget() async throws {
        let (store, replies, defaults, suite) = try fixture()
        defer { replies.clean(); defaults.removePersistentDomain(forName: suite) }
        store.set(.hiddenFiles, on: true)
        store.set(.hiddenFiles, on: false)
        store.set(.hiddenFiles, on: true)
        store.set(.hiddenFiles, on: false)
        try await replies.finishCommand(reading: true)
        let secondReady = await replies.wait { replies.commands.count == 2 }
        try #require(secondReady)
        #expect(replies.commands[0] == SystemToggle.hiddenFiles.applyCommand(on: true))
        #expect(replies.commands[1] == SystemToggle.hiddenFiles.applyCommand(on: false))
        try await replies.finishCommand(reading: false)
        let finished = await replies.wait { store.applying.isEmpty }
        try #require(finished)
        #expect(store.isOn[.hiddenFiles] == false)
        #expect(store.state.pendingShellTargets.isEmpty)
    }

    @Test("chip taps stay blocked through settling and held read-back")
    func tapsDuringSettle() async throws {
        let (store, replies, defaults, suite) = try fixture()
        defer { replies.clean(); defaults.removePersistentDomain(forName: suite) }
        store.apply(.hiddenFiles)
        let commandReady = await replies.wait { !replies.commandReplies.isEmpty }
        try #require(commandReady)
        replies.commandReplies.removeFirst().resume(returning: (nil, nil))
        let settleReady = await replies.wait { !replies.settles.isEmpty }
        try #require(settleReady)
        store.apply(.hiddenFiles)
        #expect(store.applying.contains(.hiddenFiles))
        #expect(replies.commands.count == 1)
        replies.settles.removeFirst().resume()
        let readReady = await replies.wait { !replies.readReplies.isEmpty }
        try #require(readReady)
        store.apply(.hiddenFiles)
        #expect(store.applying.contains(.hiddenFiles))
        #expect(replies.commands.count == 1)
        replies.readReplies.removeFirst().resume(returning: true)
        let finished = await replies.wait { store.applying.isEmpty }
        try #require(finished)
        #expect(replies.commands.count == 1)
    }

    @Test("an explicit target queued during the first probe can avoid a needless restart")
    func targetDuringInitialProbe() async throws {
        let (store, replies, defaults, suite) = try fixture()
        defer { replies.clean(); defaults.removePersistentDomain(forName: suite) }
        store.state.isOn.removeValue(forKey: .hiddenFiles)
        store.set(.hiddenFiles, on: true)
        let readReady = await replies.wait { !replies.readReplies.isEmpty }
        try #require(readReady)
        store.set(.hiddenFiles, on: false)
        store.apply(.hiddenFiles)
        replies.readReplies.removeFirst().resume(returning: false)
        let finished = await replies.wait { store.applying.isEmpty }
        try #require(finished)
        #expect(replies.commands.isEmpty)
        #expect(store.isOn[.hiddenFiles] == false)
        #expect(store.state.pendingShellTargets.isEmpty)
    }

    @Test("a failed write reads truth and releases busy state without a duplicate retry")
    func failureCleanup() async throws {
        let (store, replies, defaults, suite) = try fixture()
        defer { replies.clean(); defaults.removePersistentDomain(forName: suite) }
        store.set(.hiddenFiles, on: true)
        store.set(.hiddenFiles, on: false)
        try await replies.finishCommand(error: "Synthetic refusal", reading: false)
        let finished = await replies.wait { store.applying.isEmpty }
        try #require(finished)
        #expect(store.isOn[.hiddenFiles] == false)
        #expect(store.lastError == "Hidden: Synthetic refusal")
        #expect(replies.commands.count == 1)
        #expect(store.state.pendingShellTargets.isEmpty)
        #expect(store.state.shellTasks.isEmpty)
    }

    @Test("independent shell-backed toggles start without waiting on each other")
    func independentToggles() async throws {
        let (store, replies, defaults, suite) = try fixture()
        defer { replies.clean(); defaults.removePersistentDomain(forName: suite) }
        store.set(.hiddenFiles, on: true)
        store.set(.desktopIcons, on: true)
        let bothReady = await replies.wait { replies.commands.count == 2 }
        try #require(bothReady)
        #expect(store.applying == [.hiddenFiles, .desktopIcons])
        #expect(Set(replies.commands) == Set([
            SystemToggle.hiddenFiles.applyCommand(on: true)!,
            SystemToggle.desktopIcons.applyCommand(on: true)!,
        ]))
        // Both writes are already out. Retire their held replies without system effects.
        replies.clean()
        let finished = await replies.wait({ store.applying.isEmpty }, timeout: .seconds(120))
        try #require(finished)
    }
}
