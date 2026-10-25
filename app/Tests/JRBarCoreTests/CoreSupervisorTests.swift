import Foundation
import JRBarTestSupport
import Testing
@testable import JRBarCore

/// Drives the supervisor with tiny shell scripts and a scaled-down backoff.
@Suite("Core supervisor", .serialized, .timeLimit(.minutes(1)))
struct CoreSupervisorTests {
    static func wait(until condition: @escaping @Sendable () -> Bool) async -> Bool {
        while !condition(), !Task.isCancelled { await Task.yield() }
        return condition()
    }

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        private var _states: [CoreSupervisor.State] = []
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
        var states: [CoreSupervisor.State] { lock.lock(); defer { lock.unlock() }; return _states }
        func add(_ line: String) { lock.lock(); _lines.append(line); lock.unlock() }
        func add(_ state: CoreSupervisor.State) { lock.lock(); _states.append(state); lock.unlock() }
    }

    @Test("a child that exits at once is restarted on the backoff schedule, then given up on")
    func restartsThenGivesUp() async throws {
        let log = Log()
        let supervisor = CoreSupervisor(executable: "/bin/sh", arguments: ["-c", "echo hello from $$; echo oops >&2; exit 3"],
                                        maxFailures: 4, failureWindow: 60, backoffScale: 0.02)
        supervisor.onOutput = { stream, line in log.add("\(stream): \(line)") }
        supervisor.onStateChange = { log.add($0) }
        supervisor.start()
        defer { supervisor.stop(gracePeriod: 0.2) }

        #expect(await Self.wait { supervisor.state == .crashed(failures: 4) }, "state was \(supervisor.state)")
        let lines = log.lines
        #expect(lines.filter { $0.hasPrefix("stdout: hello from") }.count == 4, "\(lines)")
        #expect(lines.filter { $0 == "stderr: oops" }.count == 4)
        #expect(lines.filter { $0 == "supervisor: core exited with status 3" }.count == 4)
        #expect(lines.contains { $0.hasPrefix("supervisor: core crashed 4 times") })
        let delays = log.states.compactMap { state -> TimeInterval? in
            if case .backingOff(_, let delay) = state { return delay / 0.02 }
            return nil
        }
        #expect(delays == [0.5, 1.0, 2.0], "the protocol's schedule before the fourth exit gives up")
        #expect(supervisor.recentFailures == 4)

        // Restart forgets the history and tries again.
        supervisor.restart()
        #expect(await Self.wait { log.lines.filter { $0.hasPrefix("stdout: hello from") }.count >= 5 })
        #expect(await Self.wait { supervisor.state == .crashed(failures: 4) })
    }

    @Test("a long-running child is terminated cleanly on stop")
    func stopsCleanly() async throws {
        let supervisor = CoreSupervisor(executable: "/usr/bin/python3", arguments: ["-u", "-c", """
            import signal, sys
            def finish(*_):
                print("bye", flush=True)
                sys.exit(0)
            signal.signal(signal.SIGTERM, finish)
            print("up", flush=True)
            signal.pause()
            """], backoffScale: 0.02)
        let log = Log()
        supervisor.onOutput = { stream, line in log.add("\(stream): \(line)") }
        supervisor.start()
        #expect(await Self.wait { log.lines.contains("stdout: up") })
        guard case .running(let pid) = supervisor.state else { Issue.record("expected running, got \(supervisor.state)"); return }
        #expect(pid > 0)
        let started = Date()
        supervisor.stop(gracePeriod: 3.0)
        #expect(Date().timeIntervalSince(started) < 2.5, "SIGTERM should be enough")
        #expect(supervisor.state == .stopped)
        #expect(await Self.wait { log.lines.contains("stdout: bye") })
        #expect(kill(pid, 0) != 0 || errno == ESRCH, "the child is gone")
        // stop() joined the owned child and its exit handler; no restart remains queued.
        #expect(supervisor.state == .stopped, "no restart after an intentional stop")
    }

    @Test("a child that ignores SIGTERM gets SIGKILL after the grace period")
    func killsAfterGrace() async throws {
        let supervisor = CoreSupervisor(executable: "/usr/bin/python3", arguments: ["-u", "-c", """
            import signal
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            print("stubborn", flush=True)
            signal.pause()
            """], backoffScale: 0.02)
        let log = Log()
        supervisor.onOutput = { stream, line in log.add("\(stream): \(line)") }
        supervisor.start()
        #expect(await Self.wait { log.lines.contains("stdout: stubborn") })
        let started = Date()
        supervisor.stop(gracePeriod: 0.3)
        let took = Date().timeIntervalSince(started)
        #expect(took >= 0.25 && took < 3, "took \(took)")
        #expect(supervisor.state == .stopped)
    }

    @Test("command lines split into an executable and arguments")
    func commandLine() async throws {
        let bare = try #require(CoreSupervisor(commandLine: "python3 scripts/mock-core.py --step 1"))
        #expect(bare.executable == "/usr/bin/env")
        #expect(bare.arguments == ["python3", "scripts/mock-core.py", "--step", "1"])
        let absolute = try #require(CoreSupervisor(commandLine: "/usr/bin/true"))
        #expect(absolute.executable == "/usr/bin/true")
        #expect(absolute.arguments.isEmpty)
        #expect(CoreSupervisor(commandLine: "   ") == nil)
        let missing = CoreSupervisor(executable: "/nonexistent/jrbar-core", maxFailures: 2, backoffScale: 0.01)
        let log = Log()
        missing.onOutput = { _, line in log.add(line) }
        missing.start()
        #expect(await Self.wait { missing.state == .crashed(failures: 2) })
        #expect(log.lines.contains { $0.hasPrefix("cannot launch /nonexistent/jrbar-core") })
        missing.stop(gracePeriod: 0)
    }

    /// Runs one shell script to its end and returns the log once the
    /// supervisor has given up (or stopped restarting).
    private func output(of script: String, maxFailures: Int = 1) async -> Log {
        let log = Log()
        let supervisor = CoreSupervisor(executable: "/bin/sh", arguments: ["-c", script],
                                        maxFailures: maxFailures, failureWindow: 60, backoffScale: 0.02)
        supervisor.onOutput = { stream, line in log.add("\(stream): \(line)") }
        supervisor.start()
        defer { supervisor.stop(gracePeriod: 0.2) }
        _ = await Self.wait { supervisor.state == .crashed(failures: maxFailures) }
        return log
    }

    @Test("output with an invalid byte in it keeps the line, with a replacement character")
    func invalidByteIsKept() async {
        let log = await output(of: "printf 'good\\n'; printf 'ok \\377 bad\\n'; exit 0")
        let lines = log.lines
        #expect(lines.contains("stdout: good"), "\(lines)")
        let odd = lines.first { $0.hasPrefix("stdout: ok ") }
        #expect(odd?.contains("\u{FFFD}") == true, "\(lines)")
        #expect(odd?.hasSuffix(" bad") == true, "\(lines)")
    }

    @Test("a non-ASCII character arrives whole")
    func emDashArrives() async {
        let log = await output(of: "printf '\\342\\200\\224 dash\\n'; exit 0")
        #expect(log.lines.contains("stdout: \u{2014} dash"), "\(log.lines)")
    }

    @Test("CRLF line endings split into lines without the carriage return")
    func crlfSplits() async {
        let log = await output(of: "printf 'one\\r\\ntwo\\n'; exit 0")
        let lines = log.lines.filter { $0.hasPrefix("stdout: ") }
        #expect(lines == ["stdout: one", "stdout: two"], "\(log.lines)")
    }

    @Test("a last line without a newline is kept at exit and never glued to the next child's output")
    func tailFlushedAtExit() async throws {
        let log = await output(of: "printf partial; exit 1", maxFailures: 2)
        let lines = log.lines
        #expect(lines.filter { $0 == "stdout: partial" }.count == 2, "\(lines)")
        #expect(!lines.contains("stdout: partialpartial"), "\(lines)")
        // The last line comes before the exit notice that follows it.
        let partialAt = try #require(lines.firstIndex(of: "stdout: partial"))
        let noticeAt = try #require(lines.firstIndex { $0.hasPrefix("supervisor: core exited") })
        #expect(partialAt < noticeAt, "\(lines)")
    }

    /// A settable flag polled from async tests (semaphore waits are
    /// unavailable in async contexts on this toolchain).
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _set = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return _set }
        func set() { lock.lock(); _set = true; lock.unlock() }
    }

    @Test("a stop that lands mid-spawn still kills the child and never wedges the supervisor")
    func stopDuringSpawn() async throws {
        let supervisor = CoreSupervisor(executable: "/usr/bin/python3",
                                        arguments: ["-u", "-c", "import signal; print('late', flush=True); signal.pause()"],
                                        backoffScale: 0.02)
        let runEntered = TestSignal()
        let releaseRun = TestGate()
        supervisor.processRunHook = { process in
            runEntered.signal()
            releaseRun.wait()
            try process.run()
        }
        let log = Log()
        supervisor.onOutput = { stream, line in log.add("\(stream): \(line)") }
        defer {
            supervisor.processRunHook = nil
            supervisor.stop(gracePeriod: 0.5)
        }

        let spawnThread = Thread { supervisor.start() }
        spawnThread.start()
        #expect(await runEntered.wait(), "spawn never reached run()")

        // stop() must wait out the in-flight spawn, then kill the child.
        let stopDone = TestSignal()
        let stopEntered = TestSignal()
        Thread.detachNewThread {
            stopEntered.signal()
            supervisor.stop(gracePeriod: 2.0)
            stopDone.signal()
        }
        // Give stop() a moment to block on the supervisor lock, then let
        // the spawn proceed: the child becomes visible and is terminated.
        #expect(await stopEntered.wait())
        releaseRun.signal()

        #expect(await stopDone.wait(), "stop() wedged on a mid-flight spawn")
        #expect(supervisor.state == .stopped)
        #expect(await Self.wait { log.lines.contains { $0.hasPrefix("supervisor: core exited") } },
                "the spawned child was never supervised to exit; lines: \(log.lines)")

        // And the supervisor is not stuck in .stopped: a fresh start works.
        supervisor.processRunHook = nil
        supervisor.start()
        #expect(await Self.wait { supervisor.isRunning })
        supervisor.stop(gracePeriod: 1.0)
        #expect(supervisor.state == .stopped)
    }

    enum SyntheticLaunchError: Error { case refused }

    @Test("a stop during a launch error keeps the stopped state and does not schedule a retry",
          arguments: [1, 2])
    func stopFromLaunchFailure(maxFailures: Int) {
        let supervisor = CoreSupervisor(executable: "/synthetic/jrbar-core", maxFailures: maxFailures)
        supervisor.processRunHook = { _ in throw SyntheticLaunchError.refused }
        let log = Log()
        supervisor.onStateChange = { log.add($0) }
        supervisor.onOutput = { [weak supervisor] _, line in
            if line.hasPrefix("cannot launch") { supervisor?.stop(gracePeriod: 0) }
        }

        supervisor.start()

        #expect(supervisor.state == .stopped)
        #expect(supervisor.recentFailures == 0)
        #expect(log.states == [.stopped])
    }

    @Test("concurrent starts reserve one launch before generating a secret")
    func concurrentStartsReserveOneLaunch() async {
        let supervisor = CoreSupervisor(executable: "/synthetic/jrbar-core", maxFailures: 1,
                                        authSecret: CoreAuthSecret())
        let generationEntered = TestSignal()
        let startDone = TestSignal()
        let releaseGeneration = TestGate()
        let log = Log()
        supervisor.secretGenerator = {
            log.add("secret")
            generationEntered.signal()
            releaseGeneration.wait()
            return Data(repeating: 7, count: CoreAuthSecret.byteCount)
        }
        supervisor.processRunHook = { _ in
            log.add("launch")
            throw SyntheticLaunchError.refused
        }
        defer {
            releaseGeneration.signal()
            supervisor.stop(gracePeriod: 0)
        }
        Thread.detachNewThread {
            supervisor.start()
            startDone.signal()
        }
        #expect(await generationEntered.wait())

        supervisor.start()
        #expect(log.lines == ["secret"], "another start must leave the reserved launch alone")
        releaseGeneration.signal()

        #expect(await startDone.wait())
        #expect(log.lines == ["secret", "launch"])
        #expect(supervisor.state == .crashed(failures: 1))
    }

    @Test("a stopped launch cannot clear the secret or count a failure for its replacement")
    func staleLaunchLeavesReplacementAlone() async {
        let secret = CoreAuthSecret()
        let supervisor = CoreSupervisor(executable: "/synthetic/jrbar-core", maxFailures: 1,
                                        authSecret: secret)
        let generationEntered = TestSignal()
        let oldStartDone = TestSignal()
        let releaseGeneration = TestGate()
        let log = Log()
        supervisor.secretGenerator = {
            generationEntered.signal()
            releaseGeneration.wait()
            return Data(repeating: 7, count: CoreAuthSecret.byteCount)
        }
        supervisor.processRunHook = { _ in
            log.add("old launch")
            throw SyntheticLaunchError.refused
        }
        defer {
            releaseGeneration.signal()
            supervisor.stop(gracePeriod: 0)
        }
        Thread.detachNewThread {
            supervisor.start()
            oldStartDone.signal()
        }
        #expect(await generationEntered.wait())
        supervisor.stop(gracePeriod: 0)
        // A replacement launch may own this holder while the old start is
        // still preparing its pipe. The abandoned start must not touch it.
        let replacement = Data(repeating: 9, count: CoreAuthSecret.byteCount)
        secret.set(replacement, daemonPID: 123)
        releaseGeneration.signal()

        #expect(await oldStartDone.wait())
        #expect(log.lines.isEmpty)
        #expect(secret.current == replacement)
        #expect(secret.supervisedPID == 123)
        #expect(supervisor.state == .stopped)
        #expect(supervisor.recentFailures == 0)
    }

    @Test("letting a supervisor go ends its child without waiting for it")
    func releaseDoesNotWait() async throws {
        var supervisor: CoreSupervisor? = CoreSupervisor(
            executable: "/usr/bin/python3", arguments: ["-u", "-c", """
            import signal
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            print("up", flush=True)
            signal.pause()
            """])
        let log = Log()
        supervisor?.onOutput = { stream, line in log.add("\(stream): \(line)") }
        supervisor?.start()
        #expect(await Self.wait { log.lines.contains("stdout: up") })
        guard case .running(let pid) = supervisor?.state else { Issue.record("expected running"); return }

        let started = Date()
        supervisor = nil
        #expect(Date().timeIntervalSince(started) < 0.5, "the destructor waited on the child")
        #expect(await Self.wait { kill(pid, 0) != 0 })
    }
}
