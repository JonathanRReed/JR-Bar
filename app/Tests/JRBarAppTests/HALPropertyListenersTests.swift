import CoreAudio
import CoreMediaIO
import Foundation
import Testing
@testable import JRBarApp

@Suite("HAL listener ownership")
struct HALPropertyListenersTests {
    private typealias Key = HALPropertyListeners.Key
    private final class Fake {
        struct Identity: Equatable {
            let audio: UInt
            let camera: UInt
            let context: UInt
        }
        var live: [Key: Identity] = [:]
        var adds = 0
        var removes = 0
        var failure: OSStatus = noErr
        var failAdd = false
        var removedCallback: (() -> Void)?
        var addedCallback: (() -> Void)?
        var api: HALPropertyListeners.API {
            .init(add: { [self] key, audio, camera, context in
                if failAdd { return -1 }
                #expect(live[key] == nil, "unchanged objects must not register twice")
                live[key] = Identity(audio: unsafeBitCast(audio, to: UInt.self),
                                     camera: unsafeBitCast(camera, to: UInt.self), context: UInt(bitPattern: context))
                addedCallback = {
                    if key.system == .audio {
                        var address = AudioObjectPropertyAddress()
                        _ = audio(key.object, 1, &address, context)
                    } else {
                        var address = CMIOObjectPropertyAddress()
                        _ = camera(key.object, 1, &address, context)
                    }
                }
                adds += 1
                return noErr
            }, remove: { [self] key, audio, camera, context in
                let identity = Identity(audio: unsafeBitCast(audio, to: UInt.self),
                                        camera: unsafeBitCast(camera, to: UInt.self), context: UInt(bitPattern: context))
                #expect(live[key] == identity, "remove must use the identical C callback and context")
                removedCallback = {
                    if key.system == .audio {
                        var address = AudioObjectPropertyAddress()
                        _ = audio(key.object, 1, &address, context)
                    } else {
                        var address = CMIOObjectPropertyAddress()
                        _ = camera(key.object, 1, &address, context)
                    }
                }
                if failure != noErr { return failure }
                live.removeValue(forKey: key)
                removes += 1
                return noErr
            })
        }
    }

    @Test func reconciliationsKeepExactlyTheLiveSet() {
        let fake = Fake()
        let listeners = HALPropertyListeners(api: fake.api) { _ in }
        for step in 0..<1_000 {
            let desired = Set((0..<16).map { offset in
                Key(system: offset.isMultiple(of: 2) ? .audio : .camera,
                    object: UInt32(step + offset), selector: 1)
            })
            listeners.reconcile(desired)
            #expect(Set(fake.live.keys) == desired)
            #expect(listeners.count == 16)
            let adds = fake.adds
            let removes = fake.removes
            listeners.reconcile(desired)
            #expect(fake.adds == adds)
            #expect(fake.removes == removes)
        }
        listeners.reconcile([])
        #expect(fake.live.isEmpty)
        #expect(fake.adds == fake.removes)
    }

    @Test func failedRemovalIsReportedAndRetriedWithoutDuplicating() {
        let fake = Fake()
        var failures: [OSStatus] = []
        let listeners = HALPropertyListeners(api: fake.api, report: { _, status in failures.append(status) }) { _ in }
        let key = Key(system: .audio, object: 42, selector: 1)
        listeners.reconcile([key])
        fake.failure = -1
        listeners.reconcile([])
        #expect(failures == [-1])
        #expect(listeners.count == 1)
        listeners.reconcile([key])
        #expect(fake.adds == 1)
        fake.failure = noErr
        listeners.reconcile([])
        #expect(listeners.count == 0)
        #expect(fake.live.isEmpty)
    }

    @Test func aDeviceThatLeftIsReleasedWithoutAReport() {
        let fake = Fake()
        var failures: [OSStatus] = []
        let listeners = HALPropertyListeners(api: fake.api, report: { _, status in failures.append(status) }) { _ in }
        listeners.reconcile([Key(system: .audio, object: 157, selector: 1)])
        fake.failure = kAudioHardwareBadObjectError
        listeners.reconcile([])
        #expect(failures.isEmpty)
        #expect(listeners.count == 0)
    }

    @Test func reusedProcessObjectReplacesItsRegistration() {
        let fake = Fake()
        let listeners = HALPropertyListeners(api: fake.api) { _ in }
        let old = Key(system: .audio, object: 42, selector: 1, processID: 101)
        let replacement = Key(system: .audio, object: 42, selector: 1, processID: 202)
        listeners.reconcile([old])
        let context = fake.live[old]?.context
        listeners.reconcile([replacement])
        #expect(fake.removes == 1)
        #expect(fake.adds == 2)
        #expect(Set(fake.live.keys) == [replacement])
        #expect(fake.live[replacement]?.context != context)
        listeners.reconcile([replacement])
        #expect(fake.adds == 2)
    }

    @Test func removalFailuresAreReportedOncePerObjectAcrossSelectorsAndRetries() {
        let fake = Fake()
        var failures: [UInt32] = []
        let listeners = HALPropertyListeners(api: fake.api, report: { key, _ in failures.append(key.object) }) { _ in }
        let first = Key(system: .audio, object: 42, selector: 1)
        let second = Key(system: .audio, object: 42, selector: 2)
        let other = Key(system: .audio, object: 43, selector: 1)
        listeners.reconcile([first, second, other])
        fake.failure = -1
        for _ in 0..<10 { listeners.reconcile([]) }
        #expect(failures.sorted() == [42, 43])
        #expect(listeners.count == 3)
        fake.failure = noErr
        listeners.reconcile([])
        #expect(fake.live.isEmpty)
        // Once an object leaves, a later registration owns its own diagnostic.
        listeners.reconcile([first])
        fake.failure = -1
        listeners.reconcile([])
        #expect(failures.filter { $0 == 42 }.count == 2)
        fake.failure = noErr
        listeners.reconcile([])
    }

    @Test func failedAddIsRetried() {
        let fake = Fake()
        fake.failAdd = true
        let listeners = HALPropertyListeners(api: fake.api) { _ in }
        let key = Key(system: .camera, object: 42, selector: 1)
        listeners.reconcile([key])
        #expect(listeners.count == 0)
        fake.failAdd = false
        listeners.reconcile([key])
        #expect(listeners.count == 1)
        listeners.reconcile([])
    }

    @Test func callbacksQueuedBeforeRemovalDoNotReachTheOwner() async {
        let fake = Fake()
        let queue = DispatchQueue(label: "jrbar.test.hal-callbacks")
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func increment() { lock.withLock { count += 1 } }
        }
        let calls = Calls()
        let listeners = HALPropertyListeners(api: fake.api, queue: queue) { _ in calls.increment() }
        listeners.reconcile([.init(system: .audio, object: 42, selector: 1)])
        fake.addedCallback?()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        #expect(calls.lock.withLock { calls.count } == 1)
        queue.suspend()
        fake.addedCallback?()
        listeners.reconcile([])
        queue.resume()
        fake.removedCallback?()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        #expect(calls.lock.withLock { calls.count } == 1)
    }

    @Test func failedRemovalAtDeinitReleasesTheOwnedContextAndLeavesLateCallbacksSafe() {
        final class Owner: @unchecked Sendable {}
        let fake = Fake()
        weak var released: Owner?
        var listeners: HALPropertyListeners?
        do {
            let owner = Owner()
            released = owner
            listeners = HALPropertyListeners(api: fake.api, report: { _, _ in }) { [owner] _ in
                withExtendedLifetime(owner) {}
            }
        }
        listeners?.reconcile([.init(system: .camera, object: 42, selector: 1)])
        #expect(released != nil)
        fake.failure = -1
        listeners = nil
        #expect(released == nil)
        fake.removedCallback?()
    }
}
