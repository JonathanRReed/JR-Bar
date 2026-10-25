import Foundation
import JRBarCore

final class TestReplyClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: TimeInterval = 0
    private var pending: [(TimeInterval, @Sendable () -> Void)] = []

    var clock: CoreReplyClock {
        CoreReplyClock { [self] seconds, expire in
            lock.withLock { pending.append((now + seconds, expire)) }
        }
    }

    func advance(by seconds: TimeInterval) {
        let due = lock.withLock {
            now += seconds
            let due = pending.filter { $0.0 <= now }
            pending.removeAll { $0.0 <= now }
            return due
        }
        for (_, expire) in due { expire() }
    }
}
