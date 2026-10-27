import CoreAudio
import CoreMediaIO
import Foundation
import os

/// Owns C listener registrations. Call reconcile on the owner's actor or queue.
final class HALPropertyListeners {
    struct Key: Hashable, Sendable {
        enum System: Hashable, Sendable { case audio, camera }
        let system: System
        let object: UInt32
        let selector: UInt32
        var scope: UInt32 = kAudioObjectPropertyScopeGlobal
        var element: UInt32 = kAudioObjectPropertyElementMain
        var processID: pid_t?
    }

    struct API {
        typealias Operation = (Key, AudioObjectPropertyListenerProc, CMIOObjectPropertyListenerProc,
                               UnsafeMutableRawPointer) -> OSStatus
        var add: Operation
        var remove: Operation

        static var live: API { API(add: { key, audio, camera, context in
            if key.system == .audio {
                var address = AudioObjectPropertyAddress(mSelector: key.selector, mScope: key.scope, mElement: key.element)
                return AudioObjectAddPropertyListener(key.object, &address, audio, context)
            }
            var address = CMIOObjectPropertyAddress(mSelector: key.selector, mScope: key.scope, mElement: key.element)
            return CMIOObjectAddPropertyListener(key.object, &address, camera, context)
        }, remove: { key, audio, camera, context in
            if key.system == .audio {
                var address = AudioObjectPropertyAddress(mSelector: key.selector, mScope: key.scope, mElement: key.element)
                return AudioObjectRemovePropertyListener(key.object, &address, audio, context)
            }
            var address = CMIOObjectPropertyAddress(mSelector: key.selector, mScope: key.scope, mElement: key.element)
            return CMIOObjectRemovePropertyListener(key.object, &address, camera, context)
        }) }
    }

    private static let log = Logger(subsystem: "devin.jrbar", category: "property-listeners")
    private let api: API
    private let queue: DispatchQueue
    private let changed: @Sendable (Key) -> Void
    private let report: (Key, OSStatus) -> Void
    private struct Object: Hashable {
        let system: Key.System
        let id: UInt32
        init(_ key: Key) { system = key.system; id = key.object }
    }
    private var reportedRemovals: Set<Object> = []
    private var registrations: [Key: UInt] = [:]
    var count: Int { registrations.count }

    init(api: API = .live, queue: DispatchQueue = .main,
         report: @escaping (Key, OSStatus) -> Void = { key, status in
             log.error("Listener removal failed: object=\(key.object) selector=\(key.selector) status=\(status)")
         }, changed: @escaping @Sendable (Key) -> Void) {
        self.api = api
        self.queue = queue
        self.report = report
        self.changed = changed
    }

    /// Failed removals stay owned and inactive, and are retried next time.
    /// A different PID on the same process object gets a new registration.
    func reconcile(_ desired: Set<Key>) {
        for (key, token) in registrations where !desired.contains(key) {
            Self.contexts.setEnabled(token, false)
            let status = api.remove(key, Self.audioCallback, Self.cameraCallback, Self.pointer(token))
            // A device that left took its listener with it: that removal is
            // done, not failed, so only other statuses are reported.
            let gone = key.system == .audio ? kAudioHardwareBadObjectError : OSStatus(kCMIOHardwareBadObjectError)
            if status != noErr, status != gone, reportedRemovals.insert(Object(key)).inserted { report(key, status) }
            if status == noErr || status == gone {
                Self.contexts.remove(token)
                registrations.removeValue(forKey: key)
            }
        }
        for key in desired {
            if let token = registrations[key] {
                Self.contexts.setEnabled(token, true)
                continue
            }
            let token = Self.contexts.insert(Context(queue: queue) { [changed] in changed(key) })
            if api.add(key, Self.audioCallback, Self.cameraCallback, Self.pointer(token)) == noErr {
                registrations[key] = token
            } else {
                Self.contexts.remove(token)
            }
        }
        reportedRemovals.formIntersection(Set(registrations.keys.map(Object.init)))
    }

    deinit {
        reconcile([])
        // A failed HAL removal must never leave a dangling client-data pointer.
        // The opaque token is never reused; late callbacks find no context.
        for token in registrations.values { Self.contexts.remove(token) }
    }

    private static func pointer(_ token: UInt) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: token)!
    }

    private static let audioCallback: AudioObjectPropertyListenerProc = { _, _, _, data in
        if let data { contexts.enqueue(UInt(bitPattern: data)) }
        return noErr
    }
    private static let cameraCallback: CMIOObjectPropertyListenerProc = { _, _, _, data in
        if let data { contexts.enqueue(UInt(bitPattern: data)) }
        return noErr
    }

    private final class Context: @unchecked Sendable {
        let queue: DispatchQueue
        let action: @Sendable () -> Void
        let lock = NSLock()
        var enabled = true
        var pending = false
        init(queue: DispatchQueue, action: @escaping @Sendable () -> Void) {
            self.queue = queue
            self.action = action
        }
        func setEnabled(_ value: Bool) { lock.withLock { enabled = value } }
        func enqueue() {
            let needed = lock.withLock {
                guard enabled, !pending else { return false }
                pending = true
                return true
            }
            if needed { queue.async { self.fire() } }
        }
        func fire() {
            let live = lock.withLock {
                pending = false
                return enabled
            }
            if live { action() }
        }
    }

    /// C callbacks may race removal. They look up an owned context under the
    /// lock, then dispatch it without ever dereferencing the client-data token.
    private final class Contexts: @unchecked Sendable {
        let lock = NSLock()
        var next: UInt = 0
        var values: [UInt: Context] = [:]
        func insert(_ context: Context) -> UInt {
            lock.withLock {
                next += 1
                values[next] = context
                return next
            }
        }
        func setEnabled(_ token: UInt, _ value: Bool) {
            lock.withLock { values[token]?.setEnabled(value) }
        }
        func remove(_ token: UInt) {
            lock.withLock {
                values.removeValue(forKey: token)?.setEnabled(false)
            }
        }
        func enqueue(_ token: UInt) {
            let context = lock.withLock { values[token] }
            context?.enqueue()
        }
    }
    private static let contexts = Contexts()
}
