import AppKit
import Testing
@testable import JRBarApp

/// A tap the system switches off is asked to come back, and the answer is
/// checked: a refusal means the owner is not live.
@MainActor
@Suite("Event tap health")
struct EventTapHealthTests {
    private func port() -> CFMachPort {
        CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil)
    }

    @Test("a tap that comes back on is healthy, and a refused one is not")
    func reenableReportsTheAnswer() {
        let asked = Counter()
        let accepted = EventTapHealth.Control(enable: { _, on in if on { asked.bump() } }, isEnabled: { _ in true })
        let refused = EventTapHealth.Control(enable: { _, on in if on { asked.bump() } }, isEnabled: { _ in false })
        #expect(EventTapHealth.reenable(port(), control: accepted))
        #expect(!EventTapHealth.reenable(port(), control: refused))
        #expect(asked.value == 2, "the request is always made before the answer is read")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private final class Owner {
        var live = false
        var revived = 0
    }

    @Test("becoming active again revives only the taps that are down")
    func activationRevivesDownTaps() {
        let center = NotificationCenter()
        let revival = EventTapRevival(center: center)
        let down = Owner()
        let up = Owner()
        up.live = true
        revival.register(down, key: "down", isLive: { $0.live }, revive: { $0.revived += 1 })
        revival.register(up, key: "up", isLive: { $0.live }, revive: { $0.revived += 1 })

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(down.revived == 1)
        #expect(up.revived == 0)

        down.live = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(down.revived == 1, "a live tap is left alone")
    }

    @Test("a registration lapses with its owner and is replaced by one under the same key")
    func registrationsLapse() {
        let revival = EventTapRevival(center: NotificationCenter())
        var first: Owner? = Owner()
        var calls = 0
        revival.register(first!, key: "tap", isLive: { _ in false }, revive: { _ in calls += 1 })
        first = nil
        revival.appBecameActive()
        #expect(calls == 0, "the owner is gone")

        let second = Owner()
        revival.register(second, key: "tap", isLive: { _ in false }, revive: { $0.revived += 1 })
        revival.register(second, key: "tap", isLive: { _ in false }, revive: { $0.revived += 10 })
        revival.appBecameActive()
        #expect(second.revived == 10)
    }
}
