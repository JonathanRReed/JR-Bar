import Foundation
import Testing
@testable import JRBarApp

@MainActor
@Suite("Mirror startup states")
struct ShelfMirrorStateTests {
    final class Driver: ShelfMirrorSessionDriver, @unchecked Sendable {
        private let lock = NSLock()
        private var canPrepare = true
        private var prepares = 0
        private var starts = 0
        private var attachments = 0

        var preparationAllowed: Bool {
            get { lock.withLock { canPrepare } }
            set { lock.withLock { canPrepare = newValue } }
        }
        func prepare() -> Bool { lock.withLock { prepares += 1; return canPrepare } }
        func start() { lock.withLock { starts += 1 } }
        func stop() {}
        @MainActor func attach(to preview: MirrorPreviewView) { lock.withLock { attachments += 1 } }
        var counts: (prepares: Int, starts: Int, attachments: Int) {
            lock.withLock { (prepares, starts, attachments) }
        }
    }

    private func wait(_ model: ShelfMirrorModel, for state: ShelfMirrorModel.State) async {
        while model.state != state { await Task.yield() }
    }

    @Test("a permission refresh recovers a visible mirror without reopening it", .timeLimit(.minutes(2)))
    func refreshAfterExternalGrant() async {
        let driver = Driver()
        let model = ShelfMirrorModel(driver: driver, authorization: { .denied },
                                     requestAccess: { _ in Issue.record("must not ask again") })
        defer { model.sync(enabled: false) }
        model.sync(enabled: true)
        #expect(model.state == .denied)
        model.authorization = { .authorized }
        model.sync(enabled: true)
        #expect(model.state == .starting)
        await wait(model, for: .live)
        #expect(driver.counts.starts == 1)
    }

    @Test("an authorized open shows starting before the preview becomes live", .timeLimit(.minutes(2)))
    func startingThenLive() async {
        let driver = Driver()
        let model = ShelfMirrorModel(driver: driver, authorization: { .authorized })
        defer { model.sync(enabled: false) }
        model.sync(enabled: true)
        #expect(model.state == .starting)
        await wait(model, for: .live)
        #expect(driver.counts.starts == 1)
        #expect(driver.counts.attachments == 1)
    }

    @Test("permission waiting survives a reopen without asking twice and a closed card stays off",
          .timeLimit(.minutes(2)))
    func permissionOwnership() async {
        let driver = Driver()
        var answer: (@Sendable (Bool) -> Void)?
        var prompts = 0
        let model = ShelfMirrorModel(driver: driver, authorization: { .notDetermined }, requestAccess: {
            prompts += 1
            answer = $0
        })
        model.sync(enabled: true)
        #expect(model.state == .requestingPermission)
        model.sync(enabled: false)
        #expect(model.state == .off)
        model.sync(enabled: true)
        #expect(model.state == .requestingPermission)
        #expect(prompts == 1)
        model.sync(enabled: false)
        answer?(true)
        // Await the main-actor permission callback without starting a session.
        while model.permissionRequestPending { await Task.yield() }
        #expect(model.state == .off)
        #expect(driver.counts.starts == 0)
        model.sync(enabled: true)
        #expect(model.state == .requestingPermission)
        #expect(prompts == 2)
        answer?(true)
        await wait(model, for: .live)
        #expect(driver.counts.starts == 1)
        model.sync(enabled: false)
    }

    @Test("an unavailable camera can retry while a starting run cannot duplicate work", .timeLimit(.minutes(2)))
    func retryUnavailable() async {
        let driver = Driver()
        driver.preparationAllowed = false
        let model = ShelfMirrorModel(driver: driver, authorization: { .authorized })
        defer { model.sync(enabled: false) }
        model.sync(enabled: true)
        model.retry()
        await wait(model, for: .unavailable)
        #expect(driver.counts.prepares == 1)
        driver.preparationAllowed = true
        model.retry()
        #expect(model.state == .starting)
        await wait(model, for: .live)
        #expect(driver.counts.prepares == 2)
        #expect(driver.counts.starts == 1)
    }

    @Test("a permission callback cannot start a reopened authorized mirror twice", .timeLimit(.minutes(2)))
    func permissionCallbackAfterAuthorizedReopen() async {
        let driver = Driver()
        var answer: (@Sendable (Bool) -> Void)?
        let model = ShelfMirrorModel(driver: driver, authorization: { .notDetermined }, requestAccess: { answer = $0 })
        defer { model.sync(enabled: false) }
        model.sync(enabled: true)
        model.sync(enabled: false)
        model.authorization = { .authorized }
        model.sync(enabled: true)
        answer?(true)
        while model.permissionRequestPending { await Task.yield() }
        await wait(model, for: .live)
        #expect(driver.counts.prepares == 1)
        #expect(driver.counts.starts == 1)
    }

    @Test("a permission refusal stays visible and retry rechecks a newly allowed camera", .timeLimit(.minutes(2)))
    func retryAfterPermissionChange() async {
        let driver = Driver()
        let model = ShelfMirrorModel(driver: driver, authorization: { .notDetermined },
                                     requestAccess: { $0(false) })
        defer { model.sync(enabled: false) }
        model.sync(enabled: true)
        await wait(model, for: .denied)
        #expect(!model.permissionRequestPending)
        #expect(driver.counts.prepares == 0)
        model.authorization = { .authorized }
        model.retry()
        #expect(model.state == .starting)
        await wait(model, for: .live)
        #expect(driver.counts.starts == 1)
    }

    @Test("closing a starting mirror immediately clears the placeholder and retires queued work",
          .timeLimit(.minutes(2)))
    func closeStartingMirror() async {
        let driver = Driver()
        let queue = DispatchQueue(label: "jrbar.test.mirror-starting-state")
        let model = ShelfMirrorModel(driver: driver, queue: queue, authorization: { .authorized })
        queue.suspend()
        model.sync(enabled: true)
        #expect(model.state == .starting)
        model.sync(enabled: false)
        #expect(model.state == .off)
        queue.resume()
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            queue.async { finished.resume() }
        }
        #expect(driver.counts.prepares == 0)
        #expect(driver.counts.starts == 0)
        #expect(driver.counts.attachments == 0)
        #expect(model.state == .off)
    }
}
