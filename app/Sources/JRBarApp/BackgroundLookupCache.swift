import Foundation

/// Cache reads never execute the loader or wait for it. A deadline discards late
/// results; a blocked syscall keeps its lane until it actually returns.
final class BackgroundLookupCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private struct Entry {
        var value: Value?
        var expires: TimeInterval
        var token: UUID?
        var timedOut = false
    }
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var queued: [Key: UUID] = [:]
    private var waiters: [Key: [@Sendable (Value?) -> Void]] = [:]
    private var active = 0
    private let limit: Int
    private let capacity: Int
    private let lifetime: TimeInterval
    private let timeout: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let load: @Sendable (Key) -> Value?
    private let changed: @Sendable () -> Void
    private let scheduleDeadline: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private let queue = DispatchQueue(label: "dev.jrbar.file-lookups", qos: .utility, attributes: .concurrent)

    init(limit: Int = 2, capacity: Int = 512, lifetime: TimeInterval = 30, timeout: TimeInterval = 2,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         scheduleDeadline: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, work in
             DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
         },
         changed: @escaping @Sendable () -> Void = {},
         load: @escaping @Sendable (Key) -> Value?) {
        self.limit = limit
        self.capacity = capacity
        self.lifetime = lifetime
        self.timeout = timeout
        self.now = now
        self.scheduleDeadline = scheduleDeadline
        self.changed = changed
        self.load = load
    }

    func value(for key: Key) -> Value? {
        lock.lock()
        let current = now()
        let previous = entries[key]
        if let previous, previous.token != nil || (current >= previous.expires - lifetime && previous.expires > current) {
            lock.unlock()
            return previous.value
        }
        guard active < limit else { lock.unlock(); return previous?.value }
        if entries.count >= capacity, let victim = entries.first(where: { $0.value.token == nil })?.key {
            entries[victim] = nil
        }
        let token = UUID()
        queued[key] = nil
        entries[key] = Entry(value: previous?.value, expires: current + lifetime, token: token)
        active += 1
        lock.unlock()
        scheduleDeadline(timeout) { [weak self] in self?.expire(key, token: token) }
        queue.async { [self] in
            let result = load(key)
            lock.lock()
            active -= 1
            if var entry = entries[key], entry.token == token {
                if !entry.timedOut { entry.value = result }
                entry.token = nil
                entry.expires = now() + lifetime
                entries[key] = entry
            }
            let callbacks = waiters.removeValue(forKey: key) ?? []
            let value = entries[key]?.value
            lock.unlock()
            callbacks.forEach { $0(value) }
            changed()
            drain()
        }
        return previous?.value
    }

    func invalidate(_ key: Key) {
        lock.lock()
        if entries[key]?.token == nil { entries[key]?.expires = -.infinity }
        lock.unlock()
    }

    func resolve(_ key: Key) async -> Value? {
        _ = value(for: key)
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let entry = entries[key], entry.token != nil, !entry.timedOut {
                waiters[key, default: []].append { continuation.resume(returning: $0) }
                lock.unlock()
            } else if entries[key]?.token == nil,
                      (entries[key] == nil || (entries[key]?.expires ?? 0) <= now()), queued.count < capacity {
                let token = queued[key] ?? UUID()
                queued[key] = token
                waiters[key, default: []].append { continuation.resume(returning: $0) }
                lock.unlock()
                scheduleDeadline(timeout) { [weak self] in self?.expireQueued(key, token: token) }
                drain()
            } else {
                let value = entries[key]?.value
                lock.unlock()
                continuation.resume(returning: value)
            }
        }
    }

    private func drain() {
        lock.lock()
        let pending = Array(queued.keys)
        lock.unlock()
        for key in pending { _ = value(for: key) }
    }

    private func expireQueued(_ key: Key, token: UUID) {
        lock.lock()
        guard queued[key] == token else { lock.unlock(); return }
        queued[key] = nil
        let callbacks = waiters.removeValue(forKey: key) ?? []
        let value = entries[key]?.value
        lock.unlock()
        callbacks.forEach { $0(value) }
    }

    private func expire(_ key: Key, token: UUID) {
        lock.lock()
        guard var entry = entries[key], entry.token == token else { lock.unlock(); return }
        entry.timedOut = true
        entries[key] = entry
        let callbacks = waiters.removeValue(forKey: key) ?? []
        let value = entries[key]?.value
        lock.unlock()
        callbacks.forEach { $0(value) }
        changed()
    }
}
