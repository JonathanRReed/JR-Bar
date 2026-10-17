import AppKit
import Foundation
import Testing
@testable import JRBarApp

@MainActor
@Suite("Mirror queued start ownership")
struct ShelfMirrorStartTests {
    private final class Driver: ShelfMirrorSessionDriver, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let startEntered = DispatchSemaphore(value: 0)
        let startRelease = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var prepares = 0
        private var starts = 0
        private var stops = 0
        private var attachments = 0
        private var failures: [String] = []
        let holdFirstPrepare: Bool
        let holdStart: Bool
        // The full suite can queue main-actor continuations for over 30
        // seconds. Keep fixture holds bounded while allowing that queue to drain.
        private let holdTimeout: TimeInterval = 120

        init(holdFirstPrepare: Bool = true, holdStart: Bool = false) {
            self.holdFirstPrepare = holdFirstPrepare
            self.holdStart = holdStart
        }

        func prepare() -> Bool {
            lock.lock()
            prepares += 1
            let first = prepares == 1
            lock.unlock()
            if first, holdFirstPrepare {
                entered.signal()
                if release.wait(timeout: .now() + holdTimeout) == .timedOut {
                    recordFailure("fixture preparation was not released")
                    return false
                }
            }
            return true
        }

        func start() {
            lock.lock()
            starts += 1
            lock.unlock()
            if holdStart {
                startEntered.signal()
                if startRelease.wait(timeout: .now() + holdTimeout) == .timedOut {
                    recordFailure("fixture start was not released")
                }
            }
        }

        func stop() {
            lock.lock(); defer { lock.unlock() }
            stops += 1
        }

        @MainActor func attach(to preview: MirrorPreviewView) {
            lock.lock(); defer { lock.unlock() }
            attachments += 1
        }

        var counts: (prepares: Int, starts: Int, stops: Int, attachments: Int) {
            lock.lock(); defer { lock.unlock() }
            return (prepares, starts, stops, attachments)
        }

        func recordFailure(_ message: String) {
            lock.withLock { failures.append(message) }
        }

        var recordedFailures: [String] { lock.withLock { failures } }

        func waitForPreparation() async -> Bool { await signalled(entered) }
        func waitForStart() async -> Bool { await signalled(startEntered) }

        private func signalled(_ semaphore: DispatchSemaphore) async -> Bool {
            // A blocked fixture wait belongs on Dispatch, not Swift's
            // cooperative pool alongside the queued camera callbacks.
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
                }
            }
        }
    }

    private func drain(_ model: ShelfMirrorModel) async {
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            model.queue.async { DispatchQueue.main.async { finished.resume() } }
        }
    }

    @Test("a fold before queued preparation starts does not build or start the camera")
    func foldBeforePrepare() async {
        let driver = Driver(holdFirstPrepare: false)
        let queue = DispatchQueue(label: "jrbar.test.mirror-before-prepare")
        let release = DispatchSemaphore(value: 0)
        queue.async {
            if release.wait(timeout: .now() + 5) == .timedOut {
                driver.recordFailure("fixture queue was not released")
            }
        }
        let model = ShelfMirrorModel(driver: driver, queue: queue, authorization: { .authorized })
        model.sync(enabled: true)
        model.sync(enabled: false)
        release.signal()
        await drain(model)
        #expect(driver.recordedFailures.isEmpty)
        #expect(driver.counts.prepares == 0)
        #expect(driver.counts.starts == 0)
        #expect(driver.counts.attachments == 0)
        #expect(model.state == .off)
    }

    @Test("a fold during preparation prevents the prepared camera from starting")
    func foldDuringPrepare() async throws {
        let driver = Driver()
        let model = ShelfMirrorModel(driver: driver, authorization: { .authorized })
        defer { driver.release.signal(); model.sync(enabled: false) }
        model.sync(enabled: true)
        let preparing = await driver.waitForPreparation()
        try #require(preparing)
        model.sync(enabled: false)
        driver.release.signal()
        await drain(model)
        #expect(driver.recordedFailures.isEmpty)
        #expect(driver.counts.prepares == 1)
        #expect(driver.counts.starts == 0)
        #expect(driver.counts.attachments == 0)
        #expect(model.state == .off)
    }

    @Test("a reopened mirror starts only its newest run and keeps that run live")
    func reopenDuringPrepare() async throws {
        let driver = Driver()
        let model = ShelfMirrorModel(driver: driver, authorization: { .authorized })
        defer { driver.release.signal(); model.sync(enabled: false) }
        model.sync(enabled: true)
        let preparing = await driver.waitForPreparation()
        try #require(preparing)
        model.sync(enabled: false)
        model.sync(enabled: true)
        driver.release.signal()
        await drain(model)
        #expect(driver.recordedFailures.isEmpty)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while model.state != .live, clock.now < deadline { await Task.yield() }
        #expect(driver.counts.prepares == 2)
        #expect(driver.counts.starts == 1)
        #expect(driver.counts.stops == 1)
        #expect(driver.counts.attachments == 1)
        #expect(model.state == .live)
    }

    @Test("a fold during a running start stops it without publishing a live preview")
    func foldDuringStart() async throws {
        let driver = Driver(holdFirstPrepare: false, holdStart: true)
        let model = ShelfMirrorModel(driver: driver, authorization: { .authorized })
        defer { driver.startRelease.signal(); model.sync(enabled: false) }
        model.sync(enabled: true)
        let starting = await driver.waitForStart()
        try #require(starting)
        model.sync(enabled: false)
        driver.startRelease.signal()
        await drain(model)
        #expect(driver.recordedFailures.isEmpty)
        #expect(driver.counts.starts == 1)
        #expect(driver.counts.stops == 1)
        #expect(driver.counts.attachments == 0)
        #expect(model.state == .off)
    }
}
