import AppKit
import ScreenCaptureKit
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Dock capture revocation", .serialized)
struct DockCaptureRevocationTests {
    @MainActor
    private final class ImageReply {
        var entered = false
        private var reply: CheckedContinuation<NSImage?, Never>?

        func read() async -> NSImage? {
            entered = true
            return await withCheckedContinuation { reply = $0 }
        }

        func finish(_ image: NSImage?) {
            let pending = reply
            reply = nil
            pending?.resume(returning: image)
        }

        func waitUntilEntered() async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while !entered, clock.now < deadline { await Task.yield() }
            return entered
        }
    }

    private func controller() -> DockEnhanceController {
        let preferences = DockEnhancePreferences()
        preferences.read = {
            var settings = DockEnhanceSettings()
            settings.showThumbnails = true
            return settings
        }
        let controller = DockEnhanceController(preferences: preferences)
        controller.trustProbe = { false }
        controller.captureProbe = { _ in true }
        controller.refreshPermissions(force: true)
        controller.preview.processIdentifier = 12345
        controller.preview.windows = [DockPreviewWindow(
            id: 1, title: "Synthetic window", minimized: false, fullScreen: nil,
            frame: nil, thumbnail: NSImage(size: NSSize(width: 2, height: 2)),
            element: nil, windowID: 98765)]
        return controller
    }

    private func revoke(_ controller: DockEnhanceController) {
        controller.captureProbe = { _ in false }
        controller.refreshPermissions(force: true)
    }

    @Test("a held hover image cannot return after revocation, even after another grant",
          arguments: [false, true])
    func heldHoverReply(restoreGrant: Bool) async throws {
        let controller = controller()
        let reply = ImageReply()
        defer { reply.finish(nil); controller.hidePreview() }
        controller.freshThumbnail = { _, _, _ in await reply.read() }
        let task = try #require(controller.freshenStill(controller.preview.windows[0]))
        let entered = await reply.waitUntilEntered()
        try #require(entered, "synthetic capture did not start")
        let epoch = DockThumbnailer.captureEpoch
        #expect(controller.captureIsCurrent(epoch: epoch, generation: 0))
        revoke(controller)
        #expect(controller.preview.windows[0].thumbnail == nil)
        if restoreGrant {
            controller.captureProbe = { _ in true }
            controller.refreshPermissions(force: true)
        }
        #expect(!controller.captureIsCurrent(epoch: epoch, generation: 0))
        reply.finish(NSImage(size: NSSize(width: 3, height: 3)))
        await task.value
        #expect(controller.preview.windows[0].thumbnail == nil)
    }

    @Test("revocation stops a pending live lookup and refuses frame publication")
    func pendingLiveLookup() async throws {
        let controller = controller()
        let reply = ImageReply()
        defer { reply.finish(nil); controller.hidePreview() }
        controller.liveStill.lookup = { _, _ in
            _ = await reply.read()
            return nil
        }
        controller.liveStill.start(windowID: 98765, pid: 12345)
        let entered = await reply.waitUntilEntered()
        try #require(entered, "synthetic live lookup did not start")
        #expect(controller.liveStill.windowID == 98765)
        revoke(controller)
        #expect(controller.liveStill.windowID == nil)
        controller.liveStill.onFrame?(98765, NSImage(size: NSSize(width: 3, height: 3)))
        #expect(controller.preview.windows[0].thumbnail == nil)
        reply.finish(nil)
    }

    @Test("an old capture cannot refill the shared cache after permission is restored")
    func oldCacheWriteIsRejected() {
        let controller = controller()
        defer { controller.hidePreview() }
        let epoch = DockThumbnailer.captureEpoch
        let image = NSImage(size: NSSize(width: 2, height: 2))
        #expect(DockThumbnailer.cacheCapture(image, pid: 44444, windowID: 55555, tag: nil, epoch: epoch) != nil)
        revoke(controller)
        controller.captureProbe = { _ in true }
        controller.refreshPermissions(force: true)
        #expect(DockThumbnailer.cached(pid: 44444, windowID: 55555) == nil)
        #expect(DockThumbnailer.cacheCapture(image, pid: 44444, windowID: 55555, tag: nil, epoch: epoch) == nil)
        #expect(DockThumbnailer.cached(pid: 44444, windowID: 55555) == nil)
    }

    @Test("shared cache invalidation retires the old hover request without blocking the next")
    func sharedInvalidationAllowsNextHover() async throws {
        let controller = controller()
        let firstReply = ImageReply()
        let nextReply = ImageReply()
        defer { firstReply.finish(nil); nextReply.finish(nil); controller.hidePreview() }
        controller.freshThumbnail = { _, _, _ in await firstReply.read() }
        let firstTask = try #require(controller.freshenStill(controller.preview.windows[0]))
        let firstEntered = await firstReply.waitUntilEntered()
        try #require(firstEntered)
        DockThumbnailer.invalidateCaptures()
        firstReply.finish(NSImage(size: NSSize(width: 3, height: 3)))
        await firstTask.value
        controller.freshThumbnail = { _, _, _ in await nextReply.read() }
        let nextTask = try #require(controller.freshenStill(controller.preview.windows[0]))
        let nextEntered = await nextReply.waitUntilEntered()
        try #require(nextEntered)
        nextReply.finish(nil)
        await nextTask.value
    }

    @Test("a hidden preview's old reply cannot clear the next request's busy marker")
    func oldReplyPreservesNewOwner() async throws {
        let controller = controller()
        let firstReply = ImageReply()
        let nextReply = ImageReply()
        defer { firstReply.finish(nil); nextReply.finish(nil); controller.hidePreview() }
        controller.freshThumbnail = { _, _, _ in await firstReply.read() }
        let firstTask = try #require(controller.freshenStill(controller.preview.windows[0]))
        let firstEntered = await firstReply.waitUntilEntered()
        try #require(firstEntered)
        controller.hidePreview()
        controller.freshThumbnail = { _, _, _ in await nextReply.read() }
        let nextTask = try #require(controller.freshenStill(controller.preview.windows[0]))
        let nextEntered = await nextReply.waitUntilEntered()
        try #require(nextEntered)
        firstReply.finish(nil)
        await firstTask.value
        #expect(controller.freshenStill(controller.preview.windows[0]) == nil)
        nextReply.finish(nil)
        await nextTask.value
    }
}
