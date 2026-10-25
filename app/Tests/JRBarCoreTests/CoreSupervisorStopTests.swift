import Darwin
import Foundation
import JRBarTestSupport
import Testing
@testable import JRBarCore

@Suite("Core supervisor overlapping stops", .serialized, .timeLimit(.minutes(1)))
struct CoreSupervisorStopTests {
    final class Launches: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }

    private func supervisor() -> CoreSupervisor {
        CoreSupervisor(executable: "/usr/bin/env", arguments: ["python3", "-c", """
        import signal
        signal.signal(signal.SIGTERM, lambda *_: print('term', flush=True))
        print('ready', flush=True)
        while True: signal.pause()
        """])
    }

    @Test("overlapping waiting stops both wait for the child to exit")
    func overlappingStops() async throws {
        let core = supervisor()
        let ready = TestSignal()
        let terminated = TestSignal()
        let firstDone = TestSignal()
        core.onOutput = { _, line in
            if line == "ready" { ready.signal() }
            if line == "term" { terminated.signal() }
        }
        core.start()
        defer { core.stop(gracePeriod: 0) }
        try #require(await ready.wait())
        guard case .running(let pid) = core.state else { Issue.record("child did not start"); return }
        DispatchQueue.global().async {
            core.stop(gracePeriod: 2)
            firstDone.signal()
        }
        try #require(await terminated.wait())
        core.stop(gracePeriod: 0)
        #expect(kill(pid, 0) != 0, "a waiting stop returned with its child alive")
        #expect(core.state == .stopped)
        #expect(await firstDone.wait())
        #expect(core.state == .stopped)
    }

    @Test("a nonwaiting stop permits a replacement and a waiting stop joins both children")
    func nonwaitingStopThenWait() async throws {
        let core = supervisor()
        let ready = TestSignal()
        let releaseOutput = TestGate()
        let launches = Launches()
        core.processRunHook = { child in
            launches.add()
            try child.run()
        }
        core.onOutput = { _, line in
            if line == "ready" {
                ready.signal()
                releaseOutput.wait()
            }
        }
        core.start()
        defer {
            releaseOutput.signal()
            core.stop(gracePeriod: 0)
        }
        try #require(await ready.wait())
        guard case .running(let pid) = core.state else { Issue.record("child did not start"); return }
        core.stop(gracePeriod: 0, waitForExit: false)
        core.start()
        #expect(launches.count == 2, "start must admit a replacement after a nonwaiting stop")
        guard case .running(let replacementPID) = core.state else { Issue.record("replacement did not start"); return }
        core.stop(gracePeriod: 0)
        #expect(kill(pid, 0) != 0)
        #expect(kill(replacementPID, 0) != 0)
        #expect(core.state == .stopped)
        releaseOutput.signal()
        core.start()
        #expect(launches.count == 3, "a completed stop must allow a fresh launch")
        core.stop(gracePeriod: 0)
        #expect(core.state == .stopped)
    }
}
