import AppKit
import CoreGraphics

/// Pointer moves, as the Dock previews, the Screen Bar and the menu bar
/// reveal need them. Each used to poll `NSEvent.mouseLocation` on its own
/// timer, 3 to 20 times a second, whether the pointer moved or not:
/// about 900 timer fires a minute with the pointer still, and up to
/// 3,000 near a screen edge. The watcher hears the moves instead and
/// hands them on at most `interval` apart, so a still pointer costs
/// nothing and a moving one wakes the main thread 20 times a second
/// whichever of them is listening.
///
/// A subscriber reads `NSEvent.mouseLocation` itself when told; the
/// watcher carries no position, so a move that arrives while the last
/// delivery is still due only makes it read a newer one.
@MainActor
protocol PointerWatching: AnyObject {
    /// Starts telling `onMove` about pointer moves. nil when moves can't
    /// be heard here — the caller then polls as it always did. `onLost`
    /// fires if the source dies under a held token — the token is dead
    /// then, so drop it and poll; the next subscribe asks again.
    func subscribe(_ onMove: @escaping @MainActor () -> Void,
                   onLost: @escaping @MainActor () -> Void) -> Int?
    func unsubscribe(_ token: Int)
}

extension PointerWatching {
    /// A subscription with nothing to do when the source dies — the
    /// token simply goes quiet.
    func subscribe(_ onMove: @escaping @MainActor () -> Void) -> Int? {
        subscribe(onMove, onLost: {})
    }
}

/// Where moves come from. Started by the first subscriber, stopped by
/// the last.
protocol PointerMoveSource: AnyObject, Sendable {
    /// Start listening; `moved` and `died` may be called on any thread.
    /// False when the source can't listen here. `died` says the source
    /// stopped hearing moves for good — the watcher lets its subscribers
    /// know, and the next arm is refused and polls as before.
    func start(moved: @escaping @Sendable () -> Void,
               died: @escaping @Sendable () -> Void) -> Bool
    func stop()
}

/// The pacing rule, pure so a test can drive it with a fixed clock: the
/// first move after a quiet spell goes at once, and later ones wait until
/// `interval` has passed since the last delivery. Moves that land while a
/// delivery is due join it.
struct PointerMovePacer: Equatable {
    let interval: TimeInterval
    private(set) var pending = false
    private(set) var lastDelivery: TimeInterval?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// A move at `now`: how long until its delivery, or nil when one is
    /// already on its way.
    mutating func noteMove(at now: TimeInterval) -> TimeInterval? {
        guard !pending else { return nil }
        pending = true
        guard let last = lastDelivery, now >= last else { return 0 }
        return max(0, last + interval - now)
    }

    mutating func delivered(at now: TimeInterval) {
        pending = false
        lastDelivery = now
    }
}

/// The app's pointer watcher: one source, any number of subscribers.
@MainActor
final class PointerWatcher: PointerWatching {
    /// Twenty deliveries a second at most — what the fastest of the old
    /// polls ran at, so a hover feels as it did.
    nonisolated static let interval: TimeInterval = 0.05

    /// Made on first use. It listens only inside the app itself: a test
    /// process gets a watcher that hears nothing, so every surface a test
    /// builds polls as before unless the test hands in a watcher of its
    /// own.
    static let shared = PointerWatcher(
        source: Bundle.main.bundlePath.hasSuffix(".app") ? EventTapPointerSource() : nil)

    /// The pacing, shared with the source's thread.
    private final class Gate: @unchecked Sendable {
        let lock = NSLock()
        var pacer: PointerMovePacer
        init(interval: TimeInterval) { pacer = PointerMovePacer(interval: interval) }
    }

    private let source: PointerMoveSource?
    private nonisolated let gate: Gate
    private nonisolated let clock: @Sendable () -> TimeInterval
    private nonisolated let schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private var subscribers: [Int: (move: @MainActor () -> Void, lost: @MainActor () -> Void)] = [:]
    private var nextToken = 0
    /// Counts the starts, so a `died` the previous tap posted before it
    /// stopped cannot kill the one running now.
    private var startGeneration = 0
    /// Whether the source is listening right now.
    private(set) var listening = false
    /// When a start failed — the next subscriber asks again only after
    /// `retryAfter`, so a refused source isn't hammered.
    private var failedAt: TimeInterval?
    nonisolated static let retryAfter: TimeInterval = 30

    /// `schedule` runs its work on the main thread after a delay; `clock`
    /// is monotonic seconds. Both are a test's to replace.
    init(source: PointerMoveSource?,
         interval: TimeInterval = PointerWatcher.interval,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.source = source
        self.gate = Gate(interval: interval)
        self.clock = clock
        self.schedule = schedule
    }

    var subscriberCount: Int { subscribers.count }

    func subscribe(_ onMove: @escaping @MainActor () -> Void,
                   onLost: @escaping @MainActor () -> Void) -> Int? {
        guard startIfNeeded() else { return nil }
        nextToken += 1
        subscribers[nextToken] = (move: onMove, lost: onLost)
        return nextToken
    }

    func unsubscribe(_ token: Int) {
        guard subscribers.removeValue(forKey: token) != nil, subscribers.isEmpty, listening else { return }
        source?.stop()
        listening = false
        gate.lock.withLock { gate.pacer = PointerMovePacer(interval: gate.pacer.interval) }
    }

    private func startIfNeeded() -> Bool {
        if listening { return true }
        guard let source else { return false }
        let now = clock()
        if let failedAt, now - failedAt < Self.retryAfter, now >= failedAt { return false }
        startGeneration += 1
        let generation = startGeneration
        listening = source.start(moved: { [weak self] in self?.moved() },
                                 died: { [weak self] in self?.sourceDied(generation) })
        failedAt = listening ? nil : now
        return listening
    }

    /// The source gave up on the watcher's behalf — the tap died when
    /// Accessibility was pulled. Treated as a failed start: the dead
    /// source is stopped and every token is let go — the surfaces hear
    /// `lost` and go back to their polls rather than wait on moves that
    /// will never come. A stale `died` posted by an earlier tap before
    /// it stopped is ignored by its generation.
    private nonisolated func sourceDied(_ generation: Int) {
        schedule(0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.listening,
                      self.startGeneration == generation else { return }
                self.source?.stop()
                self.listening = false
                self.failedAt = self.clock()
                let lost = self.subscribers.values.map(\.lost)
                self.subscribers.removeAll()
                self.gate.lock.withLock {
                    self.gate.pacer = PointerMovePacer(interval: self.gate.pacer.interval)
                }
                for onLost in lost { onLost() }
            }
        }
    }

    /// A move, on the source's thread.
    private nonisolated func moved() {
        let now = clock()
        let delay = gate.lock.withLock { gate.pacer.noteMove(at: now) }
        guard let delay else { return }
        schedule(delay) { [weak self] in
            MainActor.assumeIsolated { self?.deliver() }
        }
    }

    private func deliver() {
        gate.lock.withLock { gate.pacer.delivered(at: clock()) }
        for subscriber in subscribers.values { subscriber.move() }
    }
}

/// Pointer moves off a listen-only event tap on a thread of its own: it
/// never changes, holds or posts an event, and the main thread hears only
/// the paced deliveries. It starts only with the Accessibility grant, so
/// it never asks for anything; without one the surfaces poll as before.
final class EventTapPointerSource: PointerMoveSource, @unchecked Sendable {
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var loop: TapLoop?
    private var moved: (@Sendable () -> Void)?
    private var died: (@Sendable () -> Void)?

    /// Moves and drags: a drag moves the pointer without a single
    /// `mouseMoved`, and a Dock hover during one still counts.
    private static let mask: CGEventMask = [CGEventType.mouseMoved, .leftMouseDragged,
                                            .rightMouseDragged, .otherMouseDragged]
        .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

    func start(moved: @escaping @Sendable () -> Void,
               died: @escaping @Sendable () -> Void) -> Bool {
        // Whatever an earlier tap left goes first, so a second start
        // never leaves a dead tap's thread spinning beside the new one.
        stop()
        guard AXIsProcessTrusted() else { return false }
        lock.withLock { self.moved = moved; self.died = died }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: Self.mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let source = Unmanaged<EventTapPointerSource>.fromOpaque(info).takeUnretainedValue()
                source.handle(type)
                return Unmanaged.passUnretained(event)
            },
            userInfo: pointer),
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        else { return false }
        let loop = TapLoop(source: runLoopSource)
        let thread = Thread {
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, loop.source, .commonModes)
            loop.runLoop = runLoop
            loop.ready.signal()
            // Returns once `stop` takes the source off and stops the loop.
            CFRunLoopRun()
            loop.finished.signal()
        }
        thread.name = "JR-Bar pointer watch"
        thread.qualityOfService = .userInteractive
        // The tap and loop are published before the thread can drain an
        // event — a `tapDisabledBy*` landing in the gap would find no tap
        // to re-enable, die silently, and leave a live token on a dead tap.
        lock.withLock {
            self.tap = tap
            self.loop = loop
        }
        thread.start()
        loop.ready.wait()
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// The tap's thread as `stop` needs it: the source to take off its
    /// run loop, the loop to stop, and a signal that the thread returned.
    private final class TapLoop: @unchecked Sendable {
        let source: CFRunLoopSource
        /// Written by the tap thread before `ready` fires; read after.
        var runLoop: CFRunLoop?
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        init(source: CFRunLoopSource) { self.source = source }
    }

    func stop() {
        let (tap, loop) = lock.withLock { () -> (CFMachPort?, TapLoop?) in
            defer {
                self.tap = nil
                self.loop = nil
                self.moved = nil
                self.died = nil
            }
            return (self.tap, self.loop)
        }
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let loop, let runLoop = loop.runLoop {
            CFRunLoopRemoveSource(runLoop, loop.source, .commonModes)
            CFRunLoopStop(runLoop)
            // The callback never waits on anything, so the loop returns
            // within one callback's length.
            _ = loop.finished.wait(timeout: .now() + 1)
        }
        CFMachPortInvalidate(tap)
    }

    deinit { stop() }

    private func handle(_ type: CGEventType) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            guard let tap = lock.withLock({ tap }) else { return }
            CGEvent.tapEnable(tap: tap, enable: true)
            // The re-enable is a request: an untrusted process — the
            // Accessibility grant pulled under us — gets nothing, and
            // its tap hears no move ever again. Say so, so the watcher
            // lets the surfaces go back to their polls.
            if !CGEvent.tapIsEnabled(tap: tap) { lock.withLock { died }?() }
            return
        }
        lock.withLock { moved }?()
    }
}
