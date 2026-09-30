import Foundation
import Testing
@testable import JRBarApp

/// The single-instance flock: one holder per state directory, a second
/// acquire yields, and releasing the fd frees the lock again. Only proven
/// contention yields: a lock that cannot be taken at all lets the app run.
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

    @Test func unopenableStateDirectoryDoesNotYield() throws {
        // A regular file where the state directory's parent should be: the
        // directory cannot be made and the lock file cannot be opened.
        let blocker = NSTemporaryDirectory() + "jrbar-lock-\(UUID().uuidString)"
        try Data().write(to: URL(fileURLWithPath: blocker))
        defer { try? FileManager.default.removeItem(atPath: blocker) }
        var reported: Int32?
        let result = SingleInstanceLock.acquire(stateDirectory: blocker + "/state", environment: [:],
                                                onUnavailable: { reported = $0 })
        #expect(result == -1, "no lock, but no other instance either: the app runs")
        #expect(reported == ENOTDIR)
    }

    @Test(.enabled(if: geteuid() != 0, "root ignores file modes"))
    func readOnlyExistingLockFileStillLocks() throws {
        let dir = NSTemporaryDirectory() + "jrbar-lock-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/app.lock"
        #expect(FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o444]))
        var reported: Int32?
        let first = try #require(SingleInstanceLock.acquire(stateDirectory: dir, environment: [:],
                                                            onUnavailable: { reported = $0 }))
        #expect(first >= 0, "the read-only fallback holds a real lock")
        #expect(reported == nil)
        #expect(SingleInstanceLock.acquire(stateDirectory: dir, environment: [:]) == nil,
                "and a second instance still yields to it")
        SingleInstanceLock.release(first)
    }

    @Test func contentionDoesNotReportUnavailable() throws {
        let dir = NSTemporaryDirectory() + "jrbar-lock-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let first = try #require(SingleInstanceLock.acquire(stateDirectory: dir, environment: [:]))
        var reported = false
        let second = SingleInstanceLock.acquire(stateDirectory: dir, environment: [:],
                                                onUnavailable: { _ in reported = true })
        #expect(second == nil)
        #expect(!reported, "contention is a yield, never an unavailable lock")
        SingleInstanceLock.release(first)
    }
}
