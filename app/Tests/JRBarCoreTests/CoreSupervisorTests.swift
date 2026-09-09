import Foundation
import Testing
@testable import JRBarCore

/// Drives the supervisor with tiny shell scripts and a scaled-down backoff.
@Suite("Core supervisor", .serialized)
struct CoreSupervisorTests {
    static func wait(timeout: TimeInterval = 10, until condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
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
        let supervisor = CoreSupervisor(executable: "/bin/sh", arguments: ["-c", "trap 'echo bye; exit 0' TERM; echo up; while :; do sleep 0.05; done"], backoffScale: 0.02)
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
        #expect(await Self.wait(timeout: 2) { log.lines.contains("stdout: bye") })
        #expect(kill(pid, 0) != 0 || errno == ESRCH, "the child is gone")
        try await Task.sleep(for: .milliseconds(150))
        #expect(supervisor.state == .stopped, "no restart after an intentional stop")
    }

    @Test("a child that ignores SIGTERM gets SIGKILL after the grace period")
    func killsAfterGrace() async throws {
        let supervisor = CoreSupervisor(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; echo stubborn; while :; do sleep 0.05; done"], backoffScale: 0.02)
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
}
