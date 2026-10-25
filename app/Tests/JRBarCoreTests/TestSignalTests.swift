import Foundation
import JRBarTestSupport
import Testing

@Suite("Owned test signals", .timeLimit(.minutes(1)))
struct TestSignalTests {
    @Test("a callback before its waiter stays buffered")
    func bufferedSignal() async {
        let signal = TestSignal()
        signal.signal()
        #expect(await signal.wait())
    }

    @Test("cancellation ends a missing callback wait")
    func cancelledSignal() async {
        let signal = TestSignal()
        let waiter = Task { await signal.wait() }
        waiter.cancel()
        #expect(await waiter.value == false)
    }

    @Test("a test releases its Dispatch worker explicitly")
    func ownedWorker() async {
        let entered = TestSignal()
        let finished = TestSignal()
        let gate = TestGate()
        defer { gate.signal() }
        DispatchQueue.global().async {
            entered.signal()
            gate.wait()
            finished.signal()
        }
        #expect(await entered.wait())
        gate.signal()
        #expect(await finished.wait())
        gate.wait()
    }
}
