import Darwin
import Foundation
import JRBarTestSupport
import Testing
@testable import JRBarApp
import JRBarCore

@Suite("Menu Bar script ownership", .temporaryDirectory, .serialized, .timeLimit(.minutes(2)))
struct MenuBarScriptRunnerTests {
    private final class Receipts: @unchecked Sendable {
        private let lock = NSLock()
        private let changed = TestSignal()
        private var values: [MenuBarScriptRunner.Receipt] = []

        func record(_ receipt: MenuBarScriptRunner.Receipt) {
            lock.withLock { values.append(receipt) }
            changed.signal()
        }

        func waitFor(_ count: Int) async -> [MenuBarScriptRunner.Receipt] {
            while lock.withLock({ values.count < count }), !Task.isCancelled {
                guard await changed.wait() else { break }
            }
            return lock.withLock { values }
        }

    }

    private func rule(_ id: String, command: String, enabled: Bool = true) -> MenuBarTriggerRule {
        MenuBarTriggerRule(id: id, enabled: enabled, trigger: .screenLocked,
                           action: .runScript(command: command))
    }

    /// Reap a real newly spawned shell before telling the runner ECHILD.
    /// Subsequent calls are recorded, never forwarded to a recycled PID.
    private final class ExternalReaper: @unchecked Sendable {
        private let lock = NSLock()
        private var didReap = false
        private var status: Int32?
        private var subsequentCalls = 0

        func observe(_ pid: pid_t) -> MenuBarScriptRunner.Observation {
            var value: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &value, 0) } while result == -1 && errno == EINTR
            lock.withLock {
                didReap = result == pid
                status = result == pid ? value : nil
            }
            return .failed(errno: ECHILD)
        }

        func reap(_ pid: pid_t) { lock.withLock { subsequentCalls += 1 } }
        func signal(_ pid: pid_t, _ signal: Int32) { lock.withLock { subsequentCalls += 1 } }
        var result: (reaped: Bool, status: Int32?, calls: Int) {
            lock.withLock { (didReap, status, subsequentCalls) }
        }
    }

    private final class Signals: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int32] = []
        func send(_ pid: pid_t, _ signal: Int32) {
            MenuBarScriptRunner.ProcessDriver.system.signalGroup(pid, signal)
            lock.withLock { values.append(signal) }
        }
        var sentKill: Bool { lock.withLock { values.contains(SIGKILL) } }
    }

    @Test("ECHILD never waits or signals again after an actual external reap")
    func externallyReaped() async {
        let reaper = ExternalReaper()
        let receipts = Receipts()
        let driver = MenuBarScriptRunner.ProcessDriver(observe: reaper.observe,
            reap: reaper.reap, signalGroup: reaper.signal)
        let runner = MenuBarScriptRunner(process: driver, report: receipts.record)
        runner.start()
        #expect(runner.submit(rule("reaped", command: "exit 0")) == .queued)
        let receipt = await receipts.waitFor(1).first
        runner.shutdown()
        #expect(receipt?.outcome == .waitFailed(errno: ECHILD))
        #expect(reaper.result.reaped)
        #expect(reaper.result.status == 0)
        #expect(reaper.result.calls == 0)
        #expect(runner.activeCount == 0)
    }

    @Test("tail retention stays bounded, including a single oversized chunk")
    func boundedTail() {
        var output = Data("old".utf8)
        MenuBarScriptRunner.retainTail(Data(repeating: 65, count: 30_000), in: &output)
        #expect(output == Data(repeating: 65, count: MenuBarScriptRunner.outputLimit))
        MenuBarScriptRunner.retainTail(Data("tail".utf8), in: &output)
        #expect(output.count == MenuBarScriptRunner.outputLimit)
        #expect(output.suffix(4) == Data("tail".utf8))
    }

    @Test("admission distinguishes same rule, capacity and stopped; stop retires queued launches")
    func queuedAdmission() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("must-not-launch")
        let queue = DispatchQueue(label: "script fixture held launches")
        queue.suspend()
        let receipts = Receipts()
        let runner = MenuBarScriptRunner(launches: queue, report: receipts.record)
        runner.start()
        let first = rule("one", command: "printf launched > \(quoted(marker.path))")
        #expect(runner.submit(first) == .queued)
        #expect(runner.submit(first) == .ruleBusy)
        for id in ["two", "three", "four"] {
            #expect(runner.submit(rule(id, command: "printf launched > \(quoted(marker.path))")) == .queued)
        }
        #expect(runner.activeCount == 4)
        #expect(runner.submit(rule("five", command: "exit 0")) == .capacity)
        runner.stop()
        #expect(runner.submit(rule("six", command: "exit 0")) == .stopped)
        queue.resume()
        let all = await receipts.waitFor(7)
        #expect(all.filter { $0.outcome == .cancelled }.count == 4)
        #expect(runner.activeCount == 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("a queued rule edited before launch is cancelled; a disabled manual rule remains valid")
    func queuedEdit() async {
        let queue = DispatchQueue(label: "script fixture edited launch")
        queue.suspend()
        let receipts = Receipts()
        let runner = MenuBarScriptRunner(launches: queue, report: receipts.record)
        runner.start()
        let original = rule("same", command: "printf original", enabled: false)
        #expect(runner.submit(original) == .queued)
        runner.synchronize([original])
        #expect(runner.submit(original) == .ruleBusy)
        runner.synchronize([rule("same", command: "printf replacement", enabled: false)])
        queue.resume()
        let cancelled = await receipts.waitFor(2)
        #expect(cancelled.last?.outcome == .cancelled)
        let replacement = rule("same", command: "printf replacement", enabled: false)
        #expect(runner.submit(replacement) == .queued)
        let completed = await receipts.waitFor(3)
        #expect(completed.last?.outcome == .completed(status: 0))
        #expect(completed.last?.output == Data("replacement".utf8))
        runner.stop()
    }

    @Test("stdout and stderr drain beyond pipe capacity with a bounded tail and true exit status")
    func combinedOutput() async {
        let receipts = Receipts()
        let runner = MenuBarScriptRunner(report: receipts.record)
        runner.start()
        defer { runner.stop() }
        let command = "i=0; while [ \"$i\" -lt 3000 ]; do printf '012345678901234567890123456789\\n'; i=$((i+1)); done; printf 'stderr-tail' >&2; exit 7"
        #expect(runner.submit(rule("flood", command: command)) == .queued)
        let receipt = await receipts.waitFor(1).first
        #expect(receipt?.outcome == .completed(status: 7))
        #expect(receipt?.output.count == MenuBarScriptRunner.outputLimit)
        #expect(receipt?.output.suffix(11) == Data("stderr-tail".utf8))
    }

    @Test("invalid shell text fails truthfully without running a truncated command")
    func invalidCommand() async {
        let receipts = Receipts()
        let runner = MenuBarScriptRunner(report: receipts.record)
        runner.start()
        #expect(runner.submit(rule("invalid", command: "printf unwanted\0ignored")) == .queued)
        let receipt = await receipts.waitFor(1).first
        #expect(receipt?.outcome == .launchFailed(errno: EINVAL))
        #expect(receipt?.output.isEmpty == true)
        #expect(runner.activeCount == 0)
        runner.stop()
    }

    @Test("stop, quit, edit, removal and disable terminate a real owned child", arguments: ["stop", "quit", "edit", "remove", "disable"])
    func ownedChild(reason: String) async throws {
        let fixture = try ChildFixture()
        defer { fixture.close() }
        let receipts = Receipts()
        let signals = Signals()
        let system = MenuBarScriptRunner.ProcessDriver.system
        let driver = MenuBarScriptRunner.ProcessDriver(observe: system.observe, reap: system.reap,
                                                       signalGroup: signals.send)
        let runner = MenuBarScriptRunner(process: driver, report: receipts.record)
        runner.start()
        defer { runner.stop() }
        let original = rule("child", command: fixture.command(leaveShell: false))
        #expect(runner.submit(original) == .queued)
        let childPID = try #require(fixture.waitUntilReady())
        #expect(childPID > 0)
        let exit = ProcessExit(childPID)
        defer { exit.close() }
        try #require(await exit.waitUntilRegistered())
        #expect(runner.activeCount == 1)
        switch reason {
        case "stop": runner.stop()
        case "quit":
            runner.shutdown()
            #expect(signals.sentKill, "quit must send KILL before returning, without a worker turn")
        case "edit": runner.synchronize([rule("child", command: "exit 0")])
        case "disable": runner.synchronize([rule("child", command: originalCommand(original), enabled: false)])
        default: runner.synchronize([])
        }
        #expect(await exit.waitUntilExited(), "the kernel must report the owned descendant's exit before its job receipt")
        let receipt = await receipts.waitFor(1).first
        #expect(receipt?.outcome == .cancelled)
        #expect(runner.activeCount == 0)
    }

    @Test("a completed shell cannot leave its background child holding the output pipe")
    func inheritedPipe() async throws {
        let fixture = try ChildFixture()
        defer { fixture.close() }
        let receipts = Receipts()
        let runner = MenuBarScriptRunner(report: receipts.record)
        runner.start()
        defer { runner.stop() }
        // The shell waits for a ready receipt from the child before exiting.
        #expect(runner.submit(rule("background", command: fixture.command(leaveShell: true))) == .queued)
        let childPID = try #require(fixture.waitUntilReady())
        let exit = ProcessExit(childPID)
        defer { exit.close() }
        try #require(await exit.waitUntilRegistered())
        try fixture.releaseShell()
        let receipt = await receipts.waitFor(1).first
        #expect(receipt?.outcome == .completed(status: 0))
        #expect(runner.activeCount == 0)
        #expect(await exit.waitUntilExited(), "shell completion must retire its pipe-holding descendant")
    }

    @Test("matched rules retain identity when several rules have the same script")
    func ruleIdentity() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule("one", command: "exit 0"), rule("two", command: "exit 0"),
                     rule("off", command: "exit 0", enabled: false)]
        #expect(engine.matchedRules(for: .screenLocked, rules: rules).map(\.id) == ["one", "two"])
    }

    private func originalCommand(_ rule: MenuBarTriggerRule) -> String {
        guard case .runScript(let command) = rule.action else { return "" }
        return command
    }

    private func scratch() throws -> URL {
        let directory = TestTemporaryDirectory.currentURL.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Register against the known live fixture PID before retirement. A kernel
    /// exit event proves death even while launchd has not reaped an orphan yet.
    private final class ProcessExit: @unchecked Sendable {
        private let source: DispatchSourceProcess
        private let registered = TestSignal()
        private let exited = TestSignal()

        init(_ pid: pid_t) {
            source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                queue: DispatchQueue(label: "script fixture child exit"))
            source.setRegistrationHandler { [weak self] in self?.registered.signal() }
            source.setEventHandler { [weak self] in self?.exited.signal() }
            source.resume()
        }

        func waitUntilRegistered() async -> Bool { await registered.wait() }
        func waitUntilExited() async -> Bool { await exited.wait() }

        func close() { source.cancel() }
        deinit { source.cancel() }
    }

    private struct ChildFixture {
        let directory: URL
        let ready: URL
        let blocked: URL
        let acknowledged: URL
        let readyFD: Int32
        let acknowledgedFD: Int32

        init() throws {
            directory = TestTemporaryDirectory.currentURL.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ready = directory.appendingPathComponent("ready")
            blocked = directory.appendingPathComponent("blocked")
            acknowledged = directory.appendingPathComponent("acknowledged")
            guard mkfifo(ready.path, 0o600) == 0, mkfifo(blocked.path, 0o600) == 0,
                  mkfifo(acknowledged.path, 0o600) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            readyFD = Darwin.open(ready.path, O_RDWR | O_NONBLOCK)
            guard readyFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            acknowledgedFD = Darwin.open(acknowledged.path, O_RDWR | O_NONBLOCK)
            guard acknowledgedFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }

        private func quote(_ text: String) -> String {
            "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        func command(leaveShell: Bool) -> String {
            // Ignore TERM to require the runner's KILL escalation. A shell trap
            // marker depends on Bash scheduling and cannot prove containment.
            let child = "trap '' TERM; printf '%s\\n' \"$$\" > \(quote(ready.path)); /bin/cat \(quote(blocked.path)); exit 0"
            if leaveShell {
                // The test releases the shell only after registering the child's
                // native exit observer, preventing observation of a recycled PID.
                return "/bin/sh -c \(quote(child)) & read -r acknowledged < \(quote(acknowledged.path)); exit 0"
            }
            return "/bin/sh -c \(quote(child)) & wait"
        }

        func releaseShell() throws {
            var byte: UInt8 = 10
            guard Darwin.write(acknowledgedFD, &byte, 1) == 1 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }

        func waitUntilReady() -> pid_t? {
            var data = Data()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var bytes = [UInt8](repeating: 0, count: 128)
            while ProcessInfo.processInfo.systemUptime < deadline {
                let count = Darwin.read(readyFD, &bytes, bytes.count)
                if count > 0 {
                    data.append(contentsOf: bytes.prefix(count))
                    if data.contains(10) { return pid_t(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
                }
                var descriptor = pollfd(fd: readyFD, events: Int16(POLLIN), revents: 0)
                _ = Darwin.poll(&descriptor, 1, 50)
            }
            return nil
        }

        func close() {
            Darwin.close(readyFD)
            Darwin.close(acknowledgedFD)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
