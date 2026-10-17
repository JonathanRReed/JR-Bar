import Foundation
import JRBarCore
import ServiceManagement
import Testing
@testable import JRBarApp

@Suite("Login item state", .serialized)
@MainActor
struct LoginItemStateTests {
    private struct StartSignal: Sendable {
        private let stream: AsyncStream<Bool>
        private let continuation: AsyncStream<Bool>.Continuation

        nonisolated init() {
            let signal = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
            stream = signal.stream
            continuation = signal.continuation
        }

        nonisolated func signal() {
            continuation.yield(true)
            continuation.finish()
        }

        nonisolated func wait() async -> Bool {
            let deadline = Task {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                continuation.yield(false)
                continuation.finish()
            }
            defer {
                deadline.cancel()
                continuation.finish()
            }
            for await started in stream { return started }
            return false
        }
    }

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var writes: [Bool] = []
        private var readCount = 0
        private var onMain = false

        func changed(_ on: Bool) {
            lock.lock(); defer { lock.unlock() }
            writes.append(on)
            onMain = Thread.isMainThread
        }

        func read() {
            lock.lock(); defer { lock.unlock() }
            readCount += 1
        }

        var snapshot: (writes: [Bool], reads: Int, onMain: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (writes, readCount, onMain)
        }
    }

    @Test func approvalIsARequestRatherThanEnabledStartup() {
        let approval = LoginItemState(SMAppService.Status.requiresApproval)
        #expect(approval == .requiresApproval)
        #expect(approval.isRequested)
        #expect(!approval.isEnabled)
        #expect(approval.subtitle.contains("Waiting for approval"))
        #expect(LoginItemState(.enabled).isEnabled)
        #expect(!LoginItemState(.notRegistered).isRequested)
        #expect(LoginItemState(.notFound).subtitle.contains("could not find"))
    }

    @Test func anOlderReadCannotReplaceTheLatestStatus() async {
        let started = StartSignal()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = SettingsStore(core: CoreModel())
        store.loginItemStateReader = {
            started.signal()
            _ = release.wait(timeout: .now() + 10)
            return .enabled
        }
        let old = store.refreshLaunchAtLogin()
        let startedResult = await started.wait()
        #expect(startedResult)
        store.loginItemStateReader = { .requiresApproval }
        await store.refreshLaunchAtLogin().value
        release.signal()
        await old.value
        #expect(store.loginItemState == .requiresApproval)
        #expect(!store.launchAtLogin)
        #expect(!store.launchAtLoginBusy)
    }

    @Test func registrationStaysOffMainAndIgnoresDuplicatePendingRequests() async {
        let started = StartSignal()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let probe = Probe()
        let store = SettingsStore(core: CoreModel())
        store.loginItemChange = { on in
            probe.changed(on)
            started.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        store.loginItemStateReader = { probe.read(); return .requiresApproval }
        let first = store.setLaunchAtLogin(true)
        let startedResult = await started.wait()
        #expect(startedResult)
        let duplicate = store.setLaunchAtLogin(true)
        let refresh = store.refreshLaunchAtLogin()
        #expect(store.launchAtLoginBusy)
        #expect(!store.launchAtLogin)
        #expect(probe.snapshot.reads == 0)
        release.signal()
        await first.value
        await duplicate.value
        await refresh.value
        #expect(probe.snapshot.writes == [true])
        #expect(!probe.snapshot.onMain)
        #expect(probe.snapshot.reads == 1)
        #expect(store.loginItemState == .requiresApproval)
        #expect(!store.launchAtLogin)
        #expect(!store.launchAtLoginBusy)

        store.loginItemChange = { probe.changed($0) }
        store.loginItemStateReader = { .notRegistered }
        await store.setLaunchAtLogin(false).value
        #expect(probe.snapshot.writes == [true, false])
        #expect(!store.loginItemState.isRequested)
    }

    @Test func failureShowsTheActualStateRatherThanTheRequestedValue() async {
        let store = SettingsStore(core: CoreModel())
        store.loginItemChange = { _ in
            throw NSError(domain: "example.test", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Registration refused"])
        }
        store.loginItemStateReader = { .notRegistered }
        await store.setLaunchAtLogin(true).value
        #expect(!store.launchAtLogin)
        #expect(store.loginItemState == .notRegistered)
        #expect(store.launchAtLoginError == "Registration refused")
        #expect(!store.launchAtLoginBusy)

        store.loginItemStateReader = { .enabled }
        await store.refreshLaunchAtLogin().value
        #expect(store.launchAtLogin)
        #expect(store.launchAtLoginError == nil)
    }

    @Test func cancelingAReadReleasesThePendingControl() async {
        let started = StartSignal()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = SettingsStore(core: CoreModel())
        store.loginItemStateReader = {
            started.signal()
            _ = release.wait(timeout: .now() + 10)
            return .enabled
        }
        let read = store.refreshLaunchAtLogin()
        let startedResult = await started.wait()
        #expect(startedResult)
        read.cancel()
        release.signal()
        await read.value
        #expect(!store.launchAtLoginBusy)
        #expect(store.loginItemState == .unknown)
    }
}
