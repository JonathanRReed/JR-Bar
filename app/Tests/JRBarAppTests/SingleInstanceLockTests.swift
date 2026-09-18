import Foundation
import Testing
@testable import JRBarApp

/// The single-instance flock: one holder per state directory, a second
/// acquire yields, and releasing the fd frees the lock again.
@Suite struct SingleInstanceLockTests {
    @Test func secondAcquireYieldsWhileFirstHolds() throws {
        let dir = NSTemporaryDirectory() + "jrbar-lock-\(UUID().uuidString)"
        let first = try #require(SingleInstanceLock.acquire(stateDirectory: dir, environment: [:]))
        #expect(SingleInstanceLock.acquire(stateDirectory: dir, environment: [:]) == nil)
        SingleInstanceLock.release(first)
        let reacquired = try #require(SingleInstanceLock.acquire(stateDirectory: dir, environment: [:]))
        SingleInstanceLock.release(reacquired)
    }

    @Test func allowMultiBypassesTheLock() {
        let dir = NSTemporaryDirectory() + "jrbar-lock-\(UUID().uuidString)"
        #expect(SingleInstanceLock.acquire(
            stateDirectory: dir, environment: ["JRBAR_ALLOW_MULTI": "1"]) == -1)
    }
}
