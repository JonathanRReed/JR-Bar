import Darwin
import Foundation
import Testing
@testable import JRBarCore

@Suite("Core supervisor restart recovery", .serialized)
struct CoreSupervisorRestartTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var ready = 0
        private var exits: [CoreSupervisor.Exit] = []
        var readyCount: Int { lock.withLock { ready } }
        var recordedExits: [CoreSupervisor.Exit] { lock.withLock { exits } }
        func append(_ stream: String, _ line: String) {
            if stream == "stdout", line == "ready" { lock.withLock { ready += 1 } }
        }
        func append(_ exit: CoreSupervisor.Exit) { lock.withLock { exits.append(exit) } }
    }

    private final class Deadlines: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(delay: TimeInterval, action: @Sendable () -> Void)] = []
        var delays: [TimeInterval] { lock.withLock { entries.map { $0.delay } } }
        func add(_ delay: TimeInterval, _ action: @escaping @Sendable () -> Void) {
            lock.withLock { entries.append((delay, action)) }
        }
        func fire(_ index: Int) {
            let action = lock.withLock { entries[index].action }
            action()
        }
    }

    private func child(log: Log, deadlines: Deadlines? = nil, cooperative: Bool = false) -> CoreSupervisor {
        let handler = cooperative ? "lambda *_: sys.exit(0)" : "signal.SIG_IGN"
        let supervisor = CoreSupervisor(executable: "/usr/bin/python3", arguments: ["-u", "-c", """
            import signal, sys
            signal.signal(signal.SIGTERM, \(handler))
            print("ready", flush=True)
            signal.pause()
            """], backoffScale: 0.001)
        supervisor.onOutput = { log.append($0, $1) }
        supervisor.onExit = { log.append($0) }
        if let deadlines { supervisor.restartEscalationHook = { deadlines.add($0, $1) } }
        return supervisor
    }

    private func until(_ predicate: @Sendable () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(6))
        while !predicate(), clock.now < deadline, !Task.isCancelled { await Task.yield() }
        return predicate()
    }

    @Test("Restart replaces a ready child that ignores termination without waiting on the caller")
    func stubbornChildIsReplaced() async throws {
        let supervisor = CoreSupervisor(executable: "/usr/bin/python3", arguments: ["-u", "-c", """
            import signal
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            print("ready", flush=True)
            signal.pause()
            """], backoffScale: 0.001)
        let log = Log()
        supervisor.onOutput = { log.append($0, $1) }
        supervisor.start()
        defer { supervisor.stop(gracePeriod: 0) }
        try #require(await until { log.readyCount == 1 })
        guard case .running(let original) = supervisor.state else {
            Issue.record("Synthetic child did not start")
            return
        }
        let clock = ContinuousClock()
        let started = clock.now
        supervisor.restart()
        #expect(started.duration(to: clock.now) < .milliseconds(250), "Restart must not wait for child termination")
        #expect(await until { log.readyCount == 2 }, "Restart left its termination-resistant child running")
        if case .running(let replacement) = supervisor.state {
            #expect(replacement != original)
        } else {
            Issue.record("Restart did not leave a replacement running")
        }
    }

    @Test("repeated Restart clicks preserve one deadline and produce one replacement")
    func repeatedRestartsCoalesce() async throws {
        let log = Log(), deadlines = Deadlines()
        let supervisor = child(log: log, deadlines: deadlines)
        supervisor.start()
        defer { supervisor.stop(gracePeriod: 0) }
        try #require(await until { log.readyCount == 1 })
        let original = supervisor.state
        for _ in 0..<20 { supervisor.restart() }
        #expect(deadlines.delays == [3])
        #expect(supervisor.state == original)
        deadlines.fire(0)
        try #require(await until { log.readyCount == 2 })
        #expect(supervisor.state != original)
        #expect(log.recordedExits.count == 1)
        #expect(log.recordedExits.first?.signal == SIGKILL)
    }

    @Test("a cooperative child exits normally and its replacement survives the stale deadline")
    func cooperativeExitRetiresDeadline() async throws {
        let log = Log(), deadlines = Deadlines()
        let supervisor = child(log: log, deadlines: deadlines, cooperative: true)
        supervisor.start()
        defer { supervisor.stop(gracePeriod: 0) }
        try #require(await until { log.readyCount == 1 })
        supervisor.restart()
        try #require(await until { log.readyCount == 2 })
        #expect(deadlines.delays == [3])
        #expect(log.recordedExits.first?.status == 0)
        #expect(log.recordedExits.first?.signal == nil)
        let replacement = supervisor.state
        deadlines.fire(0)
        #expect(supervisor.state == replacement)
        #expect(log.recordedExits.count == 1)
    }

    @Test("Stop retires pending Restart before a later Start owns a replacement")
    func stopAndStartRetireDeadline() async throws {
        let log = Log(), deadlines = Deadlines()
        let supervisor = child(log: log, deadlines: deadlines)
        supervisor.start()
        defer { supervisor.stop(gracePeriod: 0) }
        try #require(await until { log.readyCount == 1 })
        supervisor.restart()
        try #require(deadlines.delays == [3])
        supervisor.stop(gracePeriod: 0)
        deadlines.fire(0)
        #expect(supervisor.state == .stopped)
        #expect(supervisor.recentFailures == 0)
        supervisor.start()
        try #require(await until { log.readyCount == 2 })
        let replacement = supervisor.state
        deadlines.fire(0)
        #expect(supervisor.state == replacement)
        #expect(supervisor.recentFailures == 0)
    }

    @Test("each replacement gets a new restart deadline without inheriting the previous one")
    func successiveRestartsHaveSeparateOwners() async throws {
        let log = Log(), deadlines = Deadlines()
        let supervisor = child(log: log, deadlines: deadlines)
        supervisor.start()
        defer { supervisor.stop(gracePeriod: 0) }
        try #require(await until { log.readyCount == 1 })
        supervisor.restart()
        try #require(deadlines.delays == [3])
        deadlines.fire(0)
        try #require(await until { log.readyCount == 2 })
        supervisor.restart()
        try #require(deadlines.delays == [3, 3])
        let second = supervisor.state
        deadlines.fire(0)
        #expect(supervisor.state == second)
        deadlines.fire(1)
        try #require(await until { log.readyCount == 3 })
        #expect(supervisor.state != second)
        #expect(log.recordedExits.count == 2)
    }

    @Test("a pending Restart does not retain the supervisor or make destruction wait")
    func pendingRestartDoesNotRetainOwner() async throws {
        let log = Log(), deadlines = Deadlines()
        var supervisor: CoreSupervisor? = child(log: log, deadlines: deadlines)
        weak var released = supervisor
        supervisor?.start()
        defer { supervisor?.stop(gracePeriod: 0) }
        try #require(await until { log.readyCount == 1 })
        guard case .running(let original) = supervisor?.state else {
            Issue.record("Synthetic child did not start")
            return
        }
        supervisor?.restart()
        try #require(deadlines.delays == [3])
        let clock = ContinuousClock()
        let started = clock.now
        supervisor = nil
        #expect(started.duration(to: clock.now) < .milliseconds(250))
        #expect(released == nil)
        #expect(await until { kill(original, 0) != 0 })
        deadlines.fire(0)
        #expect(released == nil)
    }
}
