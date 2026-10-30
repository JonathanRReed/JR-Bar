import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Keep Awake handover intent")
struct KeepAwakeHandoverTests {
    @MainActor
    private final class Replies {
        var requests: [CoreAwakeRequest?] = []
        private var reply: CheckedContinuation<SystemTogglesStore.LeaseAnswer, Never>?
        private var closed = false
        private var waits: [UUID: (count: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]

        func send(_ request: CoreAwakeRequest?) async -> SystemTogglesStore.LeaseAnswer {
            requests.append(request)
            for (id, wait) in waits where requests.count >= wait.count {
                waits.removeValue(forKey: id)?.continuation.resume(returning: true)
            }
            guard !closed else { return .failed("Synthetic reply closed.") }
            return await withCheckedContinuation { continuation in
                reply = continuation
            }
        }

        func waitForRequest(_ count: Int) async -> Bool {
            if requests.count >= count { return true }
            if closed { return false }
            // Request arrival wakes the waiter directly instead of adding
            // polling tasks to the same actor that sends the next request.
            let id = UUID()
            return await withCheckedContinuation { continuation in
                waits[id] = (count, continuation)
            }
        }

        func close() {
            closed = true
            take(.failed("Synthetic reply closed."))
            let pending = waits
            waits.removeAll()
            for wait in pending.values { wait.continuation.resume(returning: false) }
        }

        func take(_ answer: SystemTogglesStore.LeaseAnswer = .taken) {
            let pending = reply
            reply = nil
            pending?.resume(returning: answer)
        }
    }

    private func state(_ replies: Replies) -> (SystemTogglesStore.State, UserDefaults, String) {
        let suite = "jrbar-handover-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        state.takeAssertion = { _ in 0 }
        state.releaseAssertion = { _ in kIOReturnSuccess }
        state.sendLease = { await replies.send($0) }
        state.holdAwake(seconds: nil)
        return (state, defaults, suite)
    }

    @Test("turning off during handover releases the accepted daemon lease", arguments: [false, true])
    func turnOffDuringHandover(releaseFails: Bool) async throws {
        let replies = Replies()
        let (state, defaults, suite) = state(replies)
        defer { replies.close(); state.releaseAssertion = { _ in kIOReturnSuccess }; state.setAwake(false); defaults.removePersistentDomain(forName: suite) }
        state.releaseAssertion = { _ in releaseFails ? kIOReturnError : kIOReturnSuccess }
        state.noteDaemonHold(nil, live: true)
        let firstArrived = await replies.waitForRequest(1)
        try #require(firstArrived, "handover request did not arrive")
        let handover = state.handoverTask
        state.holdAwake(seconds: 0)
        #expect(state.awake.held == releaseFails)
        replies.take()
        let nextArrived = await replies.waitForRequest(2)
        try #require(nextArrived, "reconciliation request did not arrive")
        #expect(replies.requests[1] == nil)
        replies.take()
        await handover?.value
    }

    @Test("the latest manual deadline survives a display change during handover")
    func latestHoldAndDisplay() async throws {
        let replies = Replies()
        let (state, defaults, suite) = state(replies)
        defer { replies.close(); state.setAwake(false); defaults.removePersistentDomain(forName: suite) }
        state.noteDaemonHold(nil, live: true)
        let firstArrived = await replies.waitForRequest(1)
        try #require(firstArrived, "handover request did not arrive")
        let handover = state.handoverTask
        state.holdAwake(seconds: 900)
        let expectedDeadline = try #require(state.awakeUntil)
        state.setAwakeKeepsDisplay(true)
        replies.take()
        let nextArrived = await replies.waitForRequest(2)
        try #require(nextArrived, "reconciliation request did not arrive")
        let newest = replies.requests[1]
        #expect(newest?.display == false)
        #expect(state.awakeKeepsDisplay)
        if let newest, case .until(let end) = newest.shape {
            #expect(end == expectedDeadline.timeIntervalSince1970)
        } else { Issue.record("the newer timed hold was lost") }
        #expect(state.awake.held)
        replies.take()
        await handover?.value
        #expect(!state.awake.held)
    }

    @Test("an agents-finish choice survives a display change during handover")
    func agentsChoiceAndDisplay() async throws {
        let replies = Replies()
        let (state, defaults, suite) = state(replies)
        defer { replies.close(); state.setAwake(false); defaults.removePersistentDomain(forName: suite) }
        state.holdAwake(seconds: 900)
        state.noteDaemonHold(nil, live: true)
        let firstArrived = await replies.waitForRequest(1)
        try #require(firstArrived, "handover request did not arrive")
        let handover = state.handoverTask
        state.holdAwakeUntilAgentsFinish()
        state.setAwakeKeepsDisplay(true)
        replies.take()
        let nextArrived = await replies.waitForRequest(2)
        try #require(nextArrived, "reconciliation request did not arrive")
        #expect(replies.requests[1] == CoreAwakeRequest(.untilAgentsFinish(sessions: nil), display: false))
        #expect(state.awakeKeepsDisplay)
        replies.take()
        await handover?.value
        #expect(!state.awake.held)
    }

    @Test("an unchanged handover releases the local assertion only after acceptance")
    func normalHandover() async throws {
        let replies = Replies()
        let (state, defaults, suite) = state(replies)
        defer { replies.close(); state.setAwake(false); defaults.removePersistentDomain(forName: suite) }
        state.noteDaemonHold(nil, live: true)
        let firstArrived = await replies.waitForRequest(1)
        try #require(firstArrived, "handover request did not arrive")
        let handover = state.handoverTask
        #expect(state.awake.held)
        replies.take()
        await handover?.value
        #expect(!state.awake.held)
        #expect(replies.requests.count == 1)
    }

    @Test("expiry during handover does not leave a daemon hold behind", arguments: [false, true])
    func expiryDuringHandover(releaseFails: Bool) async throws {
        let replies = Replies()
        let (state, defaults, suite) = state(replies)
        defer { replies.close(); state.releaseAssertion = { _ in kIOReturnSuccess }; state.setAwake(false); defaults.removePersistentDomain(forName: suite) }
        state.releaseAssertion = { _ in releaseFails ? kIOReturnError : kIOReturnSuccess }
        state.holdAwake(seconds: 900)
        state.noteDaemonHold(nil, live: true)
        let firstArrived = await replies.waitForRequest(1)
        try #require(firstArrived, "handover request did not arrive")
        let handover = state.handoverTask
        // The local expiry task ends its assertion through this exact path.
        state.setAwake(false)
        replies.take()
        let nextArrived = await replies.waitForRequest(2)
        try #require(nextArrived, "reconciliation request did not arrive")
        #expect(replies.requests[1] == nil)
        #expect(!state.awakeClockRunning)
        replies.take()
        await handover?.value
    }

    @Test("a failed turn-off reconciliation reports that the monitor did not release")
    func failedCleanupReportsError() async throws {
        let replies = Replies()
        let (state, defaults, suite) = state(replies)
        defer { replies.close(); state.setAwake(false); defaults.removePersistentDomain(forName: suite) }
        state.noteDaemonHold(nil, live: true)
        let firstArrived = await replies.waitForRequest(1)
        try #require(firstArrived, "handover request did not arrive")
        let handover = state.handoverTask
        state.holdAwake(seconds: 0)
        replies.take()
        let nextArrived = await replies.waitForRequest(2)
        try #require(nextArrived, "reconciliation request did not arrive")
        #expect(replies.requests[1] == nil)
        replies.take(.failed("Synthetic release failed."))
        await handover?.value
        #expect(state.lastError == "Awake: Synthetic release failed.")
    }

    @Test("a reply from the old connection cannot settle the new connection's hold",
          arguments: [SystemTogglesStore.LeaseAnswer.taken, .unavailable, .failed("Old monitor failed.")])
    func reconnectDuringHandover(oldAnswer: SystemTogglesStore.LeaseAnswer) async throws {
        let replies = Replies()
        let (state, defaults, suite) = state(replies)
        defer { replies.close(); state.setAwake(false); defaults.removePersistentDomain(forName: suite) }
        state.noteDaemonHold(nil, live: true)
        let firstArrived = await replies.waitForRequest(1)
        try #require(firstArrived, "handover request did not arrive")
        let handover = state.handoverTask
        state.noteDaemonHold(nil, live: false)
        state.noteDaemonHold(nil, live: true)
        replies.take(oldAnswer)
        let nextArrived = await replies.waitForRequest(2)
        try #require(nextArrived, "the new connection was not asked to hold")
        #expect(state.awake.held)
        #expect(!state.leaseUnsupported)
        #expect(state.lastError == nil)
        #expect(replies.requests[1] == replies.requests[0])
        replies.take()
        await handover?.value
        #expect(!state.awake.held)
    }

    @Test("a successful retry clears only the previous Awake error")
    func successfulRecoveryClearsAwakeError() async throws {
        let replies = Replies()
        let (state, defaults, suite) = state(replies)
        defer { replies.close(); state.setAwake(false); defaults.removePersistentDomain(forName: suite) }
        state.noteDaemonHold(nil, live: true)
        let firstArrived = await replies.waitForRequest(1)
        try #require(firstArrived)
        let first = state.handoverTask
        replies.take(.failed("Synthetic handover failed."))
        await first?.value
        #expect(state.lastError == "Awake: Synthetic handover failed.")
        #expect(state.awake.held)
        state.noteDaemonHold(nil, live: true)
        let nextArrived = await replies.waitForRequest(2)
        try #require(nextArrived)
        let retry = state.handoverTask
        replies.take()
        await retry?.value
        #expect(state.lastError == nil)
    }

    @Test("a refused agents-finish choice keeps the original timed fallback")
    func refusedAgentsChoiceKeepsDeadline() async throws {
        let replies = Replies()
        let (state, defaults, suite) = state(replies)
        defer { replies.close(); state.setAwake(false); defaults.removePersistentDomain(forName: suite) }
        state.holdAwake(seconds: 900)
        let original = state.awakeReading
        state.noteDaemonHold(nil, live: true)
        let firstArrived = await replies.waitForRequest(1)
        try #require(firstArrived)
        let handover = state.handoverTask
        state.holdAwakeUntilAgentsFinish()
        replies.take()
        let nextArrived = await replies.waitForRequest(2)
        try #require(nextArrived)
        #expect(replies.requests[1]?.shape == .untilAgentsFinish(sessions: nil))
        replies.take(.refused("No agents are working."))
        await handover?.value
        #expect(state.awake.held)
        #expect(state.awakeReading.state == original.state)
        #expect(state.awakeClockRunning)
        #expect(state.lastError == "Awake: No agents are working.")
    }

    @Test("accepting a handover preserves another utility's error")
    func unrelatedErrorSurvivesHandover() async throws {
        let replies = Replies()
        let (state, defaults, suite) = state(replies)
        defer { replies.close(); state.setAwake(false); defaults.removePersistentDomain(forName: suite) }
        state.lastError = "Dock: Synthetic failure."
        state.noteDaemonHold(nil, live: true)
        let firstArrived = await replies.waitForRequest(1)
        try #require(firstArrived)
        let handover = state.handoverTask
        replies.take()
        await handover?.value
        #expect(state.lastError == "Dock: Synthetic failure.")
    }

    @Test("a changed hello invalidates handover even when both observations are live")
    func coalescedReconnectDuringHandover() async throws {
        let replies = Replies()
        let (state, defaults, suite) = state(replies)
        defer { replies.close(); state.setAwake(false); defaults.removePersistentDomain(forName: suite) }
        state.noteDaemonHold(nil, live: true, hello: CoreHello(pid: 1, stream: "old"))
        let firstArrived = await replies.waitForRequest(1)
        try #require(firstArrived)
        let handover = state.handoverTask
        state.noteDaemonHold(nil, live: true, hello: CoreHello(pid: 2, stream: "new"))
        replies.take()
        let nextArrived = await replies.waitForRequest(2)
        try #require(nextArrived)
        #expect(state.awake.held)
        #expect(replies.requests[1] == replies.requests[0])
        replies.take()
        await handover?.value
        #expect(!state.awake.held)
    }

    @Test("an old ordinary lease reply cannot change a reconnected monitor",
          arguments: [SystemTogglesStore.LeaseAnswer.taken, .unavailable,
                      .refused("Old monitor refused."), .failed("Old monitor failed.")])
    func reconnectDuringOrdinaryLease(oldAnswer: SystemTogglesStore.LeaseAnswer) async throws {
        let replies = Replies()
        let (state, defaults, suite) = state(replies)
        defer { replies.close(); state.setAwake(false); defaults.removePersistentDomain(forName: suite) }
        state.setAwake(false)
        state.noteDaemonHold(nil, live: true, hello: CoreHello(pid: 1, stream: "old"))
        state.holdAwake(seconds: 900)
        let arrived = await replies.waitForRequest(1)
        try #require(arrived)
        let pending = state.leaseTask
        state.noteDaemonHold(nil, live: true, hello: CoreHello(pid: 2, stream: "new"))
        state.lastError = "Awake: New monitor failure."
        #expect(!state.applying.contains(.keepAwake))
        replies.take(oldAnswer)
        await pending?.value
        #expect(!state.awake.held)
        #expect(!state.leaseUnsupported)
        #expect(state.lastError == "Awake: New monitor failure.")
    }


    @Test("an older ordinary reply cannot clear a newer request's applying state")
    func newerOrdinaryLeaseOwnsResponse() async throws {
        let replies = Replies()
        let (state, defaults, suite) = state(replies)
        defer { replies.close(); state.setAwake(false); defaults.removePersistentDomain(forName: suite) }
        state.setAwake(false)
        state.noteDaemonHold(nil, live: true)
        state.holdAwake(seconds: 900)
        let firstArrived = await replies.waitForRequest(1)
        try #require(firstArrived)
        let first = state.leaseTask
        replies.take(.unavailable)
        state.holdAwake(seconds: 1800)
        let latest = state.leaseTask
        await first?.value
        let nextArrived = await replies.waitForRequest(2)
        try #require(nextArrived)
        #expect(state.applying.contains(.keepAwake))
        #expect(!state.awake.held)
        #expect(!state.leaseUnsupported)
        replies.take()
        await latest?.value
        #expect(!state.applying.contains(.keepAwake))
    }

}
