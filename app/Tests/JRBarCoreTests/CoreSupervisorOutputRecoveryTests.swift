import Darwin
import Foundation
import JRBarTestSupport
import Testing
@testable import JRBarCore

@Suite("Core supervisor output recovery", .serialized)
struct CoreSupervisorOutputRecoveryTests {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var output: [String] = []
        private var writers: [FileHandle] = []
        private var launches = 0
        var lines: [String] { lock.withLock { output } }
        func nextLaunch() -> Int { lock.withLock { launches += 1; return launches } }
        func append(_ stream: String, _ line: String) { lock.withLock { output.append("\(stream): \(line)") } }
        func retainWriter(of pipe: Pipe) throws {
            let descriptor = dup(pipe.fileHandleForWriting.fileDescriptor)
            guard descriptor >= 0 else { throw POSIXError(.EBADF) }
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                close(descriptor)
                throw POSIXError(.EBADF)
            }
            lock.withLock { writers.append(FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)) }
        }
        func closeWriters() {
            let held = lock.withLock { let held = writers; writers.removeAll(); return held }
            for writer in held { try? writer.close() }
        }
    }

    private func until(_ predicate: @Sendable () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate(), clock.now < deadline, !Task.isCancelled { await Task.yield() }
        return predicate()
    }

    @Test("Restart does not wait for an inherited output writer to close", arguments: ["stdout", "stderr", "both", "none"])
    func retainedWriterDoesNotBlockReplacement(stream: String) async throws {
        let capture = Capture()
        let supervisor = CoreSupervisor(executable: "/usr/bin/python3", arguments: ["-u", "-c", """
            import signal, sys
            signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
            print("ready", flush=True)
            sys.stdout.write("out-tail")
            sys.stdout.flush()
            sys.stderr.write("err-tail")
            sys.stderr.flush()
            signal.pause()
            """], backoffScale: 0.001)
        supervisor.onOutput = { capture.append($0, $1) }
        supervisor.onExit = { _ in capture.append("event", "exit") }
        supervisor.processRunHook = { process in
            if stream == "stdout" || stream == "both" {
                try capture.retainWriter(of: try #require(process.standardOutput as? Pipe))
            }
            if stream == "stderr" || stream == "both" {
                try capture.retainWriter(of: try #require(process.standardError as? Pipe))
            }
            try process.run()
        }
        supervisor.start()
        defer {
            supervisor.stop(gracePeriod: 0)
            capture.closeWriters()
        }
        try #require(await until { capture.lines.filter { $0 == "stdout: ready" }.count == 1 })
        let original = supervisor.state
        guard case .running(let originalPID) = original else {
            Issue.record("Synthetic child did not start")
            return
        }
        supervisor.restart()
        #expect(await until { kill(originalPID, 0) != 0 }, "The synthetic child itself must have exited")
        #expect(await until { capture.lines.filter { $0 == "stdout: ready" }.count == 2 },
                "A retained \(stream) writer blocked replacement after the child exited")
        #expect(supervisor.state != original)
        let lines = capture.lines
        #expect(lines.contains("stdout: out-tail"))
        #expect(lines.contains("stderr: err-tail"))
        let exit = try #require(lines.firstIndex(of: "event: exit"))
        #expect(try #require(lines.firstIndex(of: "stdout: out-tail")) < exit)
        #expect(try #require(lines.firstIndex(of: "stderr: err-tail")) < exit)
        #expect(lines.filter { $0 == "stdout: out-tail" }.count == 1)
        #expect(lines.filter { $0 == "stderr: err-tail" }.count == 1)
    }

    @Test("overlapping child lifetimes keep partial lines separate and flush each before its exit")
    func overlappingChildrenKeepSeparateOutput() async throws {
        let capture = Capture()
        let release = TestGate()
        let supervisor = CoreSupervisor(executable: "/usr/bin/python3", backoffScale: 0.001)
        supervisor.onOutput = { stream, line in
            capture.append(stream, line)
            if stream == "stdout", line == "old-ready" {
                release.wait()
            }
        }
        supervisor.onExit = { _ in capture.append("event", "exit") }
        supervisor.processRunHook = { process in
            let prefix = capture.nextLaunch() == 1 ? "old" : "new"
            process.arguments = ["-u", "-c", """
                import os, signal, sys
                signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
                os.write(2, b"\(prefix)-error")
                os.write(1, b"\(prefix)-ready\\n\(prefix)-tail")
                signal.pause()
                """]
            try capture.retainWriter(of: try #require(process.standardOutput as? Pipe))
            try capture.retainWriter(of: try #require(process.standardError as? Pipe))
            try process.run()
        }
        supervisor.start()
        defer {
            release.signal()
            supervisor.stop(gracePeriod: 0)
            capture.closeWriters()
        }
        try #require(await until { capture.lines.contains("stdout: old-ready") })
        supervisor.stop(gracePeriod: 0)
        supervisor.start()
        release.signal()
        try #require(await until { capture.lines.contains("stdout: new-ready") })
        supervisor.stop(gracePeriod: 0)
        try #require(await until { capture.lines.filter { $0 == "event: exit" }.count == 2 })
        let lines = capture.lines
        let exits = lines.indices.filter { lines[$0] == "event: exit" }
        try #require(exits.count == 2)
        for (prefix, exit) in zip(["old", "new"], exits) {
            for stream in ["stdout", "stderr"] {
                let tail = "\(stream): \(prefix)-\(stream == "stdout" ? "tail" : "error")"
                #expect(lines.filter { $0 == tail }.count == 1)
                #expect(try #require(lines.firstIndex(of: tail)) < exit)
            }
        }
        #expect(!lines.contains("gate: timed out"))
    }

    @Test("an output callback can stop its child without blocking output finalization")
    func outputCallbackCanStop() async throws {
        let capture = Capture()
        let supervisor = CoreSupervisor(executable: "/usr/bin/python3", arguments: ["-u", "-c", """
            import signal
            print("ready", flush=True)
            signal.pause()
            """], backoffScale: 0.001)
        supervisor.onOutput = { [weak supervisor] stream, line in
            capture.append(stream, line)
            if stream == "stdout", line == "ready" {
                supervisor?.stop(gracePeriod: 0)
                capture.append("event", "callback stopped")
            }
        }
        supervisor.onExit = { _ in capture.append("event", "exit") }
        supervisor.start()
        defer { supervisor.stop(gracePeriod: 0) }
        #expect(await until { capture.lines.contains("event: callback stopped") })
        #expect(await until { capture.lines.contains("event: exit") })
        #expect(supervisor.state == .stopped)
    }
}
